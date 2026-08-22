import Foundation
import Testing
@testable import OmniPixel

#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

@Suite struct EXIFTests {
    private func makeSampleEXIF() -> EXIFData {
        EXIFData(
            tags: [
                EXIFTag.cameraMake: .ascii("OmniPixel"),
                EXIFTag.cameraModel: .ascii("TestCam 3000"),
                EXIFTag.orientation: .short([6]),
                EXIFTag.software: .ascii("OmniPixelTests"),
            ],
            photoTags: [
                EXIFTag.dateTimeOriginal: .ascii("2026:08:19 12:34:56"),
                EXIFTag.exposureTime: .rational([EXIFRational(numerator: 1, denominator: 250)]),
                EXIFTag.fNumber: .rational([EXIFRational(numerator: 28, denominator: 10)]),
                EXIFTag.isoSpeed: .short([400]),
                EXIFTag.focalLength: .rational([EXIFRational(numerator: 50, denominator: 1)]),
            ],
            gpsTags: [
                EXIFTag.gpsLatitudeReference: .ascii("N"),
                EXIFTag.gpsLatitude: .rational([
                    EXIFRational(numerator: 47, denominator: 1),
                    EXIFRational(numerator: 22, denominator: 1),
                    EXIFRational(numerator: 30, denominator: 1),
                ]),
                EXIFTag.gpsLongitudeReference: .ascii("W"),
                EXIFTag.gpsLongitude: .rational([
                    EXIFRational(numerator: 8, denominator: 1),
                    EXIFRational(numerator: 33, denominator: 1),
                    EXIFRational(numerator: 0, denominator: 1),
                ]),
            ]
        )
    }

    @Test(arguments: [ImageFormat.jpeg, .png, .webp])
    func exifRoundTripsThroughEncoding(format: ImageFormat) throws {
        let image = Image(width: 10, height: 8, fill: RGBA(red: 120, green: 60, blue: 30))
        let data = try image.encoded(as: format, options: EncodingOptions(exif: makeSampleEXIF()))

        // The file must still decode (WebP grows a VP8X container for this).
        let decoded = try Image(data: data)
        #expect(decoded.width == 10)
        #expect(decoded.height == 8)

        let extracted = try #require(EXIFData(data: data))
        #expect(extracted.cameraMake == "OmniPixel")
        #expect(extracted.cameraModel == "TestCam 3000")
        #expect(extracted.software == "OmniPixelTests")
        #expect(extracted.orientation == .topLeft)  // reset to upright on embed
        #expect(extracted.dateTimeOriginal == "2026:08:19 12:34:56")
        #expect(extracted.exposureTime == EXIFRational(numerator: 1, denominator: 250))
        #expect(extracted.isoSpeed == 400)
        #expect(extracted.fNumber == 2.8)
        #expect(extracted.focalLength == 50)
        let latitude = try #require(extracted.gpsLatitude)
        let longitude = try #require(extracted.gpsLongitude)
        #expect(abs(latitude - 47.375) < 1e-9)
        #expect(abs(longitude - -8.55) < 1e-9)
    }

    @Test func orientationIsAppliedWhenDecodingPNG() throws {
        // Encode a plain PNG, then splice in an eXIf chunk that says
        // "rotate 90° clockwise to display" (orientation 6).
        var image = Image(width: 3, height: 2, fill: .black)
        image[0, 0] = .white
        let plain = try image.encoded(as: .png)

        var exifPayload = ByteWriter()
        exifPayload.writeBytes([0x49, 0x49, 42, 0])
        exifPayload.writeUInt32LittleEndian(8)  // IFD offset
        exifPayload.writeUInt16LittleEndian(1)  // one entry
        exifPayload.writeUInt16LittleEndian(274)  // orientation
        exifPayload.writeUInt16LittleEndian(3)  // SHORT
        exifPayload.writeUInt32LittleEndian(1)
        exifPayload.writeUInt16LittleEndian(6)
        exifPayload.writeUInt16LittleEndian(0)
        exifPayload.writeUInt32LittleEndian(0)  // no next IFD

        var chunk = ByteWriter()
        chunk.writeUInt32BigEndian(UInt32(exifPayload.bytes.count))
        chunk.writeBytes(Array("eXIf".utf8))
        chunk.writeBytes(exifPayload.bytes)
        chunk.writeUInt32BigEndian(CRC32.checksum(of: Array("eXIf".utf8) + exifPayload.bytes))

        var fileBytes = [UInt8](plain)
        fileBytes.insert(contentsOf: chunk.bytes, at: 33)  // right after IHDR

        let decoded = try Image(data: Data(fileBytes))
        #expect(decoded.width == 2)
        #expect(decoded.height == 3)
        #expect(decoded[1, 0] == .white)  // rotated 90° clockwise
    }

    @Test func orientationIsAppliedWhenDecodingTIFF() throws {
        // 3×1 RGB TIFF (red, green, blue) with orientation 6.
        let compressed = Deflate.zlibCompress([255, 0, 0, 0, 255, 0, 0, 0, 255])
        let ifdOffset = 8 + compressed.count + (compressed.count & 1)

        var writer = ByteWriter()
        writer.writeBytes([0x49, 0x49, 42, 0])
        writer.writeUInt32LittleEndian(UInt32(ifdOffset))
        writer.writeBytes(compressed)
        if compressed.count & 1 == 1 {
            writer.writeByte(0)
        }
        writer.writeUInt16LittleEndian(10)
        func entry(_ tag: Int, _ type: Int, _ value: Int) {
            writer.writeUInt16LittleEndian(UInt16(tag))
            writer.writeUInt16LittleEndian(UInt16(type))
            writer.writeUInt32LittleEndian(1)
            if type == 3 {
                writer.writeUInt16LittleEndian(UInt16(value))
                writer.writeUInt16LittleEndian(0)
            } else {
                writer.writeUInt32LittleEndian(UInt32(value))
            }
        }
        entry(256, 4, 3)  // width
        entry(257, 4, 1)  // height
        entry(258, 3, 8)  // bits per sample
        entry(259, 3, 8)  // Deflate
        entry(262, 3, 2)  // RGB
        entry(273, 4, 8)  // strip offset
        entry(274, 3, 6)  // orientation: rotate 90° clockwise to display
        entry(277, 3, 3)  // samples per pixel
        entry(278, 4, 1)  // rows per strip
        entry(279, 4, compressed.count)
        writer.writeUInt32LittleEndian(0)

        let decoded = try Image(data: writer.data)
        #expect(decoded.width == 1)
        #expect(decoded.height == 3)
        #expect(decoded[0, 0] == RGBA(red: 255, green: 0, blue: 0))
        #expect(decoded[0, 1] == RGBA(red: 0, green: 255, blue: 0))
        #expect(decoded[0, 2] == RGBA(red: 0, green: 0, blue: 255))
    }

    #if canImport(ImageIO)
    @Test func imageIOReadsOurEXIF() throws {
        let image = Image(width: 12, height: 10, fill: RGBA(red: 200, green: 100, blue: 50))
        let data = try image.encoded(as: .jpeg, options: EncodingOptions(exif: makeSampleEXIF()))

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])

        let tiff = try #require(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == "OmniPixel")
        #expect(tiff[kCGImagePropertyTIFFModel as String] as? String == "TestCam 3000")

        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:08:19 12:34:56")

        let gps = try #require(properties[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        let latitude = try #require(gps[kCGImagePropertyGPSLatitude as String] as? Double)
        #expect(abs(latitude - 47.375) < 0.001)
    }

    @Test(arguments: Array(1...8))
    func orientationMatchesImageIO(orientationValue: Int) throws {
        // ImageIO writes the EXIF orientation tag without touching pixels;
        // its transform-applying thumbnail decode is the ground truth our
        // auto-oriented decode must match.
        let width = 16
        let height = 8
        var basePixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                basePixels[i] = UInt8(x * 16)
                basePixels[i + 1] = UInt8(y * 30)
                basePixels[i + 2] = UInt8(255 - x * 12)
                basePixels[i + 3] = 255
            }
        }
        let context = try #require(CGContext(
            data: &basePixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try #require(context.makeImage())

        let jpegData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            jpegData, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyOrientation: orientationValue,
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let ours = try Image(data: jpegData as Data)

        let source = try #require(CGImageSourceCreateWithData(jpegData as CFData, nil))
        let reference = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ] as CFDictionary))
        #expect(ours.width == reference.width, "orientation \(orientationValue)")
        #expect(ours.height == reference.height, "orientation \(orientationValue)")

        var referencePixels = [UInt8](repeating: 0, count: reference.width * reference.height * 4)
        let referenceContext = try #require(CGContext(
            data: &referencePixels,
            width: reference.width,
            height: reference.height,
            bitsPerComponent: 8,
            bytesPerRow: reference.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        referenceContext.draw(reference, in: CGRect(x: 0, y: 0, width: reference.width, height: reference.height))

        var maximumError = 0
        for y in 0..<ours.height {
            for x in 0..<ours.width {
                let pixel = ours[x, y]
                let i = (y * ours.width + x) * 4
                maximumError = max(
                    maximumError,
                    abs(Int(pixel.red) - Int(referencePixels[i])),
                    abs(Int(pixel.green) - Int(referencePixels[i + 1])),
                    abs(Int(pixel.blue) - Int(referencePixels[i + 2]))
                )
            }
        }
        #expect(maximumError <= 26, "orientation \(orientationValue)")
    }
    #endif
}
