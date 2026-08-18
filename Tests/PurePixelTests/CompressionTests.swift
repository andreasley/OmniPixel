import Testing
@testable import PurePixel

#if canImport(Compression)
import Compression
#endif

@Suite struct CompressionTests {
    @Test func crc32MatchesStandardCheckValue() {
        #expect(CRC32.checksum(of: Array("123456789".utf8)) == 0xCBF43926)
    }

    @Test func adler32MatchesStandardCheckValue() {
        #expect(Adler32.checksum(of: Array("123456789".utf8)) == 0x091E01DE)
    }

    @Test func inflateDecodesFixedHuffmanStream() throws {
        // "hello" compressed by zlib at the default level (a fixed-Huffman block),
        // as an independent reference for the decoder.
        let compressed: [UInt8] = [
            0x78, 0x9C, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00, 0x06, 0x2C, 0x02, 0x15,
        ]
        #expect(try Inflate.zlibDecompress(compressed) == Array("hello".utf8))
    }

    @Test func zlibRoundTripOfIncompressibleData() throws {
        // Deterministic pseudo-random noise; the compressor should fall back
        // to stored blocks rather than expanding the data.
        var bytes: [UInt8] = []
        var state: UInt32 = 12345
        for _ in 0..<100_000 {
            state = state &* 1664525 &+ 1013904223
            bytes.append(UInt8(truncatingIfNeeded: state >> 16))
        }
        let compressed = Deflate.zlibCompress(bytes)
        #expect(try Inflate.zlibDecompress(compressed) == bytes)
        #expect(compressed.count < bytes.count + 100)
    }

    @Test func zlibRoundTripOfEmptyInput() throws {
        #expect(try Inflate.zlibDecompress(Deflate.zlibCompress([])) == [])
    }

    @Test func compressesRepetitiveText() throws {
        let bytes = Array(String(repeating: "PurePixel compresses repetitive data well. ", count: 200).utf8)
        let compressed = Deflate.zlibCompress(bytes)
        #expect(try Inflate.zlibDecompress(compressed) == bytes)
        #expect(compressed.count < bytes.count / 10)
    }

    @Test func compressesLongRuns() throws {
        let bytes = [UInt8](repeating: 0xAB, count: 70_000)
        let compressed = Deflate.zlibCompress(bytes)
        #expect(try Inflate.zlibDecompress(compressed) == bytes)
        #expect(compressed.count < 1_000)
    }

    @Test func roundTripOfMixedContent() throws {
        // Alternating flat runs and pseudo-random noise, crossing many
        // literal/match boundaries and both Huffman block types.
        var bytes: [UInt8] = []
        var state: UInt32 = 99
        for segment in 0..<50 {
            if segment % 2 == 0 {
                bytes += [UInt8](repeating: UInt8(segment), count: 500)
            } else {
                for _ in 0..<500 {
                    state = state &* 1664525 &+ 1013904223
                    bytes.append(UInt8(truncatingIfNeeded: state >> 16))
                }
            }
        }
        #expect(try Inflate.zlibDecompress(Deflate.zlibCompress(bytes)) == bytes)
    }

    @Test(arguments: ["", "a", "ab", "abcabcabcabc", "aaaaaa", "abab", "to be or not to be, that is the question"])
    func rawDeflateRoundTripOfShortInputs(text: String) throws {
        let bytes = Array(text.utf8)
        #expect(try Inflate.decompressRaw(Deflate.compressRaw(bytes)) == bytes)
    }

    @Test func inflateRejectsCorruptChecksum() {
        var compressed = Deflate.zlibCompress(Array("hello".utf8))
        compressed[compressed.count - 1] ^= 0xFF
        #expect(throws: ImageError.self) {
            _ = try Inflate.zlibDecompress(compressed)
        }
    }

    @Test func inflateRejectsTruncatedStream() {
        let compressed = Deflate.zlibCompress(Array("hello world, hello world".utf8))
        #expect(throws: ImageError.self) {
            _ = try Inflate.zlibDecompress(Array(compressed.prefix(6)))
        }
    }

    #if canImport(Compression)
    @Test func rawDeflateIsReadableBySystemZlib() throws {
        // Cross-check our compressor against Apple's zlib implementation, so a
        // spec misreading mirrored in our own inflater can't hide.
        let bytes = Array(String(repeating: "interoperability check with some variety 0123456789. ", count: 300).utf8)
        let compressed = Deflate.compressRaw(bytes)

        var decoded = [UInt8](repeating: 0, count: bytes.count + 1)
        let decodedCount = compressed.withUnsafeBufferPointer { source in
            compression_decode_buffer(
                &decoded, decoded.count,
                source.baseAddress!, source.count,
                nil, COMPRESSION_ZLIB
            )
        }
        #expect(decodedCount == bytes.count)
        #expect(Array(decoded.prefix(decodedCount)) == bytes)
    }
    #endif
}
