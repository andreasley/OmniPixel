import Foundation
import Testing
import OmniPixel

/// Exhaustive PNG decode conformance: every colour type paired with every bit
/// depth the spec allows it, all five row filters, both interlace modes, and
/// sizes that land on and off byte boundaries.
///
/// Files come from `PNGBuilder`, which follows the spec independently of
/// `PNGCodec`, so this catches a decoder that agrees with itself but not with
/// the format. It runs by default — it is deterministic and quick — and is the
/// counterpart to the fuzz suites: those prove the decoder does not crash,
/// this proves it decodes correctly.
@Suite("PNGConformance")
struct PNGConformanceTests {

    /// Small enough to stay fast, chosen to exercise partial bytes at sub-byte
    /// depths and to leave several Adam7 passes empty.
    static let sizes = [(1, 1), (1, 7), (7, 1), (3, 5), (8, 8), (9, 9), (13, 6), (17, 11)]

    static let layouts: [PNGBuilder.Layout] = {
        var layouts: [PNGBuilder.Layout] = []
        for combination in PNGBuilder.validCombinations {
            for interlaced in [false, true] {
                for (width, height) in sizes {
                    layouts.append(PNGBuilder.Layout(
                        width: width,
                        height: height,
                        bitDepth: combination.bitDepth,
                        colorType: combination.colorType,
                        interlaced: interlaced
                    ))
                }
            }
        }
        return layouts
    }()

    @Test("every colour type, depth, filter and interlace mode decodes exactly")
    func decodesEveryCombination() throws {
        for layout in Self.layouts {
            // nil cycles all five filter types across the rows of one file.
            for filterType in [nil, 0, 1, 2, 3, 4] as [Int?] {
                let description = "type \(layout.colorType) depth \(layout.bitDepth) "
                    + "\(layout.width)x\(layout.height)"
                    + (layout.interlaced ? " interlaced" : "")
                    + " filter \(filterType.map(String.init) ?? "cycled")"
                let bytes = PNGBuilder.file(layout, filterType: filterType)
                let decoded = try Image(data: Data(bytes))
                #expect(decoded == PNGBuilder.expectedImage(layout), "\(description)")
            }
        }
    }

    /// Our own encoder has to round-trip exactly at every shape, including the
    /// ones where a row is narrower than the filter's four-byte distance.
    @Test("the encoder round-trips at every shape")
    func encoderRoundTripsExactly() throws {
        for width in 1...20 {
            for height in 1...20 {
                let image = FuzzCorpus.sampleImage(width: width, height: height)
                let decoded = try Image(data: image.encoded(as: .png))
                #expect(decoded == image, "\(width)x\(height)")
            }
        }
    }
}
