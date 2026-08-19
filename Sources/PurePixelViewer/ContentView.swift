#if canImport(SwiftUI) && os(macOS)
import PurePixel
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = ViewerModel()
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var showExportSheet = false
    @State private var exportFormat: ImageFormat = .png
    @State private var exportQuality = 85.0
    @State private var exportDocument: ExportDocument?
    @State private var zoom = 1.0

    var body: some View {
        Group {
            if let cgImage = model.displayImage {
                imageView(cgImage)
            } else {
                emptyView
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .toolbar { toolbarContent }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                model.open(url: url)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportDocument?.contentType ?? .data,
            defaultFilename: exportFileName
        ) { result in
            if case .failure(let error) = result {
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showExportSheet) { exportSheet }
        .alert(
            "PurePixel",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url: url)
            return true
        }
        .navigationTitle(model.fileName ?? "PurePixel Viewer")
    }

    // MARK: Views

    private var emptyView: some View {
        VStack(spacing: 12) {
            if model.isLoading {
                ProgressView("Decoding with PurePixel…")
            } else {
                SwiftUI.Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Drop an image here")
                    .font(.title3)
                Text("PNG, JPEG, GIF, TIFF, WebP, HEIC, BMP, QOI, PPM/PGM — all decoded in pure Swift")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Image…") { isImporting = true }
                    .keyboardShortcut("o")
            }
        }
        .padding(40)
    }

    private func imageView(_ cgImage: CGImage) -> some View {
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                SwiftUI.Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .interpolation(zoom >= 4 ? .none : .high)
                    .frame(
                        width: Double(cgImage.width) * zoom,
                        height: Double(cgImage.height) * zoom
                    )
                    .padding(16)
            }
            .background(.quaternary.opacity(0.4))
            Divider()
            infoBar
        }
    }

    private var infoBar: some View {
        HStack(spacing: 16) {
            if let format = model.sourceFormat {
                Text(format.rawValue.uppercased())
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            }
            if let image = model.image {
                Text("\(image.width) × \(image.height)")
            }
            Text(ByteCountFormatter.string(
                fromByteCount: Int64(model.sourceByteCount), countStyle: .file
            ))
            .foregroundStyle(.secondary)
            if let exif = model.exif, !exif.isEmpty {
                Text(exifSummary(exif))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Slider(value: $zoom, in: 0.1...8) {
                Text("Zoom")
            }
            .frame(width: 140)
            Text("\(Int((zoom * 100).rounded())) %")
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func exifSummary(_ exif: EXIFData) -> String {
        var parts: [String] = []
        if let make = exif.cameraMake, let cameraModel = exif.cameraModel {
            parts.append("\(make) \(cameraModel)")
        }
        if let date = exif.dateTimeOriginal ?? exif.dateTime {
            parts.append(date)
        }
        if let exposure = exif.exposureTime {
            parts.append("\(exposure.numerator)/\(exposure.denominator) s")
        }
        if let fNumber = exif.fNumber {
            parts.append(String(format: "ƒ%.1f", fNumber))
        }
        if let iso = exif.isoSpeed {
            parts.append("ISO \(iso)")
        }
        return parts.isEmpty ? "EXIF present" : parts.joined(separator: " · ")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                isImporting = true
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open an image (⌘O)")

            if model.image != nil {
                ControlGroup {
                    Button {
                        model.rotate(.clockwise270)
                    } label: {
                        Label("Rotate Left", systemImage: "rotate.left")
                    }
                    Button {
                        model.rotate(.clockwise90)
                    } label: {
                        Label("Rotate Right", systemImage: "rotate.right")
                    }
                    Button {
                        model.mirror(.horizontal)
                    } label: {
                        Label("Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    Button {
                        model.mirror(.vertical)
                    } label: {
                        Label("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    }
                }
                ControlGroup {
                    Button {
                        model.scale(by: 0.5)
                    } label: {
                        Label("Half Size", systemImage: "minus.magnifyingglass")
                    }
                    Button {
                        model.scale(by: 2)
                    } label: {
                        Label("Double Size", systemImage: "plus.magnifyingglass")
                    }
                    Button {
                        model.cropCenterHalf()
                    } label: {
                        Label("Crop Center", systemImage: "crop")
                    }
                }
                Button {
                    model.revert()
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.hasEdits)
                Button {
                    showExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Re-encode with PurePixel and save")
            }
        }
    }

    // MARK: Export

    private static let exportFormats: [ImageFormat] = [
        .png, .jpeg, .gif, .tiff, .webp, .bmp, .qoi, .netpbm,
    ]

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export with PurePixel")
                .font(.headline)
            Picker("Format", selection: $exportFormat) {
                ForEach(Self.exportFormats, id: \.self) { format in
                    Text(format.rawValue.uppercased()).tag(format)
                }
            }
            if exportFormat == .jpeg {
                VStack(alignment: .leading) {
                    Slider(value: $exportQuality, in: 1...100, step: 1) {
                        Text("Quality")
                    }
                    Text("JPEG quality: \(Int(exportQuality))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showExportSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    do {
                        let data = try model.exportData(
                            as: exportFormat, jpegQuality: Int(exportQuality)
                        )
                        exportDocument = ExportDocument(
                            data: data, contentType: Self.contentType(for: exportFormat)
                        )
                        showExportSheet = false
                        isExporting = true
                    } catch let ImageError.unsupportedFeature(reason) {
                        model.errorMessage = reason
                        showExportSheet = false
                    } catch {
                        model.errorMessage = error.localizedDescription
                        showExportSheet = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var exportFileName: String {
        let base = (model.fileName as NSString?)?.deletingPathExtension ?? "image"
        return "\(base).\(exportFormat.fileExtension)"
    }

    private static func contentType(for format: ImageFormat) -> UTType {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .gif: .gif
        case .tiff: .tiff
        case .webp: .webP
        case .bmp: .bmp
        default: .data
        }
    }
}

/// A write-only document wrapping PurePixel-encoded bytes for `fileExporter`.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [
        .png, .jpeg, .gif, .tiff, .webP, .bmp, .data,
    ]

    var data: Data
    var contentType: UTType

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
