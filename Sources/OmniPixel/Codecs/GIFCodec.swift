import Foundation

/// GIF (Graphics Interchange Format), 87a and 89a.
///
/// Decoding supports global and local color tables, interlacing and 1-bit
/// transparency; for animated GIFs the first frame is returned, composited
/// onto the logical screen. Encoding produces a single-frame GIF89a, using
/// median-cut quantization when an image has more than 256 distinct colors;
/// pixels with alpha below 128 become fully transparent.
enum GIFCodec: ImageCodec {
    static func canDecode(_ data: Data) -> Bool {
        data.count >= 6 && [UInt8](data.prefix(4)) == Array("GIF8".utf8)
    }

    // MARK: Decoding

    static func decode(_ data: Data) throws -> Image {
        var reader = ByteReader(data)
        let header = try reader.readBytes(6)
        guard header == Array("GIF87a".utf8) || header == Array("GIF89a".utf8) else {
            throw ImageError.invalidData(reason: "Missing GIF header")
        }

        let screenWidth = Int(try reader.readUInt16LittleEndian())
        let screenHeight = Int(try reader.readUInt16LittleEndian())
        let packed = try reader.readByte()
        _ = try reader.readByte()  // background color index
        _ = try reader.readByte()  // pixel aspect ratio
        let (pixelCount, overflow) = screenWidth.multipliedReportingOverflow(by: screenHeight)
        guard screenWidth > 0, screenHeight > 0, !overflow, pixelCount <= Image.maxPixelCount else {
            throw ImageError.invalidData(reason: "Invalid GIF dimensions")
        }

        var globalColorTable: [RGBA] = []
        if packed & 0x80 != 0 {
            globalColorTable = try readColorTable(&reader, sizeField: Int(packed & 0x07))
        }

        var transparentIndex: Int?

        while true {
            switch try reader.readByte() {
            case 0x21:  // extension
                let label = try reader.readByte()
                let body = try readSubBlocks(&reader)
                // A graphic control extension can mark one index transparent.
                if label == 0xF9, body.count >= 4, body[0] & 0x01 != 0 {
                    transparentIndex = Int(body[3])
                }
            case 0x2C:  // image descriptor — decode the first frame and stop
                return try decodeFrame(
                    &reader,
                    screenWidth: screenWidth,
                    screenHeight: screenHeight,
                    globalColorTable: globalColorTable,
                    transparentIndex: transparentIndex
                )
            case 0x3B:  // trailer
                throw ImageError.invalidData(reason: "GIF contains no image")
            default:
                throw ImageError.invalidData(reason: "Unknown GIF block type")
            }
        }
    }

    private static func decodeFrame(
        _ reader: inout ByteReader,
        screenWidth: Int,
        screenHeight: Int,
        globalColorTable: [RGBA],
        transparentIndex: Int?
    ) throws -> Image {
        let left = Int(try reader.readUInt16LittleEndian())
        let top = Int(try reader.readUInt16LittleEndian())
        let frameWidth = Int(try reader.readUInt16LittleEndian())
        let frameHeight = Int(try reader.readUInt16LittleEndian())
        let packed = try reader.readByte()
        guard frameWidth > 0, frameHeight > 0,
              left + frameWidth <= screenWidth, top + frameHeight <= screenHeight else {
            throw ImageError.invalidData(reason: "GIF frame exceeds its logical screen")
        }

        var colorTable = globalColorTable
        if packed & 0x80 != 0 {
            colorTable = try readColorTable(&reader, sizeField: Int(packed & 0x07))
        }
        guard !colorTable.isEmpty else {
            throw ImageError.invalidData(reason: "GIF image has no color table")
        }
        let isInterlaced = packed & 0x40 != 0

        let minimumCodeSize = Int(try reader.readByte())
        guard (2...8).contains(minimumCodeSize) else {
            throw ImageError.invalidData(reason: "Invalid GIF LZW code size")
        }
        let compressed = try readSubBlocks(&reader)
        let indices = try GIFLZW.decompress(
            compressed,
            minimumCodeSize: minimumCodeSize,
            expectedCount: frameWidth * frameHeight
        )

        // Interlaced frames store their rows in four passes.
        var rowOrder: [Int] = []
        if isInterlaced {
            for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)] {
                rowOrder += stride(from: start, to: frameHeight, by: step)
            }
        } else {
            rowOrder = Array(0..<frameHeight)
        }

        // Composite onto a transparent canvas of the logical screen size.
        var pixels = [RGBA](repeating: .transparent, count: screenWidth * screenHeight)
        for (storedRow, y) in rowOrder.enumerated() {
            for x in 0..<frameWidth {
                let index = indices[storedRow * frameWidth + x]
                if index == transparentIndex {
                    continue
                }
                guard index < colorTable.count else {
                    throw ImageError.invalidData(reason: "GIF color index out of range")
                }
                pixels[(top + y) * screenWidth + (left + x)] = colorTable[index]
            }
        }
        return Image(width: screenWidth, height: screenHeight, pixels: pixels)
    }

    private static func readColorTable(_ reader: inout ByteReader, sizeField: Int) throws -> [RGBA] {
        let bytes = try reader.readBytes((2 << sizeField) * 3)
        return stride(from: 0, to: bytes.count, by: 3).map {
            RGBA(red: bytes[$0], green: bytes[$0 + 1], blue: bytes[$0 + 2])
        }
    }

    private static func readSubBlocks(_ reader: inout ByteReader) throws -> [UInt8] {
        var bytes: [UInt8] = []
        while true {
            let length = Int(try reader.readByte())
            if length == 0 {
                return bytes
            }
            bytes += try reader.readBytes(length)
        }
    }

    // MARK: Encoding

    static func encode(_ image: Image) throws -> Data {
        guard image.width <= 65535, image.height <= 65535 else {
            throw ImageError.invalidDimensions
        }

        let hasTransparency = image.pixels.contains { $0.alpha < 128 }
        let quantization = quantize(pixels: image.pixels, maximumColors: hasTransparency ? 255 : 256)

        var tableColors = quantization.palette
        let transparentIndex = hasTransparency ? tableColors.count : nil
        if hasTransparency {
            tableColors.append(.black)
        }

        // The color table size must be a power of two between 2 and 256.
        var tableSize = 2
        while tableSize < tableColors.count {
            tableSize <<= 1
        }
        let sizeField = tableSize.trailingZeroBitCount - 1
        while tableColors.count < tableSize {
            tableColors.append(.black)
        }

        var writer = ByteWriter()
        writer.writeBytes(Array("GIF89a".utf8))
        writer.writeUInt16LittleEndian(UInt16(image.width))
        writer.writeUInt16LittleEndian(UInt16(image.height))
        writer.writeByte(0x80 | 0x70 | UInt8(sizeField))  // global table, 8-bit color resolution
        writer.writeByte(0)  // background color index
        writer.writeByte(0)  // pixel aspect ratio
        for color in tableColors {
            writer.writeBytes([color.red, color.green, color.blue])
        }

        if let transparentIndex {
            writer.writeByte(0x21)  // extension
            writer.writeByte(0xF9)  // graphic control
            writer.writeByte(4)
            writer.writeByte(0x01)  // transparent color flag
            writer.writeUInt16LittleEndian(0)  // frame delay
            writer.writeByte(UInt8(transparentIndex))
            writer.writeByte(0)  // block terminator
        }

        writer.writeByte(0x2C)  // image descriptor
        writer.writeUInt16LittleEndian(0)
        writer.writeUInt16LittleEndian(0)
        writer.writeUInt16LittleEndian(UInt16(image.width))
        writer.writeUInt16LittleEndian(UInt16(image.height))
        writer.writeByte(0)  // no local table, not interlaced

        let indices = image.pixels.map { pixel in
            pixel.alpha < 128 ? transparentIndex! : quantization.index(of: pixel)
        }
        let minimumCodeSize = max(2, tableSize.trailingZeroBitCount)
        writer.writeByte(UInt8(minimumCodeSize))
        writeSubBlocks(GIFLZW.compress(indices, minimumCodeSize: minimumCodeSize), to: &writer)

        writer.writeByte(0x3B)  // trailer
        return writer.data
    }

    private static func writeSubBlocks(_ bytes: [UInt8], to writer: inout ByteWriter) {
        var start = 0
        while start < bytes.count {
            let length = min(255, bytes.count - start)
            writer.writeByte(UInt8(length))
            writer.writeBytes(Array(bytes[start..<start + length]))
            start += length
        }
        writer.writeByte(0)
    }

    // MARK: Color quantization

    private struct Quantization {
        var palette: [RGBA]
        var indexByColor: [RGBA: Int]

        func index(of pixel: RGBA) -> Int {
            indexByColor[RGBA(red: pixel.red, green: pixel.green, blue: pixel.blue)] ?? 0
        }
    }

    /// Reduces the image's opaque colors to at most `maximumColors` using
    /// median cut: repeatedly split the color box with the widest channel
    /// range, then average each box into one palette entry.
    private static func quantize(pixels: [RGBA], maximumColors: Int) -> Quantization {
        var counts: [RGBA: Int] = [:]
        for pixel in pixels where pixel.alpha >= 128 {
            counts[RGBA(red: pixel.red, green: pixel.green, blue: pixel.blue), default: 0] += 1
        }
        guard !counts.isEmpty else {
            // Fully transparent image; the palette still needs one entry.
            return Quantization(palette: [.black], indexByColor: [:])
        }

        let uniqueColors = counts.keys.sorted {
            ($0.red, $0.green, $0.blue) < ($1.red, $1.green, $1.blue)
        }
        if uniqueColors.count <= maximumColors {
            var indexByColor: [RGBA: Int] = [:]
            for (index, color) in uniqueColors.enumerated() {
                indexByColor[color] = index
            }
            return Quantization(palette: uniqueColors, indexByColor: indexByColor)
        }

        var boxes: [[RGBA]] = [uniqueColors]
        while boxes.count < maximumColors {
            var widestBox = -1
            var widestRange = 0
            var widestChannel: KeyPath<RGBA, UInt8> = \.red
            for (boxIndex, box) in boxes.enumerated() where box.count > 1 {
                for channel in [\RGBA.red, \RGBA.green, \RGBA.blue] {
                    let values = box.map { Int($0[keyPath: channel]) }
                    let range = values.max()! - values.min()!
                    if range > widestRange {
                        widestRange = range
                        widestBox = boxIndex
                        widestChannel = channel
                    }
                }
            }
            guard widestBox >= 0 else { break }  // nothing left to split

            let sortedBox = boxes[widestBox].sorted {
                $0[keyPath: widestChannel] < $1[keyPath: widestChannel]
            }
            let half = sortedBox.count / 2
            boxes[widestBox] = Array(sortedBox[..<half])
            boxes.append(Array(sortedBox[half...]))
        }

        var palette: [RGBA] = []
        var indexByColor: [RGBA: Int] = [:]
        for (boxIndex, box) in boxes.enumerated() {
            var red = 0
            var green = 0
            var blue = 0
            var total = 0
            for color in box {
                let count = counts[color] ?? 1
                red += Int(color.red) * count
                green += Int(color.green) * count
                blue += Int(color.blue) * count
                total += count
            }
            palette.append(RGBA(red: UInt8(red / total), green: UInt8(green / total), blue: UInt8(blue / total)))
            for color in box {
                indexByColor[color] = boxIndex
            }
        }
        return Quantization(palette: palette, indexByColor: indexByColor)
    }
}

/// The LZW variant used by GIF: variable code widths up to 12 bits, packed
/// least significant bit first, with in-band clear and end codes.
///
/// The decoder widens its codes when its table reaches 2^size entries; the
/// encoder widens at 2^size + 1 because the decoder's table always lags one
/// entry behind the encoder's.
enum GIFLZW {
    private static let maximumCodeCount = 4096

    static func decompress(_ input: [UInt8], minimumCodeSize: Int, expectedCount: Int) throws -> [Int] {
        let clearCode = 1 << minimumCodeSize
        let endCode = clearCode + 1
        var reader = BitReader(input)
        var codeSize = minimumCodeSize + 1
        var table: [[Int]] = []

        func resetTable() {
            table = (0..<clearCode).map { [$0] }
            table.append([])  // placeholder for the clear code
            table.append([])  // placeholder for the end code
            codeSize = minimumCodeSize + 1
        }
        resetTable()

        var output: [Int] = []
        // Reserve in a bounded step: `expectedCount` comes from the header
        // and no compressed byte has been validated yet, so a truncated file
        // must not be able to commit the whole allocation up front. Growth
        // from here is amortized.
        output.reserveCapacity(min(expectedCount, 1 << 20))
        var previous: [Int]?

        while output.count < expectedCount {
            let code = try reader.readBits(codeSize)
            if code == clearCode {
                resetTable()
                previous = nil
                continue
            }
            if code == endCode {
                break
            }

            let entry: [Int]
            if code < table.count {
                entry = table[code]
                guard !entry.isEmpty else {
                    throw ImageError.invalidData(reason: "Invalid GIF LZW code")
                }
            } else if code == table.count, let previous {
                entry = previous + [previous[0]]  // the KwKwK case
            } else {
                throw ImageError.invalidData(reason: "Invalid GIF LZW code")
            }

            output += entry
            if let previous, table.count < maximumCodeCount {
                table.append(previous + [entry[0]])
                if table.count == 1 << codeSize, codeSize < 12 {
                    codeSize += 1
                }
            }
            previous = entry
        }

        guard output.count >= expectedCount else {
            throw ImageError.invalidData(reason: "GIF image data ended early")
        }
        output.removeLast(output.count - expectedCount)
        return output
    }

    static func compress(_ indices: [Int], minimumCodeSize: Int) -> [UInt8] {
        let clearCode = 1 << minimumCodeSize
        let endCode = clearCode + 1
        var writer = BitWriter()
        var codeSize = minimumCodeSize + 1
        var table: [Int: Int] = [:]  // (prefix code << 8 | next index) → code
        var nextCode = endCode + 1

        func resetTable() {
            table.removeAll(keepingCapacity: true)
            nextCode = endCode + 1
            codeSize = minimumCodeSize + 1
        }

        writer.writeBits(clearCode, count: codeSize)
        guard let first = indices.first else {
            writer.writeBits(endCode, count: codeSize)
            return writer.finish()
        }

        var current = first
        for index in indices.dropFirst() {
            let key = current << 8 | index
            if let code = table[key] {
                current = code
                continue
            }
            writer.writeBits(current, count: codeSize)
            if nextCode < maximumCodeCount {
                table[key] = nextCode
                nextCode += 1
                if nextCode == (1 << codeSize) + 1, codeSize < 12 {
                    codeSize += 1
                }
            } else {
                writer.writeBits(clearCode, count: codeSize)
                resetTable()
            }
            current = index
        }
        writer.writeBits(current, count: codeSize)
        writer.writeBits(endCode, count: codeSize)
        return writer.finish()
    }
}
