import Foundation
import Testing
import OmniPixel

/// Feeds corrupted files to every decoder.
///
/// The library's contract is to reject bad data by throwing, so a trap — an
/// array bounds check, an arithmetic overflow, a failed precondition — takes the
/// test process down and shows up as a crashed run rather than a failed
/// expectation. That is the point: much of the decoding hot path works through
/// raw pointers, where the compiler cannot check the arithmetic for us.
@Suite("FuzzDecoders", .tags(.fuzz),
       .enabled(if: FuzzGate.isEnabled, Comment(rawValue: FuzzGate.skipReason)),
       .timeLimit(.minutes(FuzzBudget.timeLimitMinutes)))
struct DecoderFuzzTests {

    /// Formats the library can encode, so the corpus is generated rather than
    /// checked in. AVIF, HEIC and SVG are decode-only and covered by
    /// `mutatedSampleFilesNeverCrash` instead.
    static let encodableFormats: [ImageFormat] = [.png, .jpeg, .gif, .tiff, .webp, .bmp, .qoi, .netpbm]

    /// Encoded once up front: all shards of a format share these, and
    /// encoding per test case would repeat the work `shardCount` times over.
    private static let seedsByFormat: [ImageFormat: [Data]] = Dictionary(
        uniqueKeysWithValues: encodableFormats.map { ($0, FuzzCorpus.encodedSeeds(for: $0)) }
    )

    @Test("mutated files are rejected, not fatal",
          arguments: encodableFormats, 0..<FuzzBudget.shardCount)
    func mutatedFilesNeverCrash(format: ImageFormat, shard: Int) throws {
        let seeds = Self.seedsByFormat[format] ?? []
        try #require(!seeds.isEmpty, "no encoder produced a seed file for \(format)")

        let oracle = FuzzOracle(label: "\(format) mutation")
        var decoded = 0
        for iteration in FuzzBudget.indices(shard: shard) {
            let seed = FuzzBudget.seed &+ UInt64(iteration) &* 0x9E37_79B9
            var random = FuzzRandom(seed: seed)
            let original = [UInt8](seeds[random.below(seeds.count)])
            let mutation = FuzzMutation.allCases[random.below(FuzzMutation.allCases.count)]
            var bytes = mutation.apply(to: original, using: &random)
            // PNG guards every chunk with a CRC, so without repairing it most
            // mutations would never reach the decoding logic at all.
            if format == .png, random.chance(oneIn: 2) {
                bytes = PNGBuilder.repairingCRCs(bytes)
            }
            if oracle.check(bytes, seed: seed) {
                decoded += 1
            }
        }
        // Not a correctness requirement, but a run where nothing ever decoded
        // would mean the mutations are too destructive to be testing much.
        // A shard with only a handful of cases can legitimately land on all
        // rejects, so the check only applies to a real budget.
        if FuzzBudget.shardsCanExpectDecodes {
            #expect(decoded > 0, "\(format): no mutated file decoded, so little was exercised")
        }
    }

    @Test("mutated sample files are rejected, not fatal", arguments: 0..<FuzzBudget.shardCount)
    func mutatedSampleFilesNeverCrash(shard: Int) throws {
        let samples = FuzzCorpus.sampleFiles
        try #require(!samples.isEmpty, "no sample files found next to the package")

        // The container formats these cover — AVIF and HEIC — run full AV1 and
        // HEVC decoders, so a case costs orders of magnitude more than a PNG or
        // BMP one. A tenth of the budget keeps a default run to a few seconds.
        let oracle = FuzzOracle(label: "sample mutation")
        for iteration in FuzzBudget.indices(shard: shard, of: max(100, FuzzBudget.iterations / 10)) {
            let seed = FuzzBudget.seed &+ UInt64(iteration) &* 0x8E37_79B1
            var random = FuzzRandom(seed: seed)
            let sample = samples[random.below(samples.count)]
            // Whole sample files can be large; a prefix keeps each case quick
            // while still covering the container parsers.
            let limit = min(sample.data.count, 8 << 10)
            let original = [UInt8](sample.data.prefix(limit))
            let mutation = FuzzMutation.allCases[random.below(FuzzMutation.allCases.count)]
            oracle.check(mutation.apply(to: original, using: &random), seed: seed)
        }
    }

    /// The first eight bytes of a valid file, one entry per distinct
    /// signature: from our encoders where the library has one, from the
    /// sample files for the decode-only formats. Computed once — encoding
    /// per case would spend the budget on generating inputs rather than
    /// decoding them.
    private static let signaturePrefixes: [[UInt8]] = {
        let encoded = ImageFormat.allCases.compactMap { format -> [UInt8]? in
            guard let data = try? FuzzCorpus.sampleImage(width: 2, height: 2).encoded(as: format)
            else { return nil }
            return Array([UInt8](data).prefix(8))
        }
        let sampled = FuzzCorpus.sampleFiles.map { Array($0.data.prefix(8)) }
        var seen = Set<[UInt8]>()
        return (encoded + sampled).filter { seen.insert($0).inserted }
    }()

    /// Bytes with no valid header at all: the format detector and every
    /// `canDecode` must cope with arbitrary input, including very short input.
    @Test("arbitrary bytes are rejected, not fatal", arguments: 0..<FuzzBudget.shardCount)
    func arbitraryBytesNeverCrash(shard: Int) {
        let oracle = FuzzOracle(label: "arbitrary bytes")
        for iteration in FuzzBudget.indices(shard: shard) {
            let seed = FuzzBudget.seed &+ UInt64(iteration) &* 0x7E37_79A7
            var random = FuzzRandom(seed: seed)
            let count = random.below(512)
            var bytes = (0..<count).map { _ in random.byte() }
            // Half the cases start with a real signature, so detection succeeds
            // and the bytes reach an actual decoder.
            if random.chance(oneIn: 2), !Self.signaturePrefixes.isEmpty {
                bytes = Self.signaturePrefixes[random.below(Self.signaturePrefixes.count)] + bytes
            }
            oracle.check(bytes, seed: seed)
        }
    }
}

/// PNG-specific fuzzing that reaches past the container checks.
///
/// Mutating a whole file mostly produces something the CRC or the zlib header
/// rejects. These cases keep the container well-formed on purpose and corrupt
/// what is inside it, so the row unfiltering, the pixel conversion and the
/// Adam7 pass arithmetic — all of which walk raw pointers — actually run.
@Suite("FuzzPNGStructure", .tags(.fuzz),
       .enabled(if: FuzzGate.isEnabled, Comment(rawValue: FuzzGate.skipReason)),
       .timeLimit(.minutes(FuzzBudget.timeLimitMinutes)))
struct PNGStructureFuzzTests {

    private static func randomLayout(using random: inout FuzzRandom) -> PNGBuilder.Layout {
        let combination = PNGBuilder.validCombinations[random.below(PNGBuilder.validCombinations.count)]
        return PNGBuilder.Layout(
            width: 1 + random.below(40),
            height: 1 + random.below(40),
            bitDepth: combination.bitDepth,
            colorType: combination.colorType,
            interlaced: random.chance(oneIn: 2)
        )
    }

    /// Arbitrary content in the unfiltered stream, including the per-row filter
    /// type bytes, and a stream that is too short or too long for the header.
    @Test("corrupt row data is rejected, not fatal", arguments: 0..<FuzzBudget.shardCount)
    func corruptRowDataNeverCrashes(shard: Int) {
        let oracle = FuzzOracle(label: "PNG row content")
        var decoded = 0
        for iteration in FuzzBudget.indices(shard: shard) {
            let seed = FuzzBudget.seed &+ UInt64(iteration) &* 0x6E37_7993
            var random = FuzzRandom(seed: seed)
            let layout = Self.randomLayout(using: &random)
            var raw = PNGBuilder.rawStream(layout, filterType: nil)

            for _ in 0..<(1 + random.below(20)) where !raw.isEmpty {
                raw[random.below(raw.count)] = random.byte()
            }
            switch random.below(4) {
            case 0: raw = Array(raw.prefix(random.below(raw.count + 1)))
            case 1: raw += (0..<(1 + random.below(64))).map { _ in random.byte() }
            default: break
            }

            if oracle.check(PNGBuilder.file(layout, raw: raw), seed: seed) {
                decoded += 1
            }
        }
        // As above: only a real per-shard budget makes a zero decode count
        // suspicious.
        if FuzzBudget.shardsCanExpectDecodes {
            #expect(decoded > 0, "no case decoded, so the row pipeline was barely exercised")
        }
    }

    /// A header that disagrees with the data it describes. This is where the
    /// pass geometry could walk off either the row buffer or the pixel buffer.
    @Test("header geometry that contradicts the data is rejected, not fatal",
          arguments: 0..<FuzzBudget.shardCount)
    func contradictoryGeometryNeverCrashes(shard: Int) {
        let oracle = FuzzOracle(label: "PNG geometry")
        for iteration in FuzzBudget.indices(shard: shard) {
            let seed = FuzzBudget.seed &+ UInt64(iteration) &* 0x5E37_7981
            var random = FuzzRandom(seed: seed)
            // Build the stream for one layout and describe it as another.
            let actual = Self.randomLayout(using: &random)
            var claimed = Self.randomLayout(using: &random)
            // Occasionally keep the dimensions and change only the sample
            // format, which is the subtler mismatch.
            if random.chance(oneIn: 3) {
                claimed.width = actual.width
                claimed.height = actual.height
            }
            let raw = PNGBuilder.rawStream(actual, filterType: nil)
            oracle.check(PNGBuilder.file(claimed, raw: raw), seed: seed)
        }
    }

    /// Valid PNGs for the deflate-stream cases to corrupt. Compressed with our
    /// own encoder, so the bytes being mutated are a real dynamic-Huffman
    /// stream rather than the stored blocks `PNGBuilder` emits. Encoding one
    /// costs far more than decoding the corrupted result, so the pool is built
    /// once instead of per case — otherwise most of the budget goes on
    /// producing inputs rather than testing the decoder.
    private static let compressedSeeds: [[UInt8]] = {
        [(7, 5), (16, 16), (33, 21), (40, 40)].compactMap { width, height in
            guard let data = try? FuzzCorpus.sampleImage(width: width, height: height)
                .encoded(as: .png) else { return nil }
            return [UInt8](data)
        }
    }()

    /// Byte noise inside a well-formed container with the CRCs repaired, so
    /// corruption lands in the zlib stream and the Huffman tables.
    @Test("corrupt compressed data is rejected, not fatal", arguments: 0..<FuzzBudget.shardCount)
    func corruptCompressedDataNeverCrashes(shard: Int) throws {
        try #require(!Self.compressedSeeds.isEmpty, "the encoder produced no seed files")

        let oracle = FuzzOracle(label: "PNG deflate stream")
        for iteration in FuzzBudget.indices(shard: shard) {
            let seed = FuzzBudget.seed &+ UInt64(iteration) &* 0x4E37_7975
            var random = FuzzRandom(seed: seed)
            var bytes = Self.compressedSeeds[random.below(Self.compressedSeeds.count)]

            for _ in 0..<(1 + random.below(16)) where !bytes.isEmpty {
                let index = random.below(bytes.count)
                if random.chance(oneIn: 2) {
                    bytes[index] ^= UInt8(1 << random.below(8))
                } else {
                    bytes[index] = random.byte()
                }
            }
            if random.chance(oneIn: 4) {
                bytes = Array(bytes.prefix(random.below(bytes.count + 1)))
            }
            oracle.check(PNGBuilder.repairingCRCs(bytes), seed: seed)
        }
    }
}
