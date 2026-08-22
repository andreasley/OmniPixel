#if canImport(SwiftUI) && os(macOS)
import CoreGraphics
import Foundation
import OmniPixel

/// The viewer's state: the currently loaded image, everything OmniPixel
/// knows about its source file, and the editing operations offered by the
/// interface. All decoding, metadata parsing, editing and re-encoding is
/// done by OmniPixel; the platform only displays and moves bytes.
@MainActor
final class ViewerModel: ObservableObject {
    @Published private(set) var image: PixelImage?
    @Published private(set) var displayImage: CGImage?
    @Published private(set) var fileName: String?
    @Published private(set) var sourceFormat: ImageFormat?
    @Published private(set) var sourceByteCount = 0
    @Published private(set) var exif: EXIFData?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var originalImage: PixelImage?

    var hasEdits: Bool {
        image != originalImage
    }

    func open(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            load(data: data, name: url.lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func load(data: Data, name: String) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                // Decode off the main actor; OmniPixel types are Sendable.
                let decoded = try await Task.detached(priority: .userInitiated) {
                    try PixelImage(data: data)
                }.value
                let format = ImageFormat(detecting: data)
                let metadata = EXIFData(data: data)
                apply(
                    decoded, name: name, format: format,
                    byteCount: data.count, metadata: metadata
                )
            } catch let ImageError.unsupportedFeature(reason) {
                finishLoading(error: "Unsupported: \(reason)")
            } catch let ImageError.invalidData(reason) {
                finishLoading(error: "Corrupt image: \(reason)")
            } catch {
                finishLoading(error: error.localizedDescription)
            }
        }
    }

    private func apply(
        _ decoded: PixelImage, name: String, format: ImageFormat?,
        byteCount: Int, metadata: EXIFData?
    ) {
        image = decoded
        originalImage = decoded
        displayImage = decoded.makeCGImage()
        fileName = name
        sourceFormat = format
        sourceByteCount = byteCount
        exif = metadata
        isLoading = false
    }

    private func finishLoading(error: String) {
        errorMessage = error
        isLoading = false
    }

    // MARK: Editing (OmniPixel operations)

    func transform(_ operation: (PixelImage) throws -> PixelImage) {
        guard let current = image else { return }
        do {
            let updated = try operation(current)
            image = updated
            displayImage = updated.makeCGImage()
        } catch let ImageError.invalidData(reason) {
            errorMessage = reason
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rotate(_ rotation: Rotation) {
        transform { $0.rotated(by: rotation) }
    }

    func mirror(_ axis: MirrorAxis) {
        transform { $0.mirrored(across: axis) }
    }

    func scale(by factor: Double) {
        transform { try $0.scaled(by: factor) }
    }

    func cropCenterHalf() {
        transform { image in
            let width = max(1, image.width / 2)
            let height = max(1, image.height / 2)
            return try image.cropped(to: Region(
                x: (image.width - width) / 2,
                y: (image.height - height) / 2,
                width: width,
                height: height
            ))
        }
    }

    func revert() {
        guard let original = originalImage else { return }
        image = original
        displayImage = original.makeCGImage()
    }

    // MARK: Export (OmniPixel encoders)

    func exportData(as format: ImageFormat, jpegQuality: Int) throws -> Data {
        guard let image else {
            throw ImageError.invalidData(reason: "No image loaded")
        }
        // Carry the source's EXIF along where the format supports embedding.
        let options = EncodingOptions(jpegQuality: jpegQuality, exif: exif)
        return try image.encoded(as: format, options: options)
    }
}
#endif
