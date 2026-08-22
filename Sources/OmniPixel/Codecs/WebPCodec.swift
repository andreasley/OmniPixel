import Foundation

/// WebP (RIFF container), lossless flavor.
///
/// Decoding supports lossless (VP8L) images in full: all four transforms
/// (predictor, cross-color, subtract-green, color indexing with pixel
/// bundling), color cache, meta prefix groups and LZ77 back-references.
/// Lossy (VP8) and animated WebP are not supported. Encoding produces a
/// lossless VP8L file that stores literal ARGB values with fixed 8-bit
/// prefix codes.
enum WebPCodec: ImageCodec {
    static func canDecode(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data.prefix(12))
        return Array(bytes[0..<4]) == Array("RIFF".utf8) && Array(bytes[8..<12]) == Array("WEBP".utf8)
    }

    // MARK: Container

    static func decode(_ data: Data) throws -> Image {
        guard canDecode(data) else {
            throw ImageError.invalidData(reason: "Missing WebP header")
        }
        let bytes = [UInt8](data)
        var offset = 12
        while offset + 8 <= bytes.count {
            let fourCC = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
                | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
            let payloadStart = offset + 8
            guard size >= 0, payloadStart + size <= bytes.count else {
                throw ImageError.invalidData(reason: "WebP chunk exceeds the file")
            }
            switch fourCC {
            case "VP8L":
                return try decodeLossless(Array(bytes[payloadStart..<payloadStart + size]))
            case "VP8 ", "ALPH":
                throw ImageError.unsupportedFeature(reason: "Lossy WebP is not supported yet")
            case "ANMF":
                throw ImageError.unsupportedFeature(reason: "Animated WebP is not supported")
            default:
                break  // VP8X and metadata chunks; keep looking for the image
            }
            offset = payloadStart + size + (size & 1)
        }
        throw ImageError.invalidData(reason: "WebP contains no image chunk")
    }

    // MARK: VP8L decoding

    private enum VP8LCode {
        case single(Int)
        case table(HuffmanTable)

        func decode(from reader: inout BitReader) throws -> Int {
            switch self {
            case .single(let symbol):
                return symbol  // one-symbol codes use zero bits
            case .table(let table):
                return try table.decodeSymbol(from: &reader)
            }
        }
    }

    private enum Transform {
        case predictor(blockBits: Int, modes: [UInt32], width: Int)
        case colorTransform(blockBits: Int, elements: [UInt32], width: Int)
        case subtractGreen
        case colorIndexing(palette: [UInt32], widthBits: Int, originalWidth: Int)
    }

    /// The order in which code-length code lengths are stored.
    private static let codeLengthOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    /// Maps LZ77 distance codes 1...120 to two-dimensional pixel offsets.
    private static let distanceOffsets: [(dx: Int, dy: Int)] = [
        (0, 1), (1, 0), (1, 1), (-1, 1), (0, 2), (2, 0), (1, 2), (-1, 2),
        (2, 1), (-2, 1), (2, 2), (-2, 2), (0, 3), (3, 0), (1, 3), (-1, 3),
        (3, 1), (-3, 1), (2, 3), (-2, 3), (3, 2), (-3, 2), (0, 4), (4, 0),
        (1, 4), (-1, 4), (4, 1), (-4, 1), (3, 3), (-3, 3), (2, 4), (-2, 4),
        (4, 2), (-4, 2), (0, 5), (3, 4), (-3, 4), (4, 3), (-4, 3), (5, 0),
        (1, 5), (-1, 5), (5, 1), (-5, 1), (2, 5), (-2, 5), (5, 2), (-5, 2),
        (4, 4), (-4, 4), (3, 5), (-3, 5), (5, 3), (-5, 3), (0, 6), (6, 0),
        (1, 6), (-1, 6), (6, 1), (-6, 1), (2, 6), (-2, 6), (6, 2), (-6, 2),
        (4, 5), (-4, 5), (5, 4), (-5, 4), (3, 6), (-3, 6), (6, 3), (-6, 3),
        (0, 7), (7, 0), (1, 7), (-1, 7), (5, 5), (-5, 5), (7, 1), (-7, 1),
        (4, 6), (-4, 6), (6, 4), (-6, 4), (2, 7), (-2, 7), (7, 2), (-7, 2),
        (3, 7), (-3, 7), (7, 3), (-7, 3), (5, 6), (-5, 6), (6, 5), (-6, 5),
        (8, 0), (4, 7), (-4, 7), (7, 4), (-7, 4), (8, 1), (8, 2), (6, 6),
        (-6, 6), (8, 3), (5, 7), (-5, 7), (7, 5), (-7, 5), (8, 4), (6, 7),
        (-6, 7), (7, 6), (-7, 6), (8, 5), (7, 7), (-7, 7), (8, 6), (8, 7),
    ]

    private static func decodeLossless(_ payload: [UInt8]) throws -> Image {
        guard payload.first == 0x2F else {
            throw ImageError.invalidData(reason: "Missing VP8L signature")
        }
        var reader = BitReader(Array(payload.dropFirst()))
        let width = try reader.readBits(14) + 1
        let height = try reader.readBits(14) + 1
        _ = try reader.readBit()  // alpha hint
        guard try reader.readBits(3) == 0 else {
            throw ImageError.invalidData(reason: "Unknown VP8L version")
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= Image.maxPixelCount else {
            throw ImageError.invalidData(reason: "Invalid VP8L dimensions")
        }

        let argb = try decodeImageStream(&reader, width: width, height: height, isTopLevel: true)

        var pixels = [RGBA](repeating: .transparent, count: pixelCount)
        for i in 0..<pixelCount {
            let value = argb[i]
            pixels[i] = RGBA(
                red: UInt8((value >> 16) & 0xFF),
                green: UInt8((value >> 8) & 0xFF),
                blue: UInt8(value & 0xFF),
                alpha: UInt8((value >> 24) & 0xFF)
            )
        }
        return Image(width: width, height: height, pixels: pixels)
    }

    private static func decodeImageStream(
        _ reader: inout BitReader,
        width: Int,
        height: Int,
        isTopLevel: Bool
    ) throws -> [UInt32] {
        var transforms: [Transform] = []
        var currentWidth = width

        if isTopLevel {
            var seenTypes = Set<Int>()
            while try reader.readBit() == 1 {
                let type = try reader.readBits(2)
                guard seenTypes.insert(type).inserted else {
                    throw ImageError.invalidData(reason: "Duplicate VP8L transform")
                }
                switch type {
                case 0, 1:
                    let blockBits = try reader.readBits(3) + 2
                    let blocksWide = (currentWidth + (1 << blockBits) - 1) >> blockBits
                    let blocksHigh = (height + (1 << blockBits) - 1) >> blockBits
                    let sub = try decodeImageStream(&reader, width: blocksWide, height: blocksHigh, isTopLevel: false)
                    transforms.append(type == 0
                        ? .predictor(blockBits: blockBits, modes: sub, width: currentWidth)
                        : .colorTransform(blockBits: blockBits, elements: sub, width: currentWidth))
                case 2:
                    transforms.append(.subtractGreen)
                default:  // 3: color indexing
                    let colorCount = try reader.readBits(8) + 1
                    var palette = try decodeImageStream(&reader, width: colorCount, height: 1, isTopLevel: false)
                    for i in 1..<palette.count {
                        palette[i] = addChannels(palette[i], palette[i - 1])
                    }
                    let widthBits = colorCount <= 2 ? 3 : colorCount <= 4 ? 2 : colorCount <= 16 ? 1 : 0
                    transforms.append(.colorIndexing(
                        palette: palette,
                        widthBits: widthBits,
                        originalWidth: currentWidth
                    ))
                    currentWidth = (currentWidth + (1 << widthBits) - 1) >> widthBits
                }
            }
        }

        var argb = try decodeEntropyImage(&reader, width: currentWidth, height: height, allowMeta: isTopLevel)

        for transform in transforms.reversed() {
            argb = try applyInverse(transform, to: argb, height: height)
        }
        return argb
    }

    private static func decodeEntropyImage(
        _ reader: inout BitReader,
        width: Int,
        height: Int,
        allowMeta: Bool
    ) throws -> [UInt32] {
        var cacheBits = 0
        if try reader.readBit() == 1 {
            cacheBits = try reader.readBits(4)
            guard (1...11).contains(cacheBits) else {
                throw ImageError.invalidData(reason: "Invalid VP8L color cache size")
            }
        }

        // Meta prefix groups: a subresolution image selects a code group per block.
        var groupIndexes: [Int] = []
        var metaBlockBits = 0
        var metaWidth = 0
        var groupCount = 1
        if allowMeta, try reader.readBit() == 1 {
            metaBlockBits = try reader.readBits(3) + 2
            metaWidth = (width + (1 << metaBlockBits) - 1) >> metaBlockBits
            let metaHeight = (height + (1 << metaBlockBits) - 1) >> metaBlockBits
            let metaImage = try decodeEntropyImage(&reader, width: metaWidth, height: metaHeight, allowMeta: false)
            groupIndexes = metaImage.map { Int(($0 >> 8) & 0xFFFF) }
            groupCount = (groupIndexes.max() ?? 0) + 1
        }

        let greenAlphabet = 256 + 24 + (cacheBits > 0 ? 1 << cacheBits : 0)
        var groups: [[VP8LCode]] = []
        groups.reserveCapacity(groupCount)
        for _ in 0..<groupCount {
            var codes: [VP8LCode] = []
            for alphabetSize in [greenAlphabet, 256, 256, 256, 40] {
                codes.append(try readPrefixCode(&reader, alphabetSize: alphabetSize))
            }
            groups.append(codes)
        }

        var cache = [UInt32](repeating: 0, count: cacheBits > 0 ? 1 << cacheBits : 0)
        var argb = [UInt32](repeating: 0, count: width * height)
        var position = 0
        var x = 0
        var y = 0

        func emit(_ pixel: UInt32) {
            argb[position] = pixel
            if cacheBits > 0 {
                cache[Int((0x1E35_A7BD &* pixel) >> UInt32(32 - cacheBits))] = pixel
            }
            position += 1
            x += 1
            if x == width {
                x = 0
                y += 1
            }
        }

        while position < width * height {
            let group = groupIndexes.isEmpty
                ? groups[0]
                : groups[groupIndexes[(y >> metaBlockBits) * metaWidth + (x >> metaBlockBits)]]

            let green = try group[0].decode(from: &reader)
            if green < 256 {
                let red = try group[1].decode(from: &reader)
                let blue = try group[2].decode(from: &reader)
                let alpha = try group[3].decode(from: &reader)
                emit(UInt32(alpha) << 24 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue))
            } else if green < 256 + 24 {
                let length = try prefixValue(green - 256, reader: &reader)
                let distanceSymbol = try group[4].decode(from: &reader)
                guard distanceSymbol < 40 else {
                    throw ImageError.invalidData(reason: "Invalid VP8L distance symbol")
                }
                let distanceCode = try prefixValue(distanceSymbol, reader: &reader)
                let distance = mapDistance(distanceCode, width: width)
                guard distance <= position, position + length <= width * height else {
                    throw ImageError.invalidData(reason: "Invalid VP8L back-reference")
                }
                for _ in 0..<length {
                    emit(argb[position - distance])
                }
            } else {
                let index = green - 256 - 24
                guard cacheBits > 0, index < cache.count else {
                    throw ImageError.invalidData(reason: "Invalid VP8L color cache reference")
                }
                emit(cache[index])
            }
        }
        return argb
    }

    private static func readPrefixCode(_ reader: inout BitReader, alphabetSize: Int) throws -> VP8LCode {
        if try reader.readBit() == 1 {  // simple code: one or two symbols
            let symbolCount = try reader.readBit() + 1
            let firstIs8Bits = try reader.readBit()
            let symbol0 = try reader.readBits(firstIs8Bits == 1 ? 8 : 1)
            guard symbol0 < alphabetSize else {
                throw ImageError.invalidData(reason: "VP8L simple code symbol out of range")
            }
            if symbolCount == 1 {
                return .single(symbol0)
            }
            let symbol1 = try reader.readBits(8)
            guard symbol1 < alphabetSize, symbol1 != symbol0 else {
                throw ImageError.invalidData(reason: "VP8L simple code symbol out of range")
            }
            var lengths = [Int](repeating: 0, count: alphabetSize)
            lengths[symbol0] = 1
            lengths[symbol1] = 1
            return .table(try HuffmanTable(codeLengths: lengths))
        }

        // Normal code: the code lengths are themselves prefix-coded.
        var codeLengthLengths = [Int](repeating: 0, count: 19)
        let lengthCount = try reader.readBits(4) + 4
        for i in 0..<lengthCount {
            codeLengthLengths[codeLengthOrder[i]] = try reader.readBits(3)
        }
        let codeLengthCode = try makeCode(from: codeLengthLengths)

        // An optional cap on how many code-length symbols are stored.
        var symbolBudget = alphabetSize
        if try reader.readBit() == 1 {
            let lengthBitCount = 2 + 2 * (try reader.readBits(3))
            symbolBudget = 2 + (try reader.readBits(lengthBitCount))
            guard symbolBudget <= alphabetSize * 2 else {
                throw ImageError.invalidData(reason: "Invalid VP8L symbol budget")
            }
        }

        var lengths = [Int](repeating: 0, count: alphabetSize)
        var previousLength = 8
        var symbol = 0
        while symbol < alphabetSize, symbolBudget > 0 {
            symbolBudget -= 1
            let lengthSymbol = try codeLengthCode.decode(from: &reader)
            switch lengthSymbol {
            case 0..<16:
                lengths[symbol] = lengthSymbol
                symbol += 1
                if lengthSymbol != 0 {
                    previousLength = lengthSymbol
                }
            case 16:
                let repeatCount = 3 + (try reader.readBits(2))
                guard symbol + repeatCount <= alphabetSize else {
                    throw ImageError.invalidData(reason: "VP8L code lengths overflow their alphabet")
                }
                for _ in 0..<repeatCount {
                    lengths[symbol] = previousLength
                    symbol += 1
                }
            case 17:
                symbol += 3 + (try reader.readBits(3))
            case 18:
                symbol += 11 + (try reader.readBits(7))
            default:
                throw ImageError.invalidData(reason: "Invalid VP8L code length symbol")
            }
        }
        guard symbol <= alphabetSize else {
            throw ImageError.invalidData(reason: "VP8L code lengths overflow their alphabet")
        }
        return try makeCode(from: lengths)
    }

    private static func makeCode(from lengths: [Int]) throws -> VP8LCode {
        let used = lengths.enumerated().filter { $0.element > 0 }
        guard !used.isEmpty else {
            throw ImageError.invalidData(reason: "Empty VP8L prefix code")
        }
        if used.count == 1 {
            return .single(used[0].offset)
        }
        return .table(try HuffmanTable(codeLengths: lengths))
    }

    /// LZ77 prefix coding: turns a prefix code into a length or distance value.
    private static func prefixValue(_ code: Int, reader: inout BitReader) throws -> Int {
        if code < 4 {
            return code + 1
        }
        let extraBits = (code - 2) >> 1
        let offset = (2 + (code & 1)) << extraBits
        return offset + (try reader.readBits(extraBits)) + 1
    }

    private static func mapDistance(_ code: Int, width: Int) -> Int {
        guard code <= 120 else {
            return code - 120
        }
        let (dx, dy) = distanceOffsets[code - 1]
        return max(1, dy * width + dx)
    }

    // MARK: Inverse transforms

    /// Adds two pixels channel by channel, modulo 256.
    private static func addChannels(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let alpha = ((a >> 24) &+ (b >> 24)) & 0xFF
        let red = ((a >> 16) &+ (b >> 16)) & 0xFF
        let green = ((a >> 8) &+ (b >> 8)) & 0xFF
        let blue = (a &+ b) & 0xFF
        return alpha << 24 | red << 16 | green << 8 | blue
    }

    private static func applyInverse(_ transform: Transform, to argb: [UInt32], height: Int) throws -> [UInt32] {
        switch transform {
        case .subtractGreen:
            var result = argb
            for i in result.indices {
                let green = (result[i] >> 8) & 0xFF
                let red = (((result[i] >> 16) & 0xFF) &+ green) & 0xFF
                let blue = ((result[i] & 0xFF) &+ green) & 0xFF
                result[i] = (result[i] & 0xFF00_FF00) | red << 16 | blue
            }
            return result

        case .predictor(let blockBits, let modes, let width):
            var result = argb
            let blocksWide = (width + (1 << blockBits) - 1) >> blockBits
            for y in 0..<height {
                for x in 0..<width {
                    let position = y * width + x
                    let predicted: UInt32
                    if x == 0 && y == 0 {
                        predicted = 0xFF00_0000
                    } else if y == 0 {
                        predicted = result[position - 1]  // L
                    } else if x == 0 {
                        predicted = result[position - width]  // T
                    } else {
                        let modeIndex = (y >> blockBits) * blocksWide + (x >> blockBits)
                        guard modeIndex < modes.count else {
                            throw ImageError.invalidData(reason: "VP8L predictor image too small")
                        }
                        let mode = Int((modes[modeIndex] >> 8) & 0xFF)
                        // At the right edge, position - width + 1 wraps to the
                        // leftmost pixel of the current row, as the spec requires.
                        predicted = try predict(
                            mode: mode,
                            left: result[position - 1],
                            top: result[position - width],
                            topLeft: result[position - width - 1],
                            topRight: result[position - width + 1]
                        )
                    }
                    result[position] = addChannels(result[position], predicted)
                }
            }
            return result

        case .colorTransform(let blockBits, let elements, let width):
            var result = argb
            let blocksWide = (width + (1 << blockBits) - 1) >> blockBits
            for y in 0..<height {
                for x in 0..<width {
                    let position = y * width + x
                    let elementIndex = (y >> blockBits) * blocksWide + (x >> blockBits)
                    guard elementIndex < elements.count else {
                        throw ImageError.invalidData(reason: "VP8L color transform image too small")
                    }
                    let element = elements[elementIndex]
                    let greenToRed = Int8(truncatingIfNeeded: element)         // blue byte
                    let greenToBlue = Int8(truncatingIfNeeded: element >> 8)   // green byte
                    let redToBlue = Int8(truncatingIfNeeded: element >> 16)    // red byte
                    let green = Int8(truncatingIfNeeded: result[position] >> 8)

                    var red = Int((result[position] >> 16) & 0xFF)
                    var blue = Int(result[position] & 0xFF)
                    red = (red + colorDelta(greenToRed, green)) & 0xFF
                    blue = (blue + colorDelta(greenToBlue, green)) & 0xFF
                    blue = (blue + colorDelta(redToBlue, Int8(truncatingIfNeeded: UInt8(red)))) & 0xFF
                    result[position] = (result[position] & 0xFF00_FF00) | UInt32(red) << 16 | UInt32(blue)
                }
            }
            return result

        case .colorIndexing(let palette, let widthBits, let originalWidth):
            let packedWidth = argb.count / height
            let pixelsPerPacked = 1 << widthBits
            let bitsPerPixel = 8 >> widthBits
            let mask = (1 << bitsPerPixel) - 1
            var result = [UInt32](repeating: 0, count: originalWidth * height)
            for y in 0..<height {
                for x in 0..<originalWidth {
                    let packed = argb[y * packedWidth + x / pixelsPerPacked]
                    let green = Int((packed >> 8) & 0xFF)
                    let index = (green >> ((x % pixelsPerPacked) * bitsPerPixel)) & mask
                    guard index < palette.count else {
                        throw ImageError.invalidData(reason: "VP8L palette index out of range")
                    }
                    result[y * originalWidth + x] = palette[index]
                }
            }
            return result
        }
    }

    private static func colorDelta(_ transform: Int8, _ channel: Int8) -> Int {
        (Int(transform) * Int(channel)) >> 5
    }

    private static func predict(
        mode: Int,
        left: UInt32,
        top: UInt32,
        topLeft: UInt32,
        topRight: UInt32
    ) throws -> UInt32 {
        switch mode {
        case 0: return 0xFF00_0000
        case 1: return left
        case 2: return top
        case 3: return topRight
        case 4: return topLeft
        case 5: return average2(average2(left, topRight), top)
        case 6: return average2(left, topLeft)
        case 7: return average2(left, top)
        case 8: return average2(topLeft, top)
        case 9: return average2(top, topRight)
        case 10: return average2(average2(left, topLeft), average2(top, topRight))
        case 11: return select(left: left, top: top, topLeft: topLeft)
        case 12: return clampAddSubtractFull(left, top, topLeft)
        case 13: return clampAddSubtractHalf(average2(left, top), topLeft)
        default: throw ImageError.invalidData(reason: "Invalid VP8L predictor mode")
        }
    }

    /// Per-channel (a + b) / 2 without unpacking the channels.
    private static func average2(_ a: UInt32, _ b: UInt32) -> UInt32 {
        (((a ^ b) & 0xFEFE_FEFE) >> 1) &+ (a & b)
    }

    private static func select(left: UInt32, top: UInt32, topLeft: UInt32) -> UInt32 {
        var leftDistance = 0
        var topDistance = 0
        for shift in [UInt32(24), 16, 8, 0] {
            let l = Int((left >> shift) & 0xFF)
            let t = Int((top >> shift) & 0xFF)
            let predicted = l + t - Int((topLeft >> shift) & 0xFF)
            leftDistance += abs(predicted - l)
            topDistance += abs(predicted - t)
        }
        return leftDistance < topDistance ? left : top
    }

    private static func clampAddSubtractFull(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        var result: UInt32 = 0
        for shift in [UInt32(24), 16, 8, 0] {
            let value = Int((a >> shift) & 0xFF) + Int((b >> shift) & 0xFF) - Int((c >> shift) & 0xFF)
            result |= UInt32(min(255, max(0, value))) << shift
        }
        return result
    }

    private static func clampAddSubtractHalf(_ a: UInt32, _ b: UInt32) -> UInt32 {
        var result: UInt32 = 0
        for shift in [UInt32(24), 16, 8, 0] {
            let av = Int((a >> shift) & 0xFF)
            let bv = Int((b >> shift) & 0xFF)
            result |= UInt32(min(255, max(0, av + (av - bv) / 2))) << shift
        }
        return result
    }

    // MARK: Encoding

    static func encode(_ image: Image) throws -> Data {
        try encode(image, options: EncodingOptions())
    }

    static func encode(_ image: Image, options: EncodingOptions) throws -> Data {
        guard image.width <= 1 << 14, image.height <= 1 << 14 else {
            throw ImageError.invalidDimensions
        }

        var bits = BitWriter()
        bits.writeBits(image.width - 1, count: 14)
        bits.writeBits(image.height - 1, count: 14)
        bits.writeBits(image.pixels.contains { $0.alpha < 255 } ? 1 : 0, count: 1)
        bits.writeBits(0, count: 3)  // version

        bits.writeBits(0, count: 1)  // no transforms
        bits.writeBits(0, count: 1)  // no color cache
        bits.writeBits(0, count: 1)  // no meta prefix groups

        // Green (280 symbols) and red/blue/alpha (256 each) get fixed 8-bit
        // codes, described with a two-symbol code-length code for {0, 8}.
        writeFixedEightBitCode(&bits, alphabetSize: 280, codedSymbols: 256)
        for _ in 0..<3 {
            writeFixedEightBitCode(&bits, alphabetSize: 256, codedSymbols: 256)
        }
        // The distance code is never used; a single-symbol simple code is 4 bits.
        bits.writeBits(1, count: 1)  // simple
        bits.writeBits(0, count: 1)  // one symbol
        bits.writeBits(0, count: 1)  // coded in one bit
        bits.writeBits(0, count: 1)  // symbol 0

        // With all-eight-bit canonical codes, each symbol's code equals its value.
        for pixel in image.pixels {
            bits.writeCode(Int(pixel.green), length: 8)
            bits.writeCode(Int(pixel.red), length: 8)
            bits.writeCode(Int(pixel.blue), length: 8)
            bits.writeCode(Int(pixel.alpha), length: 8)
        }

        var payload: [UInt8] = [0x2F]
        payload += bits.finish()

        // Assemble the chunk list; metadata requires the extended (VP8X) container.
        var chunks: [(fourCC: String, payload: [UInt8])] = []
        if let exif = options.exif, !exif.isEmpty {
            var vp8x: [UInt8] = []
            let hasAlpha = image.pixels.contains { $0.alpha < 255 }
            vp8x.append(hasAlpha ? 0x18 : 0x08)  // EXIF flag, plus alpha when present
            vp8x += [0, 0, 0]  // reserved
            let width = image.width - 1
            let height = image.height - 1
            vp8x += [UInt8(width & 0xFF), UInt8(width >> 8 & 0xFF), UInt8(width >> 16 & 0xFF)]
            vp8x += [UInt8(height & 0xFF), UInt8(height >> 8 & 0xFF), UInt8(height >> 16 & 0xFF)]
            chunks.append(("VP8X", vp8x))
            chunks.append(("VP8L", payload))
            chunks.append(("EXIF", exif.serializedPayload()))
        } else {
            chunks.append(("VP8L", payload))
        }

        var body = ByteWriter()
        for chunk in chunks {
            body.writeBytes(Array(chunk.fourCC.utf8))
            body.writeUInt32LittleEndian(UInt32(chunk.payload.count))
            body.writeBytes(chunk.payload)
            if chunk.payload.count & 1 == 1 {
                body.writeByte(0)
            }
        }

        var writer = ByteWriter()
        writer.writeBytes(Array("RIFF".utf8))
        writer.writeUInt32LittleEndian(UInt32(4 + body.bytes.count))
        writer.writeBytes(Array("WEBP".utf8))
        writer.writeBytes(body.bytes)
        return writer.data
    }

    /// Writes a prefix code giving the first `codedSymbols` symbols length 8
    /// and the rest length 0, via a code-length code over {0, 8}.
    private static func writeFixedEightBitCode(_ bits: inout BitWriter, alphabetSize: Int, codedSymbols: Int) {
        bits.writeBits(0, count: 1)  // not simple
        bits.writeBits(12 - 4, count: 4)  // twelve code-length code lengths follow
        // In code-length order 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8:
        // symbols 0 and 8 get length 1 ("0" and "1"), everything else 0.
        for length in [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1] {
            bits.writeBits(length, count: 3)
        }
        bits.writeBits(0, count: 1)  // no symbol budget; entries cover the alphabet
        for _ in 0..<codedSymbols {
            bits.writeBits(1, count: 1)  // code-length symbol 8
        }
        for _ in 0..<(alphabetSize - codedSymbols) {
            bits.writeBits(0, count: 1)  // code-length symbol 0
        }
    }
}
