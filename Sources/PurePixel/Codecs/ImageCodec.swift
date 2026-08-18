import Foundation

/// A file format PurePixel can read and write.
public enum ImageFormat: String, CaseIterable, Sendable {
    case png
    case jpeg
    case gif
    case bmp
    case qoi
    /// Netpbm binary formats (PPM/PGM).
    case netpbm

    /// The conventional file extension for the format.
    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .gif: "gif"
        case .bmp: "bmp"
        case .qoi: "qoi"
        case .netpbm: "ppm"
        }
    }

    /// Detects the format of encoded image data by its magic bytes.
    public init?(detecting data: Data) {
        guard let match = ImageFormat.allCases.first(where: { $0.codec.canDecode(data) }) else {
            return nil
        }
        self = match
    }

    var codec: any ImageCodec.Type {
        switch self {
        case .png: PNGCodec.self
        case .jpeg: JPEGCodec.self
        case .gif: GIFCodec.self
        case .bmp: BMPCodec.self
        case .qoi: QOICodec.self
        case .netpbm: NetpbmCodec.self
        }
    }
}

/// Options for encoding. Each field applies only to the formats that use it;
/// the others ignore it.
public struct EncodingOptions: Sendable {
    /// JPEG quality from 1 (smallest file) to 100 (highest fidelity).
    /// Values outside that range are clamped.
    public var jpegQuality: Int

    public init(jpegQuality: Int = 85) {
        self.jpegQuality = jpegQuality
    }
}

/// Reads and writes one image file format.
protocol ImageCodec {
    /// Cheap magic-byte check; must not fully parse the data.
    static func canDecode(_ data: Data) -> Bool
    static func decode(_ data: Data) throws -> Image
    static func encode(_ image: Image) throws -> Data
    /// Codecs with encoding parameters implement this; the default ignores options.
    static func encode(_ image: Image, options: EncodingOptions) throws -> Data
}

extension ImageCodec {
    static func encode(_ image: Image, options: EncodingOptions) throws -> Data {
        try encode(image)
    }
}

extension Image {
    /// Decodes an image, detecting its format from the data.
    public init(data: Data) throws {
        guard let format = ImageFormat(detecting: data) else {
            throw ImageError.unknownFormat
        }
        try self.init(data: data, format: format)
    }

    /// Decodes an image that is known to be in the given format.
    public init(data: Data, format: ImageFormat) throws {
        self = try format.codec.decode(data)
    }

    /// Encodes the image in the given format.
    public func encoded(as format: ImageFormat, options: EncodingOptions = EncodingOptions()) throws -> Data {
        try format.codec.encode(self, options: options)
    }
}
