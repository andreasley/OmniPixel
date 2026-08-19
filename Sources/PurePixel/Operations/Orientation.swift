/// A quarter-turn rotation.
public enum Rotation: Sendable {
    case clockwise90
    case clockwise180
    case clockwise270
}

/// An axis to mirror across.
public enum MirrorAxis: Sendable {
    /// Swaps left and right (reflection across the vertical center line).
    case horizontal
    /// Swaps top and bottom (reflection across the horizontal center line).
    case vertical
}

extension Image {
    /// Returns a copy of the image turned by the given quarter-turn rotation.
    public func rotated(by rotation: Rotation) -> Image {
        var rotatedPixels = [RGBA](repeating: .transparent, count: width * height)

        switch rotation {
        case .clockwise90:
            // (x, y) moves to (height - 1 - y, x); the result is height × width.
            for y in 0..<height {
                for x in 0..<width {
                    rotatedPixels[x * height + (height - 1 - y)] = pixels[y * width + x]
                }
            }
            return Image(width: height, height: width, pixels: rotatedPixels)

        case .clockwise180:
            // (x, y) moves to (width - 1 - x, height - 1 - y).
            for y in 0..<height {
                for x in 0..<width {
                    rotatedPixels[(height - 1 - y) * width + (width - 1 - x)] = pixels[y * width + x]
                }
            }
            return Image(width: width, height: height, pixels: rotatedPixels)

        case .clockwise270:
            // (x, y) moves to (y, width - 1 - x); the result is height × width.
            for y in 0..<height {
                for x in 0..<width {
                    rotatedPixels[(width - 1 - x) * height + y] = pixels[y * width + x]
                }
            }
            return Image(width: height, height: width, pixels: rotatedPixels)
        }
    }

    /// Returns a copy of the image reflected across the given axis.
    public func mirrored(across axis: MirrorAxis) -> Image {
        var mirroredPixels = [RGBA](repeating: .transparent, count: width * height)

        switch axis {
        case .horizontal:
            for y in 0..<height {
                for x in 0..<width {
                    mirroredPixels[y * width + (width - 1 - x)] = pixels[y * width + x]
                }
            }
        case .vertical:
            for y in 0..<height {
                let sourceStart = y * width
                let targetStart = (height - 1 - y) * width
                for x in 0..<width {
                    mirroredPixels[targetStart + x] = pixels[sourceStart + x]
                }
            }
        }
        return Image(width: width, height: height, pixels: mirroredPixels)
    }
}
