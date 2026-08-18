/// Writes bits least-significant-bit first into a byte buffer, as DEFLATE requires.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var currentByte: UInt8 = 0
    private var bitCount = 0

    /// Writes `count` bits of `value`, least significant bit first.
    mutating func writeBits(_ value: Int, count: Int) {
        for i in 0..<count {
            if value >> i & 1 == 1 {
                currentByte |= 1 << bitCount
            }
            bitCount += 1
            if bitCount == 8 {
                bytes.append(currentByte)
                currentByte = 0
                bitCount = 0
            }
        }
    }

    /// Writes a Huffman code, which DEFLATE stores most significant bit first.
    mutating func writeCode(_ code: Int, length: Int) {
        for i in (0..<length).reversed() {
            writeBits(code >> i & 1, count: 1)
        }
    }

    /// Pads with zero bits to the next byte boundary.
    mutating func alignToNextByte() {
        if bitCount > 0 {
            bytes.append(currentByte)
            currentByte = 0
            bitCount = 0
        }
    }

    /// Flushes any partial byte and returns the completed buffer.
    mutating func finish() -> [UInt8] {
        alignToNextByte()
        return bytes
    }
}
