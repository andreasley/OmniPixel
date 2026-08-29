import Foundation
import Testing
@testable import OmniPixel

/// Regression tests for the inputs found in the unsafe-code audit (see
/// Documentation/SECURITY-AUDIT-2026-08-29.md). Each used to trap, exhaust the
/// stack, or run effectively forever. The contract most of them check is
/// deliberately weak — return an image or throw, but do not take the process
/// down — because for hostile input that is the whole requirement. Where a
/// specific rejection or a specific bound is the point, the test says so.
@Suite struct HostileInputTests {
    private func svg(_ text: String) -> Data { Data(text.utf8) }

    /// Decoding must end in a value or an `ImageError`, never a trap.
    private func decodesOrThrows(_ document: String) {
        do {
            _ = try Image(svgData: svg(document))
        } catch is ImageError {
            // Rejection is the expected outcome for most of these.
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: SVG — coordinate conversion

    /// `Int(_:)` traps on non-finite values and on anything outside Int's
    /// range, so every device-coordinate-to-pixel conversion has to clamp
    /// while still in floating point.
    @Test(arguments: [
        // A coordinate far outside Int's range.
        #"<svg width="100" height="100"><path d="M0 0L1e30 1e30L0 100Z" fill="black"/></svg>"#,
        // viewBox scaling inflates modest coordinates to infinity.
        #"<svg width="10" height="10" viewBox="0 0 1e-300 1e-300"><rect width="1e300" height="1e300" fill="black"/></svg>"#,
        // The same, through a transform.
        #"<svg width="10" height="10"><g transform="matrix(1e200 0 0 1e200 0 0)"><rect width="5" height="5"/></g></svg>"#,
        // Every edge degenerate, leaving the bounding box at its sentinels.
        #"<svg width="10" height="10"><path d="M0 0L0 0Z" fill="black"/></svg>"#,
    ])
    func extremeCoordinatesDoNotTrap(_ document: String) {
        decodesOrThrows(document)
    }

    /// A span narrower than the rasterizer's epsilon must not select the
    /// pixel before the one it starts in.
    @Test(arguments: [
        #"<svg width="10" height="10"><rect x="0" y="0" width="0.0000000000001" height="5" fill="black"/></svg>"#,
        #"<svg width="10" height="10"><rect x="-10" y="1" width="10.0000000000001" height="5" fill="black"/></svg>"#,
    ])
    func subPixelSpansStayInTheCoverageBuffer(_ document: String) {
        decodesOrThrows(document)
    }

    // MARK: SVG — sizing

    /// Shrinking to the pixel budget preserves the aspect ratio, so an
    /// extreme ratio left the long side above both the budget and Int.max
    /// once the short side rounded down to a single pixel.
    /// Checked on the computed size rather than by rasterizing: these
    /// documents legitimately ask for the largest image the library allows,
    /// and allocating a gigabyte per case is what the limit exists to permit,
    /// not something worth doing four times over in a test run.
    @Test(arguments: [
        #"<svg width="1e30" height="0.5"></svg>"#,
        #"<svg width="1e9" height="0.5"></svg>"#,
        #"<svg width="0.5" height="1e9"></svg>"#,
        #"<svg width="1e300" height="1e300"></svg>"#,
        #"<svg width="1e300" height="1"></svg>"#,
    ])
    func extremeAspectRatioRespectsThePixelBudget(_ document: String) throws {
        let root = try SVGXMLParser.parse(svg(document))
        let size = try SVGCodec.pixelSize(of: root, requestedWidth: nil, requestedHeight: nil)
        #expect(size.width >= 1)
        #expect(size.height >= 1)
        #expect(size.width * size.height <= Image.maxPixelCount)
    }

    /// The same bound has to hold for caller-supplied sizes.
    @Test func requestedSizesRespectThePixelBudget() throws {
        let root = try SVGXMLParser.parse(svg(#"<svg width="10" height="10"/>"#))
        let size = try SVGCodec.pixelSize(
            of: root, requestedWidth: Int.max, requestedHeight: 1
        )
        #expect(size.width * size.height <= Image.maxPixelCount)
    }

    // MARK: SVG — recursion and expansion

    /// Stack exhaustion is a signal, not a Swift error, so nesting has to be
    /// rejected before the recursion gets deep enough to matter.
    @Test func deeplyNestedElementsAreRejected() {
        let open = String(repeating: "<g>", count: 6000)
        let close = String(repeating: "</g>", count: 6000)
        #expect(throws: ImageError.self) {
            _ = try Image(svgData: svg("<svg width=\"10\" height=\"10\">\(open)\(close)</svg>"))
        }
        // Also inside <defs>, which the renderer never walks — so the parser
        // itself has to be the one that stops.
        #expect(throws: ImageError.self) {
            _ = try Image(svgData: svg(
                "<svg width=\"10\" height=\"10\"><defs>\(open)\(close)</defs></svg>"))
        }
    }

    /// Nesting within the limit still has to render.
    @Test func moderatelyNestedElementsStillRender() throws {
        let depth = SVGXMLParser.maxElementDepth / 2
        let document = "<svg width=\"8\" height=\"8\">"
            + String(repeating: "<g>", count: depth)
            + #"<rect width="8" height="8" fill="black"/>"#
            + String(repeating: "</g>", count: depth) + "</svg>"
        let image = try Image(svgData: svg(document))
        #expect(image[0, 0].alpha == 255)
    }

    /// A `use` may reference a subtree containing further `use` elements, so
    /// expansion is exponential in the nesting depth. The depth limit bounds
    /// neither the breadth nor the traversal, and a chain that bottoms out at
    /// that limit draws nothing at all — spending no geometry budget while
    /// still describing on the order of 10^12 visits.
    @Test(.timeLimit(.minutes(1)))
    func exponentialUseExpansionTerminates() throws {
        var document = "<svg width=\"64\" height=\"64\"><defs>"
            + #"<rect id="l0" width="4" height="4" fill="black"/>"#
        for level in 1...12 {
            document += "<g id=\"l\(level)\">"
                + String(repeating: "<use href=\"#l\(level - 1)\"/>", count: 10)
                + "</g>"
        }
        document += "</defs><use href=\"#l12\"/></svg>"
        _ = try Image(svgData: svg(document))
    }

    /// One curve with far-flung control points subdivides all the way to the
    /// depth limit, which is 2^24 points if nothing caps the count.
    @Test(.timeLimit(.minutes(1)))
    func degenerateBezierTerminates() throws {
        _ = try Image(svgData: svg(
            #"<svg width="64" height="64"><path d="M0 0C1e14 1e14 1e14 -1e14 1 0" fill="black"/></svg>"#))
    }

    /// Round joins emit a whole polygon per vertex and the segment count
    /// grows as the stroke widens, so the outline is vertices × segments and
    /// a document controls both factors.
    @Test(.timeLimit(.minutes(2)))
    func wideRoundJoinedStrokeTerminates() throws {
        var points = ""
        for index in 0..<20000 {
            points += "\(index % 97) \(index % 89) "
        }
        _ = try Image(svgData: svg(
            "<svg width=\"64\" height=\"64\"><polyline stroke=\"black\" "
            + "stroke-width=\"1000000\" stroke-linejoin=\"round\" points=\"\(points)\"/></svg>"))
    }

    /// The bundled icons must still rasterize, so none of the new budgets
    /// rejects ordinary artwork.
    @Test func ordinaryStrokedArtworkStillRenders() throws {
        let document = """
        <svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48">
          <path d="M8 40 C 8 8, 40 8, 40 40 Z" fill="none" stroke="black"
                stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>
          <circle cx="24" cy="24" r="6" fill="red"/>
        </svg>
        """
        let image = try Image(svgData: svg(document))
        #expect(image.width == 48)
        #expect(image[24, 24].red > 100)
    }

    // MARK: JPEG

    /// A 16-bit quantization table combined with a progressive scan's point
    /// transform made `coefficient × quantizer × idctTable` overflow Int
    /// inside the inverse DCT.
    @Test func oversizedQuantizationValuesAreRejected() {
        var data: [UInt8] = [0xFF, 0xD8]            // SOI
        data += [0xFF, 0xDB, 0x00, 0x85, 0x10]      // DQT, length 133, Pq=1 Tq=0
        data += [UInt8](repeating: 0xFF, count: 128)  // every value 65535
        data += [0xFF, 0xD9]                        // EOI
        #expect(throws: ImageError.self) {
            _ = try Image(data: Data(data), format: .jpeg)
        }
    }

    /// Ordinary 8-bit tables must still be accepted.
    @Test func eightBitQuantizationTablesAreAccepted() throws {
        let original = Image(width: 16, height: 16, fill: RGBA(red: 10, green: 120, blue: 240, alpha: 255))
        let encoded = try original.encoded(as: .jpeg)
        let decoded = try Image(data: encoded, format: .jpeg)
        #expect(decoded.width == 16)
        #expect(decoded.height == 16)
    }

    // MARK: DEFLATE

    /// DEFLATE expands by up to about 1000:1, so the output window needs a
    /// ceiling of its own rather than growing until the caller checks the
    /// finished size.
    @Test func inflateHonoursItsOutputCeiling() {
        var writer = BitWriter()
        writer.writeBits(1, count: 1)  // BFINAL
        writer.writeBits(1, count: 2)  // fixed Huffman
        // Literal 'A' (0x41): fixed code 0x71 in 8 bits, stored MSB first.
        writer.writeCode(0x71, length: 8)
        // Then repeat the previous byte 258 at a time: length symbol 285 is
        // code 0b11000101 (8 bits), distance code 0 (5 bits) means distance 1.
        for _ in 0..<4000 {
            writer.writeCode(0xC5, length: 8)
            writer.writeCode(0x00, length: 5)
        }
        writer.writeCode(0x00, length: 7)  // end-of-block symbol 256
        let stream = writer.finish()

        #expect(throws: ImageError.self) {
            _ = try Inflate.decompressRaw(stream, maximumSize: 4096)
        }
        // The same stream is fine when the ceiling accommodates it.
        let full = try? Inflate.decompressRaw(stream, maximumSize: 4000 * 258 + 16)
        #expect(full?.count == 1 + 4000 * 258)
    }

    /// A PNG's raw size follows from its header, so inflate is told that
    /// exact figure and a stream claiming to expand past it is rejected
    /// without first allocating its way there.
    @Test func pngRoundTripsWithTheOutputCeilingInPlace() throws {
        var original = Image(width: 33, height: 17, fill: .transparent)
        for y in 0..<17 {
            for x in 0..<33 {
                original[x, y] = RGBA(red: UInt8(x * 7 % 256), green: UInt8(y * 13 % 256),
                                      blue: UInt8((x + y) % 256), alpha: 255)
            }
        }
        let decoded = try Image(data: try original.encoded(as: .png), format: .png)
        #expect(decoded.width == 33)
        #expect(decoded.height == 17)
        for y in 0..<17 {
            for x in 0..<33 {
                #expect(decoded[x, y] == original[x, y])
            }
        }
    }

    // MARK: AV1 table invariants

    /// `decodeBlock` rejects streams whose block size has no chroma
    /// equivalent, which is what keeps the plane geometry lookups in
    /// `planeTxSize`, `allZeroCtx` and the intra block-copy path from
    /// indexing with ss_size_lookup's BLOCK_INVALID sentinel. This pins the
    /// table shape that guard relies on.
    @Test func av1SubsampledSizeIsUndefinedForTallBlocksIn422() {
        // 4X8, 8X16, 16X32, 32X64, 64X128, 4X16, 8X32, 16X64.
        let tallerThanWide = [1, 4, 7, 10, 13, 16, 18, 20]
        for blockSize in tallerThanWide {
            // 4:2:2 is subX = 1, subY = 0.
            #expect(AV1Tables.subsampledSize[blockSize][1][0] < 0,
                    "block \(blockSize) should have no 4:2:2 chroma size")
            // 4:2:0 and 4:4:4 always have one.
            #expect(AV1Tables.subsampledSize[blockSize][1][1] >= 0)
            #expect(AV1Tables.subsampledSize[blockSize][0][0] >= 0)
        }
    }

    /// Every entry the decoder may reach after that guard has to be a valid
    /// index into the geometry tables.
    @Test func av1SubsampledSizesIndexTheGeometryTables() {
        for blockSize in AV1Tables.subsampledSize.indices {
            for subX in 0...1 {
                for subY in 0...1 {
                    let size = AV1Tables.subsampledSize[blockSize][subX][subY]
                    guard size >= 0 else { continue }
                    #expect(size < AV1Tables.blockWidth4.count)
                    #expect(size < AV1Tables.blockHeight4.count)
                    #expect(size < AV1Tables.maxTxSizeRect.count)
                }
            }
        }
    }
}
