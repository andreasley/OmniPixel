/// Reads bits least-significant-bit first from a byte buffer, as DEFLATE requires.
struct BitReader {
    private let bytes: [UInt8]
    private var byteOffset = 0
    private var bitOffset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readBit() throws -> Int {
        guard byteOffset < bytes.count else {
            throw ImageError.invalidData(reason: "Unexpected end of compressed data")
        }
        let bit = Int(bytes[byteOffset] >> bitOffset) & 1
        bitOffset += 1
        if bitOffset == 8 {
            bitOffset = 0
            byteOffset += 1
        }
        return bit
    }

    mutating func readBits(_ count: Int) throws -> Int {
        var value = 0
        for i in 0..<count {
            value |= try readBit() << i
        }
        return value
    }

    /// Discards any bits remaining in the current byte and reads whole bytes.
    mutating func readAlignedBytes(_ count: Int) throws -> [UInt8] {
        if bitOffset > 0 {
            bitOffset = 0
            byteOffset += 1
        }
        guard count >= 0, byteOffset + count <= bytes.count else {
            throw ImageError.invalidData(reason: "Unexpected end of compressed data")
        }
        defer { byteOffset += count }
        return Array(bytes[byteOffset..<byteOffset + count])
    }
}
