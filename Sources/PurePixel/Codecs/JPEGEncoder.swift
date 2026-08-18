import Foundation

// The encoding half of JPEGCodec: baseline 4:4:4 YCbCr with the standard
// Annex K quantization and Huffman tables. Quality comes from
// EncodingOptions.jpegQuality (1...100, default 85).
extension JPEGCodec {

    // MARK: Standard tables (ITU T.81 Annex K)

    private static let baseLuminanceQuantization = [
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99,
    ]

    private static let baseChrominanceQuantization = [
        17, 18, 24, 47, 99, 99, 99, 99,
        18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
    ]

    private static let dcLuminanceCounts = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
    private static let dcLuminanceSymbols: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    private static let dcChrominanceCounts = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
    private static let dcChrominanceSymbols: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

    private static let acLuminanceCounts = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125]
    private static let acLuminanceSymbols: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
        0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ]

    private static let acChrominanceCounts = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119]
    private static let acChrominanceSymbols: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
        0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
        0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
        0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
        0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
        0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ]

    /// libjpeg's quality curve: linear above 50, hyperbolic below.
    private static func scaledTable(_ base: [Int], quality: Int) -> [Int] {
        let scale = quality < 50 ? 5000 / quality : 200 - 2 * quality
        return base.map { min(255, max(1, ($0 * scale + 50) / 100)) }
    }

    // MARK: Encoding

    static func encode(_ image: Image) throws -> Data {
        try encode(image, options: EncodingOptions())
    }

    static func encode(_ image: Image, options: EncodingOptions) throws -> Data {
        guard image.width <= 65535, image.height <= 65535 else {
            throw ImageError.invalidDimensions
        }

        let quality = min(100, max(1, options.jpegQuality))
        let luminanceQuantization = scaledTable(baseLuminanceQuantization, quality: quality)
        let chrominanceQuantization = scaledTable(baseChrominanceQuantization, quality: quality)

        // Convert to level-shifted YCbCr planes padded to multiples of eight
        // by edge replication (alpha is discarded).
        let paddedWidth = (image.width + 7) / 8 * 8
        let paddedHeight = (image.height + 7) / 8 * 8
        var planes = [[Double]](
            repeating: [Double](repeating: 0, count: paddedWidth * paddedHeight),
            count: 3
        )
        for y in 0..<paddedHeight {
            for x in 0..<paddedWidth {
                let pixel = image.pixels[min(y, image.height - 1) * image.width + min(x, image.width - 1)]
                let red = Double(pixel.red)
                let green = Double(pixel.green)
                let blue = Double(pixel.blue)
                let i = y * paddedWidth + x
                planes[0][i] = 0.299 * red + 0.587 * green + 0.114 * blue - 128
                planes[1][i] = -0.168736 * red - 0.331264 * green + 0.5 * blue
                planes[2][i] = 0.5 * red - 0.418688 * green - 0.081312 * blue
            }
        }

        let dcEncoders = [
            HuffmanEncoder(counts: dcLuminanceCounts, symbols: dcLuminanceSymbols),
            HuffmanEncoder(counts: dcChrominanceCounts, symbols: dcChrominanceSymbols),
        ]
        let acEncoders = [
            HuffmanEncoder(counts: acLuminanceCounts, symbols: acLuminanceSymbols),
            HuffmanEncoder(counts: acChrominanceCounts, symbols: acChrominanceSymbols),
        ]
        let quantizations = [luminanceQuantization, chrominanceQuantization]

        var bitWriter = JPEGBitWriter()
        var predictors = [0, 0, 0]
        for blockY in stride(from: 0, to: paddedHeight, by: 8) {
            for blockX in stride(from: 0, to: paddedWidth, by: 8) {
                for componentIndex in 0..<3 {
                    let tableIndex = componentIndex == 0 ? 0 : 1
                    encodeBlock(
                        plane: planes[componentIndex],
                        planeWidth: paddedWidth,
                        originX: blockX,
                        originY: blockY,
                        quantization: quantizations[tableIndex],
                        dcEncoder: dcEncoders[tableIndex],
                        acEncoder: acEncoders[tableIndex],
                        predictor: &predictors[componentIndex],
                        to: &bitWriter
                    )
                }
            }
        }
        let entropyData = bitWriter.finish()

        // Assemble the file.
        var writer = ByteWriter()
        writer.writeBytes([0xFF, 0xD8])  // SOI

        writer.writeBytes([0xFF, 0xE0])  // APP0 (JFIF)
        writer.writeUInt16BigEndian(16)
        writer.writeBytes(Array("JFIF".utf8) + [0])
        writer.writeBytes([1, 1])  // version 1.1
        writer.writeByte(0)  // density unit: none
        writer.writeUInt16BigEndian(1)  // horizontal density
        writer.writeUInt16BigEndian(1)  // vertical density
        writer.writeBytes([0, 0])  // no thumbnail

        writer.writeBytes([0xFF, 0xDB])  // DQT, both tables in zigzag order
        writer.writeUInt16BigEndian(UInt16(2 + 2 * 65))
        writer.writeByte(0x00)
        for k in 0..<64 {
            writer.writeByte(UInt8(luminanceQuantization[zigzag[k]]))
        }
        writer.writeByte(0x01)
        for k in 0..<64 {
            writer.writeByte(UInt8(chrominanceQuantization[zigzag[k]]))
        }

        writer.writeBytes([0xFF, 0xC0])  // SOF0: 8-bit, three components, 4:4:4
        writer.writeUInt16BigEndian(UInt16(8 + 3 * 3))
        writer.writeByte(8)
        writer.writeUInt16BigEndian(UInt16(image.height))
        writer.writeUInt16BigEndian(UInt16(image.width))
        writer.writeByte(3)
        writer.writeBytes([1, 0x11, 0])  // Y
        writer.writeBytes([2, 0x11, 1])  // Cb
        writer.writeBytes([3, 0x11, 1])  // Cr

        writeHuffmanTable(descriptor: 0x00, counts: dcLuminanceCounts, symbols: dcLuminanceSymbols, to: &writer)
        writeHuffmanTable(descriptor: 0x10, counts: acLuminanceCounts, symbols: acLuminanceSymbols, to: &writer)
        writeHuffmanTable(descriptor: 0x01, counts: dcChrominanceCounts, symbols: dcChrominanceSymbols, to: &writer)
        writeHuffmanTable(descriptor: 0x11, counts: acChrominanceCounts, symbols: acChrominanceSymbols, to: &writer)

        writer.writeBytes([0xFF, 0xDA])  // SOS
        writer.writeUInt16BigEndian(UInt16(6 + 2 * 3))
        writer.writeByte(3)
        writer.writeBytes([1, 0x00])
        writer.writeBytes([2, 0x11])
        writer.writeBytes([3, 0x11])
        writer.writeBytes([0, 63, 0])  // full spectral range, no approximation

        writer.writeBytes(entropyData)
        writer.writeBytes([0xFF, 0xD9])  // EOI
        return writer.data
    }

    private static func writeHuffmanTable(
        descriptor: UInt8,
        counts: [Int],
        symbols: [UInt8],
        to writer: inout ByteWriter
    ) {
        writer.writeBytes([0xFF, 0xC4])
        writer.writeUInt16BigEndian(UInt16(2 + 1 + 16 + symbols.count))
        writer.writeByte(descriptor)
        writer.writeBytes(counts.map { UInt8($0) })
        writer.writeBytes(symbols)
    }

    private static func encodeBlock(
        plane: [Double],
        planeWidth: Int,
        originX: Int,
        originY: Int,
        quantization: [Int],
        dcEncoder: HuffmanEncoder,
        acEncoder: HuffmanEncoder,
        predictor: inout Int,
        to writer: inout JPEGBitWriter
    ) {
        // Forward DCT.
        var frequency = [Double](repeating: 0, count: 64)
        for v in 0..<8 {
            for u in 0..<8 {
                var sum = 0.0
                for y in 0..<8 {
                    for x in 0..<8 {
                        sum += plane[(originY + y) * planeWidth + originX + x]
                            * cosineTable[u][x] * cosineTable[v][y]
                    }
                }
                frequency[v * 8 + u] = sum * normalization[u] * normalization[v] / 4
            }
        }

        var quantized = [Int](repeating: 0, count: 64)
        for i in 0..<64 {
            // The clamp keeps AC magnitudes within the 10 bits the standard
            // Huffman tables can express (only reachable near quality 100).
            quantized[i] = min(1023, max(-1023, Int((frequency[i] / Double(quantization[i])).rounded())))
        }

        // DC coefficient, coded as the difference from the previous block.
        let difference = quantized[0] - predictor
        predictor = quantized[0]
        let dcSize = bitSize(of: difference)
        dcEncoder.write(dcSize, to: &writer)
        writeAmplitude(difference, size: dcSize, to: &writer)

        // AC coefficients in zigzag order with run-length coding.
        var zeroRun = 0
        for k in 1..<64 {
            let value = quantized[zigzag[k]]
            if value == 0 {
                zeroRun += 1
                continue
            }
            while zeroRun > 15 {
                acEncoder.write(0xF0, to: &writer)  // ZRL: sixteen zeros
                zeroRun -= 16
            }
            let size = bitSize(of: value)
            acEncoder.write(zeroRun << 4 | size, to: &writer)
            writeAmplitude(value, size: size, to: &writer)
            zeroRun = 0
        }
        if zeroRun > 0 {
            acEncoder.write(0x00, to: &writer)  // EOB
        }
    }

    private static func bitSize(of value: Int) -> Int {
        Int.bitWidth - abs(value).leadingZeroBitCount
    }

    private static func writeAmplitude(_ value: Int, size: Int, to writer: inout JPEGBitWriter) {
        guard size > 0 else { return }
        writer.writeBits(value < 0 ? value + (1 << size) - 1 : value, count: size)
    }

    /// Canonical JPEG Huffman codes for encoding, built from a standard
    /// (counts, symbols) table definition.
    private struct HuffmanEncoder {
        private var codes = [Int](repeating: 0, count: 256)
        private var lengths = [Int](repeating: 0, count: 256)

        init(counts: [Int], symbols: [UInt8]) {
            precondition(counts.reduce(0, +) == symbols.count, "Huffman counts must match symbol count")
            var code = 0
            var symbolIndex = 0
            for length in 1...16 {
                for _ in 0..<counts[length - 1] {
                    let symbol = Int(symbols[symbolIndex])
                    codes[symbol] = code
                    lengths[symbol] = length
                    code += 1
                    symbolIndex += 1
                }
                code <<= 1
            }
        }

        func write(_ symbol: Int, to writer: inout JPEGBitWriter) {
            precondition(lengths[symbol] > 0, "Symbol missing from Huffman table")
            writer.writeBits(codes[symbol], count: lengths[symbol])
        }
    }
}

/// Writes bits most-significant-bit first, stuffing a zero byte after every
/// 0xFF as JPEG entropy coding requires; the final partial byte is padded
/// with one bits.
private struct JPEGBitWriter {
    private var bytes: [UInt8] = []
    private var currentByte = 0
    private var bitCount = 0

    mutating func writeBits(_ value: Int, count: Int) {
        for i in (0..<count).reversed() {
            currentByte = currentByte << 1 | (value >> i & 1)
            bitCount += 1
            if bitCount == 8 {
                bytes.append(UInt8(currentByte))
                if currentByte == 0xFF {
                    bytes.append(0x00)
                }
                currentByte = 0
                bitCount = 0
            }
        }
    }

    mutating func finish() -> [UInt8] {
        while bitCount > 0 {
            writeBits(1, count: 1)
        }
        return bytes
    }
}
