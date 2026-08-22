import Foundation

/// A path flattened to polylines: curves have been subdivided into
/// line segments within a flatness tolerance.
struct SVGFlattenedPath {
    struct Subpath {
        var points: [SVGPoint] = []
        var isClosed = false
    }

    var subpaths: [Subpath] = []

    var isEmpty: Bool {
        subpaths.allSatisfy { $0.points.count < 2 }
    }

    func transformed(by matrix: SVGMatrix) -> SVGFlattenedPath {
        var result = self
        for index in result.subpaths.indices {
            result.subpaths[index].points = result.subpaths[index].points.map(matrix.apply(to:))
        }
        return result
    }
}

/// Builds flattened paths from move/line/curve commands.
///
/// `tolerance` is the maximum distance a line approximation may deviate
/// from the true curve, in the same units as the input coordinates.
struct SVGPathBuilder {
    private(set) var path = SVGFlattenedPath()
    private var current = SVGPoint.zero
    private var subpathStart = SVGPoint.zero
    let tolerance: Double

    init(tolerance: Double = 0.25) {
        self.tolerance = max(1e-4, tolerance)
    }

    var currentPoint: SVGPoint { current }

    mutating func move(to point: SVGPoint) {
        path.subpaths.append(SVGFlattenedPath.Subpath(points: [point]))
        current = point
        subpathStart = point
    }

    mutating func line(to point: SVGPoint) {
        appendPoint(point)
    }

    mutating func curve(to end: SVGPoint, control1: SVGPoint, control2: SVGPoint) {
        flattenCubic(current, control1, control2, end, depth: 0)
        appendPoint(end)
    }

    mutating func quadCurve(to end: SVGPoint, control: SVGPoint) {
        // Elevate the quadratic to a cubic.
        let control1 = current + (control - current) * (2.0 / 3.0)
        let control2 = end + (control - end) * (2.0 / 3.0)
        curve(to: end, control1: control1, control2: control2)
    }

    mutating func close() {
        guard var last = path.subpaths.popLast() else { return }
        last.isClosed = true
        path.subpaths.append(last)
        current = subpathStart
    }

    private mutating func appendPoint(_ point: SVGPoint) {
        if path.subpaths.isEmpty {
            path.subpaths.append(SVGFlattenedPath.Subpath(points: [current]))
        }
        path.subpaths[path.subpaths.count - 1].points.append(point)
        current = point
    }

    // MARK: Curve flattening

    /// Recursively subdivides a cubic Bézier until it is flat enough,
    /// emitting the interior points (not the endpoints).
    private mutating func flattenCubic(
        _ p0: SVGPoint, _ p1: SVGPoint, _ p2: SVGPoint, _ p3: SVGPoint, depth: Int
    ) {
        // Flatness: max distance of the control points from the chord.
        let chord = p3 - p0
        let chordLength = max(chord.length, 1e-9)
        let deviation1 = abs(chord.x * (p0.y - p1.y) - chord.y * (p0.x - p1.x)) / chordLength
        let deviation2 = abs(chord.x * (p0.y - p2.y) - chord.y * (p0.x - p2.x)) / chordLength
        if max(deviation1, deviation2) <= tolerance || depth >= 24 {
            return
        }
        // de Casteljau split at t = 0.5.
        let p01 = (p0 + p1) * 0.5
        let p12 = (p1 + p2) * 0.5
        let p23 = (p2 + p3) * 0.5
        let p012 = (p01 + p12) * 0.5
        let p123 = (p12 + p23) * 0.5
        let midpoint = (p012 + p123) * 0.5
        flattenCubic(p0, p01, p012, midpoint, depth: depth + 1)
        appendPoint(midpoint)
        flattenCubic(midpoint, p123, p23, p3, depth: depth + 1)
    }

    /// Appends an elliptical arc per the SVG endpoint parameterization
    /// (spec section F.6.5).
    mutating func arc(
        to end: SVGPoint,
        radiusX: Double, radiusY: Double,
        rotationDegrees: Double,
        largeArc: Bool, sweep: Bool
    ) {
        let start = current
        var rx = abs(radiusX), ry = abs(radiusY)
        if rx < 1e-9 || ry < 1e-9 || (start - end).length < 1e-12 {
            line(to: end)
            return
        }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        // Transform to the ellipse-aligned frame.
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        // Scale radii up if they can't span the endpoints.
        let radiiCheck = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if radiiCheck > 1 {
            let scale = radiiCheck.squareRoot()
            rx *= scale
            ry *= scale
        }

        // Center in the aligned frame.
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = (max(0, numerator) / denominator).squareRoot()
        if largeArc == sweep { coefficient = -coefficient }
        let cxAligned = coefficient * rx * y1 / ry
        let cyAligned = -coefficient * ry * x1 / rx

        let centerX = cosPhi * cxAligned - sinPhi * cyAligned + (start.x + end.x) / 2
        let centerY = sinPhi * cxAligned + cosPhi * cyAligned + (start.y + end.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let lengths = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var value = acos(min(1, max(-1, dot / lengths)))
            if ux * vy - uy * vx < 0 { value = -value }
            return value
        }

        let startAngle = angle(1, 0, (x1 - cxAligned) / rx, (y1 - cyAligned) / ry)
        var sweepAngle = angle(
            (x1 - cxAligned) / rx, (y1 - cyAligned) / ry,
            (-x1 - cxAligned) / rx, (-y1 - cyAligned) / ry
        )
        if !sweep && sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep && sweepAngle < 0 { sweepAngle += 2 * .pi }

        // Sample the arc finely enough for the flattening tolerance.
        let maxRadius = max(rx, ry)
        let stepLimit = 2 * acos(min(1, max(-1, 1 - tolerance / maxRadius)))
        let segmentCount = max(2, Int(ceil(abs(sweepAngle) / max(stepLimit, 1e-3))))
        for step in 1...segmentCount {
            let theta = startAngle + sweepAngle * Double(step) / Double(segmentCount)
            let px = centerX + rx * cos(theta) * cosPhi - ry * sin(theta) * sinPhi
            let py = centerY + rx * cos(theta) * sinPhi + ry * sin(theta) * cosPhi
            appendPoint(SVGPoint(x: px, y: py))
        }
        current = end
    }
}

// MARK: - Path data parsing

extension SVGPathBuilder {
    /// Parses SVG path data (`d` attribute) into the builder.
    ///
    /// Follows the spec's error handling: on malformed input, everything
    /// up to the error still renders and the rest is dropped.
    mutating func addPathData(_ data: String) {
        var scanner = SVGNumberScanner(data)
        var command: UnicodeScalar? = nil
        var lastControl: SVGPoint? = nil
        var lastCommand: UnicodeScalar = " "

        func number() -> Double? { scanner.scanNumber() }

        while true {
            scanner.skipWhitespaceAndCommas()
            guard let scalar = scanner.peek() else { return }
            let isLetter = ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
            if isLetter {
                command = scalar
                scanner.position += 1
            }
            guard var effective = command else { return }  // junk before any command
            // Implicit repetition: after M/m, subsequent pairs are L/l.
            if !isLetter {
                if effective == "M" { effective = "L" }
                if effective == "m" { effective = "l" }
                command = effective
            }

            let isRelative = ("a"..."z").contains(effective)
            let origin = isRelative ? current : .zero
            let uppercased = UnicodeScalar(effective.value < 97 ? effective.value : effective.value - 32)!

            switch uppercased {
            case "M":
                guard let x = number(), let y = number() else { return }
                move(to: SVGPoint(x: origin.x + x, y: origin.y + y))
                lastControl = nil
            case "L":
                guard let x = number(), let y = number() else { return }
                line(to: SVGPoint(x: origin.x + x, y: origin.y + y))
                lastControl = nil
            case "H":
                guard let x = number() else { return }
                line(to: SVGPoint(x: origin.x + x, y: current.y))
                lastControl = nil
            case "V":
                guard let y = number() else { return }
                line(to: SVGPoint(x: current.x, y: origin.y + y))
                lastControl = nil
            case "C":
                guard let x1 = number(), let y1 = number(),
                      let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return }
                let control2 = SVGPoint(x: origin.x + x2, y: origin.y + y2)
                curve(to: SVGPoint(x: origin.x + x, y: origin.y + y),
                      control1: SVGPoint(x: origin.x + x1, y: origin.y + y1),
                      control2: control2)
                lastControl = control2
            case "S":
                guard let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return }
                let reflectable = lastCommand == "C" || lastCommand == "c"
                    || lastCommand == "S" || lastCommand == "s"
                let control1 = reflectable && lastControl != nil
                    ? current + (current - lastControl!)
                    : current
                let control2 = SVGPoint(x: origin.x + x2, y: origin.y + y2)
                curve(to: SVGPoint(x: origin.x + x, y: origin.y + y),
                      control1: control1, control2: control2)
                lastControl = control2
            case "Q":
                guard let x1 = number(), let y1 = number(),
                      let x = number(), let y = number() else { return }
                let control = SVGPoint(x: origin.x + x1, y: origin.y + y1)
                quadCurve(to: SVGPoint(x: origin.x + x, y: origin.y + y), control: control)
                lastControl = control
            case "T":
                guard let x = number(), let y = number() else { return }
                let reflectable = lastCommand == "Q" || lastCommand == "q"
                    || lastCommand == "T" || lastCommand == "t"
                let control = reflectable && lastControl != nil
                    ? current + (current - lastControl!)
                    : current
                quadCurve(to: SVGPoint(x: origin.x + x, y: origin.y + y), control: control)
                lastControl = control
            case "A":
                guard let rx = number(), let ry = number(), let rotation = number(),
                      let largeArc = scanFlag(&scanner), let sweep = scanFlag(&scanner),
                      let x = number(), let y = number() else { return }
                arc(to: SVGPoint(x: origin.x + x, y: origin.y + y),
                    radiusX: rx, radiusY: ry, rotationDegrees: rotation,
                    largeArc: largeArc, sweep: sweep)
                lastControl = nil
            case "Z":
                close()
                lastControl = nil
            default:
                return  // unknown command: stop parsing
            }
            lastCommand = effective
        }
    }

    /// Arc flags are single digits and may be packed without separators.
    private func scanFlag(_ scanner: inout SVGNumberScanner) -> Bool? {
        scanner.skipWhitespaceAndCommas()
        switch scanner.peek() {
        case "0": scanner.position += 1; return false
        case "1": scanner.position += 1; return true
        default: return nil
        }
    }
}

// MARK: - Basic shapes

extension SVGPathBuilder {
    mutating func addRect(x: Double, y: Double, width: Double, height: Double,
                          radiusX: Double, radiusY: Double) {
        guard width > 0, height > 0 else { return }
        var rx = min(max(0, radiusX), width / 2)
        var ry = min(max(0, radiusY), height / 2)
        if rx == 0 || ry == 0 { rx = 0; ry = 0 }

        if rx == 0 {
            move(to: SVGPoint(x: x, y: y))
            line(to: SVGPoint(x: x + width, y: y))
            line(to: SVGPoint(x: x + width, y: y + height))
            line(to: SVGPoint(x: x, y: y + height))
            close()
            return
        }
        move(to: SVGPoint(x: x + rx, y: y))
        line(to: SVGPoint(x: x + width - rx, y: y))
        arc(to: SVGPoint(x: x + width, y: y + ry),
            radiusX: rx, radiusY: ry, rotationDegrees: 0, largeArc: false, sweep: true)
        line(to: SVGPoint(x: x + width, y: y + height - ry))
        arc(to: SVGPoint(x: x + width - rx, y: y + height),
            radiusX: rx, radiusY: ry, rotationDegrees: 0, largeArc: false, sweep: true)
        line(to: SVGPoint(x: x + rx, y: y + height))
        arc(to: SVGPoint(x: x, y: y + height - ry),
            radiusX: rx, radiusY: ry, rotationDegrees: 0, largeArc: false, sweep: true)
        line(to: SVGPoint(x: x, y: y + ry))
        arc(to: SVGPoint(x: x + rx, y: y),
            radiusX: rx, radiusY: ry, rotationDegrees: 0, largeArc: false, sweep: true)
        close()
    }

    mutating func addEllipse(centerX: Double, centerY: Double, radiusX: Double, radiusY: Double) {
        guard radiusX > 0, radiusY > 0 else { return }
        move(to: SVGPoint(x: centerX + radiusX, y: centerY))
        arc(to: SVGPoint(x: centerX - radiusX, y: centerY),
            radiusX: radiusX, radiusY: radiusY, rotationDegrees: 0, largeArc: false, sweep: true)
        arc(to: SVGPoint(x: centerX + radiusX, y: centerY),
            radiusX: radiusX, radiusY: radiusY, rotationDegrees: 0, largeArc: false, sweep: true)
        close()
    }

    /// Adds a polyline/polygon from a `points` attribute.
    mutating func addPointList(_ text: String, closing: Bool) {
        var scanner = SVGNumberScanner(text)
        var isFirst = true
        while let x = scanner.scanNumber(), let y = scanner.scanNumber() {
            let point = SVGPoint(x: x, y: y)
            if isFirst {
                move(to: point)
                isFirst = false
            } else {
                line(to: point)
            }
        }
        if closing && !isFirst { close() }
    }
}

// MARK: - Stroking

enum SVGLineCap: String {
    case butt, round, square
}

enum SVGLineJoin: String {
    case miter, round, bevel
}

/// Converts a flattened path into closed outline polygons that, filled
/// with the nonzero rule, produce the stroked shape.
///
/// The approach is a union of pieces: one quad per segment, plus join
/// geometry at vertices and caps at open ends. Every emitted subpath is
/// wound positively so the nonzero fill unions them correctly.
struct SVGStroker {
    let width: Double
    let cap: SVGLineCap
    let join: SVGLineJoin
    let miterLimit: Double
    let tolerance: Double

    func stroke(_ path: SVGFlattenedPath) -> SVGFlattenedPath {
        var outline = SVGFlattenedPath()
        let halfWidth = max(width, 1e-6) / 2
        for subpath in path.subpaths {
            strokeSubpath(subpath, halfWidth: halfWidth, into: &outline)
        }
        return outline
    }

    private func strokeSubpath(
        _ subpath: SVGFlattenedPath.Subpath, halfWidth: Double,
        into outline: inout SVGFlattenedPath
    ) {
        // Drop consecutive duplicate points; they produce degenerate normals.
        var points: [SVGPoint] = []
        for point in subpath.points where points.last.map({ ($0 - point).length > 1e-9 }) ?? true {
            points.append(point)
        }
        if subpath.isClosed, let first = points.first, let last = points.last,
           points.count > 1, (first - last).length <= 1e-9 {
            points.removeLast()
        }

        // A zero-length subpath still draws round/square caps as a dot.
        if points.count == 1 {
            if cap == .round {
                appendCircle(center: points[0], radius: halfWidth, into: &outline)
            } else if cap == .square {
                appendPolygon([
                    SVGPoint(x: points[0].x - halfWidth, y: points[0].y - halfWidth),
                    SVGPoint(x: points[0].x + halfWidth, y: points[0].y - halfWidth),
                    SVGPoint(x: points[0].x + halfWidth, y: points[0].y + halfWidth),
                    SVGPoint(x: points[0].x - halfWidth, y: points[0].y + halfWidth),
                ], into: &outline)
            }
            return
        }
        guard points.count >= 2 else { return }

        let isClosed = subpath.isClosed

        // Segment quads.
        let segmentEnd = isClosed ? points.count : points.count - 1
        for index in 0..<segmentEnd {
            let start = points[index]
            let end = points[(index + 1) % points.count]
            let normal = (end - start).normalized().perpendicular * halfWidth
            appendPolygon([start + normal, end + normal, end - normal, start - normal],
                          into: &outline)
        }

        // Joins at interior vertices (all vertices when closed).
        let joinRange = isClosed ? 0..<points.count : 1..<(points.count - 1)
        for index in joinRange {
            let previous = points[(index + points.count - 1) % points.count]
            let vertex = points[index]
            let next = points[(index + 1) % points.count]
            appendJoin(previous: previous, vertex: vertex, next: next,
                       halfWidth: halfWidth, into: &outline)
        }

        // Caps at open ends.
        if !isClosed {
            let startDirection = (points[0] - points[1]).normalized()
            let endDirection = (points[points.count - 1] - points[points.count - 2]).normalized()
            appendCap(at: points[0], direction: startDirection, halfWidth: halfWidth, into: &outline)
            appendCap(at: points[points.count - 1], direction: endDirection,
                      halfWidth: halfWidth, into: &outline)
        }
    }

    private func appendJoin(
        previous: SVGPoint, vertex: SVGPoint, next: SVGPoint,
        halfWidth: Double, into outline: inout SVGFlattenedPath
    ) {
        if join == .round {
            appendCircle(center: vertex, radius: halfWidth, into: &outline)
            return
        }
        let inDirection = (vertex - previous).normalized()
        let outDirection = (next - vertex).normalized()
        let turn = inDirection.x * outDirection.y - inDirection.y * outDirection.x
        if abs(turn) < 1e-12 { return }  // collinear: nothing to fill

        // Outer offsets: the join fills the wedge on the outside of the turn.
        let side: Double = turn > 0 ? 1 : -1
        let offsetIn = inDirection.perpendicular * (halfWidth * side)
        let offsetOut = outDirection.perpendicular * (halfWidth * side)
        let outerIn = vertex + offsetIn
        let outerOut = vertex + offsetOut

        if join == .miter {
            let bisector = (offsetIn + offsetOut).normalized()
            let cosineHalfAngle = (bisector.x * offsetIn.x + bisector.y * offsetIn.y) / halfWidth
            if cosineHalfAngle > 1e-6, 1 / cosineHalfAngle <= miterLimit {
                let miterPoint = vertex + bisector * (halfWidth / cosineHalfAngle)
                appendPolygon([vertex, outerIn, miterPoint, outerOut], into: &outline)
                return
            }
        }
        appendPolygon([vertex, outerIn, outerOut], into: &outline)  // bevel
    }

    private func appendCap(
        at point: SVGPoint, direction: SVGPoint, halfWidth: Double,
        into outline: inout SVGFlattenedPath
    ) {
        switch cap {
        case .butt:
            return
        case .round:
            appendCircle(center: point, radius: halfWidth, into: &outline)
        case .square:
            let normal = direction.perpendicular * halfWidth
            let extended = point + direction * halfWidth
            appendPolygon([point + normal, extended + normal, extended - normal, point - normal],
                          into: &outline)
        }
    }

    private func appendCircle(center: SVGPoint, radius: Double, into outline: inout SVGFlattenedPath) {
        let step = 2 * acos(min(1, max(0, 1 - tolerance / radius)))
        let segmentCount = max(8, Int(ceil(2 * .pi / max(step, 1e-3))))
        var points: [SVGPoint] = []
        points.reserveCapacity(segmentCount)
        for index in 0..<segmentCount {
            let theta = 2 * .pi * Double(index) / Double(segmentCount)
            points.append(SVGPoint(x: center.x + radius * cos(theta),
                                   y: center.y + radius * sin(theta)))
        }
        appendPolygon(points, into: &outline)
    }

    /// Appends a closed polygon, flipped if needed so it always winds
    /// positively — the union then works under the nonzero fill rule.
    private func appendPolygon(_ points: [SVGPoint], into outline: inout SVGFlattenedPath) {
        guard points.count >= 3 else { return }
        var signedArea = 0.0
        for index in 0..<points.count {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            signedArea += current.x * next.y - next.x * current.y
        }
        var polygon = points
        if signedArea < 0 { polygon.reverse() }
        outline.subpaths.append(SVGFlattenedPath.Subpath(points: polygon, isClosed: true))
    }
}
