import Foundation
import Testing
import OmniPixel

extension Tag {
    /// Randomized robustness testing. Tagged so an Xcode test plan can select
    /// or exclude it as a group; see `FuzzGate` for how a run opts in.
    @Tag static var fuzz: Self
}

/// Decides whether the randomized suites run at all.
///
/// They take as long as you let them, so they stay off during an ordinary
/// `swift test`. A run opts in either by naming them on the command line —
/// `swift test --filter Fuzz` — or by setting `OMNIPIXEL_FUZZ`, which is what an
/// Xcode test plan should do, since Xcode selects tests without passing a
/// filter this process can see.
enum FuzzGate {
    static let isEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if let flag = environment["OMNIPIXEL_FUZZ"], flag != "0", !flag.isEmpty {
            return true
        }
        // SwiftPM forwards `--filter` to the test runner, so the selection is
        // visible here. Matching the value rather than the whole argument list
        // matters: this bundle's own path also contains "Fuzz".
        var arguments = ProcessInfo.processInfo.arguments.makeIterator()
        while let argument = arguments.next() {
            let value: String?
            if argument == "--filter" {
                value = arguments.next()
            } else if argument.hasPrefix("--filter=") {
                value = String(argument.dropFirst("--filter=".count))
            } else {
                value = nil
            }
            if let value, value.range(of: "fuzz", options: .caseInsensitive) != nil {
                return true
            }
        }
        return false
    }()

    static let skipReason = """
        Randomized suites are off by default. Run `swift test --filter Fuzz`, or \
        set OMNIPIXEL_FUZZ=1 (for example as an Xcode test plan's environment \
        variable). OMNIPIXEL_FUZZ_ITERATIONS scales the work; \
        OMNIPIXEL_FUZZ_SEED replays a reported failure.
        """
}

/// How much work each randomized test does, and where its randomness starts.
enum FuzzBudget {
    /// Cases per test. The default is enough to be meaningful in a few seconds
    /// per format; raise it for a long session.
    static let iterations = integer(named: "OMNIPIXEL_FUZZ_ITERATIONS", default: 5_000)

    /// The base seed. Every case derives its own seed from this and its index,
    /// so a reported seed replays the whole run exactly.
    static let seed = UInt64(integer(named: "OMNIPIXEL_FUZZ_SEED", default: 0x243F_6A88))

    /// Minutes any one randomized test may take. A backstop against a decoder
    /// that loops instead of rejecting: see the README on why this cannot be a
    /// per-case check.
    static let timeLimitMinutes = integer(named: "OMNIPIXEL_FUZZ_MINUTES", default: 10)

    private static func integer(named name: String, default fallback: Int) -> Int {
        guard let text = ProcessInfo.processInfo.environment[name],
              let parsed = Int(text), parsed > 0 else {
            return fallback
        }
        return parsed
    }
}

/// A deterministic generator, so a failing case can be replayed from its seed
/// alone. xorshift64 is more than enough for shuffling bytes around.
struct FuzzRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// A value in `0..<bound`, or zero if the range is empty.
    mutating func below(_ bound: Int) -> Int {
        bound <= 0 ? 0 : Int(next() % UInt64(bound))
    }

    mutating func byte() -> UInt8 {
        UInt8(truncatingIfNeeded: next())
    }

    mutating func chance(oneIn odds: Int) -> Bool {
        below(odds) == 0
    }
}

/// How a valid file gets corrupted. Each kind targets a different sort of
/// decoder assumption: noise finds arithmetic mistakes, length changes find
/// missing end-of-input checks, and field overwrites point a reader off the end
/// of its buffer.
enum FuzzMutation: CaseIterable {
    case bitFlips
    case byteWrites
    case truncate
    case extend
    case duplicateRun
    case deleteRun
    case overwriteField

    func apply(to bytes: [UInt8], using random: inout FuzzRandom) -> [UInt8] {
        var bytes = bytes
        guard !bytes.isEmpty else { return bytes }

        switch self {
        case .bitFlips:
            for _ in 0..<(1 + random.below(24)) {
                let index = random.below(bytes.count)
                bytes[index] ^= UInt8(1 << random.below(8))
            }
        case .byteWrites:
            for _ in 0..<(1 + random.below(12)) {
                bytes[random.below(bytes.count)] = random.byte()
            }
        case .truncate:
            bytes = Array(bytes.prefix(random.below(bytes.count)))
        case .extend:
            bytes += (0..<(1 + random.below(64))).map { _ in random.byte() }
        case .duplicateRun:
            let start = random.below(bytes.count)
            let length = 1 + random.below(min(64, bytes.count - start))
            bytes.insert(contentsOf: bytes[start..<start + length], at: start)
        case .deleteRun:
            let start = random.below(bytes.count)
            let length = 1 + random.below(min(64, bytes.count - start))
            bytes.removeSubrange(start..<start + length)
        case .overwriteField:
            // Rewrite a whole four-byte, big-endian-looking field. Chunk
            // lengths, dimensions and offsets all have this shape, and a single
            // byte flip rarely moves them somewhere interesting.
            guard bytes.count >= 4 else { break }
            let index = random.below(bytes.count - 3)
            let replacement = random.next()
            for offset in 0..<4 {
                bytes[index + offset] = UInt8(truncatingIfNeeded: replacement >> (8 * UInt64(offset)))
            }
        }
        return bytes
    }
}

/// The contract every decoder is held to: given arbitrary bytes, it either
/// produces a self-consistent image or throws.
///
/// A trap — an array bounds check, an arithmetic overflow, a failed
/// precondition — takes the whole process down, and catching that is the reason
/// these suites exist: much of the decoding hot path works through raw
/// pointers, where the compiler cannot check the arithmetic for us. A decoder
/// that loops instead of rejecting shows up as a run that never finishes, which
/// the suite-level time limit turns into a failure.
struct FuzzOracle {
    let label: String

    /// Decodes and checks the contract. Returns whether the bytes decoded.
    @discardableResult
    func check(_ bytes: [UInt8], seed: UInt64) -> Bool {
        do {
            let image = try Image(data: Data(bytes))
            #expect(image.width > 0, "\(label): decoded a non-positive width. \(replay(seed: seed))")
            #expect(image.height > 0, "\(label): decoded a non-positive height. \(replay(seed: seed))")
            #expect(
                image.pixels.count == image.width * image.height,
                "\(label): pixel buffer disagrees with the dimensions. \(replay(seed: seed))"
            )
            return true
        } catch let error as ImageError {
            _ = error  // Rejecting bad data is the expected outcome.
            return false
        } catch {
            Issue.record(Comment(rawValue: "\(label): threw \(type(of: error)) rather than an "
                + "ImageError: \(error). \(replay(seed: seed))"))
            return false
        }
    }

    private func replay(seed: UInt64) -> String {
        "Replay with OMNIPIXEL_FUZZ_SEED=\(seed)."
    }
}

/// Valid files for the mutator to work from. Our encoders cover most formats;
/// the bundled sample files cover the ones the library only decodes.
enum FuzzCorpus {

    /// A small image with gradients, flat runs and partial transparency, so
    /// every encoder has something to compress and something to quantize.
    static func sampleImage(width: Int, height: Int) -> Image {
        var image = Image(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                image[x, y] = RGBA(
                    red: UInt8((x * 7 + y * 3) % 256),
                    green: UInt8((x + y * 11) % 256),
                    blue: UInt8(x < width / 2 ? 40 : (x * y) % 256),
                    alpha: UInt8((x + y) % 5 == 0 ? 90 : 255)
                )
            }
        }
        return image
    }

    /// Encoded seeds for a format, or an empty array if the format has no encoder.
    static func encodedSeeds(for format: ImageFormat) -> [Data] {
        [(1, 1), (5, 3), (17, 13), (64, 48)].compactMap { width, height in
            try? sampleImage(width: width, height: height).encoded(as: format)
        }
    }

    /// The repository's sample files, which cover the decode-only formats.
    static let sampleFiles: [(name: String, data: Data)] = {
        // Tests/OmniPixelFuzzTests/FuzzSupport.swift → repository root → Samples.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent("Samples")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  !data.isEmpty else {
                return nil
            }
            return (name, data)
        }
    }()
}
