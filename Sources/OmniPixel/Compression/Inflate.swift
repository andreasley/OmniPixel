/// A canonical Huffman decoding table built from code lengths (RFC 1951, section 3.2.2).
///
/// Codes of up to `primaryBits` bits — the overwhelming majority — resolve in a
/// single indexed load; longer codes fall back to the canonical bit-by-bit walk.
struct HuffmanTable {
    /// Nine bits keeps the lookup at 512 entries while still covering almost
    /// every code the DEFLATE and VP8L alphabets produce.
    private static let primaryBits = 9

    /// Indexed by the next `primaryBits` bits of the stream: (length << 16) |
    /// symbol, or 0 when no code that short matches.
    private let primary: [UInt32]
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

        // Assign canonical codes and fill the primary lookup. Codes are stored
        // most significant bit first but arrive least significant bit first, so
        // each one is reversed to index the table, and every table slot whose
        // low bits match it gets the entry.
        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        for length in 1...15 {
            code = (code + counts[length - 1]) << 1
            nextCode[length] = code
        }
        var primary = [UInt32](repeating: 0, count: 1 << Self.primaryBits)
        for (symbol, length) in codeLengths.enumerated() where length > 0 {
            let assigned = nextCode[length]
            nextCode[length] += 1
            guard length <= Self.primaryBits else { continue }
            let entry = UInt32(length) << 16 | UInt32(symbol)
            var index = Self.reversingBits(of: assigned, count: length)
            let step = 1 << length
            while index < primary.count {
                primary[index] = entry
                index += step
            }
        }

        self.primary = primary
        self.countsByLength = counts
        self.symbols = sortedSymbols
    }

    private static func reversingBits(of value: Int, count: Int) -> Int {
        var source = value
        var result = 0
        for _ in 0..<count {
            result = result << 1 | (source & 1)
            source >>= 1
        }
        return result
    }

    func decodeSymbol(from reader: inout BitReader) throws -> Int {
        let entry = primary[reader.peekBits(Self.primaryBits)]
        guard entry != 0 else {
            return try decodeLongSymbol(from: &reader)
        }
        try reader.consume(Int(entry >> 16))
        return Int(entry & 0xFFFF)
    }

    /// The canonical walk, for codes the primary lookup can't reach. Nothing
    /// has been consumed yet, so this starts from the same bit position.
    private func decodeLongSymbol(from reader: inout BitReader) throws -> Int {
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

/// The growing output window of an inflate run.
///
/// Back-references read from bytes already produced, so the buffer has to stay
/// directly addressable while it grows. Managing the storage by hand keeps a
/// literal down to a single store and lets a match move in machine words
/// instead of a byte at a time.
private struct InflateWindow {
    private var storage: UnsafeMutablePointer<UInt8>
    private var capacity: Int
    private(set) var count = 0

    init(capacityHint: Int) {
        capacity = max(1024, capacityHint)
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    private mutating func reserve(_ additional: Int) {
        guard count + additional > capacity else { return }
        var newCapacity = max(capacity * 2, 1024)
        while newCapacity < count + additional {
            newCapacity *= 2
        }
        let newStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
        newStorage.initialize(repeating: 0, count: newCapacity)
        newStorage.update(from: storage, count: count)
        storage.deallocate()
        storage = newStorage
        capacity = newCapacity
    }

    @inline(__always)
    mutating func append(_ byte: UInt8) {
        reserve(1)
        storage[count] = byte
        count += 1
    }

    mutating func append(_ bytes: [UInt8]) {
        reserve(bytes.count)
        bytes.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                (storage + count).update(from: base, count: buffer.count)
            }
        }
        count += bytes.count
    }

    /// Repeats `length` bytes starting `distance` back. The regions may overlap,
    /// which DEFLATE uses deliberately to encode runs.
    ///
    /// `distance` must be between 1 and `count`: the caller checks it against
    /// the stream, and this walks raw memory on the strength of that check.
    @inline(__always)
    mutating func repeatPrevious(distance: Int, length: Int) {
        precondition(distance >= 1 && distance <= count, "back-reference outside the output")
        reserve(length)
        let source = storage + (count - distance)
        let destination = storage + count
        count += length

        if distance >= length {
            // Disjoint, so one straight copy.
            destination.update(from: source, count: length)
        } else {
            // Overlapping: lay down one period, then keep doubling the region
            // already in place so long runs still move in blocks.
            destination.update(from: source, count: distance)
            var written = distance
            while written < length {
                let step = min(written, length - written)
                (destination + written).update(from: destination, count: step)
                written += step
            }
        }
    }

    /// The bytes produced so far.
    func bytes() -> [UInt8] {
        [UInt8](UnsafeBufferPointer(start: storage, count: count))
    }

    /// Frees the storage. Idempotent, so the owner can release it from a
    /// `defer` and a decode that throws part way through still gives it back.
    mutating func release() {
        guard capacity > 0 else { return }
        storage.deallocate()
        capacity = 0
        count = 0
    }
}

/// DEFLATE decompression (RFC 1951) and its zlib container (RFC 1950), in pure Swift.
enum Inflate {
    /// Decompresses a zlib stream: 2-byte header, DEFLATE data, Adler-32 checksum.
    ///
    /// `expectedSize`, when known, only sizes the output buffer up front; a
    /// stream that produces more still decompresses correctly.
    static func zlibDecompress(_ input: [UInt8], expectedSize: Int = 0) throws -> [UInt8] {
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

        let output = try decompress(input, range: 2..<(input.count - 4), expectedSize: expectedSize)

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
    static func decompressRaw(_ input: [UInt8], expectedSize: Int = 0) throws -> [UInt8] {
        try decompress(input, range: 0..<input.count, expectedSize: expectedSize)
    }

    private static func decompress(
        _ input: [UInt8],
        range: Range<Int>,
        expectedSize: Int
    ) throws -> [UInt8] {
        var reader = BitReader(input, range: range)
        // Callers that know the output size pass it. Otherwise guess four bytes
        // out per byte in, capped so a large compressed input can't turn into a
        // far larger speculative allocation; the window grows if the guess is low.
        var output = InflateWindow(
            capacityHint: expectedSize > 0 ? expectedSize : min(range.count * 4, 8 << 20)
        )
        defer { output.release() }

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
        return output.bytes()
    }

    // MARK: Blocks

    private static func copyStoredBlock(_ reader: inout BitReader, into output: inout InflateWindow) throws {
        let lengthBytes = try reader.readAlignedBytes(4)
        let length = Int(lengthBytes[0]) | Int(lengthBytes[1]) << 8
        let complement = Int(lengthBytes[2]) | Int(lengthBytes[3]) << 8
        guard length ^ complement == 0xFFFF else {
            throw ImageError.invalidData(reason: "Corrupt stored block length")
        }
        output.append(try reader.readAlignedBytes(length))
    }

    private static func decodeBlock(
        _ reader: inout BitReader,
        literals: HuffmanTable,
        distances: HuffmanTable,
        into output: inout InflateWindow
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
                guard distance >= 1, distance <= output.count else {
                    throw ImageError.invalidData(reason: "DEFLATE back-reference before start of output")
                }
                output.repeatPrevious(distance: distance, length: length)
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
