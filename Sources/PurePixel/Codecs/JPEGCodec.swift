import Foundation

/// JPEG (ISO/IEC 10918-1), Huffman DCT.
///
/// Decoding supports baseline, extended-sequential and progressive JPEGs
/// (SOF0, SOF1 and SOF2): grayscale and YCbCr, any chroma subsampling,
/// multiple scans with spectral selection and successive approximation,
/// restart markers, and 8- or 16-bit quantization tables. Arithmetic coding
/// and lossless/hierarchical modes are not supported. Encoding produces
/// baseline 4:4:4 YCbCr (see JPEGEncoder.swift).
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

    // MARK: Model

    private struct Component {
        var identifier: Int
        var horizontalSampling: Int
        var verticalSampling: Int
        var quantizationTableIndex: Int
        var dcTableIndex = 0
        var acTableIndex = 0
        var predictor = 0
        /// Block grid covering the full MCU-aligned plane.
        var blockColumns = 0
        var blockRows = 0
        /// Block grid a non-interleaved scan covers (may be smaller).
        var scanBlockColumns = 0
        var scanBlockRows = 0
        /// One 64-coefficient block per grid cell, stored in zigzag order.
        /// Scans accumulate into this; the inverse DCT runs once at the end.
        var coefficients: [Int] = []
    }

    private struct Frame {
        var width: Int
        var height: Int
        var isProgressive: Bool
        var maxHorizontalSampling = 1
        var maxVerticalSampling = 1
        var mcuColumns = 0
        var mcuRows = 0
        var components: [Component] = []
    }

    private struct Scan {
        var componentIndices: [Int]
        var spectralStart: Int
        var spectralEnd: Int
        var bitPositionHigh: Int  // Ah: 0 for a first pass, else refinement
        var bitPositionLow: Int   // Al: the bit position this scan delivers
    }

    // MARK: Decoding

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
        var decodedAnyScan = false

        markerLoop: while true {
            guard try reader.readByte() == 0xFF else {
                throw ImageError.invalidData(reason: "Expected JPEG marker")
            }
            var marker = try reader.readByte()
            while marker == 0xFF {  // fill bytes before a marker are legal
                marker = try reader.readByte()
            }

            switch marker {
            case 0xC0, 0xC1, 0xC2:  // baseline / extended sequential / progressive
                guard frame == nil else {
                    throw ImageError.unsupportedFeature(reason: "Multi-frame JPEG is not supported")
                }
                frame = try parseFrame(&reader, progressive: marker == 0xC2)
            case 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                throw ImageError.unsupportedFeature(reason: "Only Huffman DCT JPEG is supported")
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
                let scan = try parseScanHeader(&reader, frame: &currentFrame)
                let nextOffset = try decodeScan(
                    bytes: bytes,
                    startingAt: reader.offset,
                    frame: &currentFrame,
                    scan: scan,
                    dcTables: dcTables,
                    acTables: acTables,
                    restartInterval: restartInterval
                )
                frame = currentFrame
                decodedAnyScan = true
                try reader.seek(to: nextOffset)
            case 0xD9:  // EOI
                break markerLoop
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

        guard let frame, decodedAnyScan else {
            throw ImageError.invalidData(reason: "JPEG contains no image data")
        }
        return try render(frame: frame, quantizationTables: quantizationTables)
    }

    // MARK: Segment parsing

    private static func parseFrame(_ reader: inout ByteReader, progressive: Bool) throws -> Frame {
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

        var frame = Frame(width: width, height: height, isProgressive: progressive)
        for _ in 0..<componentCount {
            let identifier = Int(try reader.readByte())
            let sampling = try reader.readByte()
            let quantizationTableIndex = Int(try reader.readByte())
            // A lone component always decodes block by block, so its declared
            // sampling factors are irrelevant; normalize them away.
            let horizontal = componentCount == 1 ? 1 : Int(sampling >> 4)
            let vertical = componentCount == 1 ? 1 : Int(sampling & 0x0F)
            guard (1...4).contains(horizontal), (1...4).contains(vertical), quantizationTableIndex < 4 else {
                throw ImageError.invalidData(reason: "Invalid JPEG component parameters")
            }
            frame.components.append(Component(
                identifier: identifier,
                horizontalSampling: horizontal,
                verticalSampling: vertical,
                quantizationTableIndex: quantizationTableIndex
            ))
        }

        frame.maxHorizontalSampling = frame.components.map(\.horizontalSampling).max() ?? 1
        frame.maxVerticalSampling = frame.components.map(\.verticalSampling).max() ?? 1
        frame.mcuColumns = (width + 8 * frame.maxHorizontalSampling - 1) / (8 * frame.maxHorizontalSampling)
        frame.mcuRows = (height + 8 * frame.maxVerticalSampling - 1) / (8 * frame.maxVerticalSampling)

        for index in frame.components.indices {
            let horizontal = frame.components[index].horizontalSampling
            let vertical = frame.components[index].verticalSampling
            frame.components[index].blockColumns = frame.mcuColumns * horizontal
            frame.components[index].blockRows = frame.mcuRows * vertical
            let componentWidth = (width * horizontal + frame.maxHorizontalSampling - 1) / frame.maxHorizontalSampling
            let componentHeight = (height * vertical + frame.maxVerticalSampling - 1) / frame.maxVerticalSampling
            frame.components[index].scanBlockColumns = (componentWidth + 7) / 8
            frame.components[index].scanBlockRows = (componentHeight + 7) / 8
            frame.components[index].coefficients = [Int](
                repeating: 0,
                count: frame.components[index].blockColumns * frame.components[index].blockRows * 64
            )
        }
        return frame
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

    private static func parseScanHeader(_ reader: inout ByteReader, frame: inout Frame) throws -> Scan {
        _ = try reader.readUInt16BigEndian()  // segment length
        let scanComponentCount = Int(try reader.readByte())
        guard scanComponentCount >= 1, scanComponentCount <= frame.components.count else {
            throw ImageError.invalidData(reason: "Invalid JPEG scan component count")
        }
        var componentIndices: [Int] = []
        for _ in 0..<scanComponentCount {
            let identifier = Int(try reader.readByte())
            let tables = try reader.readByte()
            guard let componentIndex = frame.components.firstIndex(where: { $0.identifier == identifier }) else {
                throw ImageError.invalidData(reason: "JPEG scan references an unknown component")
            }
            frame.components[componentIndex].dcTableIndex = Int(tables >> 4)
            frame.components[componentIndex].acTableIndex = Int(tables & 0x0F)
            componentIndices.append(componentIndex)
        }
        let spectralStart = Int(try reader.readByte())
        let spectralEnd = Int(try reader.readByte())
        let approximation = try reader.readByte()
        let bitPositionHigh = Int(approximation >> 4)
        let bitPositionLow = Int(approximation & 0x0F)

        if frame.isProgressive {
            guard spectralStart <= spectralEnd, spectralEnd <= 63,
                  bitPositionLow <= 13, bitPositionHigh <= 14 else {
                throw ImageError.invalidData(reason: "Invalid JPEG progressive scan parameters")
            }
            if spectralStart == 0 {
                guard spectralEnd == 0 else {
                    throw ImageError.invalidData(reason: "Progressive JPEG DC scan must not include AC coefficients")
                }
            } else {
                guard componentIndices.count == 1 else {
                    throw ImageError.invalidData(reason: "Progressive JPEG AC scans must cover a single component")
                }
            }
            guard bitPositionHigh == 0 || bitPositionHigh == bitPositionLow + 1 else {
                throw ImageError.invalidData(reason: "Invalid JPEG successive approximation")
            }
        } else {
            guard spectralStart == 0, spectralEnd == 63, bitPositionHigh == 0, bitPositionLow == 0 else {
                throw ImageError.invalidData(reason: "Invalid JPEG sequential scan parameters")
            }
        }
        return Scan(
            componentIndices: componentIndices,
            spectralStart: spectralStart,
            spectralEnd: spectralEnd,
            bitPositionHigh: bitPositionHigh,
            bitPositionLow: bitPositionLow
        )
    }

    // MARK: Scan decoding

    /// Decodes one scan into the frame's coefficient buffers and returns the
    /// byte offset of the next marker.
    private static func decodeScan(
        bytes: [UInt8],
        startingAt offset: Int,
        frame: inout Frame,
        scan: Scan,
        dcTables: [JPEGHuffmanTable?],
        acTables: [JPEGHuffmanTable?],
        restartInterval: Int
    ) throws -> Int {
        var bitReader = JPEGBitReader(bytes: bytes, startingAt: offset)
        var eobRun = 0
        for index in scan.componentIndices {
            frame.components[index].predictor = 0
        }

        // Multi-component scans interleave whole MCUs; single-component scans
        // walk that component's own block grid in raster order.
        let isInterleaved = scan.componentIndices.count > 1
        let unitCount: Int
        if isInterleaved {
            unitCount = frame.mcuColumns * frame.mcuRows
        } else {
            let component = frame.components[scan.componentIndices[0]]
            unitCount = component.scanBlockColumns * component.scanBlockRows
        }

        var restartCount = 0
        for unitIndex in 0..<unitCount {
            if restartInterval > 0, unitIndex > 0, unitIndex % restartInterval == 0 {
                try bitReader.synchronizeToRestartMarker(expecting: restartCount % 8)
                restartCount += 1
                eobRun = 0
                for index in scan.componentIndices {
                    frame.components[index].predictor = 0
                }
            }

            if isInterleaved {
                let mcuX = unitIndex % frame.mcuColumns
                let mcuY = unitIndex / frame.mcuColumns
                for index in scan.componentIndices {
                    let horizontal = frame.components[index].horizontalSampling
                    let vertical = frame.components[index].verticalSampling
                    for blockY in 0..<vertical {
                        for blockX in 0..<horizontal {
                            let blockIndex = (mcuY * vertical + blockY) * frame.components[index].blockColumns
                                + mcuX * horizontal + blockX
                            try decodeUnit(
                                &bitReader,
                                frame: &frame,
                                componentIndex: index,
                                blockIndex: blockIndex,
                                scan: scan,
                                dcTables: dcTables,
                                acTables: acTables,
                                eobRun: &eobRun
                            )
                        }
                    }
                }
            } else {
                let index = scan.componentIndices[0]
                let columns = frame.components[index].scanBlockColumns
                let blockIndex = (unitIndex / columns) * frame.components[index].blockColumns + unitIndex % columns
                try decodeUnit(
                    &bitReader,
                    frame: &frame,
                    componentIndex: index,
                    blockIndex: blockIndex,
                    scan: scan,
                    dcTables: dcTables,
                    acTables: acTables,
                    eobRun: &eobRun
                )
            }
        }

        // Skip padding up to the next marker (anything but stuffing and RSTn).
        var nextOffset = bitReader.byteOffset
        while nextOffset + 1 < bytes.count {
            if bytes[nextOffset] == 0xFF,
               bytes[nextOffset + 1] != 0x00,
               !(0xD0...0xD7).contains(bytes[nextOffset + 1]) {
                break
            }
            nextOffset += 1
        }
        return min(nextOffset, bytes.count)
    }

    private static func decodeUnit(
        _ reader: inout JPEGBitReader,
        frame: inout Frame,
        componentIndex: Int,
        blockIndex: Int,
        scan: Scan,
        dcTables: [JPEGHuffmanTable?],
        acTables: [JPEGHuffmanTable?],
        eobRun: inout Int
    ) throws {
        let base = blockIndex * 64

        if scan.spectralStart == 0 {
            if scan.bitPositionHigh == 0 {
                guard let dcTable = dcTables[frame.components[componentIndex].dcTableIndex] else {
                    throw ImageError.invalidData(reason: "JPEG scan references a missing DC table")
                }
                let size = try dcTable.decodeSymbol(from: &reader)
                guard size <= 15 else {
                    throw ImageError.invalidData(reason: "Invalid JPEG DC coefficient size")
                }
                frame.components[componentIndex].predictor += extend(try reader.readBits(size), bitCount: size)
                frame.components[componentIndex].coefficients[base] =
                    frame.components[componentIndex].predictor << scan.bitPositionLow
            } else {
                // DC refinement: one bit per block.
                if try reader.readBit() == 1 {
                    frame.components[componentIndex].coefficients[base] |= 1 << scan.bitPositionLow
                }
            }
            if scan.spectralEnd == 0 {
                return  // progressive DC-only scan
            }
        }

        guard let acTable = acTables[frame.components[componentIndex].acTableIndex] else {
            throw ImageError.invalidData(reason: "JPEG scan references a missing AC table")
        }
        let bandStart = max(1, scan.spectralStart)
        if scan.bitPositionHigh == 0 {
            try decodeACFirstPass(
                &reader,
                coefficients: &frame.components[componentIndex].coefficients,
                base: base,
                from: bandStart,
                to: scan.spectralEnd,
                shift: scan.bitPositionLow,
                acTable: acTable,
                eobRun: &eobRun
            )
        } else {
            try decodeACRefinement(
                &reader,
                coefficients: &frame.components[componentIndex].coefficients,
                base: base,
                from: bandStart,
                to: scan.spectralEnd,
                shift: scan.bitPositionLow,
                acTable: acTable,
                eobRun: &eobRun
            )
        }
    }

    private static func decodeACFirstPass(
        _ reader: inout JPEGBitReader,
        coefficients: inout [Int],
        base: Int,
        from bandStart: Int,
        to bandEnd: Int,
        shift: Int,
        acTable: JPEGHuffmanTable,
        eobRun: inout Int
    ) throws {
        if eobRun > 0 {
            eobRun -= 1
            return
        }
        var k = bandStart
        while k <= bandEnd {
            let symbol = try acTable.decodeSymbol(from: &reader)
            let zeroRun = symbol >> 4
            let size = symbol & 0x0F
            if size == 0 {
                if zeroRun < 15 {  // EOBn: this block is done, plus a run of others
                    eobRun = (1 << zeroRun) - 1
                    if zeroRun > 0 {
                        eobRun += try reader.readBits(zeroRun)
                    }
                    return
                }
                k += 16  // ZRL
            } else {
                k += zeroRun
                guard k <= bandEnd else {
                    throw ImageError.invalidData(reason: "JPEG coefficient index out of range")
                }
                coefficients[base + k] = extend(try reader.readBits(size), bitCount: size) << shift
                k += 1
            }
        }
    }

    /// AC successive-approximation refinement (ITU T.81, G.1.2.3).
    private static func decodeACRefinement(
        _ reader: inout JPEGBitReader,
        coefficients: inout [Int],
        base: Int,
        from bandStart: Int,
        to bandEnd: Int,
        shift: Int,
        acTable: JPEGHuffmanTable,
        eobRun: inout Int
    ) throws {
        let magnitude = 1 << shift

        if eobRun > 0 {
            // Inside an EOB run only correction bits for already-nonzero
            // coefficients are present.
            eobRun -= 1
            for k in bandStart...bandEnd where coefficients[base + k] != 0 {
                try refineCoefficient(&coefficients[base + k], magnitude: magnitude, reader: &reader)
            }
            return
        }

        var k = bandStart
        repeat {
            let symbol = try acTable.decodeSymbol(from: &reader)
            var zeroRun = symbol >> 4
            let size = symbol & 0x0F
            var newValue = 0
            if size == 0 {
                if zeroRun < 15 {
                    eobRun = (1 << zeroRun) - 1
                    if zeroRun > 0 {
                        eobRun += try reader.readBits(zeroRun)
                    }
                    zeroRun = 64  // sweep correction bits through the rest of the band
                }
                // zeroRun == 15 (ZRL): skip sixteen zero-history coefficients
            } else {
                guard size == 1 else {
                    throw ImageError.invalidData(reason: "Invalid JPEG refinement coefficient size")
                }
                newValue = try reader.readBit() == 1 ? magnitude : -magnitude
            }

            while k <= bandEnd {
                if coefficients[base + k] != 0 {
                    try refineCoefficient(&coefficients[base + k], magnitude: magnitude, reader: &reader)
                } else {
                    if zeroRun == 0 {
                        if newValue != 0 {
                            coefficients[base + k] = newValue
                        }
                        k += 1
                        break
                    }
                    zeroRun -= 1
                }
                k += 1
            }
        } while k <= bandEnd
    }

    private static func refineCoefficient(_ value: inout Int, magnitude: Int, reader: inout JPEGBitReader) throws {
        if try reader.readBit() == 1, value & magnitude == 0 {
            value += value >= 0 ? magnitude : -magnitude
        }
    }

    /// Sign-extends a magnitude-coded value (ITU T.81, F.2.2.1 EXTEND).
    private static func extend(_ bits: Int, bitCount: Int) -> Int {
        guard bitCount > 0 else { return 0 }
        return bits < (1 << (bitCount - 1)) ? bits - (1 << bitCount) + 1 : bits
    }

    // MARK: Rendering

    private static func render(frame: Frame, quantizationTables: [[Int]?]) throws -> Image {
        var planes: [[UInt8]] = []
        var planeWidths: [Int] = []

        for component in frame.components {
            guard let quantization = quantizationTables[component.quantizationTableIndex] else {
                throw ImageError.invalidData(reason: "JPEG is missing a quantization table")
            }
            let planeWidth = component.blockColumns * 8
            var plane = [UInt8](repeating: 0, count: planeWidth * component.blockRows * 8)

            for blockRow in 0..<component.blockRows {
                for blockColumn in 0..<component.blockColumns {
                    let base = (blockRow * component.blockColumns + blockColumn) * 64
                    var natural = [Double](repeating: 0, count: 64)
                    for k in 0..<64 {
                        natural[zigzag[k]] = Double(component.coefficients[base + k] * quantization[k])
                    }
                    let samples = inverseTransform(natural)
                    let originX = blockColumn * 8
                    let originY = blockRow * 8
                    for row in 0..<8 {
                        for column in 0..<8 {
                            plane[(originY + row) * planeWidth + originX + column] = samples[row * 8 + column]
                        }
                    }
                }
            }
            planes.append(plane)
            planeWidths.append(planeWidth)
        }

        var pixels = [RGBA](repeating: .transparent, count: frame.width * frame.height)
        if frame.components.count == 1 {
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    let value = planes[0][y * planeWidths[0] + x]
                    pixels[y * frame.width + x] = RGBA(red: value, green: value, blue: value)
                }
            }
        } else {
            func sample(_ index: Int, _ x: Int, _ y: Int) -> Double {
                let component = frame.components[index]
                let sampleX = x * component.horizontalSampling / frame.maxHorizontalSampling
                let sampleY = y * component.verticalSampling / frame.maxVerticalSampling
                return Double(planes[index][sampleY * planeWidths[index] + sampleX])
            }
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    let brightness = sample(0, x, y)
                    let blueChroma = sample(1, x, y) - 128
                    let redChroma = sample(2, x, y) - 128
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

    /// The offset of the next unconsumed byte.
    var byteOffset: Int {
        offset
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
