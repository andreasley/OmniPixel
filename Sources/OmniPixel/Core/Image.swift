/// An image in memory, stored as one 8-bit RGBA pixel per point in row-major order.
public struct Image: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public private(set) var pixels: [RGBA]

    /// The largest pixel count decoders are willing to allocate,
    /// so a corrupt header can't request an absurd allocation.
    static let maxPixelCount = 1 << 28

    /// Creates an image filled with a single color.
    public init(width: Int, height: Int, fill: RGBA = .transparent) {
        precondition(width > 0 && height > 0, "Image dimensions must be positive")
        self.width = width
        self.height = height
        self.pixels = [RGBA](repeating: fill, count: width * height)
    }

    /// Creates an image from row-major pixel data.
    public init(width: Int, height: Int, pixels: [RGBA]) {
        precondition(width > 0 && height > 0, "Image dimensions must be positive")
        precondition(pixels.count == width * height, "Pixel count must equal width × height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> RGBA {
        get {
            precondition(contains(x: x, y: y), "Pixel coordinates out of bounds")
            return pixels[y * width + x]
        }
        set {
            precondition(contains(x: x, y: y), "Pixel coordinates out of bounds")
            pixels[y * width + x] = newValue
        }
    }

    /// Returns the pixel at the given coordinates, or nil if outside the image.
    public func pixel(atX x: Int, y: Int) -> RGBA? {
        guard contains(x: x, y: y) else { return nil }
        return pixels[y * width + x]
    }

    /// Whether the given coordinates lie inside the image.
    public func contains(x: Int, y: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height
    }
}
