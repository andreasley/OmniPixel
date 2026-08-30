import Foundation

/// A resolved, flattened vector scene extracted from an SVG document — the same draw
/// list the rasterizer consumes, exposed publicly for vector consumers (such as PDF
/// generation) that want to keep the artwork scalable instead of rasterizing it.
///
/// What "resolved" means here: transforms are applied, `use` references expanded,
/// styles cascaded, strokes converted into fill outlines, and curves flattened into
/// line segments (`precision` controls how finely — the flattening tolerance is about
/// `0.2 / precision` of a coordinate unit, invisible at print sizes with the default).
/// Every element is therefore a plain "fill these subpaths with one solid color".
///
/// Coordinates are y-down in the document's intrinsic coordinate space
/// (`0...width` × `0...height`).
///
/// Documents that use gradient paints throw `ImageError.unsupportedFeature`, so
/// callers can fall back to rasterizing. Features the rasterizer also skips (text,
/// filters, masks, patterns) are skipped here identically.
public struct SVGVectorScene: Sendable {
    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Subpath: Sendable {
        public var points: [Point]
        public var isClosed: Bool

        public init(points: [Point], isClosed: Bool) {
            self.points = points
            self.isClosed = isClosed
        }
    }

    /// One filled shape, in document order (painter's model: later over earlier).
    public struct Element: Sendable {
        public var subpaths: [Subpath]
        /// True for the even-odd fill rule; false for non-zero winding.
        public var usesEvenOddFill: Bool
        /// The solid paint. Its own alpha component is part of the color;
        /// `opacity` is applied on top.
        public var color: RGBA
        /// Accumulated `opacity`/`fill-opacity`/`stroke-opacity`, 0...1.
        public var opacity: Double

        public init(subpaths: [Subpath], usesEvenOddFill: Bool, color: RGBA, opacity: Double) {
            self.subpaths = subpaths
            self.usesEvenOddFill = usesEvenOddFill
            self.color = color
            self.opacity = opacity
        }
    }

    /// The document's intrinsic size in CSS pixels.
    public var width: Double
    public var height: Double
    public var elements: [Element]

    /// Extracts the vector scene from SVG data.
    /// - Parameter precision: Curve-flattening quality multiplier (clamped to 1...16).
    public init(data: Data, precision: Double = 4) throws {
        let root = try SVGXMLParser.parse(data)
        guard svgLocalName(of: root.name) == "svg" else {
            throw ImageError.invalidData(reason: "Root element is not <svg>")
        }
        let intrinsic = SVGCodec.intrinsicSize(of: root)
        guard intrinsic.width > 0, intrinsic.height > 0,
              intrinsic.width.isFinite, intrinsic.height.isFinite else {
            throw ImageError.invalidDimensions
        }

        // The scene builder flattens curves at a tolerance derived from the device
        // size, so building at a multiple of the intrinsic size and scaling the
        // coordinates back down yields sub-pixel-accurate curves.
        let scale = min(max(precision, 1), 16)
        let deviceWidth = max(1, Int((intrinsic.width * scale).rounded()))
        let deviceHeight = max(1, Int((intrinsic.height * scale).rounded()))
        let scaleX = Double(deviceWidth) / intrinsic.width
        let scaleY = Double(deviceHeight) / intrinsic.height

        let commands = SVGSceneBuilder.build(
            root: root, deviceWidth: deviceWidth, deviceHeight: deviceHeight
        )

        var elements: [Element] = []
        elements.reserveCapacity(commands.count)
        for command in commands {
            let color: RGBA
            switch command.paint {
            case .solid(let solid):
                color = solid
            case .gradient:
                throw ImageError.unsupportedFeature(
                    reason: "SVG gradients are not supported in vector export; rasterize instead"
                )
            }
            let subpaths = command.path.subpaths.compactMap { subpath -> Subpath? in
                guard subpath.points.count >= 2 else { return nil }
                return Subpath(
                    points: subpath.points.map { Point(x: $0.x / scaleX, y: $0.y / scaleY) },
                    isClosed: subpath.isClosed
                )
            }
            guard !subpaths.isEmpty else { continue }
            elements.append(Element(
                subpaths: subpaths,
                usesEvenOddFill: command.fillRule == .evenodd,
                color: color,
                opacity: min(1, max(0, command.alpha))
            ))
        }

        self.width = intrinsic.width
        self.height = intrinsic.height
        self.elements = elements
    }
}
