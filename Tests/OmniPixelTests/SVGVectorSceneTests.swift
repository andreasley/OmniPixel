import Foundation
import Testing
@testable import OmniPixel

@Suite("SVG vector scene export")
struct SVGVectorSceneTests {
    @Test func extractsResolvedSolidShapes() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="50">
          <rect x="10" y="10" width="30" height="20" fill="#ff0000"/>
          <circle cx="70" cy="25" r="15" fill="#0000ff" fill-opacity="0.5"/>
        </svg>
        """
        let scene = try SVGVectorScene(data: Data(svg.utf8))
        #expect(scene.width == 100)
        #expect(scene.height == 50)
        #expect(scene.elements.count == 2)

        let rect = scene.elements[0]
        #expect(rect.color == RGBA(red: 255, green: 0, blue: 0))
        #expect(rect.opacity == 1)
        let xs = rect.subpaths[0].points.map(\.x)
        let ys = rect.subpaths[0].points.map(\.y)
        #expect(abs(xs.min()! - 10) < 0.01 && abs(xs.max()! - 40) < 0.01)
        #expect(abs(ys.min()! - 10) < 0.01 && abs(ys.max()! - 30) < 0.01)

        let circle = scene.elements[1]
        #expect(circle.color == RGBA(red: 0, green: 0, blue: 255))
        #expect(abs(circle.opacity - 0.5) < 0.01)
        // The circle flattens into many segments spanning its bounding box.
        #expect(circle.subpaths[0].points.count > 16)
        #expect(circle.subpaths[0].isClosed)
        let cxs = circle.subpaths[0].points.map(\.x)
        #expect(abs(cxs.min()! - 55) < 0.2 && abs(cxs.max()! - 85) < 0.2)
    }

    @Test func strokesArriveAsFillOutlines() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">
          <line x1="0" y1="20" x2="40" y2="20" stroke="#00ff00" stroke-width="4"/>
        </svg>
        """
        let scene = try SVGVectorScene(data: Data(svg.utf8))
        #expect(scene.elements.count == 1)
        let ys = scene.elements[0].subpaths.flatMap { $0.points.map(\.y) }
        // A 4-unit stroke around y=20 outlines to roughly 18...22.
        #expect(abs(ys.min()! - 18) < 0.2 && abs(ys.max()! - 22) < 0.2)
    }

    @Test func evenOddFillRuleIsPreserved() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
          <path d="M0 0h20v20H0z M5 5h10v10H5z" fill-rule="evenodd" fill="black"/>
        </svg>
        """
        let scene = try SVGVectorScene(data: Data(svg.utf8))
        #expect(scene.elements.count == 1)
        #expect(scene.elements[0].usesEvenOddFill)
        #expect(scene.elements[0].subpaths.count == 2)
    }

    @Test func gradientsThrowSoCallersCanRasterize() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
          <defs><linearGradient id="g"><stop offset="0" stop-color="red"/>
          <stop offset="1" stop-color="blue"/></linearGradient></defs>
          <rect width="20" height="20" fill="url(#g)"/>
        </svg>
        """
        #expect(throws: ImageError.self) {
            try SVGVectorScene(data: Data(svg.utf8))
        }
    }

    @Test func scalesCoordinatesBackToIntrinsicSpace() throws {
        // viewBox differs from the declared size: coordinates must come back in
        // intrinsic units regardless of precision.
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 20 10">
          <rect x="0" y="0" width="20" height="10" fill="black"/>
        </svg>
        """
        for precision in [1.0, 4.0, 8.0] {
            let scene = try SVGVectorScene(data: Data(svg.utf8), precision: precision)
            let xs = scene.elements[0].subpaths[0].points.map(\.x)
            #expect(abs(xs.max()! - 200) < 0.51, "precision \(precision): \(xs.max()!)")
        }
    }
}
