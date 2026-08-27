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
            let distance = Int(token >> 16)
            let value = Int(token & 0xFFFF)
            if distance == 0 {
                literalFrequencies[value] += 1
            } else {
                let lengthSymbol = DeflateSpec.lengthSymbol(forLength: value)
                let distanceSymbol = DeflateSpec.distanceSymbol(forDistance: distance)
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

        var writer = BitWriter(capacityHint: min(dynamicBits, fixedBits) / 8 + 16)
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

    /// A literal byte or a back-reference, packed as
    /// `distance << 16 | lengthOrLiteral`; distance zero means literal. Four
    /// bytes per token rather than a two-field struct's sixteen keeps the token
    /// stream — one entry per input byte in the worst case — cache-friendly.
    private typealias Token = UInt32

    @inline(__always)
    private static func literalToken(_ byte: UInt8) -> Token {
        Token(byte)
    }

    @inline(__always)
    private static func matchToken(length: Int, distance: Int) -> Token {
        Token(distance) << 16 | Token(length)
    }

    private static func tokenize(_ input: [UInt8]) -> [Token] {
        let count = input.count
        guard count >= minMatchLength else {
            return input.map(literalToken)
        }

        var tokens: [Token] = []
        tokens.reserveCapacity(count / 2)
        let hashBits = 15
        let windowMask = windowSize - 1
        var head = [Int](repeating: -1, count: 1 << hashBits)
        // How far back the previous position with the same hash lies, or zero
        // when there is none within reach. Only the last `windowSize` positions
        // can ever be referenced, so this wraps instead of covering the whole
        // input: two bytes per slot over a 32K window is 64 KB, small enough to
        // stay in cache while a chain is walked, and walking one is a chain of
        // dependent loads whose latency sets the pace of the whole compressor.
        var chain = [UInt16](repeating: 0, count: windowSize)

        input.withUnsafeBufferPointer { inputBuffer in
            head.withUnsafeMutableBufferPointer { headBuffer in
                chain.withUnsafeMutableBufferPointer { chainBuffer in
                    let data = inputBuffer.baseAddress!
                    let head = headBuffer.baseAddress!
                    let chain = chainBuffer.baseAddress!

                    /// Hashes the three bytes at `position`, which must be
                    /// followed by at least two more.
                    func hash(_ position: Int) -> Int {
                        let value: UInt32
                        if position + 4 <= count {
                            // One unaligned load, byte-swapped into the same
                            // big-endian ordering the scalar form produces.
                            let word = UnsafeRawPointer(data + position).loadUnaligned(as: UInt32.self)
                            value = (word.byteSwapped >> 8) & 0xFFFFFF
                        } else {
                            value = UInt32(data[position]) << 16
                                | UInt32(data[position + 1]) << 8
                                | UInt32(data[position + 2])
                        }
                        return Int((value &* 2654435761) >> (32 - UInt32(hashBits)))
                    }

                    // Positions are added to their hash chain as they are consumed,
                    // so a search only ever sees candidates before the search position.
                    func insert(_ position: Int, hashValue: Int) {
                        let previous = head[hashValue]
                        // A gap wider than the window can never be followed, so
                        // it is recorded as the end of the chain.
                        let delta = previous >= 0 ? position - previous : windowSize + 1
                        chain[position & windowMask] = delta <= windowSize ? UInt16(delta) : 0
                        head[hashValue] = position
                    }

                    func insert(_ position: Int) {
                        guard position + minMatchLength <= count else { return }
                        insert(position, hashValue: hash(position))
                    }

                    /// Longest match for the bytes at `position`, or nil if
                    /// nothing reaches `minMatchLength`.
                    func findMatch(at position: Int, hashValue: Int) -> (length: Int, distance: Int)? {
                        let maxLength = min(maxMatchLength, count - position)
                        var candidate = head[hashValue]
                        var bestLength = minMatchLength - 1
                        var bestDistance = 0
                        var chainsRemaining = maxChainLength

                        while candidate >= 0, position - candidate <= windowSize, chainsRemaining > 0 {
                            // To beat the current best a candidate has to match
                            // the two bytes that would extend it and the two it
                            // starts with. Nearly every candidate fails one of
                            // those four, so they come before the full compare.
                            if data[candidate + bestLength] == data[position + bestLength],
                               data[candidate + bestLength - 1] == data[position + bestLength - 1],
                               data[candidate] == data[position],
                               data[candidate + 1] == data[position + 1] {
                                // Compare eight bytes at a time; the first
                                // differing byte falls out of the xor.
                                var length = 2
                                while length + 8 <= maxLength {
                                    let mine = UnsafeRawPointer(data + position + length)
                                        .loadUnaligned(as: UInt64.self)
                                    let theirs = UnsafeRawPointer(data + candidate + length)
                                        .loadUnaligned(as: UInt64.self)
                                    if mine != theirs {
                                        length += (mine ^ theirs).trailingZeroBitCount >> 3
                                        break
                                    }
                                    length += 8
                                }
                                while length < maxLength, data[candidate + length] == data[position + length] {
                                    length += 1
                                }
                                if length > bestLength {
                                    bestLength = length
                                    bestDistance = position - candidate
                                    if length == maxLength {
                                        break
                                    }
                                }
                            }
                            let delta = Int(chain[candidate & windowMask])
                            candidate = delta == 0 ? -1 : candidate - delta
                            chainsRemaining -= 1
                        }
                        return bestDistance > 0 ? (bestLength, bestDistance) : nil
                    }

                    var position = 0
                    // The match already found at `position` by the previous
                    // iteration's lazy look-ahead, so it isn't searched twice.
                    var carried: (length: Int, distance: Int)?

                    while position < count {
                        guard position + minMatchLength <= count else {
                            tokens.append(literalToken(data[position]))
                            position += 1
                            continue
                        }
                        // The hash is needed for both the search and the insert,
                        // so it is computed once here.
                        let hashValue = hash(position)
                        let found = carried ?? findMatch(at: position, hashValue: hashValue)
                        carried = nil
                        insert(position, hashValue: hashValue)

                        guard let match = found else {
                            tokens.append(literalToken(data[position]))
                            position += 1
                            continue
                        }

                        // Lazy evaluation: if a longer match starts one byte later,
                        // emit a literal now and take the longer match next time.
                        if match.length < lazyThreshold, position + 1 + minMatchLength <= count {
                            let next = findMatch(at: position + 1, hashValue: hash(position + 1))
                            if let next, next.length > match.length {
                                tokens.append(literalToken(data[position]))
                                position += 1
                                carried = next
                                continue
                            }
                        }

                        for coveredPosition in (position + 1)..<(position + match.length) {
                            insert(coveredPosition)
                        }
                        tokens.append(matchToken(length: match.length, distance: match.distance))
                        position += match.length
                    }
                }
            }
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
        let encoding = header.codeLengthEncoding
        for entry in header.symbols {
            writer.writeBits(
                encoding.reversedCodes[entry.symbol] | entry.extraValue << encoding.lengths[entry.symbol],
                count: encoding.lengths[entry.symbol] + entry.extraBitCount
            )
        }
    }

    // MARK: Token emission

    private static func writeTokens(
        _ tokens: [Token],
        literals: HuffmanEncoding,
        distances: HuffmanEncoding,
        to writer: inout BitWriter
    ) {
        // A Huffman code and the extra bits that follow it go out in one piece:
        // the stream is least-significant-bit first, so the extra bits simply
        // sit above the reversed code.
        literals.reversedCodes.withUnsafeBufferPointer { literalCodes in
            literals.lengths.withUnsafeBufferPointer { literalLengths in
                distances.reversedCodes.withUnsafeBufferPointer { distanceCodes in
                    distances.lengths.withUnsafeBufferPointer { distanceLengths in
                        for token in tokens {
                            let value = Int(token & 0xFFFF)
                            let distance = Int(token >> 16)
                            if distance == 0 {
                                writer.writeBits(literalCodes[value], count: literalLengths[value])
                                continue
                            }

                            let lengthSymbol = DeflateSpec.lengthSymbol(forLength: value)
                            let symbol = 257 + lengthSymbol
                            let lengthExtra = DeflateSpec.lengthExtraBits[lengthSymbol]
                            writer.writeBits(
                                literalCodes[symbol]
                                    | (value - DeflateSpec.lengthBases[lengthSymbol]) << literalLengths[symbol],
                                count: literalLengths[symbol] + lengthExtra
                            )

                            let distanceSymbol = DeflateSpec.distanceSymbol(forDistance: distance)
                            let distanceExtra = DeflateSpec.distanceExtraBits[distanceSymbol]
                            writer.writeBits(
                                distanceCodes[distanceSymbol]
                                    | (distance - DeflateSpec.distanceBases[distanceSymbol]) << distanceLengths[distanceSymbol],
                                count: distanceLengths[distanceSymbol] + distanceExtra
                            )
                        }
                    }
                }
            }
        }
        writer.writeBits(literals.reversedCodes[256], count: literals.lengths[256])  // end of block
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
