import Foundation
import OmniPixel

/// Assembles PNG files from the spec rather than from our own encoder, and
/// derives independently what they must decode to.
///
/// Two things make this useful. The IDAT is a *stored* zlib stream, so a file
/// can carry arbitrary bytes without going through our compressor — the
/// decoder is tested on its own. And nothing here shares code with
/// `PNGCodec`, so a misreading of the spec mirrored in the decoder cannot hide
/// behind a matching mistake in the fixture.
enum PNGBuilder {

    // MARK: Container

    static func bigEndian(_ value: Int) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }

    /// A zlib stream of stored (uncompressed) DEFLATE blocks.
    static func storedZlib(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = [0x78, 0x01]
        var start = 0
        repeat {
            let size = min(65535, input.count - start)
            output.append(start + size == input.count ? 1 : 0)  // BFINAL; BTYPE 00 = stored
            output.append(UInt8(size & 0xFF))
            output.append(UInt8(size >> 8))
            output.append(UInt8(~size & 0xFF))
            output.append(UInt8((~size >> 8) & 0xFF))
            output += input[start..<start + size]
            start += size
        } while start < input.count
        let checksum = adler32(input)
        output += bigEndian(Int(checksum))
        return output
    }

    static func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        return bigEndian(payload.count) + typeBytes + payload + bigEndian(Int(crc32(typeBytes + payload)))
    }

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Rewrites every chunk's CRC, so a mutation reaches the decoding logic
    /// instead of bouncing off the integrity check.
    static func repairingCRCs(_ bytes: [UInt8]) -> [UInt8] {
        var bytes = bytes
        var offset = signature.count
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 0, offset + 12 + length <= bytes.count else { return bytes }
            let crc = crc32(Array(bytes[(offset + 4)..<(offset + 8 + length)]))
            for (index, byte) in bigEndian(Int(crc)).enumerated() {
                bytes[offset + 8 + length + index] = byte
            }
            offset += 12 + length
        }
        return bytes
    }

    // MARK: Image description

    struct Layout {
        var width: Int
        var height: Int
        var bitDepth: Int
        var colorType: Int
        var interlaced: Bool

        var channels: Int {
            switch colorType {
            case 0, 3: 1
            case 4: 2
            case 2: 3
            default: 4
            }
        }

        var bitsPerPixel: Int { bitDepth * channels }
        var maxSample: Int { (1 << bitDepth) - 1 }
        var paletteEntryCount: Int { min(256, 1 << bitDepth) }
    }

    /// Every colour type paired with the bit depths the spec allows it.
    static let validCombinations: [(colorType: Int, bitDepth: Int)] = [
        (0, 1), (0, 2), (0, 4), (0, 8), (0, 16),
        (2, 8), (2, 16),
        (3, 1), (3, 2), (3, 4), (3, 8),
        (4, 8), (4, 16),
        (6, 8), (6, 16),
    ]

    static func palette(entryCount: Int) -> [RGBA] {
        (0..<entryCount).map { index in
            RGBA(
                red: UInt8((index * 37) % 256),
                green: UInt8((index * 91 + 11) % 256),
                blue: UInt8((index * 143 + 7) % 256)
            )
        }
    }

    /// A deterministic sample value in `0...maxSample`.
    static func sample(x: Int, y: Int, channel: Int, maxSample: Int) -> Int {
        let mixed = (x * 7 + y * 13 + channel * 29 + x * y * 3) & 0xFFFF
        return mixed % (maxSample + 1)
    }

    /// Reduces a full-precision sample to eight bits, as the spec prescribes.
    private static func scaled(_ value: Int, bitDepth: Int, maxSample: Int) -> UInt8 {
        switch bitDepth {
        case 16: UInt8(value >> 8)
        case 8: UInt8(value)
        default: UInt8(value * 255 / maxSample)
        }
    }

    /// The image a file of these samples must decode to, derived from the spec
    /// and not from the decoder.
    static func expectedImage(_ layout: Layout) -> Image {
        let colors = palette(entryCount: layout.paletteEntryCount)
        var image = Image(width: layout.width, height: layout.height)
        for y in 0..<layout.height {
            for x in 0..<layout.width {
                func value(_ channel: Int) -> Int {
                    sample(x: x, y: y, channel: channel, maxSample: layout.maxSample)
                }
                func eightBit(_ channel: Int) -> UInt8 {
                    scaled(value(channel), bitDepth: layout.bitDepth, maxSample: layout.maxSample)
                }
                switch layout.colorType {
                case 0:
                    let gray = eightBit(0)
                    image[x, y] = RGBA(red: gray, green: gray, blue: gray)
                case 2:
                    image[x, y] = RGBA(red: eightBit(0), green: eightBit(1), blue: eightBit(2))
                case 3:
                    image[x, y] = colors[value(0) % colors.count]
                case 4:
                    let gray = eightBit(0)
                    image[x, y] = RGBA(red: gray, green: gray, blue: gray, alpha: eightBit(1))
                default:
                    image[x, y] = RGBA(
                        red: eightBit(0), green: eightBit(1), blue: eightBit(2), alpha: eightBit(3)
                    )
                }
            }
        }
        return image
    }

    // MARK: Rows

    /// Packs samples at the given bit depth, most significant bits first.
    private static func packed(_ samples: [Int], bitDepth: Int) -> [UInt8] {
        switch bitDepth {
        case 16:
            return samples.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        case 8:
            return samples.map { UInt8($0) }
        default:
            var row = [UInt8](repeating: 0, count: (samples.count * bitDepth + 7) / 8)
            for (index, value) in samples.enumerated() {
                let bitPosition = index * bitDepth
                row[bitPosition / 8] |= UInt8(value << (8 - bitDepth - bitPosition % 8))
            }
            return row
        }
    }

    private static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a)
        let pb = abs(p - b)
        let pc = abs(p - c)
        if pa <= pb && pa <= pc { return a }
        if pb <= pc { return b }
        return c
    }

    private static func filtered(
        row: [UInt8], previous: [UInt8], type: Int, distance: Int
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: row.count)
        for i in row.indices {
            let left = i >= distance ? Int(row[i - distance]) : 0
            let above = Int(previous[i])
            let aboveLeft = i >= distance ? Int(previous[i - distance]) : 0
            let prediction: Int
            switch type {
            case 0: prediction = 0
            case 1: prediction = left
            case 2: prediction = above
            case 3: prediction = (left + above) / 2
            default: prediction = paeth(left, above, aboveLeft)
            }
            output[i] = UInt8((Int(row[i]) - prediction) & 0xFF)
        }
        return output
    }

    /// Origin and step of the pixel grid each Adam7 pass covers.
    private static let adam7: [(xStart: Int, yStart: Int, xStep: Int, yStep: Int)] = [
        (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
        (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2),
    ]

    /// The filtered byte stream for a layout. `filterType` of nil cycles all
    /// five across the rows, so one file exercises every predictor.
    static func rawStream(_ layout: Layout, filterType: Int?) -> [UInt8] {
        let distance = max(1, layout.bitsPerPixel / 8)
        let passes = layout.interlaced ? adam7 : [(xStart: 0, yStart: 0, xStep: 1, yStep: 1)]

        var raw: [UInt8] = []
        var rowCounter = 0
        for pass in passes {
            let passWidth = pass.xStart < layout.width
                ? (layout.width - pass.xStart + pass.xStep - 1) / pass.xStep
                : 0
            let passHeight = pass.yStart < layout.height
                ? (layout.height - pass.yStart + pass.yStep - 1) / pass.yStep
                : 0
            guard passWidth > 0, passHeight > 0 else { continue }

            var previous = [UInt8](repeating: 0, count: (passWidth * layout.bitsPerPixel + 7) / 8)
            for rowIndex in 0..<passHeight {
                let y = pass.yStart + rowIndex * pass.yStep
                var samples: [Int] = []
                samples.reserveCapacity(passWidth * layout.channels)
                for column in 0..<passWidth {
                    let x = pass.xStart + column * pass.xStep
                    for channel in 0..<layout.channels {
                        samples.append(sample(x: x, y: y, channel: channel, maxSample: layout.maxSample))
                    }
                }
                let row = packed(samples, bitDepth: layout.bitDepth)
                let type = filterType ?? (rowCounter % 5)
                rowCounter += 1
                raw.append(UInt8(type))
                raw += filtered(row: row, previous: previous, type: type, distance: distance)
                previous = row
            }
        }
        return raw
    }

    /// Wraps an arbitrary raw stream in a well-formed container: correct CRCs
    /// and a matching Adler-32, so nothing rejects the file before the
    /// unfiltering and pixel conversion run.
    static func file(_ layout: Layout, raw: [UInt8]) -> [UInt8] {
        var bytes = signature
        var header = bigEndian(layout.width) + bigEndian(layout.height)
        header += [
            UInt8(layout.bitDepth), UInt8(layout.colorType), 0, 0, layout.interlaced ? 1 : 0,
        ]
        bytes += chunk("IHDR", header)
        if layout.colorType == 3 {
            bytes += chunk(
                "PLTE",
                palette(entryCount: layout.paletteEntryCount).flatMap { [$0.red, $0.green, $0.blue] }
            )
        }
        bytes += chunk("IDAT", storedZlib(raw))
        bytes += chunk("IEND", [])
        return bytes
    }

    /// A complete, valid file for a layout.
    static func file(_ layout: Layout, filterType: Int?) -> [UInt8] {
        file(layout, raw: rawStream(layout, filterType: filterType))
    }
}
