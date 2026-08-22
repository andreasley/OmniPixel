/// Adler-32 checksum, used by the zlib container (RFC 1950).
enum Adler32 {
    static func checksum(of bytes: some Sequence<UInt8>) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }
}
