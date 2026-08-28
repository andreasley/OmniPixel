import Foundation

/// PNG (Portable Network Graphics), ISO/IEC 15948.
///
/// Decoding supports all standard bit depth/color type combinations (1, 2, 4,
/// 8 and 16 bits per sample), Adam7 interlacing, and tRNS transparency for
/// palette, grayscale and truecolor images. 16-bit samples are reduced to
/// 8 bits. Encoding produces non-interlaced 8-bit RGBA (color type 6) with
/// per-row filter selection.
enum PNGCodec: ImageCodec {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func canDecode(_ data: Data) -> Bool {
        data.count >= signature.count && [UInt8](data.prefix(signature.count)) == signature
    }

    // MARK: Decoding

    private struct Header {
        var width: Int
        var height: Int
        var bitDepth: Int
        var colorType: Int
        var isInterlaced: Bool
    }

    static func decode(_ data: Data) throws -> Image {
        var reader = ByteReader(data)
        guard try reader.readBytes(8) == signature else {
            throw ImageError.invalidData(reason: "Missing PNG signature")
        }

        var header: Header?
        var palette: [RGBA] = []
        var transparency: [UInt8] = []
        var compressedImageData: [UInt8] = []
        var sawEnd = false

        while !sawEnd {
            let length = Int(try reader.readUInt32BigEndian())
            let typeBytes = try reader.readBytes(4)
            let chunkData = try reader.readBytes(length)
            let storedCRC = try reader.readUInt32BigEndian()
            // Checksum the type and the payload as two pieces; joining them
            // would copy every IDAT an extra time.
            var crc = CRC32.update(CRC32.initialValue, with: typeBytes)
            crc = CRC32.update(crc, with: chunkData)
            guard CRC32.finalize(crc) == storedCRC else {
                throw ImageError.invalidData(reason: "PNG chunk CRC mismatch")
            }

            switch String(decoding: typeBytes, as: UTF8.self) {
            case "IHDR":
                header = try parseHeader(chunkData)
            case "PLTE":
                guard chunkData.count % 3 == 0, chunkData.count <= 256 * 3 else {
                    throw ImageError.invalidData(reason: "Invalid PLTE chunk size")
                }
                palette = stride(from: 0, to: chunkData.count, by: 3).map {
                    RGBA(red: chunkData[$0], green: chunkData[$0 + 1], blue: chunkData[$0 + 2])
                }
            case "tRNS":
                transparency = chunkData
            case "IDAT":
                // A single IDAT is the common case, and taking it whole avoids
                // copying it into a growing buffer.
                if compressedImageData.isEmpty {
                    compressedImageData = chunkData
                } else {
                    compressedImageData += chunkData
                }
            case "IEND":
                sawEnd = true
            default:
                break  // Ancillary chunks (text, gamma, …) are ignored.
            }
        }

        guard let header else {
            throw ImageError.invalidData(reason: "Missing IHDR chunk")
        }
        guard !compressedImageData.isEmpty else {
            throw ImageError.invalidData(reason: "Missing IDAT chunk")
        }

        let channels = try channelCount(for: header.colorType)
        var raw = try Inflate.zlibDecompress(
            compressedImageData,
            expectedSize: expectedRawSize(
                for: header,
                channels: channels,
                compressedCount: compressedImageData.count
            )
        )
        return try buildImage(
            header: header,
            channels: channels,
            raw: &raw,
            palette: palette,
            transparency: transparency
        )
    }

    private static func channelCount(for colorType: Int) throws -> Int {
        switch colorType {
        case 0, 3: 1
        case 4: 2
        case 2: 3
        case 6: 4
        default: throw ImageError.invalidData(reason: "Unknown PNG color type")
        }
    }

    private static func parseHeader(_ chunk: [UInt8]) throws -> Header {
        guard chunk.count == 13 else {
            throw ImageError.invalidData(reason: "IHDR must be 13 bytes")
        }
        var reader = ByteReader(chunk)
        let width = Int(try reader.readUInt32BigEndian())
        let height = Int(try reader.readUInt32BigEndian())
        let bitDepth = Int(try reader.readByte())
        let colorType = Int(try reader.readByte())
        let compression = try reader.readByte()
        let filter = try reader.readByte()
        let interlace = try reader.readByte()

        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, pixelCount <= Image.maxPixelCount else {
            throw ImageError.invalidData(reason: "Invalid PNG dimensions")
        }
        guard compression == 0, filter == 0 else {
            throw ImageError.invalidData(reason: "Unknown PNG compression or filter method")
        }
        guard interlace <= 1 else {
            throw ImageError.invalidData(reason: "Unknown PNG interlace method")
        }

        let validDepths: [Int: [Int]] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
        guard let depths = validDepths[colorType], depths.contains(bitDepth) else {
            throw ImageError.invalidData(reason: "Invalid PNG bit depth/color type combination")
        }
        return Header(
            width: width,
            height: height,
            bitDepth: bitDepth,
            colorType: colorType,
            isInterlaced: interlace == 1
        )
    }

    /// The origin and step of the pixel grid each Adam7 pass covers.
    private struct Pass {
        var xStart: Int
        var yStart: Int
        var xStep: Int
        var yStep: Int
    }

    private static let adam7Passes = [
        Pass(xStart: 0, yStart: 0, xStep: 8, yStep: 8),
        Pass(xStart: 4, yStart: 0, xStep: 8, yStep: 8),
        Pass(xStart: 0, yStart: 4, xStep: 4, yStep: 8),
        Pass(xStart: 2, yStart: 0, xStep: 4, yStep: 4),
        Pass(xStart: 0, yStart: 2, xStep: 2, yStep: 4),
        Pass(xStart: 1, yStart: 0, xStep: 2, yStep: 2),
        Pass(xStart: 0, yStart: 1, xStep: 1, yStep: 2),
    ]

    private static func passes(for header: Header) -> [Pass] {
        header.isInterlaced ? adam7Passes : [Pass(xStart: 0, yStart: 0, xStep: 1, yStep: 1)]
    }

    /// The size in bytes of one pass's filtered rows, or zero if the pass
    /// stores nothing.
    private static func passSize(_ pass: Pass, header: Header, bitsPerPixel: Int) -> (width: Int, height: Int, bytesPerRow: Int) {
        let width = pass.xStart < header.width
            ? (header.width - pass.xStart + pass.xStep - 1) / pass.xStep
            : 0
        let height = pass.yStart < header.height
            ? (header.height - pass.yStart + pass.yStep - 1) / pass.yStep
            : 0
        guard width > 0, height > 0 else { return (0, 0, 0) }
        return (width, height, (width * bitsPerPixel + 7) / 8)
    }

    /// The exact length of the unfiltered stream the header implies: a filter
    /// byte plus a packed row for every row of every pass.
    private static func rawSize(for header: Header, channels: Int) -> Int {
        let bitsPerPixel = header.bitDepth * channels
        var total = 0
        for pass in passes(for: header) {
            let size = passSize(pass, header: header, bitsPerPixel: bitsPerPixel)
            total += size.height * (size.bytesPerRow + 1)
        }
        return total
    }

    /// The same figure as a hint for sizing the inflate buffer once. It is
    /// capped both absolutely and by what this much compressed data could
    /// possibly expand to — DEFLATE's best case is a little over 1000:1 — so a
    /// tiny IDAT claiming huge dimensions cannot reserve megabytes it could
    /// never fill. A hint that turns out too small merely grows.
    private static func expectedRawSize(for header: Header, channels: Int, compressedCount: Int) -> Int {
        let ceiling = min(64 << 20, max(4096, compressedCount * 1032))
        return min(rawSize(for: header, channels: channels), ceiling)
    }

    /// Unfilters the raw stream in place and converts it to pixels. Rows are
    /// reconstructed where they already sit in `raw`, so the row above is just
    /// a pointer backwards and nothing is copied per row.
    private static func buildImage(
        header: Header,
        channels: Int,
        raw: inout [UInt8],
        palette: [RGBA],
        transparency: [UInt8]
    ) throws -> Image {
        let bitsPerPixel = header.bitDepth * channels
        // Filters operate on bytes; sub-byte depths use a distance of one byte.
        let filterDistance = max(1, bitsPerPixel / 8)

        // The header decides the size of the pixel buffer, which for the largest
        // image we accept is a gigabyte. Check it against the data we actually
        // have before allocating any of it, so a few bytes claiming huge
        // dimensions are rejected rather than honoured.
        guard raw.count == rawSize(for: header, channels: channels) else {
            throw ImageError.invalidData(reason: "PNG image data doesn't match its dimensions")
        }

        var pixels = [RGBA](repeating: .transparent, count: header.width * header.height)
        let converter = RowConverter(
            header: header,
            channels: channels,
            palette: palette,
            transparency: transparency
        )
        // The first row of every pass filters against an imaginary row of zeros.
        let zeroRow = [UInt8](repeating: 0, count: (header.width * bitsPerPixel + 7) / 8 + 1)

        var consumed = 0
        let rawCount = raw.count
        try raw.withUnsafeMutableBufferPointer { rawBuffer in
            try pixels.withUnsafeMutableBufferPointer { pixelBuffer in
                try zeroRow.withUnsafeBufferPointer { zeros in
                    let rawBase = rawBuffer.baseAddress!
                    let pixelBase = pixelBuffer.baseAddress!
                    let zeroBase = zeros.baseAddress!

                    for pass in passes(for: header) {
                        // Each pass is filtered like an independent image of its own size.
                        let size = passSize(pass, header: header, bitsPerPixel: bitsPerPixel)
                        guard size.height > 0 else { continue }  // empty passes store nothing
                        guard rawCount - consumed >= size.height * (size.bytesPerRow + 1) else {
                            throw ImageError.invalidData(reason: "PNG image data doesn't match its dimensions")
                        }

                        for rowIndex in 0..<size.height {
                            let filterType = rawBase[consumed]
                            let row = rawBase + consumed + 1
                            let previous = rowIndex == 0 ? zeroBase : UnsafePointer(row - (size.bytesPerRow + 1))
                            try unfilter(
                                row,
                                previous: previous,
                                count: size.bytesPerRow,
                                filterType: filterType,
                                distance: filterDistance
                            )
                            consumed += size.bytesPerRow + 1

                            let y = pass.yStart + rowIndex * pass.yStep
                            try converter.convert(
                                row,
                                into: pixelBase + y * header.width + pass.xStart,
                                step: pass.xStep,
                                count: size.width
                            )
                        }
                    }
                }
            }
        }

        guard consumed == rawCount else {
            throw ImageError.invalidData(reason: "PNG image data doesn't match its dimensions")
        }
        return Image(width: header.width, height: header.height, pixels: pixels)
    }

    /// Turns unfiltered row bytes into pixels. Everything that depends only on
    /// the header — the sample scaling, the tRNS colors — is resolved once here
    /// instead of once per row.
    private struct RowConverter {
        private let bitDepth: Int
        private let colorType: Int
        private let channels: Int
        private let palette: [RGBA]
        private let transparency: [UInt8]
        private let maxSample: Int
        private let transparentGray: Int?
        private let transparentColor: (red: Int, green: Int, blue: Int)?

        init(header: Header, channels: Int, palette: [RGBA], transparency: [UInt8]) {
            bitDepth = header.bitDepth
            colorType = header.colorType
            self.channels = channels
            self.palette = palette
            self.transparency = transparency
            maxSample = (1 << header.bitDepth) - 1

            // tRNS for grayscale/truecolor names one fully transparent color, with
            // each component stored as two bytes regardless of bit depth. Matching
            // uses the full-precision samples so 16-bit colors compare exactly.
            transparentGray = header.colorType == 0 && transparency.count >= 2
                ? Int(transparency[0]) << 8 | Int(transparency[1])
                : nil
            transparentColor = header.colorType == 2 && transparency.count >= 6
                ? (
                    red: Int(transparency[0]) << 8 | Int(transparency[1]),
                    green: Int(transparency[2]) << 8 | Int(transparency[3]),
                    blue: Int(transparency[4]) << 8 | Int(transparency[5])
                )
                : nil
        }

        /// Writes `count` pixels, `step` apart, starting at `destination`
        /// (Adam7 passes land on a sparse grid).
        func convert(
            _ row: UnsafePointer<UInt8>,
            into destination: UnsafeMutablePointer<RGBA>,
            step: Int,
            count: Int
        ) throws {
            // Eight-bit truecolor needs no scaling and no sample unpacking, and
            // is what almost every real file uses.
            if bitDepth == 8, colorType == 6 {
                for x in 0..<count {
                    let base = x * 4
                    destination[x * step] = RGBA(
                        red: row[base],
                        green: row[base + 1],
                        blue: row[base + 2],
                        alpha: row[base + 3]
                    )
                }
            } else if bitDepth == 8, colorType == 2, transparentColor == nil {
                for x in 0..<count {
                    let base = x * 3
                    destination[x * step] = RGBA(red: row[base], green: row[base + 1], blue: row[base + 2])
                }
            } else {
                try convertGeneral(row, into: destination, step: step, count: count)
            }
        }

        private func convertGeneral(
            _ row: UnsafePointer<UInt8>,
            into destination: UnsafeMutablePointer<RGBA>,
            step: Int,
            count: Int
        ) throws {
            for x in 0..<count {
                let base = x * channels
                switch colorType {
                case 0:
                    let gray = sample(row, base)
                    let value = scaled(gray)
                    destination[x * step] = RGBA(
                        red: value,
                        green: value,
                        blue: value,
                        alpha: gray == transparentGray ? 0 : 255
                    )
                case 2:
                    let red = sample(row, base)
                    let green = sample(row, base + 1)
                    let blue = sample(row, base + 2)
                    var pixel = RGBA(red: scaled(red), green: scaled(green), blue: scaled(blue))
                    if let transparentColor,
                       red == transparentColor.red,
                       green == transparentColor.green,
                       blue == transparentColor.blue {
                        pixel.alpha = 0
                    }
                    destination[x * step] = pixel
                case 3:
                    let index = sample(row, base)
                    guard index < palette.count else {
                        throw ImageError.invalidData(reason: "PNG palette index out of range")
                    }
                    var pixel = palette[index]
                    if index < transparency.count {
                        pixel.alpha = transparency[index]
                    }
                    destination[x * step] = pixel
                case 4:
                    let value = scaled(sample(row, base))
                    destination[x * step] = RGBA(
                        red: value,
                        green: value,
                        blue: value,
                        alpha: scaled(sample(row, base + 1))
                    )
                default:  // 6, already validated
                    destination[x * step] = RGBA(
                        red: scaled(sample(row, base)),
                        green: scaled(sample(row, base + 1)),
                        blue: scaled(sample(row, base + 2)),
                        alpha: scaled(sample(row, base + 3))
                    )
                }
            }
        }

        /// Reads one sample at full precision: sub-byte samples are packed most
        /// significant bits first, 16-bit samples are big-endian.
        @inline(__always)
        private func sample(_ row: UnsafePointer<UInt8>, _ index: Int) -> Int {
            switch bitDepth {
            case 8:
                return Int(row[index])
            case 16:
                return Int(row[index * 2]) << 8 | Int(row[index * 2 + 1])
            default:
                let bitPosition = index * bitDepth
                let shift = 8 - bitDepth - bitPosition % 8
                return Int(row[bitPosition / 8] >> shift) & maxSample
            }
        }

        /// Reduces a full-precision sample to 8 bits.
        @inline(__always)
        private func scaled(_ value: Int) -> UInt8 {
            switch bitDepth {
            case 16: UInt8(value >> 8)
            case 8: UInt8(value)
            default: UInt8(value * 255 / maxSample)
            }
        }
    }

    // MARK: Filters

    /// Reverses one row's filter in place. `previous` points at the already
    /// unfiltered row above, or at zeros for the first row of a pass.
    private static func unfilter(
        _ row: UnsafeMutablePointer<UInt8>,
        previous: UnsafePointer<UInt8>,
        count: Int,
        filterType: UInt8,
        distance: Int
    ) throws {
        // The first `distance` bytes have no left neighbour, so the predictors
        // that use one degenerate; splitting them out keeps the main loop clean.
        let leading = min(distance, count)
        switch filterType {
        case 0:
            break
        case 1:  // Sub
            for i in leading..<count {
                row[i] &+= row[i - distance]
            }
        case 2:  // Up
            for i in 0..<count {
                row[i] &+= previous[i]
            }
        case 3:  // Average
            for i in 0..<leading {
                row[i] &+= previous[i] >> 1
            }
            for i in leading..<count {
                row[i] &+= UInt8((UInt32(row[i - distance]) + UInt32(previous[i])) >> 1)
            }
        case 4:  // Paeth
            for i in 0..<leading {
                // With left and up-left both zero, Paeth always predicts up.
                row[i] &+= previous[i]
            }
            for i in leading..<count {
                row[i] &+= paethPredictor(
                    left: row[i - distance],
                    up: previous[i],
                    upLeft: previous[i - distance]
                )
            }
        default:
            throw ImageError.invalidData(reason: "Unknown PNG filter type")
        }
    }

    @inline(__always)
    private static func paethPredictor(left: UInt8, up: UInt8, upLeft: UInt8) -> UInt8 {
        let a = Int(left)
        let b = Int(up)
        let c = Int(upLeft)
        let p = a + b - c
        let pa = abs(p - a)
        let pb = abs(p - b)
        let pc = abs(p - c)
        if pa <= pb && pa <= pc { return left }
        if pb <= pc { return up }
        return upLeft
    }

    // MARK: Encoding

    static func encode(_ image: Image) throws -> Data {
        try encode(image, options: EncodingOptions())
    }

    static func encode(_ image: Image, options: EncodingOptions) throws -> Data {
        guard let width = UInt32(exactly: image.width), let height = UInt32(exactly: image.height) else {
            throw ImageError.invalidDimensions
        }

        var writer = ByteWriter()
        writer.writeBytes(signature)

        var ihdr = ByteWriter()
        ihdr.writeUInt32BigEndian(width)
        ihdr.writeUInt32BigEndian(height)
        ihdr.writeBytes([8, 6, 0, 0, 0])  // 8-bit RGBA, deflate, standard filtering, no interlace
        writeChunk(type: "IHDR", data: ihdr.bytes, to: &writer)

        if let exif = options.exif, !exif.isEmpty {
            writeChunk(type: "eXIf", data: exif.serializedPayload(), to: &writer)
        }

        writeChunk(type: "IDAT", data: Deflate.zlibCompress(filteredRows(of: image)), to: &writer)
        writeChunk(type: "IEND", data: [], to: &writer)
        return writer.data
    }

    /// Builds the filtered byte stream DEFLATE compresses: one filter-type byte
    /// per row followed by that row's residuals.
    private static func filteredRows(of image: Image) -> [UInt8] {
        let bytesPerRow = image.width * 4
        var raw = [UInt8](repeating: 0, count: image.height * (bytesPerRow + 1))
        // The current and previous unfiltered rows, back to back. The previous
        // row starts out zeroed, which is what PNG assumes above the image.
        var rows = [UInt8](repeating: 0, count: 2 * bytesPerRow)
        var candidates = [UInt8](repeating: 0, count: 5 * bytesPerRow)

        image.pixels.withUnsafeBufferPointer { pixels in
            raw.withUnsafeMutableBufferPointer { rawBuffer in
                rows.withUnsafeMutableBufferPointer { rowBuffer in
                    candidates.withUnsafeMutableBufferPointer { candidateBuffer in
                        var current = rowBuffer.baseAddress!
                        var previous = current + bytesPerRow
                        var output = rawBuffer.baseAddress!
                        let source = pixels.baseAddress!

                        for y in 0..<image.height {
                            let rowPixels = source + y * image.width
                            for x in 0..<image.width {
                                let pixel = rowPixels[x]
                                current[x * 4] = pixel.red
                                current[x * 4 + 1] = pixel.green
                                current[x * 4 + 2] = pixel.blue
                                current[x * 4 + 3] = pixel.alpha
                            }
                            let choice = chooseFilter(
                                row: current,
                                previous: previous,
                                count: bytesPerRow,
                                candidates: candidateBuffer.baseAddress!
                            )
                            output.pointee = choice.type
                            (output + 1).update(from: choice.bytes, count: bytesPerRow)
                            output += bytesPerRow + 1
                            swap(&current, &previous)
                        }
                    }
                }
            }
        }
        return raw
    }

    /// Filters the row all five ways and keeps the one whose output has the
    /// smallest sum of absolute residuals (libpng's selection heuristic) —
    /// small residuals are what DEFLATE compresses best.
    ///
    /// The five candidates are produced in one pass, so each source byte and its
    /// neighbours are read once and the scratch buffer is reused across rows.
    private static func chooseFilter(
        row: UnsafePointer<UInt8>,
        previous: UnsafePointer<UInt8>,
        count: Int,
        candidates: UnsafeMutablePointer<UInt8>
    ) -> (type: UInt8, bytes: UnsafePointer<UInt8>) {
        let distance = 4
        let none = candidates
        let sub = candidates + count
        let up = candidates + 2 * count
        let average = candidates + 3 * count
        let paeth = candidates + 4 * count

        var noneScore = 0
        var subScore = 0
        var upScore = 0
        var averageScore = 0
        var paethScore = 0

        for i in 0..<count {
            let value = row[i]
            let left = i >= distance ? row[i - distance] : 0
            let above = previous[i]
            let aboveLeft = i >= distance ? previous[i - distance] : 0

            let subValue = value &- left
            let upValue = value &- above
            let averageValue = value &- UInt8((UInt32(left) + UInt32(above)) >> 1)
            let paethValue = value &- paethPredictor(left: left, up: above, upLeft: aboveLeft)

            none[i] = value
            sub[i] = subValue
            up[i] = upValue
            average[i] = averageValue
            paeth[i] = paethValue

            noneScore += residual(value)
            subScore += residual(subValue)
            upScore += residual(upValue)
            averageScore += residual(averageValue)
            paethScore += residual(paethValue)
        }

        // Ties go to the lower filter type.
        var bestType: UInt8 = 0
        var bestScore = noneScore
        var best = UnsafePointer(none)
        if subScore < bestScore {
            (bestType, bestScore, best) = (1, subScore, UnsafePointer(sub))
        }
        if upScore < bestScore {
            (bestType, bestScore, best) = (2, upScore, UnsafePointer(up))
        }
        if averageScore < bestScore {
            (bestType, bestScore, best) = (3, averageScore, UnsafePointer(average))
        }
        if paethScore < bestScore {
            (bestType, best) = (4, UnsafePointer(paeth))
        }
        return (bestType, best)
    }

    /// Absolute value of a filtered byte, read as signed.
    @inline(__always)
    private static func residual(_ byte: UInt8) -> Int {
        let value = Int(byte)
        return min(value, 256 - value)
    }

    private static func writeChunk(type: String, data: [UInt8], to writer: inout ByteWriter) {
        let typeBytes = Array(type.utf8)
        writer.writeUInt32BigEndian(UInt32(data.count))
        writer.writeBytes(typeBytes)
        writer.writeBytes(data)
        var crc = CRC32.update(CRC32.initialValue, with: typeBytes)
        crc = CRC32.update(crc, with: data)
        writer.writeUInt32BigEndian(CRC32.finalize(crc))
    }
}
