import Foundation

/// TIFF (Tag Image File Format), revision 6.0, strip-based baseline.
///
/// Decoding supports both byte orders; no compression, PackBits, LZW and
/// Deflate/zlib; grayscale (including min-is-white), RGB and palette
/// photometrics; 8- and 16-bit samples (16-bit reduces to 8); alpha via
/// extra samples; and the horizontal-differencing predictor. Tiled, planar
/// and CCITT/JPEG-compressed TIFFs are not supported. Encoding produces a
/// single-strip uncompressed 8-bit RGBA little-endian TIFF.
enum TIFFCodec: ImageCodec {
    static func canDecode(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let bytes = [UInt8](data.prefix(4))
        return (bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 42 && bytes[3] == 0)
            || (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0 && bytes[3] == 42)
    }

    // MARK: Decoding

    /// Bounds-checked random-access reads honoring the file's byte order.
    private struct Cursor {
        let bytes: [UInt8]
        let isLittleEndian: Bool

        func byte(at offset: Int) throws -> Int {
            guard offset >= 0, offset < bytes.count else {
                throw ImageError.invalidData(reason: "TIFF offset out of range")
            }
            return Int(bytes[offset])
        }

        func u16(at offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= bytes.count else {
                throw ImageError.invalidData(reason: "TIFF offset out of range")
            }
            let a = Int(bytes[offset])
            let b = Int(bytes[offset + 1])
            return isLittleEndian ? a | b << 8 : a << 8 | b
        }

        func u32(at offset: Int) throws -> Int {
            guard offset >= 0, offset + 4 <= bytes.count else {
                throw ImageError.invalidData(reason: "TIFF offset out of range")
            }
            let a = Int(bytes[offset])
            let b = Int(bytes[offset + 1])
            let c = Int(bytes[offset + 2])
            let d = Int(bytes[offset + 3])
            return isLittleEndian
                ? a | b << 8 | c << 16 | d << 24
                : a << 24 | b << 16 | c << 8 | d
        }
    }

    private struct Entry {
        var type: Int
        var count: Int
        var valueOffset: Int  // offset of the entry's 4-byte value field
    }

    /// Reads an entry's values (BYTE/SHORT/LONG), inline or via offset.
    private static func values(of entry: Entry, cursor: Cursor) throws -> [Int] {
        let size: Int
        switch entry.type {
        case 1, 2, 6, 7: size = 1
        case 3: size = 2
        case 4: size = 4
        default:
            throw ImageError.unsupportedFeature(reason: "Unsupported TIFF field type \(entry.type)")
        }
        guard entry.count >= 0, entry.count <= 1 << 24 else {
            throw ImageError.invalidData(reason: "Unreasonable TIFF field count")
        }
        let start = size * entry.count <= 4 ? entry.valueOffset : try cursor.u32(at: entry.valueOffset)
        var result: [Int] = []
        result.reserveCapacity(entry.count)
        for i in 0..<entry.count {
            switch size {
            case 1: result.append(try cursor.byte(at: start + i))
            case 2: result.append(try cursor.u16(at: start + i * 2))
            default: result.append(try cursor.u32(at: start + i * 4))
            }
        }
        return result
    }

    static func decode(_ data: Data) throws -> Image {
        guard canDecode(data) else {
            throw ImageError.invalidData(reason: "Missing TIFF header")
        }
        let bytes = [UInt8](data)
        let cursor = Cursor(bytes: bytes, isLittleEndian: bytes[0] == 0x49)

        let ifdOffset = try cursor.u32(at: 4)
        let entryCount = try cursor.u16(at: ifdOffset)
        var entries: [Int: Entry] = [:]
        for i in 0..<entryCount {
            let base = ifdOffset + 2 + i * 12
            entries[try cursor.u16(at: base)] = Entry(
                type: try cursor.u16(at: base + 2),
                count: try cursor.u32(at: base + 4),
                valueOffset: base + 8
            )
        }
        func tag(_ id: Int) throws -> [Int]? {
            guard let entry = entries[id] else { return nil }
            return try values(of: entry, cursor: cursor)
        }

        guard entries[322] == nil, entries[323] == nil else {
            throw ImageError.unsupportedFeature(reason: "Tiled TIFF is not supported")
        }
        guard let width = try tag(256)?.first, let height = try tag(257)?.first else {
            throw ImageError.invalidData(reason: "TIFF is missing its dimensions")
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, pixelCount <= Image.maxPixelCount else {
            throw ImageError.invalidData(reason: "Invalid TIFF dimensions")
        }

        let samplesPerPixel = try tag(277)?.first ?? 1
        guard (1...4).contains(samplesPerPixel) else {
            throw ImageError.unsupportedFeature(reason: "\(samplesPerPixel) samples per TIFF pixel is not supported")
        }
        let bitsPerSample = try tag(258) ?? [1]
        guard let bits = bitsPerSample.first,
              bitsPerSample.allSatisfy({ $0 == bits }),
              bits == 8 || bits == 16 else {
            throw ImageError.unsupportedFeature(reason: "Only 8- and 16-bit TIFF samples are supported")
        }
        guard let photometric = try tag(262)?.first else {
            throw ImageError.invalidData(reason: "TIFF is missing its photometric interpretation")
        }
        guard (try tag(284)?.first ?? 1) == 1 else {
            throw ImageError.unsupportedFeature(reason: "Planar TIFF is not supported")
        }
        guard (try tag(339)?.first ?? 1) == 1 else {
            throw ImageError.unsupportedFeature(reason: "Only unsigned TIFF samples are supported")
        }
        let compression = try tag(259)?.first ?? 1
        let predictor = try tag(317)?.first ?? 1
        guard predictor == 1 || predictor == 2 else {
            throw ImageError.unsupportedFeature(reason: "TIFF predictor \(predictor) is not supported")
        }
        guard let stripOffsets = try tag(273),
              let stripByteCounts = try tag(279),
              stripOffsets.count == stripByteCounts.count,
              !stripOffsets.isEmpty else {
            throw ImageError.invalidData(reason: "Invalid TIFF strip layout")
        }
        let rowsPerStrip = min(try tag(278)?.first ?? height, height)
        guard rowsPerStrip > 0 else {
            throw ImageError.invalidData(reason: "Invalid TIFF rows per strip")
        }

        switch photometric {
        case 0, 1:
            break  // grayscale (optionally with alpha)
        case 2:
            guard samplesPerPixel >= 3 else {
                throw ImageError.invalidData(reason: "RGB TIFF with too few samples")
            }
        case 3:
            guard samplesPerPixel == 1, bits == 8 else {
                throw ImageError.unsupportedFeature(reason: "Only 8-bit palette TIFF is supported")
            }
        default:
            throw ImageError.unsupportedFeature(reason: "TIFF photometric \(photometric) is not supported")
        }

        // Decompress all strips into one contiguous raster.
        let bytesPerSample = bits / 8
        let rowBytes = width * samplesPerPixel * bytesPerSample
        var raster: [UInt8] = []
        // Bounded reservation: the size derives from header fields, ahead of
        // reading any strip. See the note in GIFLZW.decompress.
        raster.reserveCapacity(min(rowBytes * height, 1 << 22))
        var rowsRemaining = height

        for stripIndex in stripOffsets.indices where rowsRemaining > 0 {
            let rows = min(rowsPerStrip, rowsRemaining)
            rowsRemaining -= rows
            let expected = rows * rowBytes
            let offset = stripOffsets[stripIndex]
            let count = stripByteCounts[stripIndex]
            guard offset >= 0, count >= 0, offset + count <= bytes.count else {
                throw ImageError.invalidData(reason: "TIFF strip lies outside the file")
            }
            let stripData = Array(bytes[offset..<offset + count])

            var decoded: [UInt8]
            switch compression {
            case 1:
                decoded = stripData
            case 5:
                decoded = try TIFFLZW.decompress(stripData, expectedCount: expected)
            case 8, 32946:
                decoded = try Inflate.zlibDecompress(stripData)
            case 32773:
                decoded = try unpackBits(stripData, expectedCount: expected)
            case 2, 3, 4:
                throw ImageError.unsupportedFeature(reason: "CCITT-compressed TIFF is not supported")
            case 6, 7:
                throw ImageError.unsupportedFeature(reason: "JPEG-compressed TIFF is not supported")
            default:
                throw ImageError.unsupportedFeature(reason: "TIFF compression \(compression) is not supported")
            }
            guard decoded.count >= expected else {
                throw ImageError.invalidData(reason: "TIFF strip data ended early")
            }
            decoded.removeLast(decoded.count - expected)
            raster += decoded
        }
        guard rowsRemaining == 0 else {
            throw ImageError.invalidData(reason: "TIFF strips don't cover the image")
        }

        if predictor == 2 {
            applyHorizontalPredictor(
                &raster,
                width: width,
                height: height,
                samplesPerPixel: samplesPerPixel,
                bytesPerSample: bytesPerSample,
                isLittleEndian: cursor.isLittleEndian
            )
        }

        // Fetch one sample, reduced to 8 bits.
        func sample(_ index: Int) -> UInt8 {
            if bytesPerSample == 1 {
                return raster[index]
            }
            let offset = index * 2
            return cursor.isLittleEndian ? raster[offset + 1] : raster[offset]
        }

        var palette: [RGBA] = []
        if photometric == 3 {
            guard let map = try tag(320), map.count >= 3 * 256 else {
                throw ImageError.invalidData(reason: "TIFF palette is missing or too small")
            }
            palette = (0..<256).map {
                RGBA(
                    red: UInt8(map[$0] >> 8 & 0xFF),
                    green: UInt8(map[256 + $0] >> 8 & 0xFF),
                    blue: UInt8(map[512 + $0] >> 8 & 0xFF)
                )
            }
        }

        var pixels = [RGBA](repeating: .transparent, count: pixelCount)
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * samplesPerPixel
                switch photometric {
                case 0, 1:
                    var value = sample(base)
                    if photometric == 0 {
                        value = 255 - value  // min-is-white
                    }
                    let alpha = samplesPerPixel >= 2 ? sample(base + 1) : 255
                    pixels[y * width + x] = RGBA(red: value, green: value, blue: value, alpha: alpha)
                case 2:
                    let alpha = samplesPerPixel >= 4 ? sample(base + 3) : 255
                    pixels[y * width + x] = RGBA(
                        red: sample(base),
                        green: sample(base + 1),
                        blue: sample(base + 2),
                        alpha: alpha
                    )
                default:  // 3, already validated
                    pixels[y * width + x] = palette[Int(raster[base])]
                }
            }
        }
        return Image(width: width, height: height, pixels: pixels)
    }

    /// Undoes horizontal differencing (predictor 2).
    private static func applyHorizontalPredictor(
        _ raster: inout [UInt8],
        width: Int,
        height: Int,
        samplesPerPixel: Int,
        bytesPerSample: Int,
        isLittleEndian: Bool
    ) {
        let rowBytes = width * samplesPerPixel * bytesPerSample
        if bytesPerSample == 1 {
            for y in 0..<height {
                let rowStart = y * rowBytes
                for i in samplesPerPixel..<rowBytes {
                    raster[rowStart + i] &+= raster[rowStart + i - samplesPerPixel]
                }
            }
        } else {
            // 16-bit differencing operates on full samples in file byte order.
            for y in 0..<height {
                let rowStart = y * rowBytes
                for sampleIndex in samplesPerPixel..<(width * samplesPerPixel) {
                    let i = rowStart + sampleIndex * 2
                    let j = i - samplesPerPixel * 2
                    let current = isLittleEndian
                        ? UInt16(raster[i]) | UInt16(raster[i + 1]) << 8
                        : UInt16(raster[i]) << 8 | UInt16(raster[i + 1])
                    let previous = isLittleEndian
                        ? UInt16(raster[j]) | UInt16(raster[j + 1]) << 8
                        : UInt16(raster[j]) << 8 | UInt16(raster[j + 1])
                    let sum = current &+ previous
                    if isLittleEndian {
                        raster[i] = UInt8(truncatingIfNeeded: sum)
                        raster[i + 1] = UInt8(truncatingIfNeeded: sum >> 8)
                    } else {
                        raster[i] = UInt8(truncatingIfNeeded: sum >> 8)
                        raster[i + 1] = UInt8(truncatingIfNeeded: sum)
                    }
                }
            }
        }
    }

    /// PackBits run-length decompression.
    private static func unpackBits(_ input: [UInt8], expectedCount: Int) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(expectedCount)
        var i = 0
        while i < input.count, output.count < expectedCount {
            let control = Int(Int8(bitPattern: input[i]))
            i += 1
            if control >= 0 {
                let count = control + 1
                guard i + count <= input.count else {
                    throw ImageError.invalidData(reason: "TIFF PackBits data ended early")
                }
                output += input[i..<i + count]
                i += count
            } else if control != -128 {  // -128 is a no-op
                guard i < input.count else {
                    throw ImageError.invalidData(reason: "TIFF PackBits data ended early")
                }
                output += [UInt8](repeating: input[i], count: 1 - control)
                i += 1
            }
        }
        return output
    }

    // MARK: Encoding

    static func encode(_ image: Image) throws -> Data {
        let dataSize = image.width * image.height * 4
        let paddedDataSize = dataSize + (dataSize & 1)
        let ifdOffset = 8 + paddedDataSize
        let entryCount = 10
        let bitsOffset = ifdOffset + 2 + entryCount * 12 + 4
        guard UInt32(exactly: bitsOffset + 8) != nil else {
            throw ImageError.invalidDimensions
        }

        var writer = ByteWriter()
        writer.writeBytes([0x49, 0x49, 42, 0])  // little-endian TIFF
        writer.writeUInt32LittleEndian(UInt32(ifdOffset))
        for pixel in image.pixels {
            writer.writeBytes([pixel.red, pixel.green, pixel.blue, pixel.alpha])
        }
        if dataSize & 1 == 1 {
            writer.writeByte(0)  // keep the IFD on an even offset
        }

        writer.writeUInt16LittleEndian(UInt16(entryCount))
        func writeEntry(tag: Int, type: Int, count: Int, value: Int) {
            writer.writeUInt16LittleEndian(UInt16(tag))
            writer.writeUInt16LittleEndian(UInt16(type))
            writer.writeUInt32LittleEndian(UInt32(count))
            if type == 3 && count == 1 {  // inline SHORT
                writer.writeUInt16LittleEndian(UInt16(value))
                writer.writeUInt16LittleEndian(0)
            } else {
                writer.writeUInt32LittleEndian(UInt32(value))
            }
        }
        writeEntry(tag: 256, type: 4, count: 1, value: image.width)   // ImageWidth
        writeEntry(tag: 257, type: 4, count: 1, value: image.height)  // ImageLength
        writeEntry(tag: 258, type: 3, count: 4, value: bitsOffset)    // BitsPerSample
        writeEntry(tag: 259, type: 3, count: 1, value: 1)             // no compression
        writeEntry(tag: 262, type: 3, count: 1, value: 2)             // RGB
        writeEntry(tag: 273, type: 4, count: 1, value: 8)             // StripOffsets
        writeEntry(tag: 277, type: 3, count: 1, value: 4)             // SamplesPerPixel
        writeEntry(tag: 278, type: 4, count: 1, value: image.height)  // RowsPerStrip
        writeEntry(tag: 279, type: 4, count: 1, value: dataSize)      // StripByteCounts
        writeEntry(tag: 338, type: 3, count: 1, value: 2)             // unassociated alpha
        writer.writeUInt32LittleEndian(0)  // no next IFD
        for _ in 0..<4 {
            writer.writeUInt16LittleEndian(8)  // BitsPerSample values
        }
        return writer.data
    }
}

/// TIFF's LZW variant: MSB-first bit packing, 9-bit initial codes, clear
/// code 256, end code 257, and the "early change" convention where the code
/// width grows one code earlier than GIF's.
private enum TIFFLZW {
    static func decompress(_ input: [UInt8], expectedCount: Int) throws -> [UInt8] {
        var reader = MSBBitReader(input)
        var codeSize = 9
        var table: [[UInt8]] = []
        func resetTable() {
            table = (0..<256).map { [UInt8($0)] }
            table.append([])  // clear code
            table.append([])  // end code
            codeSize = 9
        }
        resetTable()

        var output: [UInt8] = []
        output.reserveCapacity(expectedCount)
        var previous: [UInt8]?

        while output.count < expectedCount {
            let code = try reader.readBits(codeSize)
            if code == 256 {
                resetTable()
                previous = nil
                continue
            }
            if code == 257 {
                break
            }

            let entry: [UInt8]
            if code < table.count {
                entry = table[code]
                guard !entry.isEmpty else {
                    throw ImageError.invalidData(reason: "Invalid TIFF LZW code")
                }
            } else if code == table.count, let previous {
                entry = previous + [previous[0]]
            } else {
                throw ImageError.invalidData(reason: "Invalid TIFF LZW code")
            }

            output += entry
            if let previous, table.count < 4096 {
                table.append(previous + [entry[0]])
                if table.count == (1 << codeSize) - 1, codeSize < 12 {
                    codeSize += 1  // early change
                }
            }
            previous = entry
        }

        guard output.count >= expectedCount else {
            throw ImageError.invalidData(reason: "TIFF LZW data ended early")
        }
        output.removeLast(output.count - expectedCount)
        return output
    }
}

/// Reads bits most-significant-bit first from a byte buffer.
private struct MSBBitReader {
    private let bytes: [UInt8]
    private var bitPosition = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readBits(_ count: Int) throws -> Int {
        var value = 0
        for _ in 0..<count {
            let byteIndex = bitPosition >> 3
            guard byteIndex < bytes.count else {
                throw ImageError.invalidData(reason: "Unexpected end of compressed data")
            }
            value = value << 1 | Int(bytes[byteIndex] >> (7 - (bitPosition & 7))) & 1
            bitPosition += 1
        }
        return value
    }
}
