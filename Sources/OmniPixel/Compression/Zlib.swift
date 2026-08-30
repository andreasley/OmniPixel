import Foundation

/// Public zlib-format (RFC 1950) compression and decompression, built on the internal
/// DEFLATE implementation.
///
/// This is deliberately a small, stable facade: dependents get exactly the zlib
/// container — 2-byte header, DEFLATE body, Adler-32 checksum — while the codec
/// internals stay free to evolve.
public enum Zlib {
    /// Ceiling applied when the caller does not know the decompressed size. DEFLATE
    /// expands by up to ~1000:1, so a few kilobytes could otherwise request gigabytes.
    public static let defaultMaximumOutputSize = 256 << 20

    /// Compresses bytes into a zlib stream.
    public static func compress(_ bytes: [UInt8]) -> [UInt8] {
        Deflate.zlibCompress(bytes)
    }

    /// Compresses data into a zlib stream.
    public static func compress(_ data: Data) -> Data {
        Data(Deflate.zlibCompress([UInt8](data)))
    }

    /// Decompresses a zlib stream.
    /// - Parameters:
    ///   - expectedSize: The known output size, if any — used only to size the output
    ///     buffer up front; a stream that produces more still decompresses correctly.
    ///   - maximumSize: Hard ceiling on the produced output.
    public static func decompress(
        _ bytes: [UInt8],
        expectedSize: Int = 0,
        maximumSize: Int = defaultMaximumOutputSize
    ) throws -> [UInt8] {
        try Inflate.zlibDecompress(bytes, expectedSize: expectedSize, maximumSize: maximumSize)
    }

    /// Decompresses a zlib stream.
    public static func decompress(
        _ data: Data,
        expectedSize: Int = 0,
        maximumSize: Int = defaultMaximumOutputSize
    ) throws -> Data {
        Data(try Inflate.zlibDecompress([UInt8](data), expectedSize: expectedSize, maximumSize: maximumSize))
    }
}
