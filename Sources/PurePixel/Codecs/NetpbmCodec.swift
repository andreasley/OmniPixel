import Foundation

/// Netpbm binary formats: PGM (P5, grayscale) and PPM (P6, color).
///
/// Decoding supports 1- and 2-byte samples with any maximum value, scaled to
/// 8 bits. Encoding produces P6 with a maximum value of 255 (alpha is discarded).
enum NetpbmCodec: ImageCodec {
    static func canDecode(_ data: Data) -> Bool {
        let prefix = [UInt8](data.prefix(2))
        return prefix.count == 2
            && prefix[0] == UInt8(ascii: "P")
            && (prefix[1] == UInt8(ascii: "5") || prefix[1] == UInt8(ascii: "6"))
    }

    // MARK: Decoding

    static func decode(_ data: Data) throws -> Image {
        var reader = ByteReader(data)
        let magic = try reader.readBytes(2)
        guard magic[0] == UInt8(ascii: "P"),
              magic[1] == UInt8(ascii: "5") || magic[1] == UInt8(ascii: "6") else {
            throw ImageError.invalidData(reason: "Not a binary PGM/PPM file")
        }
        let isColor = magic[1] == UInt8(ascii: "6")

        let width = try readHeaderNumber(&reader)
        let height = try readHeaderNumber(&reader)
        let maximumValue = try readHeaderNumber(&reader)
        guard maximumValue > 0, maximumValue < 65536 else {
            throw ImageError.invalidData(reason: "Invalid Netpbm maximum sample value")
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, pixelCount <= Image.maxPixelCount else {
            throw ImageError.invalidData(reason: "Invalid Netpbm dimensions")
        }
        try reader.skip(1)  // exactly one whitespace byte separates the header from the raster

        let samplesPerPixel = isColor ? 3 : 1
        let bytesPerSample = maximumValue > 255 ? 2 : 1
        let raster = try reader.readBytes(pixelCount * samplesPerPixel * bytesPerSample)

        var pixels: [RGBA] = []
        pixels.reserveCapacity(pixelCount)
        var offset = 0

        // Reads one sample and scales it to 0...255.
        func readSample() -> UInt8 {
            var value = Int(raster[offset])
            offset += 1
            if bytesPerSample == 2 {
                value = value << 8 | Int(raster[offset])
                offset += 1
            }
            return UInt8(min(value, maximumValue) * 255 / maximumValue)
        }

        for _ in 0..<pixelCount {
            if isColor {
                let red = readSample()
                let green = readSample()
                let blue = readSample()
                pixels.append(RGBA(red: red, green: green, blue: blue))
            } else {
                let value = readSample()
                pixels.append(RGBA(red: value, green: value, blue: value))
            }
        }
        return Image(width: width, height: height, pixels: pixels)
    }

    /// Skips whitespace and "#" comments, then reads one decimal number.
    private static func readHeaderNumber(_ reader: inout ByteReader) throws -> Int {
        while let byte = reader.peek(1)?.first {
            if byte == UInt8(ascii: "#") {
                while let next = reader.peek(1)?.first, next != UInt8(ascii: "\n") {
                    try reader.skip(1)
                }
            } else if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                try reader.skip(1)
            } else {
                break
            }
        }
        var digits: [UInt8] = []
        while let byte = reader.peek(1)?.first, (0x30...0x39).contains(byte) {
            digits.append(byte)
            try reader.skip(1)
        }
        guard !digits.isEmpty, let value = Int(String(decoding: digits, as: UTF8.self)) else {
            throw ImageError.invalidData(reason: "Malformed Netpbm header")
        }
        return value
    }

    // MARK: Encoding

    static func encode(_ image: Image) throws -> Data {
        var writer = ByteWriter()
        writer.writeBytes(Array("P6\n\(image.width) \(image.height)\n255\n".utf8))
        for pixel in image.pixels {
            writer.writeBytes([pixel.red, pixel.green, pixel.blue])
        }
        return writer.data
    }
}
