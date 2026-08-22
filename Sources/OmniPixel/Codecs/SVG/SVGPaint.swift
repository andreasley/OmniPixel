import Foundation

/// A paint as written in a `fill` or `stroke` attribute, before
/// gradient references are resolved.
enum SVGPaint {
    case none
    case color(RGBA)
    case currentColor
    /// `url(#id)` with an optional fallback color.
    case reference(id: String, fallback: RGBA?)
}

/// Parses CSS/SVG color and paint syntax.
enum SVGColorParser {
    static func parsePaint(_ text: String) -> SVGPaint? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Written explicitly: `.none` in an optional context is Optional.none.
        if trimmed == "none" { return SVGPaint.none }
        if trimmed == "currentColor" { return .currentColor }
        if trimmed.hasPrefix("url(") {
            guard let closeIndex = trimmed.firstIndex(of: ")") else { return nil }
            var reference = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<closeIndex]
                .trimmingCharacters(in: .whitespaces)
            reference = reference.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            guard reference.hasPrefix("#") else { return nil }
            let remainder = trimmed[trimmed.index(after: closeIndex)...]
                .trimmingCharacters(in: .whitespaces)
            let fallback = remainder.isEmpty || remainder == "none" ? nil : parseColor(remainder)
            return .reference(id: String(reference.dropFirst()), fallback: fallback)
        }
        guard let color = parseColor(trimmed) else { return nil }
        return .color(color)
    }

    static func parseColor(_ text: String) -> RGBA? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("#") {
            return parseHex(trimmed.dropFirst())
        }
        if trimmed.hasPrefix("rgb(") || trimmed.hasPrefix("rgba(") {
            return parseRGBFunction(trimmed)
        }
        if trimmed.hasPrefix("hsl(") || trimmed.hasPrefix("hsla(") {
            return parseHSLFunction(trimmed)
        }
        if trimmed == "transparent" { return .transparent }
        return namedColors[trimmed].map { value in
            RGBA(red: UInt8((value >> 16) & 0xFF),
                 green: UInt8((value >> 8) & 0xFF),
                 blue: UInt8(value & 0xFF))
        }
    }

    private static func parseHex(_ digits: Substring) -> RGBA? {
        let expand: (UInt32) -> UInt8 = { UInt8($0 | ($0 << 4)) }
        switch digits.count {
        case 3, 4:
            guard let value = UInt32(digits, radix: 16) else { return nil }
            let shift = digits.count == 4 ? 4 : 0
            let alpha = digits.count == 4 ? expand(value & 0xF) : 255
            return RGBA(red: expand((value >> (8 + shift)) & 0xF),
                        green: expand((value >> (4 + shift)) & 0xF),
                        blue: expand((value >> shift) & 0xF),
                        alpha: alpha)
        case 6, 8:
            guard let value = UInt32(digits, radix: 16) else { return nil }
            let shift = digits.count == 8 ? 8 : 0
            let alpha = digits.count == 8 ? UInt8(value & 0xFF) : 255
            return RGBA(red: UInt8((value >> (16 + shift)) & 0xFF),
                        green: UInt8((value >> (8 + shift)) & 0xFF),
                        blue: UInt8((value >> shift) & 0xFF),
                        alpha: alpha)
        default:
            return nil
        }
    }

    /// Extracts the numeric arguments of a functional notation like
    /// `rgb(1, 2, 3)`, noting which had a `%` suffix.
    private static func functionArguments(_ text: String) -> [(value: Double, isPercent: Bool)] {
        guard let openIndex = text.firstIndex(of: "("),
              let closeIndex = text.lastIndex(of: ")"), openIndex < closeIndex else { return [] }
        var scanner = SVGNumberScanner(String(text[text.index(after: openIndex)..<closeIndex]))
        var arguments: [(Double, Bool)] = []
        while let value = scanner.scanNumber() {
            var isPercent = false
            if scanner.peek() == "%" {
                isPercent = true
                scanner.position += 1
            }
            // Skip slash separators used by modern CSS syntax.
            if scanner.peek() == "/" { scanner.position += 1 }
            arguments.append((value, isPercent))
        }
        return arguments
    }

    private static func parseRGBFunction(_ text: String) -> RGBA? {
        let arguments = functionArguments(text)
        guard arguments.count >= 3 else { return nil }
        func channel(_ argument: (value: Double, isPercent: Bool)) -> UInt8 {
            let value = argument.isPercent ? argument.value * 255 / 100 : argument.value
            return UInt8(min(255, max(0, value.rounded())))
        }
        var alpha: UInt8 = 255
        if arguments.count >= 4 {
            let raw = arguments[3].isPercent ? arguments[3].value / 100 : arguments[3].value
            alpha = UInt8(min(255, max(0, (raw * 255).rounded())))
        }
        return RGBA(red: channel(arguments[0]), green: channel(arguments[1]),
                    blue: channel(arguments[2]), alpha: alpha)
    }

    private static func parseHSLFunction(_ text: String) -> RGBA? {
        let arguments = functionArguments(text)
        guard arguments.count >= 3 else { return nil }
        let hue = (arguments[0].value.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 360
        let saturation = min(1, max(0, arguments[1].value / 100))
        let lightness = min(1, max(0, arguments[2].value / 100))
        var alpha = 1.0
        if arguments.count >= 4 {
            alpha = min(1, max(0, arguments[3].isPercent ? arguments[3].value / 100 : arguments[3].value))
        }

        func hueToChannel(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let q = lightness < 0.5
            ? lightness * (1 + saturation)
            : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        return RGBA(
            red: UInt8((hueToChannel(p, q, hue + 1 / 3) * 255).rounded()),
            green: UInt8((hueToChannel(p, q, hue) * 255).rounded()),
            blue: UInt8((hueToChannel(p, q, hue - 1 / 3) * 255).rounded()),
            alpha: UInt8((alpha * 255).rounded())
        )
    }

    /// The CSS named colors (SVG 1.1 color keywords), as 0xRRGGBB.
    static let namedColors: [String: UInt32] = [
        "aliceblue": 0xF0F8FF, "antiquewhite": 0xFAEBD7, "aqua": 0x00FFFF,
        "aquamarine": 0x7FFFD4, "azure": 0xF0FFFF, "beige": 0xF5F5DC,
        "bisque": 0xFFE4C4, "black": 0x000000, "blanchedalmond": 0xFFEBCD,
        "blue": 0x0000FF, "blueviolet": 0x8A2BE2, "brown": 0xA52A2A,
        "burlywood": 0xDEB887, "cadetblue": 0x5F9EA0, "chartreuse": 0x7FFF00,
        "chocolate": 0xD2691E, "coral": 0xFF7F50, "cornflowerblue": 0x6495ED,
        "cornsilk": 0xFFF8DC, "crimson": 0xDC143C, "cyan": 0x00FFFF,
        "darkblue": 0x00008B, "darkcyan": 0x008B8B, "darkgoldenrod": 0xB8860B,
        "darkgray": 0xA9A9A9, "darkgreen": 0x006400, "darkgrey": 0xA9A9A9,
        "darkkhaki": 0xBDB76B, "darkmagenta": 0x8B008B, "darkolivegreen": 0x556B2F,
        "darkorange": 0xFF8C00, "darkorchid": 0x9932CC, "darkred": 0x8B0000,
        "darksalmon": 0xE9967A, "darkseagreen": 0x8FBC8F, "darkslateblue": 0x483D8B,
        "darkslategray": 0x2F4F4F, "darkslategrey": 0x2F4F4F, "darkturquoise": 0x00CED1,
        "darkviolet": 0x9400D3, "deeppink": 0xFF1493, "deepskyblue": 0x00BFFF,
        "dimgray": 0x696969, "dimgrey": 0x696969, "dodgerblue": 0x1E90FF,
        "firebrick": 0xB22222, "floralwhite": 0xFFFAF0, "forestgreen": 0x228B22,
        "fuchsia": 0xFF00FF, "gainsboro": 0xDCDCDC, "ghostwhite": 0xF8F8FF,
        "gold": 0xFFD700, "goldenrod": 0xDAA520, "gray": 0x808080,
        "green": 0x008000, "greenyellow": 0xADFF2F, "grey": 0x808080,
        "honeydew": 0xF0FFF0, "hotpink": 0xFF69B4, "indianred": 0xCD5C5C,
        "indigo": 0x4B0082, "ivory": 0xFFFFF0, "khaki": 0xF0E68C,
        "lavender": 0xE6E6FA, "lavenderblush": 0xFFF0F5, "lawngreen": 0x7CFC00,
        "lemonchiffon": 0xFFFACD, "lightblue": 0xADD8E6, "lightcoral": 0xF08080,
        "lightcyan": 0xE0FFFF, "lightgoldenrodyellow": 0xFAFAD2, "lightgray": 0xD3D3D3,
        "lightgreen": 0x90EE90, "lightgrey": 0xD3D3D3, "lightpink": 0xFFB6C1,
        "lightsalmon": 0xFFA07A, "lightseagreen": 0x20B2AA, "lightskyblue": 0x87CEFA,
        "lightslategray": 0x778899, "lightslategrey": 0x778899, "lightsteelblue": 0xB0C4DE,
        "lightyellow": 0xFFFFE0, "lime": 0x00FF00, "limegreen": 0x32CD32,
        "linen": 0xFAF0E6, "magenta": 0xFF00FF, "maroon": 0x800000,
        "mediumaquamarine": 0x66CDAA, "mediumblue": 0x0000CD, "mediumorchid": 0xBA55D3,
        "mediumpurple": 0x9370DB, "mediumseagreen": 0x3CB371, "mediumslateblue": 0x7B68EE,
        "mediumspringgreen": 0x00FA9A, "mediumturquoise": 0x48D1CC, "mediumvioletred": 0xC71585,
        "midnightblue": 0x191970, "mintcream": 0xF5FFFA, "mistyrose": 0xFFE4E1,
        "moccasin": 0xFFE4B5, "navajowhite": 0xFFDEAD, "navy": 0x000080,
        "oldlace": 0xFDF5E6, "olive": 0x808000, "olivedrab": 0x6B8E23,
        "orange": 0xFFA500, "orangered": 0xFF4500, "orchid": 0xDA70D6,
        "palegoldenrod": 0xEEE8AA, "palegreen": 0x98FB98, "paleturquoise": 0xAFEEEE,
        "palevioletred": 0xDB7093, "papayawhip": 0xFFEFD5, "peachpuff": 0xFFDAB9,
        "peru": 0xCD853F, "pink": 0xFFC0CB, "plum": 0xDDA0DD,
        "powderblue": 0xB0E0E6, "purple": 0x800080, "rebeccapurple": 0x663399,
        "red": 0xFF0000, "rosybrown": 0xBC8F8F, "royalblue": 0x4169E1,
        "saddlebrown": 0x8B4513, "salmon": 0xFA8072, "sandybrown": 0xF4A460,
        "seagreen": 0x2E8B57, "seashell": 0xFFF5EE, "sienna": 0xA0522D,
        "silver": 0xC0C0C0, "skyblue": 0x87CEEB, "slateblue": 0x6A5ACD,
        "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xFFFAFA,
        "springgreen": 0x00FF7F, "steelblue": 0x4682B4, "tan": 0xD2B48C,
        "teal": 0x008080, "thistle": 0xD8BFD8, "tomato": 0xFF6347,
        "turquoise": 0x40E0D0, "violet": 0xEE82EE, "wheat": 0xF5DEB3,
        "white": 0xFFFFFF, "whitesmoke": 0xF5F5F5, "yellow": 0xFFFF00,
        "yellowgreen": 0x9ACD32,
    ]
}

// MARK: - Gradients

/// A gradient definition parsed from `<linearGradient>`/`<radialGradient>`,
/// with `href` inheritance already applied.
struct SVGGradientDefinition {
    enum Kind {
        case linear(x1: SVGLength, y1: SVGLength, x2: SVGLength, y2: SVGLength)
        case radial(cx: SVGLength, cy: SVGLength, r: SVGLength, fx: SVGLength?, fy: SVGLength?)
    }

    enum Spread: String {
        case pad, reflect, `repeat`
    }

    struct Stop {
        var offset: Double
        var color: RGBA
    }

    var kind: Kind
    var stops: [Stop]
    var unitsAreObjectBoundingBox: Bool
    var transform: SVGMatrix
    var spread: Spread
}

/// A number that may be a fraction of a reference length (`50%`).
struct SVGLength {
    var value: Double
    var isPercent: Bool

    /// Resolves against a reference length; percentages are fractions of it.
    func resolved(against reference: Double) -> Double {
        isPercent ? value / 100 * reference : value
    }

    static func parse(_ text: String?) -> SVGLength? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        var scanner = SVGNumberScanner(text)
        guard let value = scanner.scanNumber() else { return nil }
        return SVGLength(value: value, isPercent: scanner.peek() == "%")
    }
}

/// A gradient mapped into device space, ready for per-pixel evaluation.
struct SVGResolvedGradient {
    enum Geometry {
        case linear(start: SVGPoint, delta: SVGPoint, inverseLengthSquared: Double)
        case radial(center: SVGPoint, radius: Double, focal: SVGPoint)
    }

    var geometry: Geometry
    /// Maps a device-space pixel position into the gradient's coordinate space.
    var deviceToGradient: SVGMatrix
    var stops: [SVGGradientDefinition.Stop]
    var spread: SVGGradientDefinition.Spread

    /// Builds a resolved gradient for a shape.
    /// - Parameters:
    ///   - userToDevice: the shape's full user→device transform.
    ///   - boundingBox: the shape's user-space bounding box (for objectBoundingBox units).
    ///   - viewport: the viewport size, for percentages in userSpaceOnUse units.
    init?(definition: SVGGradientDefinition,
          userToDevice: SVGMatrix,
          boundingBox: (minX: Double, minY: Double, width: Double, height: Double),
          viewport: (width: Double, height: Double)) {
        guard !definition.stops.isEmpty else { return nil }
        stops = definition.stops
        spread = definition.spread

        // Gradient coordinates live in a space that objectBoundingBox units
        // map onto the shape's bounds.
        var gradientToUser = definition.transform
        if definition.unitsAreObjectBoundingBox {
            let boundsTransform = SVGMatrix.translation(x: boundingBox.minX, y: boundingBox.minY)
                .concatenating(.scaling(x: max(boundingBox.width, 1e-9),
                                        y: max(boundingBox.height, 1e-9)))
            gradientToUser = boundsTransform.concatenating(definition.transform)
        }
        guard let inverse = userToDevice.concatenating(gradientToUser).inverted() else {
            return nil
        }
        deviceToGradient = inverse

        let referenceX: Double
        let referenceY: Double
        let referenceDiagonal: Double
        if definition.unitsAreObjectBoundingBox {
            // Fractions and percentages coincide; the reference length is 1.
            referenceX = 1; referenceY = 1; referenceDiagonal = 1
        } else {
            // Percentages in userSpaceOnUse refer to the viewport.
            referenceX = max(viewport.width, 1e-9)
            referenceY = max(viewport.height, 1e-9)
            referenceDiagonal = ((referenceX * referenceX + referenceY * referenceY) / 2).squareRoot()
        }

        switch definition.kind {
        case let .linear(x1, y1, x2, y2):
            let start = SVGPoint(x: x1.resolved(against: referenceX), y: y1.resolved(against: referenceY))
            let end = SVGPoint(x: x2.resolved(against: referenceX), y: y2.resolved(against: referenceY))
            let delta = end - start
            let lengthSquared = delta.x * delta.x + delta.y * delta.y
            if lengthSquared > 1e-12 {
                geometry = .linear(start: start, delta: delta, inverseLengthSquared: 1 / lengthSquared)
            } else {
                // A degenerate axis paints the last stop everywhere.
                geometry = .linear(start: start, delta: .zero, inverseLengthSquared: 0)
            }
        case let .radial(cx, cy, r, fx, fy):
            let center = SVGPoint(x: cx.resolved(against: referenceX), y: cy.resolved(against: referenceY))
            let radius = r.resolved(against: referenceDiagonal)
            let focal = SVGPoint(
                x: fx?.resolved(against: referenceX) ?? center.x,
                y: fy?.resolved(against: referenceY) ?? center.y
            )
            guard radius > 1e-12 else { return nil }
            geometry = .radial(center: center, radius: radius, focal: focal)
        }
    }

    /// The gradient color at a device-space position.
    func color(atDeviceX x: Double, y: Double) -> RGBA {
        let point = deviceToGradient.apply(to: SVGPoint(x: x, y: y))
        let t: Double
        switch geometry {
        case let .linear(start, delta, inverseLengthSquared):
            if inverseLengthSquared == 0 {
                t = 1
            } else {
                let offset = point - start
                t = (offset.x * delta.x + offset.y * delta.y) * inverseLengthSquared
            }
        case let .radial(center, radius, focal):
            // Distance from the focal point to the circle along the ray
            // through `point` (SVG 1.1 focal gradient definition).
            let direction = point - focal
            let distance = direction.length
            if distance < 1e-12 {
                t = 0
            } else {
                let unit = direction * (1 / distance)
                // Solve |focal + s·unit - center|² = radius² for s > 0.
                let offset = focal - center
                let b = 2 * (offset.x * unit.x + offset.y * unit.y)
                let c = offset.x * offset.x + offset.y * offset.y - radius * radius
                let discriminant = max(0, b * b - 4 * c)
                let s = (-b + discriminant.squareRoot()) / 2
                t = s > 1e-12 ? distance / s : 1
            }
        }
        return sample(applySpread(t))
    }

    private func applySpread(_ t: Double) -> Double {
        switch spread {
        case .pad:
            return min(1, max(0, t))
        case .repeat:
            let fraction = t.truncatingRemainder(dividingBy: 1)
            return fraction < 0 ? fraction + 1 : fraction
        case .reflect:
            let period = abs(t.truncatingRemainder(dividingBy: 2))
            return period > 1 ? 2 - period : period
        }
    }

    private func sample(_ t: Double) -> RGBA {
        guard let first = stops.first, let last = stops.last else { return .transparent }
        if t <= first.offset { return first.color }
        if t >= last.offset { return last.color }
        for index in 1..<stops.count {
            let previous = stops[index - 1]
            let next = stops[index]
            if t <= next.offset {
                let span = next.offset - previous.offset
                let fraction = span > 1e-12 ? (t - previous.offset) / span : 1
                return interpolate(previous.color, next.color, fraction)
            }
        }
        return last.color
    }

    private func interpolate(_ from: RGBA, _ to: RGBA, _ fraction: Double) -> RGBA {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(min(255, max(0, (Double(a) + (Double(b) - Double(a)) * fraction).rounded())))
        }
        return RGBA(red: mix(from.red, to.red), green: mix(from.green, to.green),
                    blue: mix(from.blue, to.blue), alpha: mix(from.alpha, to.alpha))
    }
}

/// A shape's paint after gradient resolution, as consumed by the rasterizer.
enum SVGResolvedPaint {
    case solid(RGBA)
    case gradient(SVGResolvedGradient)

    func color(atDeviceX x: Double, y: Double) -> RGBA {
        switch self {
        case .solid(let color): return color
        case .gradient(let gradient): return gradient.color(atDeviceX: x, y: y)
        }
    }

    var isFullyTransparent: Bool {
        if case .solid(let color) = self { return color.alpha == 0 }
        return false
    }
}
