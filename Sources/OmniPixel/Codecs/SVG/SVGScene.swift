import Foundation

/// Parses an SVG document tree and produces device-space draw commands.
///
/// Supported: the basic shapes, paths, groups, `defs`/`use`, transforms,
/// solid fills and strokes, linear/radial gradients, opacity, both fill
/// rules and the standard presentation attributes plus inline `style`.
/// Not supported (skipped): text, images, patterns, clipping, masking,
/// filters, CSS stylesheets/selectors, animation and dashed strokes.
final class SVGSceneBuilder {
    /// The user-space viewport, used to resolve percentage lengths.
    private let viewport: (width: Double, height: Double)
    /// Elements by `id`, for `use` and gradient references.
    private let elementsByID: [String: SVGXMLElement]
    private var commands: [SVGDrawCommand] = []
    private var useDepth = 0
    private static let maxUseDepth = 12
    /// Tree-walk depth limit. `use` re-enters the walk at an arbitrary point
    /// in the tree, so the XML nesting limit alone does not bound how deep
    /// this recursion goes; without its own cap it can overflow the stack.
    private var renderDepth = 0
    private static let maxRenderDepth = 256
    /// Total flattened points the scene may accumulate.
    ///
    /// A `use` may reference a subtree containing further `use` elements, so
    /// expansion is exponential in the nesting depth: `maxUseDepth` bounds
    /// the depth but not the breadth, and 12 levels of ten references each
    /// is 10^12 shapes. Charging every emitted point against one budget
    /// bounds the total work no matter how it is nested.
    private var pointBudget = 2_000_000
    /// Node visits the tree walk may make.
    ///
    /// Separate from the point budget because visits that emit no geometry
    /// are free to describe: a `use` chain bottoming out at `maxUseDepth`
    /// draws nothing, so it spends no points while still exploring
    /// exponentially many nodes.
    private var visitBudget = 1_000_000
    /// Draw commands the scene may hold. The point budget alone leaves room
    /// for millions of three-point shapes, and each command carries fixed
    /// per-shape cost in the rasterizer regardless of how small it is.
    private static let maxCommands = 100_000

    /// Inherited graphics state, in the spirit of the CSS cascade.
    private struct GraphicsState {
        var transform: SVGMatrix
        var fill: SVGPaint = .color(.black)
        var fillOpacity = 1.0
        var fillRule: SVGFillRule = .nonzero
        var stroke: SVGPaint = SVGPaint.none
        var strokeOpacity = 1.0
        var strokeWidth = 1.0
        var lineCap: SVGLineCap = .butt
        var lineJoin: SVGLineJoin = .miter
        var miterLimit = 4.0
        /// The CSS `color` property, targeted by `currentColor`.
        var color = RGBA.black
        /// Accumulated `opacity` of ancestor elements.
        ///
        /// True group opacity requires isolated compositing; multiplying
        /// the opacity through to each shape is a close approximation that
        /// only differs where siblings within the group overlap.
        var groupAlpha = 1.0
    }

    private init(viewport: (width: Double, height: Double),
                 elementsByID: [String: SVGXMLElement]) {
        self.viewport = viewport
        self.elementsByID = elementsByID
    }

    /// Renders the document into draw commands for a device of the given pixel size.
    static func build(
        root: SVGXMLElement,
        deviceWidth: Int,
        deviceHeight: Int
    ) -> [SVGDrawCommand] {
        let viewBox = parseViewBox(root.attributes["viewBox"])
        let viewport = viewBox.map { (width: $0.width, height: $0.height) }
            ?? (width: Double(deviceWidth), height: Double(deviceHeight))

        var elementsByID: [String: SVGXMLElement] = [:]
        collectIDs(of: root, into: &elementsByID)

        let builder = SVGSceneBuilder(viewport: viewport, elementsByID: elementsByID)
        var state = GraphicsState(transform: rootTransform(
            root: root, viewBox: viewBox,
            deviceWidth: Double(deviceWidth), deviceHeight: Double(deviceHeight)
        ))
        builder.applyStyle(of: root, to: &state)
        for child in root.children {
            builder.render(child, state: state)
        }
        return builder.commands
    }

    private static func collectIDs(of element: SVGXMLElement,
                                   into map: inout [String: SVGXMLElement]) {
        if let id = element.attributes["id"], map[id] == nil {
            map[id] = element
        }
        for child in element.children {
            collectIDs(of: child, into: &map)
        }
    }

    // MARK: Viewport mapping

    static func parseViewBox(_ text: String?)
        -> (minX: Double, minY: Double, width: Double, height: Double)? {
        guard let text else { return nil }
        var scanner = SVGNumberScanner(text)
        guard let minX = scanner.scanNumber(), let minY = scanner.scanNumber(),
              let width = scanner.scanNumber(), let height = scanner.scanNumber(),
              width > 0, height > 0 else { return nil }
        return (minX, minY, width, height)
    }

    private static func rootTransform(
        root: SVGXMLElement,
        viewBox: (minX: Double, minY: Double, width: Double, height: Double)?,
        deviceWidth: Double, deviceHeight: Double
    ) -> SVGMatrix {
        guard let viewBox else {
            // Without a viewBox, one user unit is one CSS pixel at intrinsic
            // size; rasterizing at another size scales proportionally.
            let intrinsic = SVGCodec.intrinsicSize(of: root)
            return .scaling(x: deviceWidth / intrinsic.width,
                            y: deviceHeight / intrinsic.height)
        }
        var scaleX = deviceWidth / viewBox.width
        var scaleY = deviceHeight / viewBox.height
        var alignX = 0.5, alignY = 0.5

        let preserve = (root.attributes["preserveAspectRatio"] ?? "xMidYMid meet")
            .trimmingCharacters(in: .whitespaces)
        let parts = preserve.split(separator: " ").map(String.init)
        let alignment = parts.first ?? "xMidYMid"
        if alignment != "none" {
            let isSlice = parts.count > 1 && parts[1] == "slice"
            let scale = isSlice ? max(scaleX, scaleY) : min(scaleX, scaleY)
            scaleX = scale
            scaleY = scale
            if alignment.hasPrefix("xMin") { alignX = 0 }
            if alignment.hasPrefix("xMax") { alignX = 1 }
            if alignment.hasSuffix("YMin") { alignY = 0 }
            if alignment.hasSuffix("YMax") { alignY = 1 }
        }
        let offsetX = (deviceWidth - viewBox.width * scaleX) * alignX
        let offsetY = (deviceHeight - viewBox.height * scaleY) * alignY
        return SVGMatrix.translation(x: offsetX, y: offsetY)
            .concatenating(.scaling(x: scaleX, y: scaleY))
            .concatenating(.translation(x: -viewBox.minX, y: -viewBox.minY))
    }

    // MARK: Tree walking

    private func render(_ element: SVGXMLElement, state: GraphicsState) {
        guard visitBudget > 0, pointBudget > 0,
              renderDepth < Self.maxRenderDepth else { return }
        visitBudget -= 1
        renderDepth += 1
        defer { renderDepth -= 1 }

        var state = state
        // Elements hidden via display/visibility are skipped entirely.
        let styles = styleProperties(of: element)
        if styles["display"] == "none" { return }
        if styles["visibility"] == "hidden" || styles["visibility"] == "collapse" { return }

        switch svgLocalName(of: element.name) {
        case "g", "a":
            applyStyle(of: element, to: &state)
            for child in element.children { render(child, state: state) }
        case "svg":
            // Nested svg: treated as a group offset by x/y.
            applyStyle(of: element, to: &state)
            let x = length(element, styles, "x", reference: viewport.width) ?? 0
            let y = length(element, styles, "y", reference: viewport.height) ?? 0
            state.transform = state.transform.concatenating(.translation(x: x, y: y))
            for child in element.children { render(child, state: state) }
        case "use":
            renderUse(element, state: state)
        case "switch":
            // Render the first child that has no conditional requirements.
            applyStyle(of: element, to: &state)
            let isUnconditional: (SVGXMLElement) -> Bool = {
                $0.attributes["requiredFeatures"] == nil
                    && $0.attributes["requiredExtensions"] == nil
                    && $0.attributes["systemLanguage"] == nil
            }
            if let chosen = element.children.first(where: isUnconditional) {
                render(chosen, state: state)
            }
        case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
            applyStyle(of: element, to: &state)
            renderShape(element, styles: styles, state: state)
        default:
            // defs, gradients, text, filters, metadata, unknown elements:
            // not rendered directly.
            return
        }
    }

    private func renderUse(_ element: SVGXMLElement, state: GraphicsState) {
        guard useDepth < Self.maxUseDepth else { return }
        let reference = element.attributes["href"] ?? element.attributes["xlink:href"] ?? ""
        guard reference.hasPrefix("#"),
              let target = elementsByID[String(reference.dropFirst())] else { return }

        var state = state
        applyStyle(of: element, to: &state)
        let styles = styleProperties(of: element)
        let x = length(element, styles, "x", reference: viewport.width) ?? 0
        let y = length(element, styles, "y", reference: viewport.height) ?? 0
        state.transform = state.transform.concatenating(.translation(x: x, y: y))

        useDepth += 1
        defer { useDepth -= 1 }
        render(target, state: state)
    }

    // MARK: Shapes

    private func renderShape(_ element: SVGXMLElement,
                             styles: [String: String],
                             state: GraphicsState) {
        // Flatten finely enough that curves stay smooth after scaling.
        let tolerance = 0.2 / state.transform.approximateScale
        var builder = SVGPathBuilder(tolerance: tolerance)
        let diagonal = ((viewport.width * viewport.width
            + viewport.height * viewport.height) / 2).squareRoot()

        var fillIsAllowed = true
        switch svgLocalName(of: element.name) {
        case "path":
            guard let data = element.attributes["d"] else { return }
            builder.addPathData(data)
        case "rect":
            let rxAttribute = length(element, styles, "rx", reference: viewport.width)
            let ryAttribute = length(element, styles, "ry", reference: viewport.height)
            builder.addRect(
                x: length(element, styles, "x", reference: viewport.width) ?? 0,
                y: length(element, styles, "y", reference: viewport.height) ?? 0,
                width: length(element, styles, "width", reference: viewport.width) ?? 0,
                height: length(element, styles, "height", reference: viewport.height) ?? 0,
                radiusX: rxAttribute ?? ryAttribute ?? 0,
                radiusY: ryAttribute ?? rxAttribute ?? 0
            )
        case "circle":
            let radius = length(element, styles, "r", reference: diagonal) ?? 0
            builder.addEllipse(
                centerX: length(element, styles, "cx", reference: viewport.width) ?? 0,
                centerY: length(element, styles, "cy", reference: viewport.height) ?? 0,
                radiusX: radius, radiusY: radius
            )
        case "ellipse":
            builder.addEllipse(
                centerX: length(element, styles, "cx", reference: viewport.width) ?? 0,
                centerY: length(element, styles, "cy", reference: viewport.height) ?? 0,
                radiusX: length(element, styles, "rx", reference: viewport.width) ?? 0,
                radiusY: length(element, styles, "ry", reference: viewport.height) ?? 0
            )
        case "line":
            builder.move(to: SVGPoint(
                x: length(element, styles, "x1", reference: viewport.width) ?? 0,
                y: length(element, styles, "y1", reference: viewport.height) ?? 0))
            builder.line(to: SVGPoint(
                x: length(element, styles, "x2", reference: viewport.width) ?? 0,
                y: length(element, styles, "y2", reference: viewport.height) ?? 0))
            fillIsAllowed = false
        case "polyline":
            builder.addPointList(element.attributes["points"] ?? "", closing: false)
        case "polygon":
            builder.addPointList(element.attributes["points"] ?? "", closing: true)
        default:
            return
        }

        let userPath = builder.path
        guard !userPath.isEmpty else { return }
        let boundingBox = Self.boundingBox(of: userPath)
        let devicePath = userPath.transformed(by: state.transform)

        if fillIsAllowed, let paint = resolvePaint(
            state.fill, state: state, boundingBox: boundingBox
        ) {
            guard charge(devicePath) else { return }
            commands.append(SVGDrawCommand(
                path: devicePath,
                fillRule: state.fillRule,
                paint: paint,
                alpha: state.fillOpacity * state.groupAlpha
            ))
        }

        if state.strokeWidth > 0, let paint = resolvePaint(
            state.stroke, state: state, boundingBox: boundingBox
        ) {
            let stroker = SVGStroker(
                width: state.strokeWidth,
                cap: state.lineCap,
                join: state.lineJoin,
                miterLimit: state.miterLimit,
                tolerance: tolerance
            )
            let outline = stroker.stroke(userPath).transformed(by: state.transform)
            if !outline.isEmpty, charge(outline) {
                commands.append(SVGDrawCommand(
                    path: outline,
                    fillRule: .nonzero,
                    paint: paint,
                    alpha: state.strokeOpacity * state.groupAlpha
                ))
            }
        }
    }

    /// Charges a path's points against the scene budget. Returns false once
    /// either budget is spent, which also stops the tree walk in `render`.
    private func charge(_ path: SVGFlattenedPath) -> Bool {
        let points = path.subpaths.reduce(0) { $0 + $1.points.count }
        guard points <= pointBudget, commands.count < Self.maxCommands else {
            pointBudget = 0
            return false
        }
        pointBudget -= points
        return true
    }

    private static func boundingBox(of path: SVGFlattenedPath)
        -> (minX: Double, minY: Double, width: Double, height: Double) {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for subpath in path.subpaths {
            for point in subpath.points {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
        }
        guard minX <= maxX, minY <= maxY else { return (0, 0, 0, 0) }
        return (minX, minY, maxX - minX, maxY - minY)
    }

    // MARK: Style handling

    /// Merges presentation attributes with the inline `style` attribute
    /// (style wins, per the cascade).
    private func styleProperties(of element: SVGXMLElement) -> [String: String] {
        var properties: [String: String] = [:]
        let styleable = [
            "fill", "fill-opacity", "fill-rule", "stroke", "stroke-opacity",
            "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
            "opacity", "color", "display", "visibility", "stop-color", "stop-opacity",
        ]
        for name in styleable {
            if let value = element.attributes[name] {
                properties[name] = value
            }
        }
        if let style = element.attributes["style"] {
            for declaration in style.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                properties[name] = value
            }
        }
        return properties
    }

    private func applyStyle(of element: SVGXMLElement, to state: inout GraphicsState) {
        if let transform = element.attributes["transform"] {
            state.transform = state.transform.concatenating(SVGMatrix.parse(transform))
        }
        let styles = styleProperties(of: element)

        if let value = styles["color"], let color = SVGColorParser.parseColor(value) {
            state.color = color
        }
        if let value = styles["fill"], let paint = SVGColorParser.parsePaint(value) {
            state.fill = paint
        }
        if let value = styles["stroke"], let paint = SVGColorParser.parsePaint(value) {
            state.stroke = paint
        }
        if let value = styles["fill-opacity"].flatMap(Self.parseOpacity) {
            state.fillOpacity = value
        }
        if let value = styles["stroke-opacity"].flatMap(Self.parseOpacity) {
            state.strokeOpacity = value
        }
        if let value = styles["opacity"].flatMap(Self.parseOpacity) {
            state.groupAlpha *= value
        }
        if let value = styles["fill-rule"], let rule = SVGFillRule(rawValue: value) {
            state.fillRule = rule
        }
        if let value = styles["stroke-width"],
           let width = resolveLength(value, reference: strokeReference()) {
            state.strokeWidth = max(0, width)
        }
        if let value = styles["stroke-linecap"], let cap = SVGLineCap(rawValue: value) {
            state.lineCap = cap
        }
        if let value = styles["stroke-linejoin"], let join = SVGLineJoin(rawValue: value) {
            state.lineJoin = join
        }
        if let value = styles["stroke-miterlimit"], let limit = Double(value), limit >= 1 {
            state.miterLimit = limit
        }
    }

    private static func parseOpacity(_ text: String) -> Double? {
        var scanner = SVGNumberScanner(text)
        guard let value = scanner.scanNumber() else { return nil }
        let resolved = scanner.peek() == "%" ? value / 100 : value
        return min(1, max(0, resolved))
    }

    /// Percentage lengths that aren't horizontal or vertical use the
    /// normalized viewport diagonal (SVG 1.1 §7.10).
    private func strokeReference() -> Double {
        ((viewport.width * viewport.width + viewport.height * viewport.height) / 2).squareRoot()
    }

    // MARK: Lengths

    private func length(_ element: SVGXMLElement, _ styles: [String: String],
                        _ name: String, reference: Double) -> Double? {
        let text = styles[name] ?? element.attributes[name]
        return text.flatMap { resolveLength($0, reference: reference) }
    }

    /// Parses a length with an optional unit; percentages resolve against
    /// `reference`. CSS absolute units convert at 96 px per inch.
    private func resolveLength(_ text: String, reference: Double) -> Double? {
        var scanner = SVGNumberScanner(text.trimmingCharacters(in: .whitespaces))
        guard let value = scanner.scanNumber() else { return nil }
        var unit = ""
        while let scalar = scanner.peek() {
            unit.unicodeScalars.append(scalar)
            scanner.position += 1
        }
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "", "px": return value
        case "%": return value / 100 * reference
        case "pt": return value * 96 / 72
        case "pc": return value * 16
        case "mm": return value * 96 / 25.4
        case "cm": return value * 96 / 2.54
        case "in": return value * 96
        case "em": return value * 16   // default font size
        case "ex": return value * 8
        default: return nil
        }
    }

    // MARK: Paint resolution

    private func resolvePaint(
        _ paint: SVGPaint,
        state: GraphicsState,
        boundingBox: (minX: Double, minY: Double, width: Double, height: Double)
    ) -> SVGResolvedPaint? {
        switch paint {
        case .none:
            return nil
        case .color(let color):
            return .solid(color)
        case .currentColor:
            return .solid(state.color)
        case let .reference(id, fallback):
            if let definition = gradientDefinition(id: id) {
                if definition.stops.isEmpty {
                    return nil  // a gradient with no stops means fill: none
                }
                if definition.stops.count == 1 {
                    return .solid(definition.stops[0].color)
                }
                if let gradient = SVGResolvedGradient(
                    definition: definition,
                    userToDevice: state.transform,
                    boundingBox: boundingBox,
                    viewport: viewport
                ) {
                    return .gradient(gradient)
                }
                return .solid(definition.stops[definition.stops.count - 1].color)
            }
            return fallback.map { .solid($0) }
        }
    }

    // MARK: Gradients

    /// Parses a gradient element, following `href` chains for inherited
    /// attributes and stops.
    private func gradientDefinition(id: String) -> SVGGradientDefinition? {
        // Collect the reference chain, child first.
        var chain: [SVGXMLElement] = []
        var currentID: String? = id
        while let lookupID = currentID, chain.count < 8,
              let element = elementsByID[lookupID] {
            let name = svgLocalName(of: element.name)
            guard name == "linearGradient" || name == "radialGradient" else { return nil }
            chain.append(element)
            let reference = element.attributes["href"] ?? element.attributes["xlink:href"]
            currentID = reference?.hasPrefix("#") == true ? String(reference!.dropFirst()) : nil
        }
        guard let primary = chain.first else { return nil }

        func attribute(_ name: String) -> String? {
            for element in chain {
                if let value = element.attributes[name] { return value }
            }
            return nil
        }

        let unitsAreObjectBoundingBox = (attribute("gradientUnits") ?? "objectBoundingBox")
            != "userSpaceOnUse"
        let transform = attribute("gradientTransform").map(SVGMatrix.parse) ?? .identity
        let spread = attribute("spreadMethod")
            .flatMap(SVGGradientDefinition.Spread.init(rawValue:)) ?? .pad

        let stopSource = chain.first { element in
            element.children.contains { svgLocalName(of: $0.name) == "stop" }
        }
        var stops: [SVGGradientDefinition.Stop] = []
        var lastOffset = 0.0
        for child in stopSource?.children ?? [] where svgLocalName(of: child.name) == "stop" {
            let styles = styleProperties(of: child)
            var offset = 0.0
            if let text = styles["offset"] ?? child.attributes["offset"] {
                var scanner = SVGNumberScanner(text)
                if let value = scanner.scanNumber() {
                    offset = scanner.peek() == "%" ? value / 100 : value
                }
            }
            offset = min(1, max(0, max(offset, lastOffset)))  // clamp, keep monotonic
            lastOffset = offset

            var color = styles["stop-color"].flatMap(SVGColorParser.parseColor) ?? .black
            if let opacityText = styles["stop-opacity"], let opacity = Self.parseOpacity(opacityText) {
                color.alpha = UInt8(min(255, max(0, (Double(color.alpha) * opacity).rounded())))
            }
            stops.append(SVGGradientDefinition.Stop(offset: offset, color: color))
        }

        let kind: SVGGradientDefinition.Kind
        if svgLocalName(of: primary.name) == "linearGradient" {
            kind = .linear(
                x1: SVGLength.parse(attribute("x1")) ?? SVGLength(value: 0, isPercent: true),
                y1: SVGLength.parse(attribute("y1")) ?? SVGLength(value: 0, isPercent: true),
                x2: SVGLength.parse(attribute("x2")) ?? SVGLength(value: 100, isPercent: true),
                y2: SVGLength.parse(attribute("y2")) ?? SVGLength(value: 0, isPercent: true)
            )
        } else {
            kind = .radial(
                cx: SVGLength.parse(attribute("cx")) ?? SVGLength(value: 50, isPercent: true),
                cy: SVGLength.parse(attribute("cy")) ?? SVGLength(value: 50, isPercent: true),
                r: SVGLength.parse(attribute("r")) ?? SVGLength(value: 50, isPercent: true),
                fx: SVGLength.parse(attribute("fx")),
                fy: SVGLength.parse(attribute("fy"))
            )
        }
        return SVGGradientDefinition(
            kind: kind,
            stops: stops,
            unitsAreObjectBoundingBox: unitsAreObjectBoundingBox,
            transform: transform,
            spread: spread
        )
    }
}

/// Strips a namespace prefix (`svg:rect` → `rect`).
func svgLocalName(of qualifiedName: String) -> String {
    if let colonIndex = qualifiedName.lastIndex(of: ":") {
        return String(qualifiedName[qualifiedName.index(after: colonIndex)...])
    }
    return qualifiedName
}
