import Foundation

/// JPEG (ISO/IEC 10918-1), baseline DCT.
///
/// Decoding supports baseline and extended-sequential Huffman JPEGs (SOF0 and
/// SOF1): grayscale and YCbCr, any chroma subsampling, restart markers, and
/// 8- or 16-bit quantization tables. Progressive JPEG and arithmetic coding
/// are not supported. Encoding produces baseline 4:4:4 YCbCr at a fixed
/// quality of 85 (see JPEGEncoder.swift).
enum JPEGCodec: ImageCodec {
    static func canDecode(_ data: Data) -> Bool {
        data.count >= 3 && [UInt8](data.prefix(3)) == [0xFF, 0xD8, 0xFF]
    }

    /// Maps zigzag scan position to natural (row-major) block position.
    static let zigzag: [Int] = [
         0,  1,  8, 16,  9,  2,  3, 10,
        17, 24, 32, 25, 18, 11,  4,  5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13,  6,  7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63,
    ]

    /// cosineTable[u][x] = cos((2x + 1) · u · π / 16), shared by both DCTs.
    static let cosineTable: [[Double]] = (0..<8).map { u in
        (0..<8).map { x in cos(Double(2 * x + 1) * Double(u) * Double.pi / 16) }
    }

    /// The 1/√2 normalization for the zero-frequency basis function.
    static let normalization: [Double] = (0..<8).map { $0 == 0 ? 1 / Double(2).squareRoot() : 1 }

    // MARK: Decoding

    private struct Component {
        var identifier: Int
        var horizontalSampling: Int
        var verticalSampling: Int
        var quantizationTableIndex: Int
        var dcTableIndex = 0
        var acTableIndex = 0
        var predictor = 0
        var planeWidth = 0
        var plane: [UInt8] = []
    }

    private struct Frame {
        var width: Int
        var height: Int
        var components: [Component]
    }

    static func decode(_ data: Data) throws -> Image {
        let bytes = [UInt8](data)
        var reader = ByteReader(bytes)
        guard try reader.readBytes(2) == [0xFF, 0xD8] else {
            throw ImageError.invalidData(reason: "Missing JPEG start-of-image marker")
        }

        var frame: Frame?
        var quantizationTables = [[Int]?](repeating: nil, count: 4)
        var dcTables = [JPEGHuffmanTable?](repeating: nil, count: 4)
        var acTables = [JPEGHuffmanTable?](repeating: nil, count: 4)
        var restartInterval = 0

        while true {
            guard try reader.readByte() == 0xFF else {
                throw ImageError.invalidData(reason: "Expected JPEG marker")
            }
            var marker = try reader.readByte()
            while marker == 0xFF {  // fill bytes before a marker are legal
                marker = try reader.readByte()
            }

            switch marker {
            case 0xC0, 0xC1:  // baseline / extended sequential DCT
                frame = try parseFrame(&reader)
            case 0xC2:
                throw ImageError.unsupportedFeature(reason: "Progressive JPEG is not supported yet")
            case 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                throw ImageError.unsupportedFeature(reason: "Only baseline Huffman JPEG is supported")
            case 0xC4:  // DHT
                try parseHuffmanTables(&reader, dc: &dcTables, ac: &acTables)
            case 0xDB:  // DQT
                try parseQuantizationTables(&reader, into: &quantizationTables)
            case 0xDD:  // DRI
                guard try reader.readUInt16BigEndian() == 4 else {
                    throw ImageError.invalidData(reason: "Invalid JPEG restart interval segment")
                }
                restartInterval = Int(try reader.readUInt16BigEndian())
            case 0xDA:  // SOS
                guard var currentFrame = frame else {
                    throw ImageError.invalidData(reason: "JPEG scan before frame header")
                }
                try parseScanHeader(&reader, frame: &currentFrame)
                return try decodeScan(
                    bytes: bytes,
                    startingAt: reader.offset,
                    frame: &currentFrame,
                    quantizationTables: quantizationTables,
                    dcTables: dcTables,
                    acTables: acTables,
                    restartInterval: restartInterval
                )
            case 0xD9:  // EOI
                throw ImageError.invalidData(reason: "JPEG ended before image data")
            case 0x01, 0xD0...0xD7:  // TEM / stray restart: standalone, no payload
                break
            default:  // APPn, COM and anything else with a length field
                let length = Int(try reader.readUInt16BigEndian())
                guard length >= 2 else {
                    throw ImageError.invalidData(reason: "Invalid JPEG segment length")
                }
                try reader.skip(length - 2)
            }
        }
    }

    // MARK: Segment parsing

    private static func parseFrame(_ reader: inout ByteReader) throws -> Frame {
        _ = try reader.readUInt16BigEndian()  // segment length
        let precision = try reader.readByte()
        guard precision == 8 else {
            throw ImageError.unsupportedFeature(reason: "\(precision)-bit JPEG is not supported")
        }
        let height = Int(try reader.readUInt16BigEndian())
        let width = Int(try reader.readUInt16BigEndian())
        let componentCount = Int(try reader.readByte())
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, pixelCount <= Image.maxPixelCount else {
            throw ImageError.invalidData(reason: "Invalid JPEG dimensions")
        }
        guard componentCount == 1 || componentCount == 3 else {
            throw ImageError.unsupportedFeature(reason: "Only grayscale and YCbCr JPEG are supported")
        }

        var components: [Component] = []
        for _ in 0..<componentCount {
            let identifier = Int(try reader.readByte())
            let sampling = try reader.readByte()
            let quantizationTableIndex = Int(try reader.readByte())
            // In a single-component scan the MCU is one block, so sampling
            // factors don't apply; normalize them away.
            let horizontal = componentCount == 1 ? 1 : Int(sampling >> 4)
            let vertical = componentCount == 1 ? 1 : Int(sampling & 0x0F)
            guard (1...4).contains(horizontal), (1...4).contains(vertical), quantizationTableIndex < 4 else {
                throw ImageError.invalidData(reason: "Invalid JPEG component parameters")
            }
            components.append(Component(
                identifier: identifier,
                horizontalSampling: horizontal,
                verticalSampling: vertical,
                quantizationTableIndex: quantizationTableIndex
            ))
        }
        return Frame(width: width, height: height, components: components)
    }

    private static func parseQuantizationTables(_ reader: inout ByteReader, into tables: inout [[Int]?]) throws {
        var remaining = Int(try reader.readUInt16BigEndian()) - 2
        while remaining > 0 {
            let descriptor = try reader.readByte()
            let precision = Int(descriptor >> 4)
            let index = Int(descriptor & 0x0F)
            guard index < 4, precision <= 1 else {
                throw ImageError.invalidData(reason: "Invalid JPEG quantization table")
            }
            var table = [Int](repeating: 0, count: 64)  // kept in zigzag order, as stored
            for k in 0..<64 {
                table[k] = precision == 0
                    ? Int(try reader.readByte())
                    : Int(try reader.readUInt16BigEndian())
            }
            tables[index] = table
            remaining -= 1 + 64 * (precision + 1)
        }
    }

    private static func parseHuffmanTables(
        _ reader: inout ByteReader,
        dc: inout [JPEGHuffmanTable?],
        ac: inout [JPEGHuffmanTable?]
    ) throws {
        var remaining = Int(try reader.readUInt16BigEndian()) - 2
        while remaining > 0 {
            let descriptor = try reader.readByte()
            let tableClass = Int(descriptor >> 4)
            let index = Int(descriptor & 0x0F)
            guard tableClass <= 1, index < 4 else {
                throw ImageError.invalidData(reason: "Invalid JPEG Huffman table descriptor")
            }
            var counts = [0]  // index 0 unused; lengths run 1...16
            for _ in 0..<16 {
                counts.append(Int(try reader.readByte()))
            }
            let symbolCount = counts.reduce(0, +)
            let symbols = try reader.readBytes(symbolCount)
            let table = try JPEGHuffmanTable(countsByLength: counts, symbols: symbols)
            if tableClass == 1 {
                ac[index] = table
            } else {
                dc[index] = table
            }
            remaining -= 1 + 16 + symbolCount
        }
    }

    private static func parseScanHeader(_ reader: inout ByteReader, frame: inout Frame) throws {
        _ = try reader.readUInt16BigEndian()  // segment length
        let scanComponentCount = Int(try reader.readByte())
        guard scanComponentCount == frame.components.count else {
            throw ImageError.unsupportedFeature(reason: "Multi-scan JPEG is not supported")
        }
        for _ in 0..<scanComponentCount {
            let identifier = Int(try reader.readByte())
            let tables = try reader.readByte()
            guard let componentIndex = frame.components.firstIndex(where: { $0.identifier == identifier }) else {
                throw ImageError.invalidData(reason: "JPEG scan references an unknown component")
            }
            frame.components[componentIndex].dcTableIndex = Int(tables >> 4)
            frame.components[componentIndex].acTableIndex = Int(tables & 0x0F)
        }
        let spectralStart = try reader.readByte()
        let spectralEnd = try reader.readByte()
        let approximation = try reader.readByte()
        guard spectralStart == 0, spectralEnd == 63, approximation == 0 else {
            throw ImageError.unsupportedFeature(reason: "Progressive JPEG scan parameters are not supported")
        }
    }

    // MARK: Scan decoding

    private static func decodeScan(
        bytes: [UInt8],
        startingAt offset: Int,
        frame: inout Frame,
        quantizationTables: [[Int]?],
        dcTables: [JPEGHuffmanTable?],
        acTables: [JPEGHuffmanTable?],
        restartInterval: Int
    ) throws -> Image {
        let maxHorizontal = frame.components.map(\.horizontalSampling).max() ?? 1
        let maxVertical = frame.components.map(\.verticalSampling).max() ?? 1
        let mcuColumns = (frame.width + 8 * maxHorizontal - 1) / (8 * maxHorizontal)
        let mcuRows = (frame.height + 8 * maxVertical - 1) / (8 * maxVertical)

        for index in frame.components.indices {
            let component = frame.components[index]
            frame.components[index].planeWidth = mcuColumns * component.horizontalSampling * 8
            frame.components[index].plane = [UInt8](
                repeating: 0,
                count: frame.components[index].planeWidth * mcuRows * component.verticalSampling * 8
            )
        }

        var bitReader = JPEGBitReader(bytes: bytes, startingAt: offset)
        var restartCount = 0

        for mcuIndex in 0..<(mcuColumns * mcuRows) {
            if restartInterval > 0, mcuIndex > 0, mcuIndex % restartInterval == 0 {
                try bitReader.synchronizeToRestartMarker(expecting: restartCount % 8)
                restartCount += 1
                for index in frame.components.indices {
                    frame.components[index].predictor = 0
                }
            }
            let mcuX = mcuIndex % mcuColumns
            let mcuY = mcuIndex / mcuColumns

            for index in frame.components.indices {
                let horizontal = frame.components[index].horizontalSampling
                let vertical = frame.components[index].verticalSampling
                let planeWidth = frame.components[index].planeWidth
                guard
                    let quantization = quantizationTables[frame.components[index].quantizationTableIndex],
                    let dcTable = dcTables[frame.components[index].dcTableIndex],
                    let acTable = acTables[frame.components[index].acTableIndex]
                else {
                    throw ImageError.invalidData(reason: "JPEG scan references a missing table")
                }

                for blockY in 0..<vertical {
                    for blockX in 0..<horizontal {
                        let samples = try decodeBlock(
                            &bitReader,
                            predictor: &frame.components[index].predictor,
                            dcTable: dcTable,
                            acTable: acTable,
                            quantization: quantization
                        )
                        let originX = (mcuX * horizontal + blockX) * 8
                        let originY = (mcuY * vertical + blockY) * 8
                        for row in 0..<8 {
                            for column in 0..<8 {
                                frame.components[index].plane[(originY + row) * planeWidth + originX + column]
                                    = samples[row * 8 + column]
                            }
                        }
                    }
                }
            }
        }

        return assembleImage(frame: frame, maxHorizontal: maxHorizontal, maxVertical: maxVertical)
    }

    private static func decodeBlock(
        _ reader: inout JPEGBitReader,
        predictor: inout Int,
        dcTable: JPEGHuffmanTable,
        acTable: JPEGHuffmanTable,
        quantization: [Int]
    ) throws -> [UInt8] {
        var coefficients = [Double](repeating: 0, count: 64)

        let dcSize = try dcTable.decodeSymbol(from: &reader)
        guard dcSize <= 15 else {
            throw ImageError.invalidData(reason: "Invalid JPEG DC coefficient size")
        }
        predictor += extend(try reader.readBits(dcSize), bitCount: dcSize)
        coefficients[0] = Double(predictor * quantization[0])

        var k = 1
        while k < 64 {
            let symbol = try acTable.decodeSymbol(from: &reader)
            let zeroRun = symbol >> 4
            let size = symbol & 0x0F
            if size == 0 {
                if zeroRun == 15 {  // ZRL: sixteen zero coefficients
                    k += 16
                    continue
                }
                break  // EOB
            }
            k += zeroRun
            guard k < 64 else {
                throw ImageError.invalidData(reason: "JPEG coefficient index out of range")
            }
            let value = extend(try reader.readBits(size), bitCount: size)
            coefficients[zigzag[k]] = Double(value * quantization[k])
            k += 1
        }

        return inverseTransform(coefficients)
    }

    /// Sign-extends a magnitude-coded value (ITU T.81, F.2.2.1 EXTEND).
    private static func extend(_ bits: Int, bitCount: Int) -> Int {
        guard bitCount > 0 else { return 0 }
        return bits < (1 << (bitCount - 1)) ? bits - (1 << bitCount) + 1 : bits
    }

    /// 8×8 inverse DCT, returning clamped samples after the +128 level shift.
    private static func inverseTransform(_ coefficients: [Double]) -> [UInt8] {
        var samples = [UInt8](repeating: 0, count: 64)
        for y in 0..<8 {
            for x in 0..<8 {
                var sum = 0.0
                for v in 0..<8 {
                    for u in 0..<8 {
                        sum += normalization[u] * normalization[v] * coefficients[v * 8 + u]
                            * cosineTable[u][x] * cosineTable[v][y]
                    }
                }
                let value = (sum / 4 + 128).rounded()
                samples[y * 8 + x] = UInt8(min(max(value, 0), 255))
            }
        }
        return samples
    }

    private static func assembleImage(frame: Frame, maxHorizontal: Int, maxVertical: Int) -> Image {
        var pixels = [RGBA](repeating: .transparent, count: frame.width * frame.height)

        if frame.components.count == 1 {
            let component = frame.components[0]
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    let value = component.plane[y * component.planeWidth + x]
                    pixels[y * frame.width + x] = RGBA(red: value, green: value, blue: value)
                }
            }
        } else {
            let luma = frame.components[0]
            let blueComponent = frame.components[1]
            let redComponent = frame.components[2]

            func sample(_ component: Component, _ x: Int, _ y: Int) -> Double {
                let sampleX = x * component.horizontalSampling / maxHorizontal
                let sampleY = y * component.verticalSampling / maxVertical
                return Double(component.plane[sampleY * component.planeWidth + sampleX])
            }

            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    let brightness = sample(luma, x, y)
                    let blueChroma = sample(blueComponent, x, y) - 128
                    let redChroma = sample(redComponent, x, y) - 128
                    pixels[y * frame.width + x] = RGBA(
                        red: clampedChannel(brightness + 1.402 * redChroma),
                        green: clampedChannel(brightness - 0.344136 * blueChroma - 0.714136 * redChroma),
                        blue: clampedChannel(brightness + 1.772 * blueChroma)
                    )
                }
            }
        }
        return Image(width: frame.width, height: frame.height, pixels: pixels)
    }

    private static func clampedChannel(_ value: Double) -> UInt8 {
        UInt8(min(max(value.rounded(), 0), 255))
    }
}

/// A canonical JPEG Huffman table (counts per code length plus symbols in
/// code order), decoded bit by bit exactly like the DEFLATE tables.
struct JPEGHuffmanTable {
    private let countsByLength: [Int]  // index 1...16; index 0 unused
    private let symbols: [UInt8]

    init(countsByLength: [Int], symbols: [UInt8]) throws {
        guard countsByLength.count == 17,
              countsByLength.dropFirst().reduce(0, +) == symbols.count else {
            throw ImageError.invalidData(reason: "Corrupt JPEG Huffman table")
        }
        var available = 1
        for length in 1...16 {
            available <<= 1
            available -= countsByLength[length]
            guard available >= 0 else {
                throw ImageError.invalidData(reason: "Invalid JPEG Huffman code lengths")
            }
        }
        self.countsByLength = countsByLength
        self.symbols = symbols
    }

    func decodeSymbol(from reader: inout JPEGBitReader) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        for length in 1...16 {
            code |= try reader.readBit()
            let count = countsByLength[length]
            if code - first < count {
                return Int(symbols[index + (code - first)])
            }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        throw ImageError.invalidData(reason: "Invalid JPEG Huffman code")
    }
}

/// Reads bits most-significant-bit first from JPEG entropy-coded data,
/// removing stuffed zero bytes after 0xFF and validating restart markers.
struct JPEGBitReader {
    private let bytes: [UInt8]
    private var offset: Int
    private var currentByte: UInt8 = 0
    private var bitsRemaining = 0

    init(bytes: [UInt8], startingAt offset: Int) {
        self.bytes = bytes
        self.offset = offset
    }

    mutating func readBit() throws -> Int {
        if bitsRemaining == 0 {
            try refill()
        }
        bitsRemaining -= 1
        return Int(currentByte >> bitsRemaining) & 1
    }

    mutating func readBits(_ count: Int) throws -> Int {
        var value = 0
        for _ in 0..<count {
            value = value << 1 | (try readBit())
        }
        return value
    }

    /// Discards partial bits, then consumes the expected RSTn marker.
    mutating func synchronizeToRestartMarker(expecting index: Int) throws {
        bitsRemaining = 0
        guard offset + 2 <= bytes.count,
              bytes[offset] == 0xFF,
              bytes[offset + 1] == 0xD0 + UInt8(index) else {
            throw ImageError.invalidData(reason: "Missing JPEG restart marker")
        }
        offset += 2
    }

    private mutating func refill() throws {
        guard offset < bytes.count else {
            throw ImageError.invalidData(reason: "JPEG entropy data ended early")
        }
        let byte = bytes[offset]
        offset += 1
        if byte == 0xFF {
            guard offset < bytes.count else {
                throw ImageError.invalidData(reason: "JPEG entropy data ended early")
            }
            guard bytes[offset] == 0x00 else {
                throw ImageError.invalidData(reason: "Unexpected marker inside JPEG entropy data")
            }
            offset += 1  // skip the stuffed zero byte
        }
        currentByte = byte
        bitsRemaining = 8
    }
}
