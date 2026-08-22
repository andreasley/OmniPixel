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
            guard CRC32.checksum(of: typeBytes + chunkData) == storedCRC else {
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
                compressedImageData += chunkData
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

        let raw = try Inflate.zlibDecompress(compressedImageData)
        return try buildImage(header: header, raw: raw, palette: palette, transparency: transparency)
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

    private static func buildImage(header: Header, raw: [UInt8], palette: [RGBA], transparency: [UInt8]) throws -> Image {
        let channels: Int
        switch header.colorType {
        case 0, 3: channels = 1
        case 4: channels = 2
        case 2: channels = 3
        case 6: channels = 4
        default: throw ImageError.invalidData(reason: "Unknown PNG color type")
        }
        let bitsPerPixel = header.bitDepth * channels
        // Filters operate on bytes; sub-byte depths use a distance of one byte.
        let filterDistance = max(1, bitsPerPixel / 8)
        let passes = header.isInterlaced
            ? adam7Passes
            : [Pass(xStart: 0, yStart: 0, xStep: 1, yStep: 1)]

        var pixels = [RGBA](repeating: .transparent, count: header.width * header.height)
        var offset = 0

        for pass in passes {
            // Each pass is filtered like an independent image of its own size.
            let passWidth = pass.xStart < header.width
                ? (header.width - pass.xStart + pass.xStep - 1) / pass.xStep
                : 0
            let passHeight = pass.yStart < header.height
                ? (header.height - pass.yStart + pass.yStep - 1) / pass.yStep
                : 0
            guard passWidth > 0, passHeight > 0 else { continue }  // empty passes store nothing

            let bytesPerRow = (passWidth * bitsPerPixel + 7) / 8
            guard raw.count - offset >= passHeight * (bytesPerRow + 1) else {
                throw ImageError.invalidData(reason: "PNG image data doesn't match its dimensions")
            }
            var previousRow = [UInt8](repeating: 0, count: bytesPerRow)

            for rowIndex in 0..<passHeight {
                let filterType = raw[offset]
                var row = Array(raw[(offset + 1)...(offset + bytesPerRow)])
                offset += bytesPerRow + 1
                try unfilter(&row, previous: previousRow, filterType: filterType, distance: filterDistance)
                previousRow = row

                let samples = extractSamples(from: row, bitDepth: header.bitDepth, count: passWidth * channels)
                let rowPixels = try convertRow(
                    samples: samples,
                    header: header,
                    channels: channels,
                    palette: palette,
                    transparency: transparency
                )

                let y = pass.yStart + rowIndex * pass.yStep
                for (i, pixel) in rowPixels.enumerated() {
                    pixels[y * header.width + pass.xStart + i * pass.xStep] = pixel
                }
            }
        }

        guard offset == raw.count else {
            throw ImageError.invalidData(reason: "PNG image data doesn't match its dimensions")
        }
        return Image(width: header.width, height: header.height, pixels: pixels)
    }

    /// Extracts full-precision samples from an unfiltered row: sub-byte samples
    /// are packed most significant bits first, 16-bit samples are big-endian.
    private static func extractSamples(from row: [UInt8], bitDepth: Int, count: Int) -> [Int] {
        var samples: [Int] = []
        samples.reserveCapacity(count)
        switch bitDepth {
        case 8:
            for i in 0..<count {
                samples.append(Int(row[i]))
            }
        case 16:
            for i in 0..<count {
                samples.append(Int(row[i * 2]) << 8 | Int(row[i * 2 + 1]))
            }
        default:
            let mask = (1 << bitDepth) - 1
            var bitPosition = 0
            while samples.count < count {
                let shift = 8 - bitDepth - (bitPosition % 8)
                samples.append(Int(row[bitPosition / 8] >> shift) & mask)
                bitPosition += bitDepth
            }
        }
        return samples
    }

    private static func convertRow(
        samples: [Int],
        header: Header,
        channels: Int,
        palette: [RGBA],
        transparency: [UInt8]
    ) throws -> [RGBA] {
        // Reduce a full-precision sample to 8 bits.
        let maxSample = (1 << header.bitDepth) - 1
        func scaled(_ value: Int) -> UInt8 {
            switch header.bitDepth {
            case 16: UInt8(value >> 8)
            case 8: UInt8(value)
            default: UInt8(value * 255 / maxSample)
            }
        }

        // tRNS for grayscale/truecolor names one fully transparent color, with
        // each component stored as two bytes regardless of bit depth. Matching
        // uses the full-precision samples so 16-bit colors compare exactly.
        var transparentGray: Int?
        var transparentColor: (red: Int, green: Int, blue: Int)?
        if header.colorType == 0, transparency.count >= 2 {
            transparentGray = Int(transparency[0]) << 8 | Int(transparency[1])
        }
        if header.colorType == 2, transparency.count >= 6 {
            transparentColor = (
                red: Int(transparency[0]) << 8 | Int(transparency[1]),
                green: Int(transparency[2]) << 8 | Int(transparency[3]),
                blue: Int(transparency[4]) << 8 | Int(transparency[5])
            )
        }

        let width = samples.count / channels
        var pixels: [RGBA] = []
        pixels.reserveCapacity(width)

        for x in 0..<width {
            let base = x * channels
            switch header.colorType {
            case 0:
                let value = scaled(samples[base])
                let alpha: UInt8 = samples[base] == transparentGray ? 0 : 255
                pixels.append(RGBA(red: value, green: value, blue: value, alpha: alpha))
            case 2:
                var pixel = RGBA(
                    red: scaled(samples[base]),
                    green: scaled(samples[base + 1]),
                    blue: scaled(samples[base + 2])
                )
                if let transparentColor,
                   samples[base] == transparentColor.red,
                   samples[base + 1] == transparentColor.green,
                   samples[base + 2] == transparentColor.blue {
                    pixel.alpha = 0
                }
                pixels.append(pixel)
            case 3:
                let index = samples[base]
                guard index < palette.count else {
                    throw ImageError.invalidData(reason: "PNG palette index out of range")
                }
                var color = palette[index]
                if index < transparency.count {
                    color.alpha = transparency[index]
                }
                pixels.append(color)
            case 4:
                let value = scaled(samples[base])
                pixels.append(RGBA(red: value, green: value, blue: value, alpha: scaled(samples[base + 1])))
            default:  // 6, already validated
                pixels.append(RGBA(
                    red: scaled(samples[base]),
                    green: scaled(samples[base + 1]),
                    blue: scaled(samples[base + 2]),
                    alpha: scaled(samples[base + 3])
                ))
            }
        }
        return pixels
    }

    // MARK: Filters

    private static func unfilter(_ row: inout [UInt8], previous: [UInt8], filterType: UInt8, distance: Int) throws {
        switch filterType {
        case 0:
            break
        case 1:  // Sub
            for i in row.indices where i >= distance {
                row[i] &+= row[i - distance]
            }
        case 2:  // Up
            for i in row.indices {
                row[i] &+= previous[i]
            }
        case 3:  // Average
            for i in row.indices {
                let left = i >= distance ? Int(row[i - distance]) : 0
                row[i] &+= UInt8((left + Int(previous[i])) / 2)
            }
        case 4:  // Paeth
            for i in row.indices {
                let left = i >= distance ? row[i - distance] : 0
                let upLeft = i >= distance ? previous[i - distance] : 0
                row[i] &+= paethPredictor(left: left, up: previous[i], upLeft: upLeft)
            }
        default:
            throw ImageError.invalidData(reason: "Unknown PNG filter type")
        }
    }

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

        let bytesPerRow = image.width * 4
        var raw: [UInt8] = []
        raw.reserveCapacity(image.height * (bytesPerRow + 1))
        var previousRow = [UInt8](repeating: 0, count: bytesPerRow)
        var currentRow = [UInt8](repeating: 0, count: bytesPerRow)

        for y in 0..<image.height {
            for x in 0..<image.width {
                let pixel = image.pixels[y * image.width + x]
                currentRow[x * 4] = pixel.red
                currentRow[x * 4 + 1] = pixel.green
                currentRow[x * 4 + 2] = pixel.blue
                currentRow[x * 4 + 3] = pixel.alpha
            }
            let best = bestFilter(for: currentRow, previous: previousRow, distance: 4)
            raw.append(best.type)
            raw += best.bytes
            swap(&previousRow, &currentRow)
        }

        writeChunk(type: "IDAT", data: Deflate.zlibCompress(raw), to: &writer)
        writeChunk(type: "IEND", data: [], to: &writer)
        return writer.data
    }

    /// Filters the row all five ways and keeps the one whose output has the
    /// smallest sum of absolute residuals (libpng's selection heuristic) —
    /// small residuals are what DEFLATE compresses best.
    private static func bestFilter(for row: [UInt8], previous: [UInt8], distance: Int) -> (type: UInt8, bytes: [UInt8]) {
        var bestType: UInt8 = 0
        var bestBytes = row
        var bestScore = residualScore(of: row)

        for filterType: UInt8 in 1...4 {
            var filtered = [UInt8](repeating: 0, count: row.count)
            for i in row.indices {
                let left = i >= distance ? row[i - distance] : 0
                let up = previous[i]
                let prediction: UInt8
                switch filterType {
                case 1:
                    prediction = left
                case 2:
                    prediction = up
                case 3:
                    prediction = UInt8((Int(left) + Int(up)) / 2)
                default:
                    let upLeft = i >= distance ? previous[i - distance] : 0
                    prediction = paethPredictor(left: left, up: up, upLeft: upLeft)
                }
                filtered[i] = row[i] &- prediction
            }
            let score = residualScore(of: filtered)
            if score < bestScore {
                bestType = filterType
                bestBytes = filtered
                bestScore = score
            }
        }
        return (bestType, bestBytes)
    }

    /// Sum of absolute values, interpreting each filtered byte as signed.
    private static func residualScore(of bytes: [UInt8]) -> Int {
        var total = 0
        for byte in bytes {
            total += min(Int(byte), 256 - Int(byte))
        }
        return total
    }

    private static func writeChunk(type: String, data: [UInt8], to writer: inout ByteWriter) {
        let typeBytes = Array(type.utf8)
        writer.writeUInt32BigEndian(UInt32(data.count))
        writer.writeBytes(typeBytes)
        writer.writeBytes(data)
        writer.writeUInt32BigEndian(CRC32.checksum(of: typeBytes + data))
    }
}
