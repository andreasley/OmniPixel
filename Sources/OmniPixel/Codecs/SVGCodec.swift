import Foundation

/// SVG (Scalable Vector Graphics) — decodes by rasterizing a widely used
/// subset of static SVG 1.1/2.0: shapes, paths, groups, transforms,
/// `defs`/`use`, solid paints and gradients. Text, filters, masks,
/// patterns, CSS stylesheets and animation are not supported. Encoding
/// (vectorizing raster images) is unsupported.
enum SVGCodec: ImageCodec {
    /// The CSS default object size, used when a document declares
    /// neither dimensions nor a viewBox.
    static let fallbackSize = (width: 300.0, height: 150.0)

    static func canDecode(_ data: Data) -> Bool {
        // SVG has no magic bytes; look for an opening "<svg" tag near the
        // start (after any BOM, XML declaration, comments or DOCTYPE).
        let probe: [UInt8] = [0x3C, 0x73, 0x76, 0x67]  // "<svg"
        let window = [UInt8](data.prefix(1024))
        guard window.count >= probe.count else { return false }
        for start in 0...(window.count - probe.count) {
            if window[start] == probe[0],
               window[start + 1] == probe[1],
               window[start + 2] == probe[2],
               window[start + 3] == probe[3] {
                return true
            }
        }
        return false
    }

    static func decode(_ data: Data) throws -> Image {
        try rasterize(data, width: nil, height: nil)
    }

    static func encode(_ image: Image) throws -> Data {
        throw ImageError.unsupportedFeature(reason: "SVG encoding is not supported")
    }

    /// Rasterizes an SVG document, optionally overriding the output size.
    /// Giving only one dimension preserves the document's aspect ratio.
    static func rasterize(_ data: Data, width: Int?, height: Int?) throws -> Image {
        let root = try SVGXMLParser.parse(data)
        guard svgLocalName(of: root.name) == "svg" else {
            throw ImageError.invalidData(reason: "Root element is not <svg>")
        }

        let (pixelWidth, pixelHeight) = try pixelSize(
            of: root, requestedWidth: width, requestedHeight: height
        )
        let commands = SVGSceneBuilder.build(
            root: root, deviceWidth: pixelWidth, deviceHeight: pixelHeight
        )
        var image = Image(width: pixelWidth, height: pixelHeight, fill: .transparent)
        SVGRasterizer.render(commands, into: &image)
        return image
    }

    /// The pixel dimensions to rasterize a document at.
    ///
    /// Guarantees `1 <= width`, `1 <= height` and
    /// `width * height <= Image.maxPixelCount`, whatever the document's
    /// declared size and aspect ratio.
    static func pixelSize(
        of root: SVGXMLElement,
        requestedWidth: Int?,
        requestedHeight: Int?
    ) throws -> (width: Int, height: Int) {
        let intrinsic = intrinsicSize(of: root)
        var deviceWidth: Double
        var deviceHeight: Double
        switch (requestedWidth, requestedHeight) {
        case let (.some(width), .some(height)):
            deviceWidth = Double(width)
            deviceHeight = Double(height)
        case let (.some(width), nil):
            deviceWidth = Double(width)
            deviceHeight = Double(width) * intrinsic.height / intrinsic.width
        case let (nil, .some(height)):
            deviceHeight = Double(height)
            deviceWidth = Double(height) * intrinsic.width / intrinsic.height
        case (nil, nil):
            deviceWidth = intrinsic.width
            deviceHeight = intrinsic.height
        }
        guard deviceWidth >= 0.5, deviceHeight >= 0.5,
              deviceWidth.isFinite, deviceHeight.isFinite else {
            throw ImageError.invalidDimensions
        }

        // Scale oversized requests down to the allocation limit,
        // preserving the aspect ratio.
        let limit = Double(Image.maxPixelCount)
        let pixelCount = deviceWidth * deviceHeight
        if pixelCount > limit {
            let shrink = (limit / pixelCount).squareRoot()
            deviceWidth *= shrink
            deviceHeight *= shrink
        }
        // Shrinking preserves the aspect ratio, so an extreme one leaves the
        // long side far above the limit (and possibly above Int.max) once the
        // short side has been scaled below a whole pixel. Clamp each side
        // while still in floating point, then trim the product, so neither
        // the conversion nor the allocation can exceed its bound.
        var pixelWidth = max(1, Int(min(deviceWidth.rounded(), limit)))
        let pixelHeight = max(1, Int(min(deviceHeight.rounded(), limit)))
        if pixelWidth > Image.maxPixelCount / pixelHeight {
            pixelWidth = Image.maxPixelCount / pixelHeight
        }
        return (pixelWidth, pixelHeight)
    }

    /// The document's intrinsic pixel size: its width/height attributes
    /// when present, the viewBox size otherwise, else the CSS default.
    static func intrinsicSize(of root: SVGXMLElement) -> (width: Double, height: Double) {
        let viewBox = SVGSceneBuilder.parseViewBox(root.attributes["viewBox"])
        let declaredWidth = absoluteLength(root.attributes["width"])
        let declaredHeight = absoluteLength(root.attributes["height"])

        switch (declaredWidth, declaredHeight) {
        case let (.some(width), .some(height)):
            return (width, height)
        case let (.some(width), nil):
            if let viewBox { return (width, width * viewBox.height / viewBox.width) }
            return (width, fallbackSize.height)
        case let (nil, .some(height)):
            if let viewBox { return (height * viewBox.width / viewBox.height, height) }
            return (fallbackSize.width, height)
        case (nil, nil):
            if let viewBox { return (viewBox.width, viewBox.height) }
            return fallbackSize
        }
    }

    /// Parses a positive absolute length (percentages have no meaning for
    /// the document's own size and are ignored).
    private static func absoluteLength(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        var scanner = SVGNumberScanner(text)
        guard let value = scanner.scanNumber(), value > 0 else { return nil }
        var unit = ""
        while let scalar = scanner.peek() {
            unit.unicodeScalars.append(scalar)
            scanner.position += 1
        }
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "", "px": return value
        case "pt": return value * 96 / 72
        case "pc": return value * 16
        case "mm": return value * 96 / 25.4
        case "cm": return value * 96 / 2.54
        case "in": return value * 96
        default: return nil
        }
    }
}

extension Image {
    /// Rasterizes an SVG document.
    ///
    /// With no size given, the document's intrinsic size is used (its
    /// width/height attributes, its viewBox, or 300×150 as a last resort).
    /// Giving only one dimension preserves the aspect ratio; giving both
    /// stretches per `preserveAspectRatio` like an HTML viewer would.
    public init(svgData: Data, width: Int? = nil, height: Int? = nil) throws {
        self = try SVGCodec.rasterize(svgData, width: width, height: height)
    }
}
