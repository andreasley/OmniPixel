/// How pixels are sampled when an image is resized.
public enum ScalingMethod: Sendable {
    /// Copies the closest source pixel. Fast, hard-edged.
    case nearestNeighbor
    /// Weighs the four closest source pixels. Smooth.
    case bilinear
}

extension Image {
    /// Returns a copy of the image resized to the given dimensions.
    public func resized(toWidth newWidth: Int, height newHeight: Int, method: ScalingMethod = .bilinear) throws -> Image {
        guard newWidth > 0, newHeight > 0 else {
            throw ImageError.invalidDimensions
        }
        if newWidth == width && newHeight == height {
            return self
        }

        var result = Image(width: newWidth, height: newHeight)
        let scaleX = Double(width) / Double(newWidth)
        let scaleY = Double(height) / Double(newHeight)

        for y in 0..<newHeight {
            for x in 0..<newWidth {
                switch method {
                case .nearestNeighbor:
                    let sourceX = min(width - 1, Int((Double(x) + 0.5) * scaleX))
                    let sourceY = min(height - 1, Int((Double(y) + 0.5) * scaleY))
                    result[x, y] = self[sourceX, sourceY]
                case .bilinear:
                    // Map the target pixel's center back into source coordinates.
                    result[x, y] = bilinearSample(
                        x: (Double(x) + 0.5) * scaleX - 0.5,
                        y: (Double(y) + 0.5) * scaleY - 0.5
                    )
                }
            }
        }
        return result
    }

    /// Returns a copy of the image with both dimensions multiplied by `factor`.
    public func scaled(by factor: Double, method: ScalingMethod = .bilinear) throws -> Image {
        guard factor > 0, factor.isFinite else {
            throw ImageError.invalidDimensions
        }
        return try resized(
            toWidth: max(1, Int((Double(width) * factor).rounded())),
            height: max(1, Int((Double(height) * factor).rounded())),
            method: method
        )
    }

    private func bilinearSample(x: Double, y: Double) -> RGBA {
        let clampedX = min(max(x, 0), Double(width - 1))
        let clampedY = min(max(y, 0), Double(height - 1))
        let x0 = Int(clampedX)
        let y0 = Int(clampedY)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fractionX = clampedX - Double(x0)
        let fractionY = clampedY - Double(y0)

        func blend(_ component: (RGBA) -> UInt8) -> UInt8 {
            let top = Double(component(self[x0, y0])) * (1 - fractionX)
                + Double(component(self[x1, y0])) * fractionX
            let bottom = Double(component(self[x0, y1])) * (1 - fractionX)
                + Double(component(self[x1, y1])) * fractionX
            return UInt8((top * (1 - fractionY) + bottom * fractionY).rounded())
        }
        return RGBA(red: blend(\.red), green: blend(\.green), blue: blend(\.blue), alpha: blend(\.alpha))
    }
}
