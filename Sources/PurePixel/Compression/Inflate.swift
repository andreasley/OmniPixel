/// A canonical Huffman decoding table built from code lengths (RFC 1951, section 3.2.2).
struct HuffmanTable {
    /// countsByLength[n] is the number of codes that are n bits long (index 0 unused).
    private let countsByLength: [Int]
    /// Symbols sorted by code length, then by symbol value.
    private let symbols: [Int]

    init(codeLengths: [Int]) throws {
        var counts = [Int](repeating: 0, count: 16)
        for length in codeLengths where length > 0 {
            counts[length] += 1
        }

        // Reject over-subscribed code sets (more codes than a prefix tree can hold).
        // Incomplete sets are allowed; they occur in valid files.
        var available = 1
        for length in 1...15 {
            available <<= 1
            available -= counts[length]
            if available < 0 {
                throw ImageError.invalidData(reason: "Invalid Huffman code lengths")
            }
        }

        var offsets = [Int](repeating: 0, count: 16)
        for length in 1..<15 {
            offsets[length + 1] = offsets[length] + counts[length]
        }
        var sortedSymbols = [Int](repeating: 0, count: codeLengths.count { $0 > 0 })
        for (symbol, length) in codeLengths.enumerated() where length > 0 {
            sortedSymbols[offsets[length]] = symbol
            offsets[length] += 1
        }

        self.countsByLength = counts
        self.symbols = sortedSymbols
    }

    func decodeSymbol(from reader: inout BitReader) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        for length in 1...15 {
            code |= try reader.readBit()
            let count = countsByLength[length]
            if code - first < count {
                return symbols[index + (code - first)]
            }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        throw ImageError.invalidData(reason: "Invalid Huffman code")
    }
}

/// DEFLATE decompression (RFC 1951) and its zlib container (RFC 1950), in pure Swift.
enum Inflate {
    /// Decompresses a zlib stream: 2-byte header, DEFLATE data, Adler-32 checksum.
    static func zlibDecompress(_ input: [UInt8]) throws -> [UInt8] {
        guard input.count >= 6 else {
            throw ImageError.invalidData(reason: "zlib stream too short")
        }
        let cmf = input[0]
        let flg = input[1]
        guard cmf & 0x0F == 8 else {
            throw ImageError.invalidData(reason: "Unknown zlib compression method")
        }
        guard (Int(cmf) << 8 | Int(flg)) % 31 == 0 else {
            throw ImageError.invalidData(reason: "Corrupt zlib header")
        }
        guard flg & 0x20 == 0 else {
            throw ImageError.unsupportedFeature(reason: "zlib preset dictionaries are not supported")
        }

        let output = try decompressRaw(Array(input[2..<(input.count - 4)]))

        let storedChecksum = UInt32(input[input.count - 4]) << 24
            | UInt32(input[input.count - 3]) << 16
            | UInt32(input[input.count - 2]) << 8
            | UInt32(input[input.count - 1])
        guard Adler32.checksum(of: output) == storedChecksum else {
            throw ImageError.invalidData(reason: "zlib checksum mismatch")
        }
        return output
    }

    /// Decompresses raw DEFLATE data.
    static func decompressRaw(_ input: [UInt8]) throws -> [UInt8] {
        var reader = BitReader(input)
        var output: [UInt8] = []

        while true {
            let isFinal = try reader.readBit() == 1
            let blockType = try reader.readBits(2)

            switch blockType {
            case 0:
                try copyStoredBlock(&reader, into: &output)
            case 1:
                try decodeBlock(&reader, literals: fixedLiteralTable, distances: fixedDistanceTable, into: &output)
            case 2:
                let (literals, distances) = try readDynamicTables(&reader)
                try decodeBlock(&reader, literals: literals, distances: distances, into: &output)
            default:
                throw ImageError.invalidData(reason: "Invalid DEFLATE block type")
            }
            if isFinal {
                break
            }
        }
        return output
    }

    // MARK: Blocks

    private static func copyStoredBlock(_ reader: inout BitReader, into output: inout [UInt8]) throws {
        let lengthBytes = try reader.readAlignedBytes(4)
        let length = Int(lengthBytes[0]) | Int(lengthBytes[1]) << 8
        let complement = Int(lengthBytes[2]) | Int(lengthBytes[3]) << 8
        guard length ^ complement == 0xFFFF else {
            throw ImageError.invalidData(reason: "Corrupt stored block length")
        }
        output += try reader.readAlignedBytes(length)
    }

    private static func decodeBlock(
        _ reader: inout BitReader,
        literals: HuffmanTable,
        distances: HuffmanTable,
        into output: inout [UInt8]
    ) throws {
        while true {
            let symbol = try literals.decodeSymbol(from: &reader)
            if symbol < 256 {
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let lengthIndex = symbol - 257
                guard lengthIndex < DeflateSpec.lengthBases.count else {
                    throw ImageError.invalidData(reason: "Invalid DEFLATE length symbol")
                }
                let length = DeflateSpec.lengthBases[lengthIndex]
                    + (try reader.readBits(DeflateSpec.lengthExtraBits[lengthIndex]))

                let distanceSymbol = try distances.decodeSymbol(from: &reader)
                guard distanceSymbol < DeflateSpec.distanceBases.count else {
                    throw ImageError.invalidData(reason: "Invalid DEFLATE distance symbol")
                }
                let distance = DeflateSpec.distanceBases[distanceSymbol]
                    + (try reader.readBits(DeflateSpec.distanceExtraBits[distanceSymbol]))
                guard distance <= output.count else {
                    throw ImageError.invalidData(reason: "DEFLATE back-reference before start of output")
                }

                // Copy byte by byte: back-references may overlap their own output.
                let start = output.count - distance
                for i in 0..<length {
                    output.append(output[start + i])
                }
            }
        }
    }

    // MARK: Huffman tables

    // The fixed code lengths come straight from the spec, so building the
    // tables can't fail.
    private static let fixedLiteralTable = try! HuffmanTable(codeLengths: DeflateSpec.fixedLiteralLengths)
    private static let fixedDistanceTable = try! HuffmanTable(codeLengths: DeflateSpec.fixedDistanceLengths)

    private static func readDynamicTables(_ reader: inout BitReader) throws -> (HuffmanTable, HuffmanTable) {
        let literalCount = try reader.readBits(5) + 257
        let distanceCount = try reader.readBits(5) + 1
        let codeLengthCount = try reader.readBits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else {
            throw ImageError.invalidData(reason: "Invalid DEFLATE table sizes")
        }

        var codeLengthLengths = [Int](repeating: 0, count: 19)
        for i in 0..<codeLengthCount {
            codeLengthLengths[DeflateSpec.codeLengthOrder[i]] = try reader.readBits(3)
        }
        let codeLengthTable = try HuffmanTable(codeLengths: codeLengthLengths)

        var lengths: [Int] = []
        lengths.reserveCapacity(literalCount + distanceCount)
        while lengths.count < literalCount + distanceCount {
            let symbol = try codeLengthTable.decodeSymbol(from: &reader)
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else {
                    throw ImageError.invalidData(reason: "Repeat code with no previous length")
                }
                lengths += [Int](repeating: previous, count: try reader.readBits(2) + 3)
            case 17:
                lengths += [Int](repeating: 0, count: try reader.readBits(3) + 3)
            case 18:
                lengths += [Int](repeating: 0, count: try reader.readBits(7) + 11)
            default:
                throw ImageError.invalidData(reason: "Invalid code length symbol")
            }
        }
        guard lengths.count == literalCount + distanceCount else {
            throw ImageError.invalidData(reason: "DEFLATE code lengths overflow their table")
        }
        guard lengths[256] > 0 else {
            throw ImageError.invalidData(reason: "Missing end-of-block code")
        }

        let literalTable = try HuffmanTable(codeLengths: Array(lengths[0..<literalCount]))
        let distanceTable = try HuffmanTable(codeLengths: Array(lengths[literalCount...]))
        return (literalTable, distanceTable)
    }
}
