extension Image {
    /// Returns the part of the image inside `region`.
    public func cropped(to region: Region) throws -> Image {
        guard region.width > 0, region.height > 0 else {
            throw ImageError.invalidDimensions
        }
        // Comparisons are arranged so that even absurd region values can't overflow.
        guard region.x >= 0, region.y >= 0,
              region.width <= width - region.x,
              region.height <= height - region.y else {
            throw ImageError.regionOutOfBounds
        }

        var croppedPixels: [RGBA] = []
        croppedPixels.reserveCapacity(region.width * region.height)
        for y in region.y..<(region.y + region.height) {
            let rowStart = y * width + region.x
            croppedPixels += pixels[rowStart..<(rowStart + region.width)]
        }
        return Image(width: region.width, height: region.height, pixels: croppedPixels)
    }
}
