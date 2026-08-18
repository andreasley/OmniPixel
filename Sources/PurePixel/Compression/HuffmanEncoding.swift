/// A canonical Huffman code for the encoder, with optimal length-limited code
/// lengths computed by the package-merge algorithm.
struct HuffmanEncoding {
    /// Code length in bits per symbol; 0 for unused symbols.
    let lengths: [Int]
    /// Canonical code per symbol, stored most-significant-bit first as DEFLATE writes them.
    let codes: [Int]

    init(lengths: [Int]) {
        self.lengths = lengths
        self.codes = Self.canonicalCodes(for: lengths)
    }

    /// The number of bits this code needs for symbols occurring with `frequencies`
    /// (Huffman codes only; extra bits are counted separately).
    func cost(of frequencies: [Int]) -> Int {
        var total = 0
        for (frequency, length) in zip(frequencies, lengths) {
            total += frequency * length
        }
        return total
    }

    // MARK: Canonical code assignment (RFC 1951, 3.2.2)

    private static func canonicalCodes(for lengths: [Int]) -> [Int] {
        var countsByLength = [Int](repeating: 0, count: 16)
        for length in lengths where length > 0 {
            countsByLength[length] += 1
        }
        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        for length in 1...15 {
            code = (code + countsByLength[length - 1]) << 1
            nextCode[length] = code
        }
        var codes = [Int](repeating: 0, count: lengths.count)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            codes[symbol] = nextCode[length]
            nextCode[length] += 1
        }
        return codes
    }

    // MARK: Length-limited code lengths (package-merge)

    private struct Node {
        var weight: Int
        var symbols: [Int]
    }

    /// Computes optimal code lengths no longer than `maximumLength` for the
    /// given symbol frequencies. Unused symbols get length 0. The caller must
    /// ensure the used-symbol count fits (2^maximumLength), which always holds
    /// for the DEFLATE alphabets.
    static func codeLengths(frequencies: [Int], maximumLength: Int) -> [Int] {
        var lengths = [Int](repeating: 0, count: frequencies.count)
        let used = frequencies.enumerated().filter { $0.element > 0 }
        guard used.count > 1 else {
            if let only = used.first {
                lengths[only.offset] = 1
            }
            return lengths
        }

        let leaves = used
            .sorted { $0.element < $1.element }
            .map { Node(weight: $0.element, symbols: [$0.offset]) }

        var merged = leaves
        for _ in 1..<maximumLength {
            // Package adjacent pairs, then merge them back in with the leaves.
            var packages: [Node] = []
            var index = 0
            while index + 1 < merged.count {
                packages.append(Node(
                    weight: merged[index].weight + merged[index + 1].weight,
                    symbols: merged[index].symbols + merged[index + 1].symbols
                ))
                index += 2
            }
            merged = mergeByWeight(leaves, packages)
        }

        // Every symbol occurrence among the 2(n-1) lightest nodes adds one bit
        // to that symbol's code length.
        for node in merged.prefix(2 * (used.count - 1)) {
            for symbol in node.symbols {
                lengths[symbol] += 1
            }
        }
        return lengths
    }

    private static func mergeByWeight(_ first: [Node], _ second: [Node]) -> [Node] {
        var result: [Node] = []
        result.reserveCapacity(first.count + second.count)
        var i = 0
        var j = 0
        while i < first.count && j < second.count {
            if first[i].weight <= second[j].weight {
                result.append(first[i])
                i += 1
            } else {
                result.append(second[j])
                j += 1
            }
        }
        result.append(contentsOf: first[i...])
        result.append(contentsOf: second[j...])
        return result
    }
}
