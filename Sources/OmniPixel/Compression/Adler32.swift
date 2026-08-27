/// Adler-32 checksum, used by the zlib container (RFC 1950).
enum Adler32 {
    private static let modulus: UInt32 = 65521
    /// The longest run that can be summed before `b` risks overflowing 32 bits,
    /// so the two modulo operations happen once per run instead of once per byte.
    private static let maximumRun = 5552

    static func checksum(of bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        bytes.withUnsafeBufferPointer { buffer in
            let count = buffer.count
            var index = 0
            while index < count {
                let runEnd = min(index + maximumRun, count)
                while index < runEnd {
                    a &+= UInt32(buffer[index])
                    b &+= a
                    index += 1
                }
                a %= modulus
                b %= modulus
            }
        }
        return b << 16 | a
    }
}
