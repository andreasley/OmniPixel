import Foundation

/// BMP (Windows bitmap).
///
/// Decoding supports uncompressed 8-bit palette, 24-bit and 32-bit images
/// with BITMAPINFOHEADER or newer, both bottom-up and top-down.
/// Encoding produces 24-bit uncompressed BMP (alpha is discarded).
enum BMPCodec: ImageCodec {
    private static let magic: [UInt8] = [0x42, 0x4D]  // "BM"

    static func canDecode(_ data: Data) -> Bool {
        data.count >= magic.count && [UInt8](data.prefix(magic.count)) == magic
    }

    // MARK: Decoding

    static func decode(_ data: Data) throws -> Image {
        var reader = ByteReader(data)
        guard try reader.readBytes(2) == magic else {
            throw ImageError.invalidData(reason: "Missing BM signature")
        }
        _ = try reader.readUInt32LittleEndian()  // file size (often wrong; ignored)
        _ = try reader.readBytes(4)  // reserved
        let pixelDataOffset = Int(try reader.readUInt32LittleEndian())

        let headerSize = Int(try reader.readUInt32LittleEndian())
        guard headerSize >= 40 else {
            throw ImageError.unsupportedFeature(reason: "BMP core headers are not supported")
        }
        let width = Int(try reader.readInt32LittleEndian())
        let rawHeight = Int(try reader.readInt32LittleEndian())
        let isTopDown = rawHeight < 0
        let height = abs(rawHeight)
        _ = try reader.readUInt16LittleEndian()  // color planes
        let bitsPerPixel = Int(try reader.readUInt16LittleEndian())
        let compression = try reader.readUInt32LittleEndian()
        _ = try reader.readUInt32LittleEndian()  // image data size
        _ = try reader.readBytes(8)  // resolution
        let colorsUsed = Int(try reader.readUInt32LittleEndian())
        _ = try reader.readUInt32LittleEndian()  // important colors

        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, pixelCount <= Image.maxPixelCount else {
            throw ImageError.invalidData(reason: "Invalid BMP dimensions")
        }
        guard compression == 0 else {
            throw ImageError.unsupportedFeature(reason: "Compressed BMP is not supported")
        }
        guard bitsPerPixel == 8 || bitsPerPixel == 24 || bitsPerPixel == 32 else {
            throw ImageError.unsupportedFeature(reason: "\(bitsPerPixel)-bit BMP is not supported")
        }

        var palette: [RGBA] = []
        if bitsPerPixel == 8 {
            let paletteCount = colorsUsed == 0 ? 256 : colorsUsed
            guard paletteCount <= 256 else {
                throw ImageError.invalidData(reason: "Invalid BMP palette size")
            }
            try reader.seek(to: 14 + headerSize)
            for _ in 0..<paletteCount {
                let entry = try reader.readBytes(4)  // stored as BGRX
                palette.append(RGBA(red: entry[2], green: entry[1], blue: entry[0]))
            }
        }

        // Rows are padded to a multiple of four bytes.
        let bytesPerRow = (width * bitsPerPixel + 31) / 32 * 4
        try reader.seek(to: pixelDataOffset)
        let pixelData = try reader.readBytes(bytesPerRow * height)

        var pixels = [RGBA](repeating: .transparent, count: pixelCount)
        for row in 0..<height {
            let sourceRow = isTopDown ? row : height - 1 - row
            let rowStart = sourceRow * bytesPerRow
            for x in 0..<width {
                let pixel: RGBA
                switch bitsPerPixel {
                case 8:
                    let index = Int(pixelData[rowStart + x])
                    guard index < palette.count else {
                        throw ImageError.invalidData(reason: "BMP palette index out of range")
                    }
                    pixel = palette[index]
                case 24:
                    let i = rowStart + x * 3
                    pixel = RGBA(red: pixelData[i + 2], green: pixelData[i + 1], blue: pixelData[i])
                default:  // 32, already validated
                    let i = rowStart + x * 4
                    pixel = RGBA(red: pixelData[i + 2], green: pixelData[i + 1], blue: pixelData[i], alpha: pixelData[i + 3])
                }
                pixels[row * width + x] = pixel
            }
        }

        // Many 32-bit writers leave the unused fourth byte at zero; a fully
        // transparent image almost certainly means "no alpha channel".
        if bitsPerPixel == 32 && pixels.allSatisfy({ $0.alpha == 0 }) {
            for i in pixels.indices {
                pixels[i].alpha = 255
            }
        }

        return Image(width: width, height: height, pixels: pixels)
    }

    // MARK: Encoding

    static func encode(_ image: Image) throws -> Data {
        guard let width = Int32(exactly: image.width), let height = Int32(exactly: image.height) else {
            throw ImageError.invalidDimensions
        }
        let bytesPerRow = (image.width * 3 + 3) / 4 * 4
        let pixelDataSize = bytesPerRow * image.height

        var writer = ByteWriter()
        writer.writeBytes(magic)
        writer.writeUInt32LittleEndian(UInt32(14 + 40 + pixelDataSize))
        writer.writeUInt32LittleEndian(0)  // reserved
        writer.writeUInt32LittleEndian(54)  // pixel data offset

        writer.writeUInt32LittleEndian(40)  // BITMAPINFOHEADER
        writer.writeInt32LittleEndian(width)
        writer.writeInt32LittleEndian(height)  // positive: bottom-up
        writer.writeUInt16LittleEndian(1)  // color planes
        writer.writeUInt16LittleEndian(24)
        writer.writeUInt32LittleEndian(0)  // no compression
        writer.writeUInt32LittleEndian(UInt32(pixelDataSize))
        writer.writeInt32LittleEndian(2835)  // 72 DPI in pixels per meter
        writer.writeInt32LittleEndian(2835)
        writer.writeUInt32LittleEndian(0)  // colors used
        writer.writeUInt32LittleEndian(0)  // important colors

        let padding = [UInt8](repeating: 0, count: bytesPerRow - image.width * 3)
        for y in (0..<image.height).reversed() {
            for x in 0..<image.width {
                let pixel = image.pixels[y * image.width + x]
                writer.writeBytes([pixel.blue, pixel.green, pixel.red])
            }
            writer.writeBytes(padding)
        }
        return writer.data
    }
}
