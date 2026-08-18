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

    private func opaque(_ image: Image) -> Image {
        var result = image
        for y in 0..<result.height {
            for x in 0..<result.width {
                result[x, y].alpha = 255
            }
        }
        return result
    }

    @Test(arguments: [ImageFormat.png, .qoi])
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

        var maximumError = 0
        for (expected, actual) in zip(image.pixels, decoded.pixels) {
            maximumError = max(maximumError, abs(Int(expected.red) - Int(actual.red)))
            maximumError = max(maximumError, abs(Int(expected.green) - Int(actual.green)))
            maximumError = max(maximumError, abs(Int(expected.blue) - Int(actual.blue)))
        }
        #expect(maximumError <= 64)
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
