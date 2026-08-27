/// Writes bits least-significant-bit first into a byte buffer, as DEFLATE requires.
///
/// Bits collect in a 64-bit accumulator and drain a whole byte at a time, so a
/// multi-bit field costs a shift and an or rather than a loop.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    /// Pending bits, least significant first, in the low `bitCount` bits.
    private var accumulator: UInt64 = 0
    private var bitCount = 0

    init() {}

    /// Starts a writer with room for `capacityHint` output bytes.
    init(capacityHint: Int) {
        bytes.reserveCapacity(capacityHint)
    }

    /// Writes `count` bits of `value`, least significant bit first. `count` must
    /// not exceed 56.
    mutating func writeBits(_ value: Int, count: Int) {
        let mask = (UInt64(1) << UInt64(count)) - 1
        accumulator |= (UInt64(bitPattern: Int64(value)) & mask) << UInt64(bitCount)
        bitCount += count
        while bitCount >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: accumulator))
            accumulator >>= 8
            bitCount -= 8
        }
    }

    /// Bit-reversal of every byte value, for turning a most-significant-bit-first
    /// code into the order the stream is written in.
    private static let reversedBytes: [UInt8] = (0..<256).map { value in
        var source = UInt8(value)
        var result: UInt8 = 0
        for _ in 0..<8 {
            result = result << 1 | (source & 1)
            source >>= 1
        }
        return result
    }

    /// Writes a Huffman code, which DEFLATE stores most significant bit first.
    /// `length` must not exceed 16.
    mutating func writeCode(_ code: Int, length: Int) {
        let wide = UInt16(truncatingIfNeeded: code)
        let reversed = Int(Self.reversedBytes[Int(wide & 0xFF)]) << 8
            | Int(Self.reversedBytes[Int(wide >> 8)])
        writeBits(reversed >> (16 - length), count: length)
    }

    /// Pads with zero bits to the next byte boundary.
    mutating func alignToNextByte() {
        if bitCount > 0 {
            bytes.append(UInt8(truncatingIfNeeded: accumulator))
            accumulator = 0
            bitCount = 0
        }
    }

    /// Flushes any partial byte and returns the completed buffer.
    mutating func finish() -> [UInt8] {
        alignToNextByte()
        return bytes
    }
}
