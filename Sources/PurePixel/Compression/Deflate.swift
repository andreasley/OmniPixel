/// DEFLATE compression (RFC 1951) and its zlib container (RFC 1950), in pure Swift.
///
/// Matching uses LZ77 hash chains with lazy evaluation. Each stream is emitted
/// as a single block, using whichever of stored, fixed-Huffman or
/// dynamic-Huffman encoding is smallest for the data.
enum Deflate {

    // MARK: zlib container

    static func zlibCompress(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = [0x78, 0x9C]  // deflate, 32K window, default-compression hint
        output += compressRaw(input)
        let checksum = Adler32.checksum(of: input)
        output.append(UInt8(truncatingIfNeeded: checksum >> 24))
        output.append(UInt8(truncatingIfNeeded: checksum >> 16))
        output.append(UInt8(truncatingIfNeeded: checksum >> 8))
        output.append(UInt8(truncatingIfNeeded: checksum))
        return output
    }

    // MARK: Block assembly

    /// Produces raw DEFLATE data (RFC 1951).
    static func compressRaw(_ input: [UInt8]) -> [UInt8] {
        let tokens = tokenize(input)

        // Symbol frequencies, including the mandatory end-of-block symbol,
        // and the fixed cost of all extra bits (identical for every encoding).
        var literalFrequencies = [Int](repeating: 0, count: 286)
        var distanceFrequencies = [Int](repeating: 0, count: 30)
        literalFrequencies[256] = 1
        var extraBitCost = 0
        for token in tokens {
            if token.distance == 0 {
                literalFrequencies[token.lengthOrLiteral] += 1
            } else {
                let lengthSymbol = DeflateSpec.lengthSymbol(forLength: token.lengthOrLiteral)
                let distanceSymbol = DeflateSpec.distanceSymbol(forDistance: token.distance)
                literalFrequencies[257 + lengthSymbol] += 1
                distanceFrequencies[distanceSymbol] += 1
                extraBitCost += DeflateSpec.lengthExtraBits[lengthSymbol] + DeflateSpec.distanceExtraBits[distanceSymbol]
            }
        }

        var literalLengths = HuffmanEncoding.codeLengths(frequencies: literalFrequencies, maximumLength: 15)
        if literalFrequencies.count(where: { $0 > 0 }) == 1 {
            // Only the end-of-block symbol is used. Strict decoders require a
            // complete literal/length code, so pad the tree with a second symbol.
            literalLengths[0] = 1
        }
        var distanceLengths = HuffmanEncoding.codeLengths(frequencies: distanceFrequencies, maximumLength: 15)
        if distanceLengths.allSatisfy({ $0 == 0 }) {
            distanceLengths[0] = 1  // a dynamic block must define at least one distance code
        }
        let dynamicLiterals = HuffmanEncoding(lengths: literalLengths)
        let dynamicDistances = HuffmanEncoding(lengths: distanceLengths)
        let header = dynamicHeader(literalLengths: literalLengths, distanceLengths: distanceLengths)

        let dynamicBits = 3 + header.bitCost
            + dynamicLiterals.cost(of: literalFrequencies)
            + dynamicDistances.cost(of: distanceFrequencies)
            + extraBitCost
        let fixedBits = 3
            + fixedLiteralEncoding.cost(of: literalFrequencies)
            + fixedDistanceEncoding.cost(of: distanceFrequencies)
            + extraBitCost
        let storedBits = storedCost(byteCount: input.count)

        if storedBits <= min(dynamicBits, fixedBits) {
            return storedBlocks(input)
        }

        var writer = BitWriter()
        writer.writeBits(1, count: 1)  // BFINAL: everything fits in one block
        if dynamicBits <= fixedBits {
            writer.writeBits(2, count: 2)  // BTYPE: dynamic Huffman
            writeDynamicHeader(header, to: &writer)
            writeTokens(tokens, literals: dynamicLiterals, distances: dynamicDistances, to: &writer)
        } else {
            writer.writeBits(1, count: 2)  // BTYPE: fixed Huffman
            writeTokens(tokens, literals: fixedLiteralEncoding, distances: fixedDistanceEncoding, to: &writer)
        }
        return writer.finish()
    }

    private static let fixedLiteralEncoding = HuffmanEncoding(lengths: DeflateSpec.fixedLiteralLengths)
    private static let fixedDistanceEncoding = HuffmanEncoding(lengths: DeflateSpec.fixedDistanceLengths)

    // MARK: LZ77 matching

    private static let windowSize = 32768
    private static let minMatchLength = 3
    private static let maxMatchLength = 258
    private static let maxChainLength = 128
    /// Matches at least this long are taken immediately, without lazy evaluation.
    private static let lazyThreshold = 32

    /// A literal byte (distance == 0) or a back-reference match.
    private struct Token {
        var distance: Int
        var lengthOrLiteral: Int
    }

    private static func tokenize(_ input: [UInt8]) -> [Token] {
        let count = input.count
        guard count >= minMatchLength else {
            return input.map { Token(distance: 0, lengthOrLiteral: Int($0)) }
        }

        let hashBits = 15
        var head = [Int](repeating: -1, count: 1 << hashBits)
        var chain = [Int](repeating: -1, count: count)

        func hash(_ position: Int) -> Int {
            let value = UInt32(input[position]) << 16 | UInt32(input[position + 1]) << 8 | UInt32(input[position + 2])
            return Int((value &* 2654435761) >> (32 - UInt32(hashBits)))
        }

        // Positions are added to their hash chain as they are consumed,
        // so a search only ever sees candidates before the search position.
        func insert(_ position: Int) {
            guard position + minMatchLength <= count else { return }
            let h = hash(position)
            chain[position] = head[h]
            head[h] = position
        }

        func findMatch(at position: Int) -> (length: Int, distance: Int)? {
            guard position + minMatchLength <= count else { return nil }
            let maxLength = min(maxMatchLength, count - position)
            var candidate = head[hash(position)]
            var bestLength = minMatchLength - 1
            var bestDistance = 0
            var chainsRemaining = maxChainLength

            while candidate >= 0, position - candidate <= windowSize, chainsRemaining > 0 {
                var length = 0
                while length < maxLength && input[candidate + length] == input[position + length] {
                    length += 1
                }
                if length > bestLength {
                    bestLength = length
                    bestDistance = position - candidate
                    if length == maxLength {
                        break
                    }
                }
                candidate = chain[candidate]
                chainsRemaining -= 1
            }
            return bestDistance > 0 ? (bestLength, bestDistance) : nil
        }

        var tokens: [Token] = []
        tokens.reserveCapacity(count / 2)
        var position = 0

        while position < count {
            guard let match = findMatch(at: position) else {
                tokens.append(Token(distance: 0, lengthOrLiteral: Int(input[position])))
                insert(position)
                position += 1
                continue
            }
            insert(position)

            // Lazy evaluation: if a longer match starts one byte later, emit a
            // literal now and let the next iteration take the longer match.
            if match.length < lazyThreshold, position + 1 < count,
               let next = findMatch(at: position + 1), next.length > match.length {
                tokens.append(Token(distance: 0, lengthOrLiteral: Int(input[position])))
                position += 1
                continue
            }

            for coveredPosition in (position + 1)..<(position + match.length) {
                insert(coveredPosition)
            }
            tokens.append(Token(distance: match.distance, lengthOrLiteral: match.length))
            position += match.length
        }
        return tokens
    }

    // MARK: Dynamic block header

    private struct DynamicHeader {
        var literalCount: Int
        var distanceCount: Int
        var codeLengthCount: Int
        var codeLengthEncoding: HuffmanEncoding
        var symbols: [(symbol: Int, extraValue: Int, extraBitCount: Int)]
        var bitCost: Int
    }

    private static func dynamicHeader(literalLengths: [Int], distanceLengths: [Int]) -> DynamicHeader {
        let literalCount = max(257, (literalLengths.lastIndex { $0 > 0 } ?? 0) + 1)
        let distanceCount = max(1, (distanceLengths.lastIndex { $0 > 0 } ?? 0) + 1)
        let combined = Array(literalLengths[0..<literalCount]) + Array(distanceLengths[0..<distanceCount])

        // Run-length encode the code lengths (RFC 1951, 3.2.7): 16 repeats the
        // previous length, 17 and 18 encode runs of zeros.
        var symbols: [(symbol: Int, extraValue: Int, extraBitCount: Int)] = []
        var index = 0
        while index < combined.count {
            let value = combined[index]
            var runLength = 1
            while index + runLength < combined.count && combined[index + runLength] == value {
                runLength += 1
            }
            index += runLength

            if value == 0 {
                while runLength >= 11 {
                    let take = min(runLength, 138)
                    symbols.append((18, take - 11, 7))
                    runLength -= take
                }
                if runLength >= 3 {
                    symbols.append((17, runLength - 3, 3))
                    runLength = 0
                }
                while runLength > 0 {
                    symbols.append((0, 0, 0))
                    runLength -= 1
                }
            } else {
                symbols.append((value, 0, 0))
                runLength -= 1
                while runLength >= 3 {
                    let take = min(runLength, 6)
                    symbols.append((16, take - 3, 2))
                    runLength -= take
                }
                while runLength > 0 {
                    symbols.append((value, 0, 0))
                    runLength -= 1
                }
            }
        }

        var codeLengthFrequencies = [Int](repeating: 0, count: 19)
        for entry in symbols {
            codeLengthFrequencies[entry.symbol] += 1
        }
        let codeLengthEncoding = HuffmanEncoding(
            lengths: HuffmanEncoding.codeLengths(frequencies: codeLengthFrequencies, maximumLength: 7)
        )

        let codeLengthCount = max(4, (DeflateSpec.codeLengthOrder.lastIndex { codeLengthEncoding.lengths[$0] > 0 } ?? 0) + 1)

        var bitCost = 5 + 5 + 4 + 3 * codeLengthCount
        for entry in symbols {
            bitCost += codeLengthEncoding.lengths[entry.symbol] + entry.extraBitCount
        }

        return DynamicHeader(
            literalCount: literalCount,
            distanceCount: distanceCount,
            codeLengthCount: codeLengthCount,
            codeLengthEncoding: codeLengthEncoding,
            symbols: symbols,
            bitCost: bitCost
        )
    }

    private static func writeDynamicHeader(_ header: DynamicHeader, to writer: inout BitWriter) {
        writer.writeBits(header.literalCount - 257, count: 5)
        writer.writeBits(header.distanceCount - 1, count: 5)
        writer.writeBits(header.codeLengthCount - 4, count: 4)
        for i in 0..<header.codeLengthCount {
            writer.writeBits(header.codeLengthEncoding.lengths[DeflateSpec.codeLengthOrder[i]], count: 3)
        }
        for entry in header.symbols {
            writer.writeCode(
                header.codeLengthEncoding.codes[entry.symbol],
                length: header.codeLengthEncoding.lengths[entry.symbol]
            )
            if entry.extraBitCount > 0 {
                writer.writeBits(entry.extraValue, count: entry.extraBitCount)
            }
        }
    }

    // MARK: Token emission

    private static func writeTokens(
        _ tokens: [Token],
        literals: HuffmanEncoding,
        distances: HuffmanEncoding,
        to writer: inout BitWriter
    ) {
        for token in tokens {
            if token.distance == 0 {
                writer.writeCode(literals.codes[token.lengthOrLiteral], length: literals.lengths[token.lengthOrLiteral])
            } else {
                let lengthSymbol = DeflateSpec.lengthSymbol(forLength: token.lengthOrLiteral)
                writer.writeCode(literals.codes[257 + lengthSymbol], length: literals.lengths[257 + lengthSymbol])
                writer.writeBits(
                    token.lengthOrLiteral - DeflateSpec.lengthBases[lengthSymbol],
                    count: DeflateSpec.lengthExtraBits[lengthSymbol]
                )
                let distanceSymbol = DeflateSpec.distanceSymbol(forDistance: token.distance)
                writer.writeCode(distances.codes[distanceSymbol], length: distances.lengths[distanceSymbol])
                writer.writeBits(
                    token.distance - DeflateSpec.distanceBases[distanceSymbol],
                    count: DeflateSpec.distanceExtraBits[distanceSymbol]
                )
            }
        }
        writer.writeCode(literals.codes[256], length: literals.lengths[256])  // end of block
    }

    // MARK: Stored fallback

    private static func storedCost(byteCount: Int) -> Int {
        let blockCount = max(1, (byteCount + 65534) / 65535)
        return (byteCount + blockCount * 5) * 8
    }

    /// Fallback for incompressible data: stored (uncompressed) blocks.
    private static func storedBlocks(_ input: [UInt8]) -> [UInt8] {
        let maximumBlockSize = 65535
        var output: [UInt8] = []
        output.reserveCapacity(input.count + input.count / maximumBlockSize * 5 + 5)

        var start = 0
        repeat {
            let blockSize = min(maximumBlockSize, input.count - start)
            let isFinal = start + blockSize == input.count
            output.append(isFinal ? 1 : 0)  // BFINAL flag; BTYPE 00 = stored
            output.append(UInt8(blockSize & 0xFF))
            output.append(UInt8(blockSize >> 8))
            output.append(UInt8(~blockSize & 0xFF))
            output.append(UInt8((~blockSize >> 8) & 0xFF))
            output += input[start..<start + blockSize]
            start += blockSize
        } while start < input.count
        return output
    }
}
