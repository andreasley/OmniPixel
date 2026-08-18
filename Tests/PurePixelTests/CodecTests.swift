import Foundation
import Testing
@testable import PurePixel

#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

@Suite struct CodecTests {
    /// A small image with gradients, varied alpha and a flat run,
    /// to exercise all the QOI ops and PNG value ranges.
    private func makeTestImage() -> Image {
        var image = Image(width: 23, height: 11)
        for y in 0..<image.height {
            for x in 0..<image.width {
                if x < 5 {
                    image[x, y] = RGBA(red: 200, green: 50, blue: 25)
                } else {
                    image[x, y] = RGBA(
                        red: UInt8(x * 11 % 256),
                        green: UInt8(y * 23 % 256),
                        blue: UInt8((x + y) * 7 % 256),
                        alpha: UInt8(255 - (x * y) % 128)
                    )
                }
            }
        }
        return image
    }

    /// Few distinct colors and hard (0/255) alpha — content GIF stores exactly.
    private func makePalettedTestImage() -> Image {
        let colors: [RGBA] = [
            .black,
            RGBA(red: 255, green: 0, blue: 0),
            RGBA(red: 0, green: 255, blue: 0),
            RGBA(red: 0, green: 0, blue: 255),
            RGBA(red: 255, green: 255, blue: 0),
            RGBA(red: 12, green: 34, blue: 56),
            .white,
        ]
        var image = Image(width: 40, height: 25)
        for y in 0..<image.height {
            for x in 0..<image.width {
                if (x + y) % 5 == 0 {
                    image[x, y] = .transparent
                } else {
                    image[x, y] = colors[(x * 3 + y) % colors.count]
                }
            }
        }
        return image
    }

    /// Smooth opaque gradients — content JPEG reproduces closely.
    private func makeSmoothTestImage(width: Int = 64, height: Int = 48) -> Image {
        var image = Image(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                image[x, y] = RGBA(
                    red: UInt8(min(255, x * 3)),
                    green: UInt8(min(255, y * 4)),
                    blue: UInt8(min(255, 60 + x + y))
                )
            }
        }
        return image
    }

    private func opaque(_ image: Image) -> Image {
        var result = image
        for y in 0..<result.height {
            for x in 0..<result.width {
                result[x, y].alpha = 255
            }
        }
        return result
    }

    private func maximumChannelError(_ first: Image, _ second: Image) -> Int {
        var maximum = 0
        for (a, b) in zip(first.pixels, second.pixels) {
            maximum = max(maximum, abs(Int(a.red) - Int(b.red)))
            maximum = max(maximum, abs(Int(a.green) - Int(b.green)))
            maximum = max(maximum, abs(Int(a.blue) - Int(b.blue)))
        }
        return maximum
    }

    @Test(arguments: [ImageFormat.png, .qoi, .tiff, .webp])
    func losslessRoundTrip(format: ImageFormat) throws {
        let original = makeTestImage()
        let encoded = try original.encoded(as: format)
        #expect(ImageFormat(detecting: encoded) == format)
        #expect(try Image(data: encoded) == original)
    }

    @Test(arguments: [ImageFormat.bmp, .netpbm])
    func opaqueRoundTrip(format: ImageFormat) throws {
        // BMP (as we write it) and PPM carry no alpha, so compare opaque copies.
        let original = opaque(makeTestImage())
        let encoded = try original.encoded(as: format)
        #expect(ImageFormat(detecting: encoded) == format)
        #expect(try Image(data: encoded) == original)
    }

    @Test func convertsBetweenFormats() throws {
        let original = opaque(makeTestImage())
        let bmpData = try original.encoded(as: .bmp)
        let pngData = try Image(data: bmpData).encoded(as: .png)
        #expect(try Image(data: pngData) == original)
    }

    // MARK: PNG

    @Test func pngRoundTripOfLargerImage() throws {
        // Big enough that the encoder emits real LZW matches, a dynamic
        // Huffman block and varied per-row filters, exercising the full
        // compression path (and all the decoder's unfilter paths) end to end.
        var image = Image(width: 200, height: 150)
        for y in 0..<image.height {
            for x in 0..<image.width {
                image[x, y] = RGBA(
                    red: UInt8(x % 256),
                    green: UInt8(y % 256),
                    blue: UInt8((x * y) % 256),
                    alpha: UInt8(200 + (x + y) % 56)
                )
            }
        }
        let encoded = try image.encoded(as: .png)
        #expect(try Image(data: encoded) == image)
    }

    @Test func pngCompressesFlatImages() throws {
        let image = Image(width: 100, height: 100, fill: RGBA(red: 30, green: 90, blue: 200))
        let encoded = try image.encoded(as: .png)
        #expect(try Image(data: encoded) == image)
        #expect(encoded.count < 1_000)  // raw pixel data would be 40,000 bytes
    }

    @Test func pngFiltersShrinkSmoothGradients() throws {
        // Monotonic gradients defeat plain LZ77 (no repeats), so a small file
        // here is direct evidence that scanline filtering is working.
        var image = Image(width: 256, height: 64)
        for y in 0..<image.height {
            for x in 0..<image.width {
                image[x, y] = RGBA(
                    red: UInt8(x),
                    green: UInt8((x + y) % 256),
                    blue: UInt8(255 - x),
                    alpha: 255
                )
            }
        }
        let encoded = try image.encoded(as: .png)
        #expect(try Image(data: encoded) == image)
        #expect(encoded.count < 256 * 64 * 4 / 8)  // well under an eighth of the raw size
    }

    @Test func decodes16BitPNGWithTransparency() throws {
        // Hand-built 2×1, 16-bit truecolor PNG. The tRNS chunk marks the exact
        // color of the second pixel as transparent; samples reduce to their
        // high bytes.
        let raw: [UInt8] = [
            0,  // filter: none
            0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC,  // pixel 0: R 0x1234, G 0x5678, B 0x9ABC
            0x00, 0x11, 0x00, 0x22, 0x00, 0x33,  // pixel 1: R 0x0011, G 0x0022, B 0x0033
        ]
        var ihdr = ByteWriter()
        ihdr.writeUInt32BigEndian(2)
        ihdr.writeUInt32BigEndian(1)
        ihdr.writeBytes([16, 2, 0, 0, 0])  // 16-bit truecolor

        var file = ByteWriter()
        file.writeBytes(PNGCodec.signature)
        writeChunk("IHDR", ihdr.bytes, to: &file)
        writeChunk("tRNS", [0x00, 0x11, 0x00, 0x22, 0x00, 0x33], to: &file)
        writeChunk("IDAT", Deflate.zlibCompress(raw), to: &file)
        writeChunk("IEND", [], to: &file)

        let image = try Image(data: file.data)
        #expect(image.width == 2)
        #expect(image.height == 1)
        #expect(image[0, 0] == RGBA(red: 0x12, green: 0x56, blue: 0x9A))
        #expect(image[1, 0] == RGBA(red: 0, green: 0, blue: 0, alpha: 0))
    }

    @Test func decodesGrayscalePNGWithTransparency() throws {
        // 3×1, 8-bit grayscale; tRNS marks value 128 as fully transparent.
        let raw: [UInt8] = [0, 0, 128, 255]
        var ihdr = ByteWriter()
        ihdr.writeUInt32BigEndian(3)
        ihdr.writeUInt32BigEndian(1)
        ihdr.writeBytes([8, 0, 0, 0, 0])  // 8-bit grayscale

        var file = ByteWriter()
        file.writeBytes(PNGCodec.signature)
        writeChunk("IHDR", ihdr.bytes, to: &file)
        writeChunk("tRNS", [0, 128], to: &file)
        writeChunk("IDAT", Deflate.zlibCompress(raw), to: &file)
        writeChunk("IEND", [], to: &file)

        let image = try Image(data: file.data)
        #expect(image[0, 0] == .black)
        #expect(image[1, 0] == RGBA(red: 128, green: 128, blue: 128, alpha: 0))
        #expect(image[2, 0] == .white)
    }

    @Test func decodesInterlacedPNG() throws {
        // 4×4, 8-bit grayscale, Adam7 interlaced. Pixel value = 40y + 10x,
        // stored pass by pass (passes 2 and 3 are empty at this size).
        func v(_ x: Int, _ y: Int) -> UInt8 { UInt8(40 * y + 10 * x) }
        var raw: [UInt8] = []
        raw += [0, v(0, 0)]                             // pass 1
        raw += [0, v(2, 0)]                             // pass 4
        raw += [0, v(0, 2), v(2, 2)]                    // pass 5
        raw += [0, v(1, 0), v(3, 0)]                    // pass 6, row y = 0
        raw += [0, v(1, 2), v(3, 2)]                    // pass 6, row y = 2
        raw += [0, v(0, 1), v(1, 1), v(2, 1), v(3, 1)]  // pass 7, row y = 1
        raw += [0, v(0, 3), v(1, 3), v(2, 3), v(3, 3)]  // pass 7, row y = 3

        var ihdr = ByteWriter()
        ihdr.writeUInt32BigEndian(4)
        ihdr.writeUInt32BigEndian(4)
        ihdr.writeBytes([8, 0, 0, 0, 1])  // 8-bit grayscale, Adam7 interlaced

        var file = ByteWriter()
        file.writeBytes(PNGCodec.signature)
        writeChunk("IHDR", ihdr.bytes, to: &file)
        writeChunk("IDAT", Deflate.zlibCompress(raw), to: &file)
        writeChunk("IEND", [], to: &file)

        let image = try Image(data: file.data)
        for y in 0..<4 {
            for x in 0..<4 {
                let value = v(x, y)
                #expect(image[x, y] == RGBA(red: value, green: value, blue: value), "pixel (\(x), \(y))")
            }
        }
    }

    @Test func decodesPalettePNGWithSubByteDepth() throws {
        // Hand-built 4×2 PNG, 2-bit palette. Rows: indices 0 1 2 3 and 3 2 1 0,
        // packed most-significant-bits-first, each row prefixed with filter type 0.
        let raw: [UInt8] = [0, 0b0001_1011, 0, 0b1110_0100]
        var ihdr = ByteWriter()
        ihdr.writeUInt32BigEndian(4)
        ihdr.writeUInt32BigEndian(2)
        ihdr.writeBytes([2, 3, 0, 0, 0])  // 2-bit, palette color type

        var file = ByteWriter()
        file.writeBytes(PNGCodec.signature)
        writeChunk("IHDR", ihdr.bytes, to: &file)
        writeChunk("PLTE", [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255], to: &file)
        writeChunk("IDAT", Deflate.zlibCompress(raw), to: &file)
        writeChunk("IEND", [], to: &file)

        let image = try Image(data: file.data)
        #expect(image.width == 4)
        #expect(image.height == 2)
        #expect(image[0, 0] == RGBA(red: 255, green: 0, blue: 0))
        #expect(image[1, 0] == RGBA(red: 0, green: 255, blue: 0))
        #expect(image[3, 0] == .white)
        #expect(image[0, 1] == .white)
        #expect(image[3, 1] == RGBA(red: 255, green: 0, blue: 0))
    }

    // MARK: JPEG

    @Test func jpegRoundTripIsCloseToOriginal() throws {
        let original = makeSmoothTestImage()
        let encoded = try original.encoded(as: .jpeg)
        #expect(ImageFormat(detecting: encoded) == .jpeg)

        let decoded = try Image(data: encoded)
        #expect(decoded.width == original.width)
        #expect(decoded.height == original.height)
        #expect(decoded.pixels.allSatisfy { $0.alpha == 255 })
        #expect(maximumChannelError(original, decoded) <= 16)
    }

    @Test func jpegHandlesDimensionsThatAreNotMultiplesOfEight() throws {
        let original = makeSmoothTestImage(width: 13, height: 9)
        let decoded = try Image(data: original.encoded(as: .jpeg))
        #expect(decoded.width == 13)
        #expect(decoded.height == 9)
        #expect(maximumChannelError(original, decoded) <= 16)
    }

    @Test func jpegQualityOptionControlsSizeAndFidelity() throws {
        let original = makeSmoothTestImage()
        let low = try original.encoded(as: .jpeg, options: EncodingOptions(jpegQuality: 20))
        let high = try original.encoded(as: .jpeg, options: EncodingOptions(jpegQuality: 95))
        #expect(low.count < high.count)

        let lowError = maximumChannelError(original, try Image(data: low))
        let highError = maximumChannelError(original, try Image(data: high))
        #expect(highError <= lowError)
        #expect(highError <= 8)
    }

    #if canImport(ImageIO)
    @Test func decodesProgressiveJPEG() throws {
        // ImageIO writes a real multi-scan progressive JPEG (SOF2 with
        // spectral selection and successive approximation) when asked.
        let original = makeSmoothTestImage(width: 40, height: 28)
        var pixelData = [UInt8](repeating: 0, count: original.width * original.height * 4)
        for y in 0..<original.height {
            for x in 0..<original.width {
                let pixel = original[x, y]
                let i = (y * original.width + x) * 4
                pixelData[i] = pixel.red
                pixelData[i + 1] = pixel.green
                pixelData[i + 2] = pixel.blue
                pixelData[i + 3] = 255
            }
        }
        let context = try #require(CGContext(
            data: &pixelData,
            width: original.width,
            height: original.height,
            bitsPerComponent: 8,
            bytesPerRow: original.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try #require(context.makeImage())

        let progressiveData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            progressiveData, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true],
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        // Make sure ImageIO actually produced a progressive file (SOF2).
        let bytes = [UInt8](progressiveData as Data)
        var sawProgressiveFrame = false
        for i in 0..<(bytes.count - 1) where bytes[i] == 0xFF && bytes[i + 1] == 0xC2 {
            sawProgressiveFrame = true
        }
        #expect(sawProgressiveFrame)

        let decoded = try Image(data: progressiveData as Data)
        #expect(decoded.width == original.width)
        #expect(decoded.height == original.height)
        #expect(maximumChannelError(original, decoded) <= 32)
    }

    @Test func jpegInteroperatesWithImageIO() throws {
        let original = makeSmoothTestImage()

        // Our encoder → Apple's decoder.
        let encoded = try original.encoded(as: .jpeg)
        let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
        let cgImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cgImage.width == original.width)
        #expect(cgImage.height == original.height)

        var pixelData = [UInt8](repeating: 0, count: original.width * original.height * 4)
        let context = try #require(CGContext(
            data: &pixelData,
            width: original.width,
            height: original.height,
            bitsPerComponent: 8,
            bytesPerRow: original.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))

        var appleDecoded = Image(width: original.width, height: original.height)
        for y in 0..<original.height {
            for x in 0..<original.width {
                let i = (y * original.width + x) * 4
                appleDecoded[x, y] = RGBA(red: pixelData[i], green: pixelData[i + 1], blue: pixelData[i + 2])
            }
        }
        #expect(maximumChannelError(original, appleDecoded) <= 24)

        // Apple's encoder → our decoder (typically exercises chroma subsampling).
        let appleData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            appleData, UTType.jpeg.identifier as CFString, 1, nil
        ))
        let sourceImage = try #require(context.makeImage())  // context still holds Apple's decode of our file
        CGImageDestinationAddImage(destination, sourceImage, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let redecoded = try Image(data: appleData as Data)
        #expect(redecoded.width == original.width)
        #expect(redecoded.height == original.height)
        #expect(maximumChannelError(original, redecoded) <= 32)
    }

    @Test func decodesGrayscaleJPEGFromImageIO() throws {
        let width = 32
        let height = 16
        var grayData = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                grayData[y * width + x] = UInt8(min(255, x * 6 + y * 4))
            }
        }
        let context = try #require(CGContext(
            data: &grayData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        let cgImage = try #require(context.makeImage())

        let jpegData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            jpegData, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let decoded = try Image(data: jpegData as Data)
        #expect(decoded.width == width)
        #expect(decoded.height == height)
        var maximumError = 0
        for y in 0..<height {
            for x in 0..<width {
                let pixel = decoded[x, y]
                #expect(pixel.red == pixel.green)
                #expect(pixel.green == pixel.blue)
                maximumError = max(maximumError, abs(Int(pixel.red) - Int(grayData[y * width + x])))
            }
        }
        #expect(maximumError <= 16)
    }
    #endif

    // MARK: GIF

    @Test func gifRoundTripOfPalettedImage() throws {
        let original = makePalettedTestImage()
        let encoded = try original.encoded(as: .gif)
        #expect(ImageFormat(detecting: encoded) == .gif)
        #expect(try Image(data: encoded) == original)
    }

    @Test func gifQuantizesRichImages() throws {
        // Thousands of unique colors force median-cut quantization; the round
        // trip is lossy but colors should stay close.
        var image = Image(width: 64, height: 64)
        for y in 0..<image.height {
            for x in 0..<image.width {
                image[x, y] = RGBA(red: UInt8(x * 4), green: UInt8(y * 4), blue: UInt8((x + y) * 2))
            }
        }
        let decoded = try Image(data: image.encoded(as: .gif))
        #expect(decoded.width == 64)
        #expect(decoded.height == 64)
        #expect(decoded.pixels.allSatisfy { $0.alpha == 255 })
        #expect(maximumChannelError(image, decoded) <= 64)
    }

    @Test func decodesInterlacedGIF() throws {
        // Hand-built 3×5 interlaced GIF. Row y is filled with palette index y;
        // interlacing stores the rows in the order 0, 4, 2, 1, 3.
        var writer = ByteWriter()
        writer.writeBytes(Array("GIF89a".utf8))
        writer.writeUInt16LittleEndian(3)
        writer.writeUInt16LittleEndian(5)
        writer.writeByte(0x80 | 0x02)  // global color table, 8 entries
        writer.writeByte(0)
        writer.writeByte(0)
        for i in 0..<8 {
            let value = UInt8(i * 30)
            writer.writeBytes([value, value, value])
        }
        writer.writeByte(0x2C)  // image descriptor
        writer.writeUInt16LittleEndian(0)
        writer.writeUInt16LittleEndian(0)
        writer.writeUInt16LittleEndian(3)
        writer.writeUInt16LittleEndian(5)
        writer.writeByte(0x40)  // interlaced, no local table

        let storedIndices = [0, 0, 0, 4, 4, 4, 2, 2, 2, 1, 1, 1, 3, 3, 3]
        let compressed = GIFLZW.compress(storedIndices, minimumCodeSize: 3)
        writer.writeByte(3)  // LZW minimum code size
        writer.writeByte(UInt8(compressed.count))
        writer.writeBytes(compressed)
        writer.writeByte(0)  // sub-block terminator
        writer.writeByte(0x3B)  // trailer

        let image = try Image(data: writer.data)
        for y in 0..<5 {
            let value = UInt8(y * 30)
            for x in 0..<3 {
                #expect(image[x, y] == RGBA(red: value, green: value, blue: value), "pixel (\(x), \(y))")
            }
        }
    }

    #if canImport(ImageIO)
    @Test func gifInteroperatesWithImageIO() throws {
        let original = makePalettedTestImage()
        let encoded = try original.encoded(as: .gif)

        // Our encoder → Apple's decoder.
        let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
        let cgImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cgImage.width == original.width)
        #expect(cgImage.height == original.height)

        var pixelData = [UInt8](repeating: 0, count: original.width * original.height * 4)
        let context = try #require(CGContext(
            data: &pixelData,
            width: original.width,
            height: original.height,
            bitsPerComponent: 8,
            bytesPerRow: original.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))

        var appleDecodeMismatches = 0
        for y in 0..<original.height {
            for x in 0..<original.width {
                let expected = original[x, y]
                let i = (y * original.width + x) * 4
                if pixelData[i] != expected.red || pixelData[i + 1] != expected.green
                    || pixelData[i + 2] != expected.blue || pixelData[i + 3] != expected.alpha {
                    appleDecodeMismatches += 1
                }
            }
        }
        #expect(appleDecodeMismatches == 0)

        // Apple's encoder → our decoder. ImageIO may requantize, so compare
        // transparency exactly and colors only for opaque pixels.
        let appleData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            appleData, UTType.gif.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))

        let redecoded = try Image(data: appleData as Data)
        #expect(redecoded.width == original.width)
        #expect(redecoded.height == original.height)
        var ourDecodeMismatches = 0
        for (expected, actual) in zip(original.pixels, redecoded.pixels) {
            let expectedTransparent = expected.alpha == 0
            let actualTransparent = actual.alpha == 0
            if expectedTransparent != actualTransparent {
                ourDecodeMismatches += 1
            } else if !expectedTransparent && expected != actual {
                ourDecodeMismatches += 1
            }
        }
        #expect(ourDecodeMismatches == 0)
    }
    #endif

    // MARK: TIFF

    @Test func tiffDecodesPackBitsGrayscale() throws {
        // Hand-built 4×2 grayscale TIFF, PackBits-compressed:
        // a run of four 10s, then the literals 1 2 3 4.
        var writer = ByteWriter()
        writer.writeBytes([0x49, 0x49, 42, 0])
        writer.writeUInt32LittleEndian(16)  // IFD offset (8 header + 7 data + 1 pad)
        writer.writeBytes([0xFD, 10, 0x03, 1, 2, 3, 4])
        writer.writeByte(0)  // pad

        writer.writeUInt16LittleEndian(9)
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
        entry(256, 4, 4)      // width
        entry(257, 4, 2)      // height
        entry(258, 3, 8)      // bits per sample
        entry(259, 3, 32773)  // PackBits
        entry(262, 3, 1)      // min is black
        entry(273, 4, 8)      // strip offset
        entry(277, 3, 1)      // samples per pixel
        entry(278, 4, 2)      // rows per strip
        entry(279, 4, 7)      // strip byte count
        writer.writeUInt32LittleEndian(0)

        let image = try Image(data: writer.data)
        #expect(image.width == 4)
        #expect(image.height == 2)
        #expect(image[0, 0] == RGBA(red: 10, green: 10, blue: 10))
        #expect(image[3, 0] == RGBA(red: 10, green: 10, blue: 10))
        #expect(image[0, 1] == RGBA(red: 1, green: 1, blue: 1))
        #expect(image[3, 1] == RGBA(red: 4, green: 4, blue: 4))
    }

    @Test func tiffDecodesDeflateCompressedRGB() throws {
        // Hand-built 3×1 RGB TIFF with a zlib-compressed strip.
        let compressed = Deflate.zlibCompress([255, 0, 0, 0, 255, 0, 0, 0, 255])
        let ifdOffset = 8 + compressed.count + (compressed.count & 1)

        var writer = ByteWriter()
        writer.writeBytes([0x49, 0x49, 42, 0])
        writer.writeUInt32LittleEndian(UInt32(ifdOffset))
        writer.writeBytes(compressed)
        if compressed.count & 1 == 1 {
            writer.writeByte(0)
        }
        writer.writeUInt16LittleEndian(9)
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
        entry(277, 3, 3)  // samples per pixel
        entry(278, 4, 1)  // rows per strip
        entry(279, 4, compressed.count)
        writer.writeUInt32LittleEndian(0)

        let image = try Image(data: writer.data)
        #expect(image[0, 0] == RGBA(red: 255, green: 0, blue: 0))
        #expect(image[1, 0] == RGBA(red: 0, green: 255, blue: 0))
        #expect(image[2, 0] == RGBA(red: 0, green: 0, blue: 255))
    }

    #if canImport(ImageIO)
    @Test func tiffInteroperatesWithImageIO() throws {
        let original = opaque(makeTestImage())

        // Our encoder → Apple's decoder.
        let encoded = try original.encoded(as: .tiff)
        let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
        let cgImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cgImage.width == original.width)
        #expect(cgImage.height == original.height)

        var pixelData = [UInt8](repeating: 0, count: original.width * original.height * 4)
        let context = try #require(CGContext(
            data: &pixelData,
            width: original.width,
            height: original.height,
            bitsPerComponent: 8,
            bytesPerRow: original.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        var mismatches = 0
        for y in 0..<original.height {
            for x in 0..<original.width {
                let expected = original[x, y]
                let i = (y * original.width + x) * 4
                if pixelData[i] != expected.red || pixelData[i + 1] != expected.green
                    || pixelData[i + 2] != expected.blue {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0)

        // Apple's LZW-compressed TIFF → our decoder, still lossless.
        let appleData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            appleData, UTType.tiff.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let redecoded = try Image(data: appleData as Data)
        #expect(redecoded == original)
    }
    #endif

    // MARK: WebP

    #if canImport(ImageIO)
    @Test func webpIsReadableByImageIO() throws {
        let original = opaque(makeTestImage())
        let encoded = try original.encoded(as: .webp)
        #expect(ImageFormat(detecting: encoded) == .webp)

        let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
        let cgImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cgImage.width == original.width)
        #expect(cgImage.height == original.height)

        var pixelData = [UInt8](repeating: 0, count: original.width * original.height * 4)
        let context = try #require(CGContext(
            data: &pixelData,
            width: original.width,
            height: original.height,
            bitsPerComponent: 8,
            bytesPerRow: original.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        var mismatches = 0
        for y in 0..<original.height {
            for x in 0..<original.width {
                let expected = original[x, y]
                let i = (y * original.width + x) * 4
                if pixelData[i] != expected.red || pixelData[i + 1] != expected.green
                    || pixelData[i + 2] != expected.blue {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0)
    }
    #endif

    /// Wraps a VP8L bitstream in a RIFF/WebP container.
    private func wrapVP8L(_ bits: BitWriter) -> Data {
        var mutableBits = bits
        var payload: [UInt8] = [0x2F]
        payload += mutableBits.finish()
        var writer = ByteWriter()
        writer.writeBytes(Array("RIFF".utf8))
        writer.writeUInt32LittleEndian(UInt32(4 + 8 + payload.count + (payload.count & 1)))
        writer.writeBytes(Array("WEBP".utf8))
        writer.writeBytes(Array("VP8L".utf8))
        writer.writeUInt32LittleEndian(UInt32(payload.count))
        writer.writeBytes(payload)
        if payload.count & 1 == 1 {
            writer.writeByte(0)
        }
        return writer.data
    }

    @Test func webpDecodesSubtractGreenCacheAndBackReferences() throws {
        // Hand-built 4×1 VP8L stream: subtract-green transform, a 16-entry
        // color cache, one literal, one cache hit and one LZ77 copy of
        // length 2 at distance 1 (distance code 121 = plain distance 1).
        let literal: UInt32 = 0xFF0A_141E  // a 255, r 10, g 20, b 30 (residual domain)
        let cacheIndex = Int((0x1E35_A7BD as UInt32 &* literal) >> 28)

        var bits = BitWriter()
        bits.writeBits(3, count: 14)  // width 4
        bits.writeBits(0, count: 14)  // height 1
        bits.writeBits(0, count: 1)   // alpha hint
        bits.writeBits(0, count: 3)   // version
        bits.writeBits(1, count: 1)
        bits.writeBits(2, count: 2)   // subtract-green transform
        bits.writeBits(0, count: 1)   // no more transforms
        bits.writeBits(1, count: 1)
        bits.writeBits(4, count: 4)   // color cache with 16 entries
        bits.writeBits(0, count: 1)   // no meta prefix groups

        // Green code (alphabet 296): lengths {20: 2, 257: 2, 280+cacheIndex: 1},
        // written with a code-length code over {1, 2, 17, 18}, all two bits:
        // canonical codes 1→00, 2→01, 17→10, 18→11.
        bits.writeBits(0, count: 1)   // not simple
        bits.writeBits(1, count: 4)   // five code-length code lengths (17, 18, 0, 1, 2)
        for length in [2, 2, 0, 2, 2] {
            bits.writeBits(length, count: 3)
        }
        bits.writeBits(1, count: 1)   // explicit symbol budget
        bits.writeBits(3, count: 3)   // budget field is 8 bits wide
        bits.writeBits(5, count: 8)   // budget 7 = 2 + 5 code-length symbols
        bits.writeCode(0b11, length: 2)
        bits.writeBits(9, count: 7)   // 18: twenty zeros (symbols 0-19)
        bits.writeCode(0b01, length: 2)  // symbol 20 gets length 2
        bits.writeCode(0b11, length: 2)
        bits.writeBits(127, count: 7)  // 18: 138 zeros
        bits.writeCode(0b11, length: 2)
        bits.writeBits(87, count: 7)   // 18: 98 more zeros (symbols 21-256)
        bits.writeCode(0b01, length: 2)  // symbol 257 gets length 2
        bits.writeCode(0b11, length: 2)
        bits.writeBits(11 + cacheIndex, count: 7)  // 18: zeros up to the cache symbol
        bits.writeCode(0b00, length: 2)  // symbol 280+cacheIndex gets length 1

        // Red, blue, alpha: single-symbol simple codes (10, 30, 255).
        for value in [10, 30, 255] {
            bits.writeBits(1, count: 1)
            bits.writeBits(0, count: 1)
            bits.writeBits(1, count: 1)
            bits.writeBits(value, count: 8)
        }
        // Distance: single-symbol simple code, symbol 13.
        bits.writeBits(1, count: 1)
        bits.writeBits(0, count: 1)
        bits.writeBits(1, count: 1)
        bits.writeBits(13, count: 8)

        // Canonical green codes: cache symbol → 0, literal 20 → 10, length 257 → 11.
        bits.writeCode(0b10, length: 2)  // literal pixel
        bits.writeCode(0b0, length: 1)   // cache hit
        bits.writeCode(0b11, length: 2)  // match, length 2
        bits.writeBits(24, count: 5)     // distance extra bits: 97 + 24 = code 121

        let image = try Image(data: wrapVP8L(bits))
        #expect(image.width == 4)
        #expect(image.height == 1)
        for x in 0..<4 {
            // Subtract-green inverse: r = 10+20, b = 30+20.
            #expect(image[x, 0] == RGBA(red: 30, green: 20, blue: 50), "pixel \(x)")
        }
    }

    @Test func webpDecodesPredictorTransform() throws {
        // Hand-built 2×2 VP8L stream with a predictor transform (one block,
        // mode 7 = Average2(L, T)); the borders use the black, L and T rules.
        var bits = BitWriter()
        bits.writeBits(1, count: 14)  // width 2
        bits.writeBits(1, count: 14)  // height 2
        bits.writeBits(0, count: 1)
        bits.writeBits(0, count: 3)
        bits.writeBits(1, count: 1)
        bits.writeBits(0, count: 2)   // predictor transform
        bits.writeBits(0, count: 3)   // block bits 2 → a single block
        // Sub-image (1×1): no cache; green single(7) = mode 7, others single(0).
        bits.writeBits(0, count: 1)   // no color cache
        bits.writeBits(1, count: 1)   // green: simple
        bits.writeBits(0, count: 1)   // one symbol
        bits.writeBits(1, count: 1)   // eight bits
        bits.writeBits(7, count: 8)   // mode 7
        for _ in 0..<4 {              // red, blue, alpha, distance: single symbol 0
            bits.writeBits(1, count: 1)
            bits.writeBits(0, count: 1)
            bits.writeBits(0, count: 1)
            bits.writeBits(0, count: 1)
        }
        bits.writeBits(0, count: 1)   // end of transforms
        bits.writeBits(0, count: 1)   // no color cache
        bits.writeBits(0, count: 1)   // no meta prefix groups
        // Main image residuals: greens {3, 10}, reds {1, 2}, blue single 2, alpha single 0.
        bits.writeBits(1, count: 1)   // green: simple, two symbols
        bits.writeBits(1, count: 1)
        bits.writeBits(1, count: 1)
        bits.writeBits(3, count: 8)
        bits.writeBits(10, count: 8)
        bits.writeBits(1, count: 1)   // red: simple, two symbols
        bits.writeBits(1, count: 1)
        bits.writeBits(1, count: 1)
        bits.writeBits(1, count: 8)
        bits.writeBits(2, count: 8)
        bits.writeBits(1, count: 1)   // blue: single symbol 2
        bits.writeBits(0, count: 1)
        bits.writeBits(1, count: 1)
        bits.writeBits(2, count: 8)
        bits.writeBits(1, count: 1)   // alpha: single symbol 0
        bits.writeBits(0, count: 1)
        bits.writeBits(0, count: 1)
        bits.writeBits(0, count: 1)
        bits.writeBits(1, count: 1)   // distance: single symbol 0
        bits.writeBits(0, count: 1)
        bits.writeBits(0, count: 1)
        bits.writeBits(0, count: 1)
        // Residuals (canonical: green 3→0, 10→1; red 1→0, 2→1):
        bits.writeCode(1, length: 1)  // P(0,0): g 10
        bits.writeCode(0, length: 1)  //          r 1
        bits.writeCode(1, length: 1)  // P(1,0): g 10
        bits.writeCode(0, length: 1)  //          r 1
        bits.writeCode(0, length: 1)  // P(0,1): g 3
        bits.writeCode(1, length: 1)  //          r 2
        bits.writeCode(0, length: 1)  // P(1,1): g 3
        bits.writeCode(0, length: 1)  //          r 1

        let image = try Image(data: wrapVP8L(bits))
        #expect(image.width == 2)
        #expect(image.height == 2)
        #expect(image[0, 0] == RGBA(red: 1, green: 10, blue: 2))    // black predictor
        #expect(image[1, 0] == RGBA(red: 2, green: 20, blue: 4))    // L predictor
        #expect(image[0, 1] == RGBA(red: 3, green: 13, blue: 4))    // T predictor
        #expect(image[1, 1] == RGBA(red: 3, green: 19, blue: 6))    // mode 7: Average2(L, T)
    }

    // MARK: Other formats

    @Test func decodingGarbageFails() {
        #expect(throws: ImageError.unknownFormat) {
            _ = try Image(data: Data([0x00, 0x01, 0x02, 0x03, 0x04]))
        }
    }

    @Test func decodingTruncatedPNGFails() throws {
        let encoded = try makeTestImage().encoded(as: .png)
        #expect(throws: ImageError.self) {
            _ = try Image(data: encoded.prefix(encoded.count / 2))
        }
    }

    @Test func decodesGrayscalePGM() throws {
        let header = Array("P5\n# a comment\n3 2\n255\n".utf8)
        let samples: [UInt8] = [0, 128, 255, 10, 20, 30]
        let image = try Image(data: Data(header + samples))
        #expect(image.width == 3)
        #expect(image.height == 2)
        #expect(image[1, 0] == RGBA(red: 128, green: 128, blue: 128))
        #expect(image[2, 1] == RGBA(red: 30, green: 30, blue: 30))
    }

    @Test func decodes32BitBMPTreatingZeroAlphaAsOpaque() throws {
        // Hand-built 1×1, 32-bit BMP whose alpha byte is zero — the common
        // "no alpha channel" convention, which should decode as opaque.
        var writer = ByteWriter()
        writer.writeBytes([0x42, 0x4D])
        writer.writeUInt32LittleEndian(58)  // file size
        writer.writeUInt32LittleEndian(0)
        writer.writeUInt32LittleEndian(54)  // pixel data offset
        writer.writeUInt32LittleEndian(40)  // BITMAPINFOHEADER
        writer.writeInt32LittleEndian(1)
        writer.writeInt32LittleEndian(1)
        writer.writeUInt16LittleEndian(1)
        writer.writeUInt16LittleEndian(32)
        writer.writeUInt32LittleEndian(0)
        writer.writeUInt32LittleEndian(4)
        writer.writeInt32LittleEndian(2835)
        writer.writeInt32LittleEndian(2835)
        writer.writeUInt32LittleEndian(0)
        writer.writeUInt32LittleEndian(0)
        writer.writeBytes([10, 20, 30, 0])  // B G R A

        let image = try Image(data: writer.data)
        #expect(image[0, 0] == RGBA(red: 30, green: 20, blue: 10, alpha: 255))
    }

    private func writeChunk(_ type: String, _ data: [UInt8], to writer: inout ByteWriter) {
        let typeBytes = Array(type.utf8)
        writer.writeUInt32BigEndian(UInt32(data.count))
        writer.writeBytes(typeBytes)
        writer.writeBytes(data)
        writer.writeUInt32BigEndian(CRC32.checksum(of: typeBytes + data))
    }
}
