/// The AV1 entropy decoder (AV1 specification section 8.2): a multi-symbol
/// range decoder over adaptive cumulative distribution functions.
///
/// A CDF array for N symbols has N+1 entries: entries 0…N−1 hold increasing
/// cumulative probabilities scaled to 1 << 15 (the last always 1 << 15), and
/// entry N counts how often the symbol has been decoded (capped at 32) to
/// steer the adaptation rate. The decoder's value register stores the
/// bitwise complement of the bitstream window; renormalization maintains
/// that through the XOR in the specification.
struct AV1SymbolDecoder {
    static let probabilityShift = 6   // EC_PROB_SHIFT
    static let minimumProbability = 4 // EC_MIN_PROB

    private let bytes: [UInt8]
    private let endBit: Int
    private var bitPosition: Int
    private var symbolValue = 0
    private var symbolRange = 1 << 15
    private var symbolMaxBits = 0
    /// disable_cdf_update from the frame header.
    var cdfUpdatesEnabled = true

    /// Initializes over `count` bytes starting at `start` (init_symbol).
    init(bytes: [UInt8], start: Int = 0, count: Int) throws {
        guard start >= 0, count >= 0, start + count <= bytes.count else {
            throw ImageError.invalidData(reason: "AV1 symbol data lies outside its buffer")
        }
        self.bytes = bytes
        self.bitPosition = start * 8
        self.endBit = (start + count) * 8
        let numBits = min(count * 8, 15)
        let buf = readBits(numBits)
        let paddedBuf = buf << (15 - numBits)
        symbolValue = ((1 << 15) - 1) ^ paddedBuf
        symbolRange = 1 << 15
        symbolMaxBits = 8 * count - 15
    }

    /// Decodes one symbol against (and adapts) the given CDF (read_symbol).
    mutating func readSymbol(_ cdf: inout [UInt16]) -> Int {
        let n = cdf.count - 1
        var cur = symbolRange
        var prev = cur
        var symbol = -1
        repeat {
            symbol += 1
            prev = cur
            let f = (1 << 15) - Int(cdf[symbol])
            cur = ((symbolRange >> 8) * (f >> Self.probabilityShift)) >> (7 - Self.probabilityShift)
            cur += Self.minimumProbability * (n - symbol - 1)
        } while symbolValue < cur

        symbolRange = prev - cur
        symbolValue -= cur
        renormalize()

        if cdfUpdatesEnabled {
            Self.updateCDF(&cdf, symbol: symbol)
        }
        return symbol
    }

    /// Adapts a CDF toward the decoded symbol (the update half of
    /// read_symbol, shared with the test encoder).
    static func updateCDF(_ cdf: inout [UInt16], symbol: Int) {
        let n = cdf.count - 1
        let count = Int(cdf[n])
        let rate = 3 + (count > 15 ? 1 : 0) + (count > 31 ? 1 : 0) + min(floorLog2(n), 2)
        var tmp = 0
        for i in 0..<(n - 1) {
            if i == symbol {
                tmp = 1 << 15
            }
            let value = Int(cdf[i])
            if tmp < value {
                cdf[i] = UInt16(value - ((value - tmp) >> rate))
            } else {
                cdf[i] = UInt16(value + ((tmp - value) >> rate))
            }
        }
        if count < 32 {
            cdf[n] = UInt16(count + 1)
        }
    }

    /// One equal-probability bit (read_bool): a fresh half/half CDF whose
    /// adaptation is never observable, so it is skipped.
    mutating func readBool() -> Int {
        let f = 1 << 14
        var cur = ((symbolRange >> 8) * (f >> Self.probabilityShift)) >> (7 - Self.probabilityShift)
        cur += Self.minimumProbability
        let symbol: Int
        if symbolValue < cur {
            // Second symbol: its interval reaches down to zero.
            symbol = 1
            symbolRange = cur
        } else {
            symbol = 0
            symbolRange -= cur
            symbolValue -= cur
        }
        renormalize()
        return symbol
    }

    /// n equal-probability bits, most significant first (read_literal).
    mutating func readLiteral(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            value = value << 1 | readBool()
        }
        return value
    }

    /// Validates the trailing-bit structure and returns the byte position
    /// after the symbol-coded data (exit_symbol).
    func exit() throws {
        guard symbolMaxBits >= -14 else {
            throw ImageError.invalidData(reason: "AV1 symbol decoder overran its data")
        }
        // The final one-bit marks the end of the arithmetic payload; only
        // zero padding may follow it.
        let trailingBitPosition = bitPosition - min(15, symbolMaxBits + 15)
        guard trailingBitPosition >= 0, trailingBitPosition < endBit,
              bit(at: trailingBitPosition) == 1 else {
            throw ImageError.invalidData(reason: "Corrupt AV1 trailing bits")
        }
        for position in (trailingBitPosition + 1)..<endBit where bit(at: position) != 0 {
            throw ImageError.invalidData(reason: "Corrupt AV1 trailing bits")
        }
    }

    // MARK: Internals

    private mutating func renormalize() {
        let bits = 15 - Self.floorLog2(symbolRange)
        guard bits > 0 else { return }
        symbolRange <<= bits
        let numBits = min(bits, max(0, symbolMaxBits))
        let newData = readBits(numBits)
        let paddedData = newData << (bits - numBits)
        symbolValue = paddedData ^ (((symbolValue + 1) << bits) - 1)
        symbolMaxBits -= bits
    }

    /// f(n): MSB-first bits (count ≤ 15); callers never request beyond the
    /// buffer because symbolMaxBits caps the reads. Reads up to four bytes
    /// at once instead of bit-by-bit.
    private mutating func readBits(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let byteIndex = bitPosition >> 3
        let bitOffset = bitPosition & 7
        var word = 0
        let end = min(bytes.count, byteIndex + 4)
        var i = byteIndex
        while i < end {
            word = word << 8 | Int(bytes[i])
            i += 1
        }
        word <<= 8 * (byteIndex + 4 - end)
        bitPosition += count
        return (word >> (32 - bitOffset - count)) & ((1 << count) - 1)
    }

    private func bit(at position: Int) -> Int {
        guard position < endBit else { return 0 }
        return Int(bytes[position >> 3] >> (7 - (position & 7))) & 1
    }

    static func floorLog2(_ value: Int) -> Int {
        Int.bitWidth - 1 - value.leadingZeroBitCount
    }
}
