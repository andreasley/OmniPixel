import Foundation

/// QOI ("Quite OK Image" format, qoiformat.org) — simple lossless RGBA.
enum QOICodec: ImageCodec {
    private static let magic: [UInt8] = [0x71, 0x6F, 0x69, 0x66]  // "qoif"
    private static let endMarker: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 1]

    static func canDecode(_ data: Data) -> Bool {
        data.count >= magic.count && [UInt8](data.prefix(magic.count)) == magic
    }

    private static func hash(_ pixel: RGBA) -> Int {
        (Int(pixel.red) * 3 + Int(pixel.green) * 5 + Int(pixel.blue) * 7 + Int(pixel.alpha) * 11) % 64
    }

    // MARK: Decoding

    static func decode(_ data: Data) throws -> Image {
        var reader = ByteReader(data)
        guard try reader.readBytes(4) == magic else {
            throw ImageError.invalidData(reason: "Missing QOI signature")
        }
        let width = Int(try reader.readUInt32BigEndian())
        let height = Int(try reader.readUInt32BigEndian())
        let channels = try reader.readByte()
        let colorspace = try reader.readByte()
        guard channels == 3 || channels == 4, colorspace <= 1 else {
            throw ImageError.invalidData(reason: "Invalid QOI header")
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, pixelCount <= Image.maxPixelCount else {
            throw ImageError.invalidData(reason: "Invalid QOI dimensions")
        }

        var pixels: [RGBA] = []
        // Bounded reservation: `pixelCount` is a header field and no payload
        // byte has been read yet. See the note in GIFLZW.decompress.
        pixels.reserveCapacity(min(pixelCount, 1 << 20))
        var recent = [RGBA](repeating: RGBA(red: 0, green: 0, blue: 0, alpha: 0), count: 64)
        var pixel = RGBA(red: 0, green: 0, blue: 0, alpha: 255)

        while pixels.count < pixelCount {
            let byte = try reader.readByte()
            if byte == 0xFE {  // QOI_OP_RGB
                pixel.red = try reader.readByte()
                pixel.green = try reader.readByte()
                pixel.blue = try reader.readByte()
            } else if byte == 0xFF {  // QOI_OP_RGBA
                pixel.red = try reader.readByte()
                pixel.green = try reader.readByte()
                pixel.blue = try reader.readByte()
                pixel.alpha = try reader.readByte()
            } else {
                switch byte >> 6 {
                case 0:  // QOI_OP_INDEX
                    pixel = recent[Int(byte & 0x3F)]
                case 1:  // QOI_OP_DIFF — two-bit channel deltas, bias 2, wrapping
                    pixel.red &+= ((byte >> 4) & 0x03) &- 2
                    pixel.green &+= ((byte >> 2) & 0x03) &- 2
                    pixel.blue &+= (byte & 0x03) &- 2
                case 2:  // QOI_OP_LUMA — green delta plus red/blue deltas relative to it
                    let greenDiff = (byte & 0x3F) &- 32
                    let detail = try reader.readByte()
                    pixel.red &+= greenDiff &- 8 &+ ((detail >> 4) & 0x0F)
                    pixel.green &+= greenDiff
                    pixel.blue &+= greenDiff &- 8 &+ (detail & 0x0F)
                default:  // QOI_OP_RUN — repeat the previous pixel
                    let runLength = Int(byte & 0x3F) + 1
                    guard pixels.count + runLength <= pixelCount else {
                        throw ImageError.invalidData(reason: "QOI run past end of image")
                    }
                    pixels.append(contentsOf: repeatElement(pixel, count: runLength))
                    continue
                }
            }
            recent[hash(pixel)] = pixel
            pixels.append(pixel)
        }

        guard try reader.readBytes(8) == endMarker else {
            throw ImageError.invalidData(reason: "Missing QOI end marker")
        }
        return Image(width: width, height: height, pixels: pixels)
    }

    // MARK: Encoding

    static func encode(_ image: Image) throws -> Data {
        guard let width = UInt32(exactly: image.width), let height = UInt32(exactly: image.height) else {
            throw ImageError.invalidDimensions
        }

        var writer = ByteWriter()
        writer.writeBytes(magic)
        writer.writeUInt32BigEndian(width)
        writer.writeUInt32BigEndian(height)
        writer.writeByte(4)  // RGBA
        writer.writeByte(0)  // sRGB with linear alpha

        var recent = [RGBA](repeating: RGBA(red: 0, green: 0, blue: 0, alpha: 0), count: 64)
        var previous = RGBA(red: 0, green: 0, blue: 0, alpha: 255)
        var runLength = 0

        for pixel in image.pixels {
            if pixel == previous {
                runLength += 1
                if runLength == 62 {  // longest run a single op can express
                    writer.writeByte(0xC0 | UInt8(runLength - 1))
                    runLength = 0
                }
                continue
            }
            if runLength > 0 {
                writer.writeByte(0xC0 | UInt8(runLength - 1))
                runLength = 0
            }

            let index = hash(pixel)
            if recent[index] == pixel {
                writer.writeByte(UInt8(index))
            } else {
                recent[index] = pixel
                if pixel.alpha == previous.alpha {
                    let redDiff = Int(Int8(truncatingIfNeeded: pixel.red &- previous.red))
                    let greenDiff = Int(Int8(truncatingIfNeeded: pixel.green &- previous.green))
                    let blueDiff = Int(Int8(truncatingIfNeeded: pixel.blue &- previous.blue))
                    if (-2...1).contains(redDiff), (-2...1).contains(greenDiff), (-2...1).contains(blueDiff) {
                        writer.writeByte(0x40 | UInt8(redDiff + 2) << 4 | UInt8(greenDiff + 2) << 2 | UInt8(blueDiff + 2))
                    } else if (-32...31).contains(greenDiff),
                              (-8...7).contains(redDiff - greenDiff),
                              (-8...7).contains(blueDiff - greenDiff) {
                        writer.writeByte(0x80 | UInt8(greenDiff + 32))
                        writer.writeByte(UInt8(redDiff - greenDiff + 8) << 4 | UInt8(blueDiff - greenDiff + 8))
                    } else {
                        writer.writeByte(0xFE)
                        writer.writeBytes([pixel.red, pixel.green, pixel.blue])
                    }
                } else {
                    writer.writeByte(0xFF)
                    writer.writeBytes([pixel.red, pixel.green, pixel.blue, pixel.alpha])
                }
            }
            previous = pixel
        }
        if runLength > 0 {
            writer.writeByte(0xC0 | UInt8(runLength - 1))
        }

        writer.writeBytes(endMarker)
        return writer.data
    }
}
