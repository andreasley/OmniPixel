/// Errors thrown by PurePixel when decoding, encoding or manipulating images.
public enum ImageError: Error, Equatable, Sendable {
    /// The data doesn't match any known image format.
    case unknownFormat
    /// The data claims to be a known format but is malformed.
    case invalidData(reason: String)
    /// The file uses a valid but currently unsupported feature of its format.
    case unsupportedFeature(reason: String)
    /// Requested dimensions were zero, negative or too large for the format.
    case invalidDimensions
    /// A crop region reaches outside the image.
    case regionOutOfBounds
}
