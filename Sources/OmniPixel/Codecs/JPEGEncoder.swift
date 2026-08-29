import Foundation

// The encoding half of JPEGCodec: baseline 4:4:4 YCbCr with the standard
// Annex K quantization and Huffman tables. Quality comes from
// EncodingOptions.jpegQuality (1...100, default 85).
//
// The scan is produced in two passes. The first colour-converts, transforms
// and quantizes an MCU row into 16-bit coefficients and runs concurrently
// across rows; the second Huffman-codes those coefficients and is inherently
// serial, because the DC predictor chain and the bit alignment thread through
// every block. The passes alternate over chunks of MCU rows so the
// coefficient scratch stays a few megabytes regardless of image size.
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

        // Assemble the header first, so a rejected EXIF block fails before the
        // scan is encoded.
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

        if let exif = options.exif, !exif.isEmpty {
            let payload = exif.serializedPayload()
            guard payload.count <= 65_527 else {
                throw ImageError.unsupportedFeature(reason: "EXIF metadata over 64 KB cannot be embedded in JPEG")
            }
            writer.writeBytes([0xFF, 0xE1])  // APP1 (Exif)
            writer.writeUInt16BigEndian(UInt16(2 + 6 + payload.count))
            writer.writeBytes(Array("Exif".utf8) + [0, 0])
            writer.writeBytes(payload)
        }

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

        writer.writeBytes(encodeScan(
            image,
            luminanceQuantization: luminanceQuantization,
            chrominanceQuantization: chrominanceQuantization
        ))
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

    // MARK: Scan encoding

    /// Where each of the four code tables starts in the flattened
    /// Huffman entry array.
    private static let dcLuminanceTable = 0
    private static let acLuminanceTable = 256
    private static let dcChrominanceTable = 512
    private static let acChrominanceTable = 768

    /// One position of the zigzag scan: which coefficient of the naturally
    /// ordered block it reads, and the reciprocal of the divisor to apply.
    /// Pairing the two keeps the quantization loop down to a single table.
    private struct QuantizationStep {
        var naturalIndex: Int
        var reciprocal: Double
    }

    /// Arai–Agui–Nakajima scale factors: the fast DCT below leaves its output
    /// multiplied by 8·aan[row]·aan[column], which the divisors fold back out.
    private static let aanScaleFactor: [Double] = (0..<8).map {
        $0 == 0 ? 1 : cos(Double($0) * Double.pi / 16) * Double(2).squareRoot()
    }

    /// Encodes the entropy-coded segment: every MCU in raster order, each
    /// carrying one Y, Cb and Cr block (4:4:4, so one block per component).
    private static func encodeScan(
        _ image: Image,
        luminanceQuantization: [Int],
        chrominanceQuantization: [Int]
    ) -> [UInt8] {
        var quantizationSteps = [QuantizationStep](
            repeating: QuantizationStep(naturalIndex: 0, reciprocal: 0),
            count: 128
        )
        for k in 0..<64 {
            let natural = zigzag[k]
            let scale = 8 * aanScaleFactor[natural / 8] * aanScaleFactor[natural % 8]
            quantizationSteps[k] = QuantizationStep(
                naturalIndex: natural,
                reciprocal: 1 / (Double(luminanceQuantization[natural]) * scale)
            )
            quantizationSteps[64 + k] = QuantizationStep(
                naturalIndex: natural,
                reciprocal: 1 / (Double(chrominanceQuantization[natural]) * scale)
            )
        }

        // The four canonical code tables flattened into one array of
        // (length << 16 | code) entries, so the hot loop needs a single base
        // pointer plus a table offset.
        var huffmanEntries = [UInt32](repeating: 0, count: 4 * 256)
        fillHuffmanCodes(
            into: &huffmanEntries, at: dcLuminanceTable,
            counts: dcLuminanceCounts, symbols: dcLuminanceSymbols
        )
        fillHuffmanCodes(
            into: &huffmanEntries, at: acLuminanceTable,
            counts: acLuminanceCounts, symbols: acLuminanceSymbols
        )
        fillHuffmanCodes(
            into: &huffmanEntries, at: dcChrominanceTable,
            counts: dcChrominanceCounts, symbols: dcChrominanceSymbols
        )
        fillHuffmanCodes(
            into: &huffmanEntries, at: acChrominanceTable,
            counts: acChrominanceCounts, symbols: acChrominanceSymbols
        )

        let width = image.width
        let height = image.height
        let mcuColumns = (width + 7) / 8
        let mcuRows = (height + 7) / 8
        let blocksPerRow = mcuColumns * 3
        let coefficientsPerRow = blocksPerRow * 64

        // Transform a band of MCU rows at a time, sized so the coefficient
        // scratch stays around two megabytes.
        let rowsPerChunk = max(1, min(mcuRows, 2_000_000 / (coefficientsPerRow * MemoryLayout<Int16>.stride)))
        // Below roughly a thousand blocks the dispatch overhead outweighs the
        // work, so small images stay on one thread.
        let runsConcurrently = mcuRows * mcuColumns >= 1024
        var scratch = [Int16](repeating: 0, count: rowsPerChunk * coefficientsPerRow)
        var occupancy = [UInt64](repeating: 0, count: rowsPerChunk * blocksPerRow)

        var bitWriter = JPEGBitWriter(capacityHint: mcuRows * mcuColumns * 48)
        var predictors = (luma: 0, blueChroma: 0, redChroma: 0)

        image.pixels.withUnsafeBufferPointer { pixelBuffer in
            quantizationSteps.withUnsafeBufferPointer { stepBuffer in
                huffmanEntries.withUnsafeBufferPointer { huffmanBuffer in
                    let pixels = pixelBuffer.baseAddress!
                    let steps = stepBuffer.baseAddress!
                    let huffman = huffmanBuffer.baseAddress!

                    var firstRow = 0
                    while firstRow < mcuRows {
                        let chunkRows = min(rowsPerChunk, mcuRows - firstRow)
                        let bandStart = firstRow

                        scratch.withUnsafeMutableBufferPointer { chunk in
                            occupancy.withUnsafeMutableBufferPointer { masks in
                                nonisolated(unsafe) let output = chunk.baseAddress!
                                nonisolated(unsafe) let maskOutput = masks.baseAddress!
                                nonisolated(unsafe) let source = pixels
                                nonisolated(unsafe) let divisors = steps
                                let transformRow: @Sendable (Int) -> Void = { index in
                                    transformMCURow(
                                        mcuRow: bandStart + index,
                                        mcuColumns: mcuColumns,
                                        pixels: source,
                                        width: width,
                                        height: height,
                                        steps: divisors,
                                        into: output + index * coefficientsPerRow,
                                        occupancy: maskOutput + index * blocksPerRow
                                    )
                                }
                                if runsConcurrently {
                                    DispatchQueue.concurrentPerform(iterations: chunkRows, execute: transformRow)
                                } else {
                                    for index in 0..<chunkRows {
                                        transformRow(index)
                                    }
                                }
                            }
                        }

                        scratch.withUnsafeBufferPointer { chunk in
                            occupancy.withUnsafeBufferPointer { masks in
                                encodeMCUs(
                                    chunk.baseAddress!,
                                    occupancy: masks.baseAddress!,
                                    count: chunkRows * mcuColumns,
                                    huffman: huffman,
                                    predictors: &predictors,
                                    to: &bitWriter
                                )
                            }
                        }

                        firstRow += chunkRows
                    }
                }
            }
        }

        return bitWriter.finish()
    }

    /// Fills 256 canonical `(length << 16 | code)` entries from a standard
    /// (counts, symbols) table definition; unused symbols stay zero.
    private static func fillHuffmanCodes(
        into entries: inout [UInt32],
        at base: Int,
        counts: [Int],
        symbols: [UInt8]
    ) {
        precondition(counts.reduce(0, +) == symbols.count, "Huffman counts must match symbol count")
        var code: UInt32 = 0
        var symbolIndex = 0
        for length in 1...16 {
            for _ in 0..<counts[length - 1] {
                entries[base + Int(symbols[symbolIndex])] = UInt32(length) << 16 | code
                code += 1
                symbolIndex += 1
            }
            code <<= 1
        }
    }

    // MARK: Transform pass

    /// Colour-converts, transforms and quantizes one MCU row, writing three
    /// zigzag-ordered 64-coefficient blocks (Y, Cb, Cr) per MCU, plus a
    /// bitmask per block marking which coefficients came out non-zero. The
    /// mask costs nothing here — the values are already in hand — and saves
    /// the serial entropy pass from scanning for them.
    private static func transformMCURow(
        mcuRow: Int,
        mcuColumns: Int,
        pixels: UnsafePointer<RGBA>,
        width: Int,
        height: Int,
        steps: UnsafePointer<QuantizationStep>,
        into output: UnsafeMutablePointer<Int16>,
        occupancy: UnsafeMutablePointer<UInt64>
    ) {
        let originY = mcuRow * 8
        withUnsafeTemporaryAllocation(of: Double.self, capacity: 3 * 64) { scratch in
            let block = scratch.baseAddress!
            for mcu in 0..<mcuColumns {
                loadYCbCrBlock(
                    pixels: pixels,
                    width: width,
                    height: height,
                    originX: mcu * 8,
                    originY: originY,
                    into: block
                )
                for component in 0..<3 {
                    let coefficients = block + component * 64
                    forwardDCT(coefficients)

                    let step = steps + (component == 0 ? 0 : 64)
                    let destination = output + (mcu * 3 + component) * 64
                    var nonZero: UInt64 = 0
                    for k in 0..<64 {
                        let value = (coefficients[step[k].naturalIndex] * step[k].reciprocal).rounded()
                        // The clamp keeps AC magnitudes within the 10 bits the
                        // standard Huffman tables can express (only reachable
                        // near quality 100).
                        let quantized = Int16(min(1023, max(-1023, value)))
                        destination[k] = quantized
                        nonZero |= (quantized == 0 ? 0 : 1) << UInt64(k)
                    }
                    occupancy[mcu * 3 + component] = nonZero
                }
            }
        }
    }

    /// Reads an 8×8 pixel block and writes level-shifted Y, Cb and Cr samples
    /// into three consecutive 64-sample blocks. Blocks hanging off the right
    /// or bottom edge replicate the last real column and row.
    private static func loadYCbCrBlock(
        pixels: UnsafePointer<RGBA>,
        width: Int,
        height: Int,
        originX: Int,
        originY: Int,
        into block: UnsafeMutablePointer<Double>
    ) {
        let luma = block
        let blueChroma = block + 64
        let redChroma = block + 128
        let validColumns = min(8, width - originX)
        for row in 0..<8 {
            let source = pixels + min(originY + row, height - 1) * width + originX
            let destination = row * 8
            for column in 0..<validColumns {
                let pixel = source[column]
                let red = Double(pixel.red)
                let green = Double(pixel.green)
                let blue = Double(pixel.blue)
                luma[destination + column] = 0.299 * red + 0.587 * green + 0.114 * blue - 128
                blueChroma[destination + column] = -0.168736 * red - 0.331264 * green + 0.5 * blue
                redChroma[destination + column] = 0.5 * red - 0.418688 * green - 0.081312 * blue
            }
            for column in validColumns..<8 {
                luma[destination + column] = luma[destination + validColumns - 1]
                blueChroma[destination + column] = blueChroma[destination + validColumns - 1]
                redChroma[destination + column] = redChroma[destination + validColumns - 1]
            }
        }
    }

    // Rotation constants of the AA&N factorization: cos(π/4), sin(π/8),
    // cos(π/8) − sin(π/8) and cos(π/8) + sin(π/8).
    private static let cosPiOver4 = 0.707106781186547524
    private static let sinPiOver8 = 0.382683432365089772
    private static let cosMinusSinPiOver8 = 0.541196100146196984
    private static let cosPlusSinPiOver8 = 1.306562964876376528

    /// In-place Arai–Agui–Nakajima scaled forward DCT of an 8×8 block: eight
    /// row butterflies, then eight column butterflies. Trading the textbook
    /// 4096 multiplies for 80 is the single biggest win in the encoder; the
    /// leftover per-coefficient scaling rides along in the quantization
    /// reciprocals instead of being undone here.
    private static func forwardDCT(_ block: UnsafeMutablePointer<Double>) {
        for row in 0..<8 {
            butterfly(block, base: row * 8, step: 1)
        }
        for column in 0..<8 {
            butterfly(block, base: column, step: 8)
        }
    }

    /// One 1-D pass of the AA&N factorization over eight samples starting at
    /// `base` and spaced `step` apart.
    @inline(__always)
    private static func butterfly(_ block: UnsafeMutablePointer<Double>, base: Int, step: Int) {
        let s0 = block[base]
        let s1 = block[base + step]
        let s2 = block[base + 2 * step]
        let s3 = block[base + 3 * step]
        let s4 = block[base + 4 * step]
        let s5 = block[base + 5 * step]
        let s6 = block[base + 6 * step]
        let s7 = block[base + 7 * step]

        let tmp0 = s0 + s7, tmp7 = s0 - s7
        let tmp1 = s1 + s6, tmp6 = s1 - s6
        let tmp2 = s2 + s5, tmp5 = s2 - s5
        let tmp3 = s3 + s4, tmp4 = s3 - s4

        // Even part: a two-level butterfly plus one rotation.
        let even0 = tmp0 + tmp3
        let even3 = tmp0 - tmp3
        let even1 = tmp1 + tmp2
        let even2 = tmp1 - tmp2
        let rotated = (even2 + even3) * cosPiOver4
        block[base] = even0 + even1
        block[base + 4 * step] = even0 - even1
        block[base + 2 * step] = even3 + rotated
        block[base + 6 * step] = even3 - rotated

        // Odd part, arranged as in Pennebaker & Mitchell figure 4-8 with the
        // rotator folded to avoid extra negations.
        let odd0 = tmp4 + tmp5
        let odd1 = tmp5 + tmp6
        let odd2 = tmp6 + tmp7
        let shared = (odd0 - odd2) * sinPiOver8
        let lower = cosMinusSinPiOver8 * odd0 + shared
        let upper = cosPlusSinPiOver8 * odd2 + shared
        let middle = odd1 * cosPiOver4
        let sum = tmp7 + middle
        let difference = tmp7 - middle
        block[base + 5 * step] = difference + lower
        block[base + 3 * step] = difference - lower
        block[base + step] = sum + upper
        block[base + 7 * step] = sum - upper
    }

    // MARK: Entropy pass

    /// Huffman-codes a run of MCUs, each holding one Y, Cb and Cr block.
    ///
    /// The bit writer and the DC predictors are copied into locals for the
    /// duration. Both are touched several times per coefficient, and left
    /// behind an `inout` they would have to be reloaded after every byte
    /// stored through the output buffer, which the optimizer has to assume
    /// might alias them.
    private static func encodeMCUs(
        _ coefficients: UnsafePointer<Int16>,
        occupancy: UnsafePointer<UInt64>,
        count: Int,
        huffman: UnsafePointer<UInt32>,
        predictors: inout (luma: Int, blueChroma: Int, redChroma: Int),
        to writer: inout JPEGBitWriter
    ) {
        var bits = writer
        var (luma, blueChroma, redChroma) = predictors
        var block = coefficients
        var masks = occupancy
        for _ in 0..<count {
            encodeBlock(
                block, nonZero: masks[0],
                dcTable: huffman + dcLuminanceTable, acTable: huffman + acLuminanceTable,
                predictor: &luma, to: &bits
            )
            encodeBlock(
                block + 64, nonZero: masks[1],
                dcTable: huffman + dcChrominanceTable, acTable: huffman + acChrominanceTable,
                predictor: &blueChroma, to: &bits
            )
            encodeBlock(
                block + 128, nonZero: masks[2],
                dcTable: huffman + dcChrominanceTable, acTable: huffman + acChrominanceTable,
                predictor: &redChroma, to: &bits
            )
            block += 192
            masks += 3
        }
        predictors = (luma, blueChroma, redChroma)
        writer = bits
    }

    /// Huffman-codes one already quantized, zigzag-ordered block, given the
    /// bitmask of its non-zero coefficients.
    @inline(__always)
    private static func encodeBlock(
        _ coefficients: UnsafePointer<Int16>,
        nonZero: UInt64,
        dcTable: UnsafePointer<UInt32>,
        acTable: UnsafePointer<UInt32>,
        predictor: inout Int,
        to writer: inout JPEGBitWriter
    ) {
        // DC coefficient, coded as the difference from the previous block.
        let dc = Int(coefficients[0])
        let difference = dc - predictor
        predictor = dc
        let dcSize = bitSize(of: difference)
        writer.write(
            entry: dcTable[dcSize],
            amplitude: amplitude(of: difference, size: dcSize),
            amplitudeLength: dcSize
        )

        // AC coefficients in zigzag order with run-length coding. Walking the
        // mask one set bit at a time visits only the coefficients that are
        // actually coded: most of a block is zeros, and testing them
        // individually would mean a branch per coefficient that no predictor
        // can get right.
        var remaining = nonZero & ~1  // the DC coefficient is already coded
        var previous = 0
        while remaining != 0 {
            let k = remaining.trailingZeroBitCount
            remaining &= remaining - 1
            var zeroRun = k - previous - 1
            previous = k
            while zeroRun > 15 {
                writer.write(entry: acTable[0xF0], amplitude: 0, amplitudeLength: 0)  // ZRL: sixteen zeros
                zeroRun -= 16
            }
            let value = Int(coefficients[k])
            let size = bitSize(of: value)
            writer.write(
                entry: acTable[zeroRun << 4 | size],
                amplitude: amplitude(of: value, size: size),
                amplitudeLength: size
            )
        }
        if previous < 63 {
            writer.write(entry: acTable[0x00], amplitude: 0, amplitudeLength: 0)  // EOB
        }
    }

    @inline(__always)
    private static func bitSize(of value: Int) -> Int {
        UInt.bitWidth - value.magnitude.leadingZeroBitCount
    }

    /// The magnitude bits the standard prescribes: the value itself when
    /// positive, its complement within `size` bits when negative. Written
    /// branchlessly, since the sign is unpredictable.
    @inline(__always)
    private static func amplitude(of value: Int, size: Int) -> Int {
        value + ((value >> (Int.bitWidth - 1)) & ((1 << size) - 1))
    }
}

/// Writes bits most-significant-bit first, stuffing a zero byte after every
/// 0xFF as JPEG entropy coding requires; the final partial byte is padded
/// with one bits.
///
/// Bits collect in a 64-bit window and drain a byte at a time into a manually
/// grown buffer, so a whole Huffman symbol plus its amplitude costs one shift,
/// one or, and one capacity check. The struct holds nothing but trivial
/// values, so hot loops can copy it into locals and store it back once.
/// `finish()` releases the buffer and must be called exactly once.
private struct JPEGBitWriter {
    private var buffer: UnsafeMutablePointer<UInt8>
    private var capacity: Int
    private var count = 0
    /// Pending bits, right-aligned in the low `bitCount` bits.
    private var accumulator: UInt64 = 0
    private var bitCount = 0

    init(capacityHint: Int) {
        capacity = max(4096, capacityHint)
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    /// Appends a `(length << 16 | code)` Huffman entry followed by its
    /// amplitude bits. The two lengths never exceed 16 + 11: the standard
    /// tables cap codes at 16 bits, and the ±1023 coefficient clamp caps a DC
    /// difference at ±2046.
    @inline(__always)
    mutating func write(entry: UInt32, amplitude: Int, amplitudeLength: Int) {
        assert(entry >> 16 > 0, "Symbol missing from Huffman table")
        assert(amplitude >= 0, "Amplitude bits must be non-negative")
        let length = Int(entry >> 16)
        // The eight bytes of headroom reserved below are exactly enough for
        // 27 new bits plus seven pending ones. Widening the coefficient
        // clamp or adding a longer Huffman code would silently overrun it.
        assert(length + amplitudeLength <= 27, "write drains more than the reserved headroom")
        let amplitudeMask = (UInt64(1) << UInt64(amplitudeLength)) - 1
        accumulator = (accumulator << UInt64(length + amplitudeLength))
            | (UInt64(entry & 0xFFFF) << UInt64(amplitudeLength))
            | (UInt64(amplitude) & amplitudeMask)
        bitCount += length + amplitudeLength

        // At most 27 new bits join up to seven pending ones, so this drains no
        // more than four bytes plus four stuffed zeros.
        if count + 8 > capacity {
            (buffer, capacity) = Self.grown(buffer, capacity: capacity, count: count)
        }
        while bitCount >= 8 {
            bitCount -= 8
            let byte = UInt8(truncatingIfNeeded: accumulator >> UInt64(bitCount))
            buffer[count] = byte
            count += 1
            if byte == 0xFF {
                buffer[count] = 0
                count += 1
            }
        }
    }

    /// Doubles the buffer, keeping the bytes written so far. Taking and
    /// returning plain values rather than mutating `self` keeps the writer
    /// promotable to registers in the loops that inline `write`.
    private static func grown(
        _ buffer: UnsafeMutablePointer<UInt8>,
        capacity: Int,
        count: Int
    ) -> (UnsafeMutablePointer<UInt8>, Int) {
        let newCapacity = max(capacity * 2, 4096)
        let newBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
        newBuffer.initialize(repeating: 0, count: newCapacity)
        // A zero capacity means `finish` already released the buffer, so
        // there is nothing to copy and nothing to free. Handling it here
        // rather than in `write` keeps the check off the hot path while
        // making a write after `finish` allocate afresh instead of freeing
        // the old pointer a second time.
        if capacity > 0 {
            newBuffer.update(from: buffer, count: count)
            buffer.deallocate()
        }
        return (newBuffer, newCapacity)
    }

    /// Pads the final partial byte with one bits, releases the buffer and
    /// returns the entropy-coded bytes. Idempotent.
    mutating func finish() -> [UInt8] {
        guard capacity > 0 else { return [] }
        if bitCount > 0 {
            let padding = 8 - bitCount
            write(
                entry: UInt32(padding) << 16 | ((1 << UInt32(padding)) - 1),
                amplitude: 0,
                amplitudeLength: 0
            )
        }
        let result = [UInt8](UnsafeBufferPointer(start: buffer, count: count))
        buffer.deallocate()
        capacity = 0
        count = 0
        return result
    }
}
