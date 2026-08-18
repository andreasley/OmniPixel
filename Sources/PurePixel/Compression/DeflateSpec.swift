/// Constant tables from the DEFLATE specification (RFC 1951), shared by the
/// compressor and the decompressor.
enum DeflateSpec {
    /// Smallest match length represented by each length symbol (257 + index).
    static let lengthBases = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    static let lengthExtraBits = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    /// Smallest distance represented by each distance symbol.
    static let distanceBases = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    ]
    static let distanceExtraBits = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]
    /// The order in which code-length code lengths are stored (RFC 1951, 3.2.7).
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// Code lengths of the fixed literal/length code (RFC 1951, 3.2.6).
    static let fixedLiteralLengths: [Int] = {
        var lengths = [Int](repeating: 8, count: 288)
        for symbol in 144...255 { lengths[symbol] = 9 }
        for symbol in 256...279 { lengths[symbol] = 7 }
        return lengths
    }()

    /// Code lengths of the fixed distance code.
    static let fixedDistanceLengths = [Int](repeating: 5, count: 30)

    /// Maps a match length (3...258) to its symbol index (symbol - 257).
    private static let lengthSymbols: [Int] = {
        var table = [Int](repeating: 0, count: 259)
        for symbol in 0..<lengthBases.count {
            let first = lengthBases[symbol]
            let last = min(first + (1 << lengthExtraBits[symbol]) - 1, 258)
            for length in first...last {
                table[length] = symbol  // later symbols overwrite: 258 belongs to symbol 28
            }
        }
        return table
    }()

    static func lengthSymbol(forLength length: Int) -> Int {
        lengthSymbols[length]
    }

    static func distanceSymbol(forDistance distance: Int) -> Int {
        // 30 entries; a linear scan is fine at our throughput.
        var symbol = distanceBases.count - 1
        while distanceBases[symbol] > distance {
            symbol -= 1
        }
        return symbol
    }
}
