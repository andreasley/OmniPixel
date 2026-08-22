import Foundation

/// A file format OmniPixel can read and write.
public enum ImageFormat: String, CaseIterable, Sendable {
    case png
    case jpeg
    case gif
    case tiff
    case webp
    /// Decoded by the built-in HEVC intra decoder; encoding is unsupported.
    case heic
    /// Recognized and container-parsed; decoding requires the AV1 decoder,
    /// which is under construction — `decode` throws `unsupportedFeature`.
    case avif
    case bmp
    case qoi
    /// Netpbm binary formats (PPM/PGM).
    case netpbm
    /// Decoded by rasterizing at the document's intrinsic size (see
    /// `Image(svgData:width:height:)` for custom sizes); encoding is
    /// unsupported.
    case svg

    /// The conventional file extension for the format.
    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .gif: "gif"
        case .tiff: "tiff"
        case .webp: "webp"
        case .heic: "heic"
        case .avif: "avif"
        case .bmp: "bmp"
        case .qoi: "qoi"
        case .netpbm: "ppm"
        case .svg: "svg"
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
        case .tiff: TIFFCodec.self
        case .webp: WebPCodec.self
        case .heic: HEICCodec.self
        case .avif: AVIFCodec.self
        case .bmp: BMPCodec.self
        case .qoi: QOICodec.self
        case .netpbm: NetpbmCodec.self
        case .svg: SVGCodec.self
        }
    }
}

/// Options for encoding. Each field applies only to the formats that use it;
/// the others ignore it.
public struct EncodingOptions: Sendable {
    /// JPEG quality from 1 (smallest file) to 100 (highest fidelity).
    /// Values outside that range are clamped.
    public var jpegQuality: Int

    /// EXIF metadata to embed. Honored when encoding JPEG, PNG and WebP;
    /// the orientation tag is reset to upright because OmniPixel always
    /// encodes pixels in display order.
    public var exif: EXIFData?

    public init(jpegQuality: Int = 85, exif: EXIFData? = nil) {
        self.jpegQuality = jpegQuality
        self.exif = exif
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
    ///
    /// Camera files often store their pixels unrotated alongside an EXIF
    /// orientation tag; it is applied here so decoding always yields
    /// upright pixels.
    public init(data: Data, format: ImageFormat) throws {
        var image = try format.codec.decode(data)
        if let orientation = EXIFData(data: data)?.orientation, orientation != .topLeft {
            image = image.oriented(by: orientation)
        }
        self = image
    }

    /// Encodes the image in the given format.
    public func encoded(as format: ImageFormat, options: EncodingOptions = EncodingOptions()) throws -> Data {
        try format.codec.encode(self, options: options)
    }
}
