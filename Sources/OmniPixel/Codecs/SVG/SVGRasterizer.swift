import Foundation

/// The SVG fill rules.
enum SVGFillRule: String {
    case nonzero
    case evenodd
}

/// One filled shape in device space, ready to rasterize.
struct SVGDrawCommand {
    var path: SVGFlattenedPath
    var fillRule: SVGFillRule
    var paint: SVGResolvedPaint
    /// Extra alpha from `opacity`/`fill-opacity`/`stroke-opacity`, 0...1.
    var alpha: Double
}

/// Scanline polygon rasterizer with anti-aliasing.
///
/// Vertical resolution comes from sampling several sub-scanlines per pixel
/// row; horizontal coverage is exact (fractional span ends). This keeps the
/// implementation simple while producing smooth edges in both directions.
struct SVGRasterizer {
    /// Sub-scanlines sampled per pixel row.
    private static let subsampleCount = 4

    private struct Edge {
        var topY: Double
        var bottomY: Double
        /// x at topY.
        var topX: Double
        /// Change in x per unit y.
        var slope: Double
        /// +1 if the edge points downward in the original path, else -1.
        var winding: Int
    }

    /// Renders draw commands into the image, in order.
    static func render(_ commands: [SVGDrawCommand], into image: inout Image) {
        for command in commands {
            fill(command, into: &image)
        }
    }

    private static func fill(_ command: SVGDrawCommand, into image: inout Image) {
        guard command.alpha > 0, !command.paint.isFullyTransparent else { return }

        // Build the edge list. Filling implicitly closes open subpaths.
        var edges: [Edge] = []
        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude

        for subpath in command.path.subpaths {
            let points = subpath.points
            guard points.count >= 2 else { continue }
            for index in 0..<points.count {
                let start = points[index]
                let end = index + 1 < points.count ? points[index + 1] : points[0]
                if index + 1 == points.count && (start - end).length < 1e-12 { continue }
                guard abs(start.y - end.y) > 1e-12 else { continue }  // horizontal: no crossings
                let pointsDown = end.y > start.y
                let top = pointsDown ? start : end
                let bottom = pointsDown ? end : start
                let slope = (bottom.x - top.x) / (bottom.y - top.y)
                edges.append(Edge(topY: top.y, bottomY: bottom.y, topX: top.x,
                                  slope: slope, winding: pointsDown ? 1 : -1))
                minY = min(minY, top.y)
                maxY = max(maxY, bottom.y)
                minX = min(minX, min(start.x, end.x))
                maxX = max(maxX, max(start.x, end.x))
            }
        }
        guard !edges.isEmpty else { return }

        // Reject shapes that miss the canvas entirely. Written as positive
        // comparisons so a non-finite bound — or the untouched sentinels,
        // which survive when every edge had a NaN coordinate — fails the
        // guard rather than reaching the conversions below.
        guard maxY >= 0, minY <= Double(image.height),
              maxX >= 0, minX <= Double(image.width) else { return }

        let firstRow = pixelIndex(minY.rounded(.down), limit: image.height - 1)
        let lastRow = pixelIndex(maxY.rounded(.up), limit: image.height - 1)
        let firstColumn = pixelIndex(minX.rounded(.down), limit: image.width - 1)
        let lastColumn = pixelIndex(maxX.rounded(.up), limit: image.width - 1)
        guard firstRow <= lastRow, firstColumn <= lastColumn else { return }

        // Sort by top edge so the active set can be maintained with a cursor.
        edges.sort { $0.topY < $1.topY }

        let rowWidth = lastColumn - firstColumn + 1
        var coverage = [Double](repeating: 0, count: rowWidth)
        var crossings: [(x: Double, winding: Int)] = []
        crossings.reserveCapacity(edges.count)
        var nextEdgeIndex = 0
        var active: [Edge] = []

        let subsampleStep = 1.0 / Double(Self.subsampleCount)
        let coverageScale = command.alpha / Double(Self.subsampleCount)

        for row in firstRow...lastRow {
            for slot in coverage.indices { coverage[slot] = 0 }
            var rowHasCoverage = false

            for subsample in 0..<Self.subsampleCount {
                let sampleY = Double(row) + (Double(subsample) + 0.5) * subsampleStep

                // Admit edges that start above this sample; retire finished ones.
                while nextEdgeIndex < edges.count && edges[nextEdgeIndex].topY <= sampleY {
                    active.append(edges[nextEdgeIndex])
                    nextEdgeIndex += 1
                }
                active.removeAll { $0.bottomY <= sampleY }

                crossings.removeAll(keepingCapacity: true)
                for edge in active {
                    let x = edge.topX + (sampleY - edge.topY) * edge.slope
                    crossings.append((x, edge.winding))
                }
                guard crossings.count >= 2 else { continue }
                crossings.sort { $0.x < $1.x }

                // Walk crossings, accumulating covered spans per the fill rule.
                var winding = 0
                var spanStart = 0.0
                for crossing in crossings {
                    let wasInside = command.fillRule == .nonzero
                        ? winding != 0
                        : winding % 2 != 0
                    winding += crossing.winding
                    let isInside = command.fillRule == .nonzero
                        ? winding != 0
                        : winding % 2 != 0
                    if !wasInside && isInside {
                        spanStart = crossing.x
                    } else if wasInside && !isInside {
                        rowHasCoverage = accumulateSpan(
                            from: spanStart, to: crossing.x,
                            firstColumn: firstColumn, lastColumn: lastColumn,
                            into: &coverage
                        ) || rowHasCoverage
                    }
                }
            }

            guard rowHasCoverage else { continue }
            composite(coverage: coverage, scale: coverageScale, row: row,
                      firstColumn: firstColumn, paint: command.paint, into: &image)
        }
    }

    /// Converts a device-space coordinate to a pixel index in `0...limit`.
    /// The clamping deliberately happens in floating point: `Int(_:)` traps
    /// on non-finite values and on anything outside `Int`'s range, and a
    /// document's coordinates can be arbitrarily large.
    private static func pixelIndex(_ value: Double, limit: Int) -> Int {
        guard value > 0 else { return 0 }  // also catches NaN
        guard value < Double(limit) else { return limit }
        return Int(value)
    }

    /// Adds one span's horizontal coverage (with fractional ends) to the row.
    /// Returns whether anything was added.
    private static func accumulateSpan(
        from start: Double, to end: Double,
        firstColumn: Int, lastColumn: Int,
        into coverage: inout [Double]
    ) -> Bool {
        let clampedStart = max(start, Double(firstColumn))
        let clampedEnd = min(end, Double(lastColumn + 1))
        guard clampedEnd > clampedStart else { return false }

        let startPixel = Int(clampedStart.rounded(.down))
        // The epsilon keeps a span ending exactly on a pixel boundary out of
        // the next pixel, but for a span narrower than the epsilon it would
        // otherwise select the pixel before the start.
        let endPixel = max(startPixel, Int((clampedEnd - 1e-12).rounded(.down)))

        if startPixel == endPixel {
            coverage[startPixel - firstColumn] += clampedEnd - clampedStart
            return true
        }
        coverage[startPixel - firstColumn] += Double(startPixel + 1) - clampedStart
        if startPixel + 1 <= endPixel - 1 {
            for pixel in (startPixel + 1)...(endPixel - 1) {
                coverage[pixel - firstColumn] += 1
            }
        }
        coverage[endPixel - firstColumn] += clampedEnd - Double(endPixel)
        return true
    }

    /// Source-over composites one row of coverage with the paint.
    private static func composite(
        coverage: [Double], scale: Double, row: Int, firstColumn: Int,
        paint: SVGResolvedPaint, into image: inout Image
    ) {
        for (slot, amount) in coverage.enumerated() where amount > 0.0001 {
            let column = firstColumn + slot
            let source = paint.color(atDeviceX: Double(column) + 0.5, y: Double(row) + 0.5)
            guard source.alpha > 0 else { continue }

            let sourceAlpha = min(1, amount * scale) * Double(source.alpha) / 255
            guard sourceAlpha > 0 else { continue }
            let destination = image[column, row]
            let destinationAlpha = Double(destination.alpha) / 255
            let outAlpha = sourceAlpha + destinationAlpha * (1 - sourceAlpha)
            guard outAlpha > 0 else { continue }

            func blend(_ sourceChannel: UInt8, _ destinationChannel: UInt8) -> UInt8 {
                let value = (Double(sourceChannel) * sourceAlpha
                    + Double(destinationChannel) * destinationAlpha * (1 - sourceAlpha)) / outAlpha
                return UInt8(min(255, max(0, value.rounded())))
            }
            image[column, row] = RGBA(
                red: blend(source.red, destination.red),
                green: blend(source.green, destination.green),
                blue: blend(source.blue, destination.blue),
                alpha: UInt8(min(255, max(0, (outAlpha * 255).rounded())))
            )
        }
    }
}
