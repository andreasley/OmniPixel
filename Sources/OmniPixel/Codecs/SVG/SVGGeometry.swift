import Foundation

/// A point in SVG user space.
struct SVGPoint: Equatable {
    var x: Double
    var y: Double

    static let zero = SVGPoint(x: 0, y: 0)

    static func + (a: SVGPoint, b: SVGPoint) -> SVGPoint { SVGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: SVGPoint, b: SVGPoint) -> SVGPoint { SVGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: SVGPoint, s: Double) -> SVGPoint { SVGPoint(x: a.x * s, y: a.y * s) }

    var length: Double { (x * x + y * y).squareRoot() }

    func normalized() -> SVGPoint {
        let magnitude = length
        guard magnitude > 0 else { return .zero }
        return SVGPoint(x: x / magnitude, y: y / magnitude)
    }

    /// The perpendicular (rotated 90° counterclockwise in SVG's y-down space).
    var perpendicular: SVGPoint { SVGPoint(x: -y, y: x) }
}

/// A 2D affine transform, matching SVG's `matrix(a b c d e f)`:
///
///     x' = a·x + c·y + e
///     y' = b·x + d·y + f
struct SVGMatrix: Equatable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

    static let identity = SVGMatrix()

    func apply(to point: SVGPoint) -> SVGPoint {
        SVGPoint(x: a * point.x + c * point.y + e,
                 y: b * point.x + d * point.y + f)
    }

    /// Returns `self` followed by `other` (i.e. `other × self` in matrix terms).
    func then(_ other: SVGMatrix) -> SVGMatrix {
        SVGMatrix(
            a: other.a * a + other.c * b,
            b: other.b * a + other.d * b,
            c: other.a * c + other.c * d,
            d: other.b * c + other.d * d,
            e: other.a * e + other.c * f + other.e,
            f: other.b * e + other.d * f + other.f
        )
    }

    /// Applies `other` in the local coordinate system (SVG child transforms).
    func concatenating(_ other: SVGMatrix) -> SVGMatrix {
        other.then(self)
    }

    func inverted() -> SVGMatrix? {
        let determinant = a * d - b * c
        guard abs(determinant) > 1e-12 else { return nil }
        let inverseDeterminant = 1 / determinant
        return SVGMatrix(
            a: d * inverseDeterminant,
            b: -b * inverseDeterminant,
            c: -c * inverseDeterminant,
            d: a * inverseDeterminant,
            e: (c * f - d * e) * inverseDeterminant,
            f: (b * e - a * f) * inverseDeterminant
        )
    }

    /// An estimate of how much the transform scales distances,
    /// used to pick curve-flattening tolerances.
    var approximateScale: Double {
        // Geometric mean of the two basis vector lengths.
        let scaleX = (a * a + b * b).squareRoot()
        let scaleY = (c * c + d * d).squareRoot()
        return max(1e-6, (scaleX * scaleY).squareRoot())
    }

    static func translation(x: Double, y: Double) -> SVGMatrix {
        SVGMatrix(e: x, f: y)
    }

    static func scaling(x: Double, y: Double) -> SVGMatrix {
        SVGMatrix(a: x, d: y)
    }

    static func rotation(degrees: Double) -> SVGMatrix {
        let radians = degrees * .pi / 180
        let cosine = cos(radians), sine = sin(radians)
        return SVGMatrix(a: cosine, b: sine, c: -sine, d: cosine)
    }
}

/// Scans numbers and separators from SVG attribute microsyntaxes
/// (path data, transform lists, point lists, dash arrays).
struct SVGNumberScanner {
    let scalars: [UnicodeScalar]
    var position = 0

    init(_ text: String) {
        self.scalars = Array(text.unicodeScalars)
    }

    var isAtEnd: Bool { position >= scalars.count }

    func peek() -> UnicodeScalar? {
        position < scalars.count ? scalars[position] : nil
    }

    mutating func skipWhitespaceAndCommas() {
        while let scalar = peek(),
              scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "," {
            position += 1
        }
    }

    /// Scans one floating-point number (sign, decimals, exponent).
    /// Returns nil if the input at the current position isn't a number.
    mutating func scanNumber() -> Double? {
        skipWhitespaceAndCommas()
        let start = position
        var text = ""

        if let scalar = peek(), scalar == "+" || scalar == "-" {
            text.unicodeScalars.append(scalar)
            position += 1
        }
        var hasDigits = false
        while let scalar = peek(), ("0"..."9").contains(scalar) {
            text.unicodeScalars.append(scalar)
            position += 1
            hasDigits = true
        }
        if peek() == "." {
            text.unicodeScalars.append(".")
            position += 1
            while let scalar = peek(), ("0"..."9").contains(scalar) {
                text.unicodeScalars.append(scalar)
                position += 1
                hasDigits = true
            }
        }
        guard hasDigits else {
            position = start
            return nil
        }
        if let scalar = peek(), scalar == "e" || scalar == "E" {
            let beforeExponent = position
            var exponent = String(scalar)
            position += 1
            if let sign = peek(), sign == "+" || sign == "-" {
                exponent.unicodeScalars.append(sign)
                position += 1
            }
            var hasExponentDigits = false
            while let digit = peek(), ("0"..."9").contains(digit) {
                exponent.unicodeScalars.append(digit)
                position += 1
                hasExponentDigits = true
            }
            if hasExponentDigits {
                text += exponent
            } else {
                position = beforeExponent
            }
        }
        return Double(text)
    }

    /// Scans a run of letters (a transform function name).
    mutating func scanIdentifier() -> String? {
        skipWhitespaceAndCommas()
        var name = ""
        while let scalar = peek(), ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) {
            name.unicodeScalars.append(scalar)
            position += 1
        }
        return name.isEmpty ? nil : name
    }

    mutating func scanCharacter(_ character: UnicodeScalar) -> Bool {
        skipWhitespaceAndCommas()
        guard peek() == character else { return false }
        position += 1
        return true
    }
}

extension SVGMatrix {
    /// Parses an SVG transform list like
    /// `translate(10 20) rotate(45 5 5) scale(2)`.
    static func parse(_ text: String) -> SVGMatrix {
        var scanner = SVGNumberScanner(text)
        var result = SVGMatrix.identity
        while let name = scanner.scanIdentifier() {
            guard scanner.scanCharacter("(") else { break }
            var arguments: [Double] = []
            while let number = scanner.scanNumber() {
                arguments.append(number)
            }
            guard scanner.scanCharacter(")") else { break }
            guard let transform = makeTransform(name: name, arguments: arguments) else { continue }
            result = result.concatenating(transform)
        }
        return result
    }

    private static func makeTransform(name: String, arguments: [Double]) -> SVGMatrix? {
        switch (name, arguments.count) {
        case ("matrix", 6):
            return SVGMatrix(a: arguments[0], b: arguments[1], c: arguments[2],
                             d: arguments[3], e: arguments[4], f: arguments[5])
        case ("translate", 1):
            return .translation(x: arguments[0], y: 0)
        case ("translate", 2):
            return .translation(x: arguments[0], y: arguments[1])
        case ("scale", 1):
            return .scaling(x: arguments[0], y: arguments[0])
        case ("scale", 2):
            return .scaling(x: arguments[0], y: arguments[1])
        case ("rotate", 1):
            return .rotation(degrees: arguments[0])
        case ("rotate", 3):
            // Rotation about a point: translate there, rotate, translate back.
            return SVGMatrix.translation(x: arguments[1], y: arguments[2])
                .concatenating(.rotation(degrees: arguments[0]))
                .concatenating(.translation(x: -arguments[1], y: -arguments[2]))
        case ("skewX", 1):
            return SVGMatrix(c: tan(arguments[0] * .pi / 180))
        case ("skewY", 1):
            return SVGMatrix(b: tan(arguments[0] * .pi / 180))
        default:
            return nil
        }
    }
}
