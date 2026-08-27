/// Reads bits least-significant-bit first from a byte buffer, as DEFLATE requires.
///
/// Bits are buffered in a 64-bit window that is refilled a byte at a time, so
/// reading a multi-bit field costs a mask and a shift rather than a loop. Bits
/// past the end of the buffer read as zero when peeked; consuming them throws.
struct BitReader {
    private let bytes: [UInt8]
    /// Index of the next byte to pull into the window.
    private var nextByte: Int
    private let endByte: Int
    /// Buffered bits, least significant first. Bits above `available` are zero.
    private var window: UInt64 = 0
    private var available = 0

    init(_ bytes: [UInt8]) {
        self.init(bytes, range: 0..<bytes.count)
    }

    /// Reads from a sub-range without copying it out of `bytes` first.
    init(_ bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        self.nextByte = range.lowerBound
        self.endByte = range.upperBound
    }

    @inline(__always)
    private mutating func refill() {
        while available <= 56, nextByte < endByte {
            window |= UInt64(bytes[nextByte]) << UInt64(available)
            available += 8
            nextByte += 1
        }
    }

    /// The next `count` bits without consuming them, zero-padded past the end
    /// of the buffer. `count` must not exceed 56.
    @inline(__always)
    mutating func peekBits(_ count: Int) -> Int {
        assert(count >= 0 && count <= 56, "peek width outside the window")
        refill()
        return Int(window & ((1 << UInt64(count)) - 1))
    }

    /// Discards `count` bits that a previous peek reported.
    @inline(__always)
    mutating func consume(_ count: Int) throws {
        guard count <= available else {
            throw ImageError.invalidData(reason: "Unexpected end of compressed data")
        }
        window >>= UInt64(count)
        available -= count
    }

    mutating func readBit() throws -> Int {
        try readBits(1)
    }

    mutating func readBits(_ count: Int) throws -> Int {
        let value = peekBits(count)
        try consume(count)
        return value
    }

    /// Discards any bits remaining in the current byte and reads whole bytes.
    mutating func readAlignedBytes(_ count: Int) throws -> [UInt8] {
        // The window may hold bytes that have not been consumed yet, so
        // recover the true bit position before rounding up to a boundary.
        let start = (nextByte * 8 - available + 7) / 8
        guard count >= 0, start + count <= endByte else {
            throw ImageError.invalidData(reason: "Unexpected end of compressed data")
        }
        window = 0
        available = 0
        nextByte = start + count
        return Array(bytes[start..<start + count])
    }
}
