import Foundation
import Testing
@testable import OmniPixel

@Suite struct SVGTests {
    private func decode(_ svg: String, width: Int? = nil, height: Int? = nil) throws -> Image {
        try Image(svgData: Data(svg.utf8), width: width, height: height)
    }

    // MARK: Format detection and sizing

    @Test func detectsFormat() throws {
        let plain = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"/>"
        #expect(ImageFormat(detecting: Data(plain.utf8)) == .svg)

        let withProlog = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"svg11.dtd\">\n"
            + "<!-- comment --><svg xmlns=\"http://www.w3.org/2000/svg\"/>"
        #expect(ImageFormat(detecting: Data(withProlog.utf8)) == .svg)

        #expect(ImageFormat(detecting: Data("<html><body/></html>".utf8)) != .svg)
        #expect(SVGCodec.canDecode(Data([0x89, 0x50, 0x4E, 0x47])) == false)
    }

    @Test func intrinsicSizeFromAttributes() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"17\" height=\"9\"/>")
        #expect(image.width == 17)
        #expect(image.height == 9)
    }

    @Test func intrinsicSizeFromViewBox() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 20\"/>")
        #expect(image.width == 32)
        #expect(image.height == 20)
    }

    @Test func fallbackSizeWithoutDimensions() throws {
        let image = try decode("<svg xmlns=\"http://www.w3.org/2000/svg\"/>")
        #expect(image.width == 300)
        #expect(image.height == 150)
    }

    @Test func physicalUnitsConvertToPixels() throws {
        // 1in = 96px, 72pt = 96px.
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1in\" height=\"72pt\"/>")
        #expect(image.width == 96)
        #expect(image.height == 96)
    }

    @Test func customRasterSizePreservesAspect() throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 20 10\">"
            + "<rect width=\"20\" height=\"10\" fill=\"red\"/></svg>"
        let image = try decode(svg, width: 100)
        #expect(image.width == 100)
        #expect(image.height == 50)
        #expect(image[50, 25] == RGBA(red: 255, green: 0, blue: 0))
    }

    @Test func rejectsNonSVGRoot() throws {
        // Detection sniffs "<svg" in the first kilobyte, so a document with
        // an svg element nested under a different root must fail cleanly.
        let data = Data("<root><svg width=\"4\" height=\"4\"/></root>".utf8)
        #expect(throws: ImageError.self) { try SVGCodec.decode(data) }
    }

    @Test func encodingIsUnsupported() throws {
        let image = Image(width: 1, height: 1, fill: .white)
        #expect(throws: ImageError.self) { try image.encoded(as: .svg) }
    }

    // MARK: Shapes and fills

    @Test func fillsRectWithNamedColor() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">"
            + "<rect width=\"10\" height=\"10\" fill=\"red\"/></svg>")
        #expect(image[5, 5] == RGBA(red: 255, green: 0, blue: 0))
        #expect(image[0, 0] == RGBA(red: 255, green: 0, blue: 0))
    }

    @Test func defaultFillIsBlack() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\">"
            + "<rect width=\"8\" height=\"8\"/></svg>")
        #expect(image[4, 4] == .black)
    }

    @Test func circleCoversCenterNotCorners() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">"
            + "<circle cx=\"10\" cy=\"10\" r=\"8\" fill=\"#00f\"/></svg>")
        #expect(image[10, 10] == RGBA(red: 0, green: 0, blue: 255))
        #expect(image[0, 0].alpha == 0)
        #expect(image[19, 19].alpha == 0)
    }

    @Test func antiAliasedEdgesArePartiallyCovered() throws {
        // A half-pixel-offset vertical edge should produce ~50% alpha.
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\">"
            + "<rect x=\"0.5\" width=\"3\" height=\"4\" fill=\"black\"/></svg>")
        let edge = image[0, 1].alpha
        #expect(edge > 100 && edge < 155, "expected ~128, got \(edge)")
        #expect(image[2, 2].alpha == 255)
    }

    @Test func hexAndFunctionalColors() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"6\" height=\"2\">"
            + "<rect width=\"2\" height=\"2\" fill=\"#1a2B3c\"/>"
            + "<rect x=\"2\" width=\"2\" height=\"2\" fill=\"rgb(10, 20, 30)\"/>"
            + "<rect x=\"4\" width=\"2\" height=\"2\" fill=\"rgba(100%, 0%, 50%, 0.5)\"/></svg>")
        #expect(image[1, 1] == RGBA(red: 0x1A, green: 0x2B, blue: 0x3C))
        #expect(image[3, 1] == RGBA(red: 10, green: 20, blue: 30))
        #expect(image[5, 1].red == 255)
        #expect(image[5, 1].alpha == 128)
    }

    @Test func polygonIsFilled() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">"
            + "<polygon points=\"0,0 10,0 10,10 0,10\" fill=\"lime\"/></svg>")
        #expect(image[5, 5] == RGBA(red: 0, green: 255, blue: 0))
    }

    @Test func fillNoneDrawsNothing() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"6\" height=\"6\">"
            + "<rect width=\"6\" height=\"6\" fill=\"none\"/></svg>")
        #expect(image[3, 3].alpha == 0)
    }

    // MARK: Paths

    @Test func pathWithCurvesAndClose() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">"
            + "<path d=\"M20 34 C8 24 2 16 8 9 C12 4 19 6 20 12 C21 6 28 4 32 9 "
            + "C38 16 32 24 20 34 Z\" fill=\"green\"/></svg>")
        #expect(image[20, 20] == RGBA(red: 0, green: 128, blue: 0))
        #expect(image[2, 2].alpha == 0)
    }

    @Test func relativeCommandsAndImplicitLineTo() throws {
        // "m" then implicit relative lineto pairs.
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">"
            + "<path d=\"m1 1 8 0 0 8 -8 0z\" fill=\"black\"/></svg>")
        #expect(image[5, 5] == .black)
        #expect(image[0, 0].alpha == 0)
    }

    @Test func evenOddDonutHasAHole() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">"
            + "<path d=\"M10 2 A8 8 0 1 0 10 18 A8 8 0 1 0 10 2 "
            + "M10 6 A4 4 0 1 1 10 14 A4 4 0 1 1 10 6\" "
            + "fill-rule=\"evenodd\" fill=\"purple\"/></svg>")
        #expect(image[10, 4].alpha == 255)   // ring
        #expect(image[10, 10].alpha == 0)    // hole
    }

    @Test func arcCommandDrawsHalfDisc() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">"
            + "<path d=\"M2 10 A8 8 0 0 1 18 10 Z\" fill=\"black\"/></svg>")
        #expect(image[10, 5].alpha == 255)   // above the chord: inside
        #expect(image[10, 15].alpha == 0)    // below the chord: outside
    }

    // MARK: Strokes

    @Test func strokedLine() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\">"
            + "<line x1=\"0\" y1=\"5\" x2=\"20\" y2=\"5\" stroke=\"black\" stroke-width=\"4\"/></svg>")
        #expect(image[10, 5].alpha == 255)
        #expect(image[10, 0].alpha == 0)
        #expect(image[10, 9].alpha == 0)
    }

    @Test func strokeWithoutFill() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">"
            + "<rect x=\"4\" y=\"4\" width=\"12\" height=\"12\" fill=\"none\" "
            + "stroke=\"red\" stroke-width=\"2\"/></svg>")
        #expect(image[10, 4] == RGBA(red: 255, green: 0, blue: 0))  // on the edge
        #expect(image[10, 10].alpha == 0)                           // interior empty
    }

    @Test func roundCapExtendsBeyondEndpoint() throws {
        let butt = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\">"
            + "<line x1=\"5\" y1=\"5\" x2=\"15\" y2=\"5\" stroke=\"black\" "
            + "stroke-width=\"4\" stroke-linecap=\"butt\"/></svg>")
        let round = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\">"
            + "<line x1=\"5\" y1=\"5\" x2=\"15\" y2=\"5\" stroke=\"black\" "
            + "stroke-width=\"4\" stroke-linecap=\"round\"/></svg>")
        #expect(butt[4, 5].alpha == 0)
        #expect(round[4, 5].alpha == 255)
    }

    // MARK: Transforms, groups and inheritance

    @Test func groupTransformTranslatesShape() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">"
            + "<g transform=\"translate(10 10)\">"
            + "<rect width=\"5\" height=\"5\" fill=\"black\"/></g></svg>")
        #expect(image[12, 12].alpha == 255)
        #expect(image[5, 5].alpha == 0)
    }

    @Test func rotationAboutAPoint() throws {
        // A rect rotated 90° about the canvas center stays centered.
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">"
            + "<rect x=\"2\" y=\"8\" width=\"16\" height=\"4\" fill=\"black\" "
            + "transform=\"rotate(90 10 10)\"/></svg>")
        #expect(image[10, 4].alpha == 255)   // now vertical
        #expect(image[4, 10].alpha == 0)
    }

    @Test func scaleTransformScalesStrokeToo() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">"
            + "<g transform=\"scale(2)\">"
            + "<line x1=\"0\" y1=\"10\" x2=\"20\" y2=\"10\" stroke=\"black\" stroke-width=\"2\"/>"
            + "</g></svg>")
        // Stroke width 2 scaled by 2 → 4 device pixels centered on y=20.
        #expect(image[20, 18].alpha == 255)
        #expect(image[20, 22].alpha == 0)
        #expect(image[20, 15].alpha == 0)
    }

    @Test func stylePropertiesInheritAndCascade() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"12\" height=\"6\">"
            + "<g fill=\"red\">"
            + "<rect width=\"6\" height=\"6\"/>"
            + "<rect x=\"6\" width=\"6\" height=\"6\" style=\"fill: blue\"/>"
            + "</g></svg>")
        #expect(image[3, 3] == RGBA(red: 255, green: 0, blue: 0))    // inherited
        #expect(image[9, 3] == RGBA(red: 0, green: 0, blue: 255))    // style wins
    }

    @Test func currentColorResolvesFromColorProperty() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"6\" height=\"6\">"
            + "<g color=\"orange\"><rect width=\"6\" height=\"6\" fill=\"currentColor\"/></g></svg>")
        #expect(image[3, 3] == RGBA(red: 255, green: 165, blue: 0))
    }

    @Test func opacityMultipliesThroughGroups() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"6\" height=\"6\">"
            + "<g opacity=\"0.5\"><rect width=\"6\" height=\"6\" fill=\"black\" "
            + "fill-opacity=\"0.5\"/></g></svg>")
        let alpha = image[3, 3].alpha
        #expect(alpha > 56 && alpha < 72, "expected ~64, got \(alpha)")
    }

    @Test func displayNoneHidesSubtree() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"6\" height=\"6\">"
            + "<g display=\"none\"><rect width=\"6\" height=\"6\"/></g></svg>")
        #expect(image[3, 3].alpha == 0)
    }

    // MARK: defs / use

    @Test func useReferencesDefinedShape() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\">"
            + "<defs><rect id=\"box\" width=\"5\" height=\"5\" fill=\"navy\"/></defs>"
            + "<use href=\"#box\"/><use href=\"#box\" x=\"10\" y=\"5\"/></svg>")
        #expect(image[2, 2] == RGBA(red: 0, green: 0, blue: 128))
        #expect(image[12, 7] == RGBA(red: 0, green: 0, blue: 128))
        #expect(image[12, 2].alpha == 0)
    }

    @Test func recursiveUseDoesNotHang() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\">"
            + "<g id=\"a\"><use href=\"#a\"/><rect width=\"1\" height=\"1\"/></g></svg>")
        #expect(image.width == 4)  // decoding terminated
    }

    // MARK: Gradients

    @Test func linearGradientInterpolatesHorizontally() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"21\" height=\"5\">"
            + "<defs><linearGradient id=\"g\">"
            + "<stop offset=\"0\" stop-color=\"black\"/>"
            + "<stop offset=\"1\" stop-color=\"white\"/>"
            + "</linearGradient></defs>"
            + "<rect width=\"21\" height=\"5\" fill=\"url(#g)\"/></svg>")
        #expect(image[0, 2].red < 20)
        #expect(image[20, 2].red > 235)
        let middle = image[10, 2].red
        #expect(middle > 100 && middle < 155, "expected ~128, got \(middle)")
        // Grayscale throughout.
        #expect(image[10, 2].red == image[10, 2].green)
    }

    @Test func radialGradientIsCenteredByDefault() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"21\" height=\"21\">"
            + "<defs><radialGradient id=\"g\">"
            + "<stop offset=\"0\" stop-color=\"white\"/>"
            + "<stop offset=\"1\" stop-color=\"black\"/>"
            + "</radialGradient></defs>"
            + "<rect width=\"21\" height=\"21\" fill=\"url(#g)\"/></svg>")
        #expect(image[10, 10].red > 235)              // bright center
        #expect(image[0, 0].red < 20)                 // dark corner (padded)
        #expect(image[10, 0].red < image[10, 5].red)  // darkens outward
    }

    @Test func gradientHrefInheritsStops() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">"
            + "<defs>"
            + "<linearGradient id=\"base\">"
            + "<stop offset=\"0\" stop-color=\"red\"/>"
            + "<stop offset=\"1\" stop-color=\"red\"/>"
            + "</linearGradient>"
            + "<linearGradient id=\"derived\" href=\"#base\"/>"
            + "</defs>"
            + "<rect width=\"10\" height=\"10\" fill=\"url(#derived)\"/></svg>")
        #expect(image[5, 5] == RGBA(red: 255, green: 0, blue: 0))
    }

    @Test func missingGradientFallsBackToFallbackColor() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"6\" height=\"6\">"
            + "<rect width=\"6\" height=\"6\" fill=\"url(#missing) green\"/></svg>")
        #expect(image[3, 3] == RGBA(red: 0, green: 128, blue: 0))
    }

    @Test func stopOpacityAffectsAlpha() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"4\">"
            + "<defs><linearGradient id=\"g\">"
            + "<stop offset=\"0\" stop-color=\"black\" stop-opacity=\"0\"/>"
            + "<stop offset=\"1\" stop-color=\"black\" stop-opacity=\"1\"/>"
            + "</linearGradient></defs>"
            + "<rect width=\"10\" height=\"4\" fill=\"url(#g)\"/></svg>")
        #expect(image[0, 2].alpha < 30)
        #expect(image[9, 2].alpha > 225)
    }

    // MARK: Viewport mapping

    @Test func viewBoxScalesContent() throws {
        // A viewBox of 0 0 10 10 rendered at 20x20 doubles all coordinates.
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\" "
            + "viewBox=\"0 0 10 10\">"
            + "<rect x=\"2\" y=\"2\" width=\"6\" height=\"6\" fill=\"black\"/></svg>")
        #expect(image[10, 10].alpha == 255)
        #expect(image[2, 2].alpha == 0)     // (1,1) in user units — outside
        #expect(image[5, 5].alpha == 255)   // (2.5, 2.5) — inside
    }

    @Test func preserveAspectRatioMeetCenters() throws {
        // Square viewBox into a wide canvas: content is centered horizontally.
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"10\" "
            + "viewBox=\"0 0 10 10\">"
            + "<rect width=\"10\" height=\"10\" fill=\"black\"/></svg>")
        #expect(image[15, 5].alpha == 255)  // centered content
        #expect(image[2, 5].alpha == 0)     // letterboxed left
        #expect(image[28, 5].alpha == 0)    // letterboxed right
    }

    @Test func xmlEntitiesAndCDataAreHandled() throws {
        let image = try decode(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"6\" height=\"6\">"
            + "<rect width=\"6\" height=\"6\" fill=\"&#x72;ed\"/>"
            + "<![CDATA[ignored]]></svg>")
        #expect(image[3, 3] == RGBA(red: 255, green: 0, blue: 0))
    }

    @Test func malformedXMLThrowsInvalidData() throws {
        let data = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\"".utf8)
        #expect(throws: ImageError.self) { try SVGCodec.decode(data) }
    }
}
