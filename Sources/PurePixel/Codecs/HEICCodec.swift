import Dispatch
import Foundation

/// HEIC/HEIF (ISO Base Media File Format container with an HEVC payload).
///
/// The container layer is fully implemented: the primary item, its `hvcC`
/// decoder configuration and its NAL units are located and extracted, and
/// the H.265 parameter sets and slice headers are parsed. Reconstructing
/// pixels requires the HEVC entropy decoder (CABAC) and prediction stages,
/// which are being built milestone by milestone; until they land, decoding
/// throws `ImageError.unsupportedFeature` naming the exact missing stage.
enum HEICCodec: ImageCodec {
    /// HEIF brands carrying HEVC-coded still images.
    private static let heifBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"]

    static func canDecode(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        let bytes = [UInt8](data.prefix(min(data.count, 64)))
        guard Array(bytes[4..<8]) == Array("ftyp".utf8) else { return false }

        let boxSize = min(
            Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3]),
            bytes.count
        )
        guard boxSize >= 16 else { return false }

        // The major brand plus any compatible brand may mark the file as
        // HEIF; AVIF files share the container (and often list `mif1`) but
        // belong to the AVIF codec.
        var brands = [String(decoding: bytes[8..<12], as: UTF8.self)]
        var offset = 16
        while offset + 4 <= boxSize {
            brands.append(String(decoding: bytes[offset..<offset + 4], as: UTF8.self))
            offset += 4
        }
        if brands.contains(where: { $0 == "avif" || $0 == "avis" }) {
            return false
        }
        return brands.contains { heifBrands.contains($0) }
    }

    static func decode(_ data: Data) throws -> Image {
        guard canDecode(data) else {
            throw ImageError.invalidData(reason: "Missing HEIF file type box")
        }
        let container = try HEIFContainer(bytes: [UInt8](data))
        guard let primaryID = container.primaryItemID else {
            throw ImageError.invalidData(reason: "HEIC has no primary item")
        }
        if container.itemTypes[primaryID] == "grid" {
            return try decodeGrid(container: container, gridID: primaryID)
        }
        let stream = try makeStream(container: container, itemID: primaryID)
        return try decodeStream(stream)
    }

    /// Runs the full HEVC pipeline for one coded item.
    private static func decodeStream(_ stream: HEVCStream, applyOrientation: Bool = true) throws -> Image {
        let decoder = try HEVCPictureDecoder(sps: stream.sps, pps: stream.pps)
        let picture = try decoder.decodePicture(sliceNALUnits: stream.sliceNALUnits)
        var planes = HEVCReconstruction.reconstruct(picture: picture, sps: stream.sps, pps: stream.pps)
        HEVCLoopFilters.apply(to: &planes, picture: picture, sps: stream.sps)

        var image = convertToRGB(planes, stream: stream)
        if applyOrientation {
            image = oriented(image, quarterTurns: stream.rotationQuarterTurns, mirrorAxis: stream.mirrorAxis)
        }
        return image
    }

    private static func oriented(_ image: Image, quarterTurns: Int, mirrorAxis: Int?) -> Image {
        var image = image
        if quarterTurns > 0 {
            // irot counts 90° anti-clockwise turns.
            let rotation: Rotation = [.clockwise270, .clockwise180, .clockwise90][quarterTurns - 1]
            image = image.rotated(by: rotation)
        }
        if let axis = mirrorAxis {
            image = image.mirrored(across: axis == 0 ? .horizontal : .vertical)
        }
        return image
    }

    /// Decodes a tiled image: the primary `grid` item declares the layout
    /// and output size, and `dimg` references list the coded tiles in
    /// row-major order (ISO 23008-12 section 6.6.2.3).
    private static func decodeGrid(container: HEIFContainer, gridID: Int) throws -> Image {
        guard let payload = try container.itemData(for: gridID), payload.count >= 8 else {
            throw ImageError.invalidData(reason: "Corrupt HEIC grid configuration")
        }
        let rows = Int(payload[2]) + 1
        let columns = Int(payload[3]) + 1
        let fieldSize = payload[1] & 1 == 1 ? 4 : 2
        guard payload.count >= 4 + 2 * fieldSize else {
            throw ImageError.invalidData(reason: "Corrupt HEIC grid configuration")
        }
        func dimension(at offset: Int) -> Int {
            var value = 0
            for i in 0..<fieldSize {
                value = value << 8 | Int(payload[offset + i])
            }
            return value
        }
        let outputWidth = dimension(at: 4)
        let outputHeight = dimension(at: 4 + fieldSize)
        let (pixelCount, overflow) = outputWidth.multipliedReportingOverflow(by: outputHeight)
        guard outputWidth > 0, outputHeight > 0, !overflow, pixelCount <= Image.maxPixelCount else {
            throw ImageError.invalidData(reason: "Invalid HEIC grid dimensions")
        }

        let tileIDs = container.linkedItems(ofType: "dimg", from: gridID)
        guard tileIDs.count == rows * columns else {
            throw ImageError.invalidData(reason: "HEIC grid expects \(rows * columns) tiles but references \(tileIDs.count)")
        }

        // Tiles are independent HEVC pictures; decode them concurrently.
        // Orientation and clean-aperture cropping belong to the grid item,
        // so tiles contribute their raw pixels.
        let streams = try tileIDs.map { try makeStream(container: container, itemID: $0) }
        var results = [Result<Image, Error>?](repeating: nil, count: streams.count)
        results.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let output = buffer
            DispatchQueue.concurrentPerform(iterations: streams.count) { index in
                output[index] = Result { try decodeStream(streams[index], applyOrientation: false) }
            }
        }
        let tiles = try results.map { try $0!.get() }

        let tileWidth = tiles[0].width
        let tileHeight = tiles[0].height
        guard columns * tileWidth >= outputWidth, rows * tileHeight >= outputHeight else {
            throw ImageError.invalidData(reason: "HEIC grid tiles don't cover the image")
        }
        guard tiles.allSatisfy({ $0.width == tileWidth && $0.height == tileHeight }) else {
            throw ImageError.invalidData(reason: "HEIC grid tiles have inconsistent sizes")
        }

        var compositePixels = [RGBA](repeating: .black, count: outputWidth * outputHeight)
        for (index, tile) in tiles.enumerated() {
            let originX = (index % columns) * tileWidth
            let originY = (index / columns) * tileHeight
            guard originX < outputWidth, originY < outputHeight else { continue }
            let copyWidth = min(tileWidth, outputWidth - originX)
            for y in 0..<min(tileHeight, outputHeight - originY) {
                let source = y * tileWidth
                let destination = (originY + y) * outputWidth + originX
                compositePixels[destination..<destination + copyWidth] =
                    tile.pixels[source..<source + copyWidth]
            }
        }
        let composite = Image(width: outputWidth, height: outputHeight, pixels: compositePixels)

        var rotation = 0
        if let irot = container.property(ofType: "irot", forItem: gridID), let first = irot.first {
            rotation = Int(first & 0x03)
        }
        var mirror: Int?
        if let imir = container.property(ofType: "imir", forItem: gridID), let first = imir.first {
            mirror = Int(first & 0x01)
        }
        return oriented(composite, quarterTurns: rotation, mirrorAxis: mirror)
    }

    /// Crops the coded planes to the display window and converts YCbCr to
    /// RGB using the container-declared matrix and range. Chroma is
    /// upsampled bilinearly with the default HEVC siting (co-sited with the
    /// left luma column, centred vertically).
    private static func convertToRGB(_ planes: HEVCReconstructedPlanes, stream: HEVCStream) -> Image {
        // Matrix coefficients (ISO 23091-2): BT.709, BT.601 (SMPTE 170M /
        // BT.470BG) and BT.2020; everything else falls back to BT.601.
        let kr: Double
        let kb: Double
        switch stream.matrixCoefficients {
        case 1: (kr, kb) = (0.2126, 0.0722)
        case 9, 10: (kr, kb) = (0.2627, 0.0593)
        default: (kr, kb) = (0.299, 0.114)
        }

        // Chroma reaches the matrix at ×8 (bilinear quarters × halves), so
        // the coefficients carry a ÷8; limited range folds in the 255/224
        // chroma and 255/219 luma expansions.
        let chromaScale = (stream.fullRange ? 1.0 : 255.0 / 224.0) * 65536.0 / 8.0
        let greenWeight = 1 - kr - kb
        let crToRed = Int((2 * (1 - kr) * chromaScale).rounded())
        let cbToBlue = Int((2 * (1 - kb) * chromaScale).rounded())
        let crToGreen = Int((2 * (1 - kr) * kr / greenWeight * chromaScale).rounded())
        let cbToGreen = Int((2 * (1 - kb) * kb / greenWeight * chromaScale).rounded())
        var lumaTable = [Int](repeating: 0, count: 256)
        for value in 0..<256 {
            let scaled = stream.fullRange ? Double(value) : (Double(value) - 16) * 255 / 219
            lumaTable[value] = Int((scaled * 65536).rounded())
        }

        var pixels = [RGBA](repeating: .transparent, count: stream.displayWidth * stream.displayHeight)
        let chromaWidth = planes.chromaWidth

        // Chroma sampling must stay inside the display window: the coded
        // picture is padded with arbitrary samples that must not bleed into
        // the visible edge pixels.
        let chromaMaxX = (stream.displayLeft + stream.displayWidth - 1) >> 1
        let chromaMinY = stream.displayTop >> 1
        let chromaMaxY = (stream.displayTop + stream.displayHeight - 1) >> 1

        var cbRow = [Int](repeating: 0, count: stream.displayWidth)
        var crRow = [Int](repeating: 0, count: stream.displayWidth)

        for row in 0..<stream.displayHeight {
            let lumaY = row + stream.displayTop
            // Chroma rows sit midway between the two luma rows they cover:
            // luma row y maps to chroma position (2y − 1)/4, blended in
            // quarters between the enclosing chroma rows.
            let position4 = 2 * lumaY - 1
            let topRow = min(max(position4 >> 2, chromaMinY), chromaMaxY)
            let bottomRow = min(topRow + 1, chromaMaxY)
            let weight4 = min(max(position4 - 4 * topRow, 0), 4)
            let topBase = topRow * chromaWidth
            let bottomBase = bottomRow * chromaWidth

            for column in 0..<stream.displayWidth {
                let lumaX = column + stream.displayLeft
                let baseX = lumaX >> 1
                let leftCb = (4 - weight4) * Int(planes.cb[topBase + baseX])
                    + weight4 * Int(planes.cb[bottomBase + baseX])
                let leftCr = (4 - weight4) * Int(planes.cr[topBase + baseX])
                    + weight4 * Int(planes.cr[bottomBase + baseX])
                if lumaX & 1 == 0 {
                    cbRow[column] = leftCb * 2
                    crRow[column] = leftCr * 2
                } else {
                    // Odd columns sit halfway to the next chroma sample.
                    let rightX = min(baseX + 1, chromaMaxX)
                    cbRow[column] = leftCb
                        + (4 - weight4) * Int(planes.cb[topBase + rightX])
                        + weight4 * Int(planes.cb[bottomBase + rightX])
                    crRow[column] = leftCr
                        + (4 - weight4) * Int(planes.cr[topBase + rightX])
                        + weight4 * Int(planes.cr[bottomBase + rightX])
                }
            }

            let lumaRowBase = lumaY * planes.lumaWidth + stream.displayLeft
            let pixelRowBase = row * stream.displayWidth
            for column in 0..<stream.displayWidth {
                let luma = lumaTable[Int(planes.luma[lumaRowBase + column])]
                let cb8 = cbRow[column] - 1024  // 128 × 8
                let cr8 = crRow[column] - 1024
                let red = (luma + crToRed * cr8 + 32768) >> 16
                let green = (luma - cbToGreen * cb8 - crToGreen * cr8 + 32768) >> 16
                let blue = (luma + cbToBlue * cb8 + 32768) >> 16
                pixels[pixelRowBase + column] = RGBA(
                    red: UInt8(min(max(red, 0), 255)),
                    green: UInt8(min(max(green, 0), 255)),
                    blue: UInt8(min(max(blue, 0), 255)),
                    alpha: 255
                )
            }
        }
        return Image(width: stream.displayWidth, height: stream.displayHeight, pixels: pixels)
    }

    static func encode(_ image: Image) throws -> Data {
        throw ImageError.unsupportedFeature(
            reason: "HEIC encoding requires an HEVC (H.265) encoder, which is not implemented"
        )
    }

    // MARK: HEVC stream extraction

    /// Everything parsed ahead of entropy decoding: parameter sets, the
    /// first slice header, the slice NAL units, and display transforms.
    struct HEVCStream {
        var sps: HEVCSequenceParameterSet
        var pps: HEVCPictureParameterSet
        var firstSliceHeader: HEVCSliceHeader
        var sliceNALUnits: [HEVCNALUnit]
        /// The container-declared (ispe) display size. In 4:2:0, conformance
        /// window offsets come in two-pixel units, so odd image sizes cannot
        /// be expressed in the SPS — the container carries the true size.
        var displayWidth: Int
        var displayHeight: Int
        /// Top-left of the display window in coded-picture coordinates
        /// (conformance window plus any clean-aperture offset).
        var displayLeft: Int
        var displayTop: Int
        /// irot: number of 90° counter-clockwise turns for display (0–3).
        var rotationQuarterTurns: Int
        /// imir: raw mirror axis value, when present.
        var mirrorAxis: Int?
        /// colr (nclx) colour description; BT.601 limited range if absent.
        var matrixCoefficients: Int = 6
        var fullRange: Bool = false
    }

    static func parseStream(from data: Data) throws -> HEVCStream {
        guard canDecode(data) else {
            throw ImageError.invalidData(reason: "Missing HEIF file type box")
        }
        let container = try HEIFContainer(bytes: [UInt8](data))

        guard let primaryID = container.primaryItemID else {
            throw ImageError.invalidData(reason: "HEIC has no primary item")
        }
        if container.itemTypes[primaryID] == "grid" {
            throw ImageError.invalidData(reason: "HEIC grid items contain multiple HEVC streams; decode the file instead")
        }
        return try makeStream(container: container, itemID: primaryID)
    }

    /// Builds the decodable stream for one coded (`hvc1`) item, using the
    /// properties associated with that item.
    private static func makeStream(container: HEIFContainer, itemID primaryID: Int) throws -> HEVCStream {
        let primaryType = container.itemTypes[primaryID]
        guard primaryType == "hvc1" else {
            throw ImageError.unsupportedFeature(reason: "HEIF item type '\(primaryType ?? "?")' is not supported")
        }

        guard let configPayload = container.property(ofType: "hvcC", forItem: primaryID) else {
            throw ImageError.invalidData(reason: "HEIC is missing its HEVC decoder configuration")
        }
        let configuration = try HEVCDecoderConfiguration(payload: configPayload)
        guard let itemData = try container.itemData(for: primaryID) else {
            throw ImageError.invalidData(reason: "HEIC primary item has no data")
        }

        var nalUnits = configuration.parameterSetNALUnits
        nalUnits += try splitLengthPrefixedNALUnits(itemData, lengthSize: configuration.lengthSize)

        guard let spsNAL = nalUnits.first(where: { $0.type == HEVCNALUnit.sps }) else {
            throw ImageError.invalidData(reason: "HEVC stream is missing its sequence parameter set")
        }
        guard let ppsNAL = nalUnits.first(where: { $0.type == HEVCNALUnit.pps }) else {
            throw ImageError.invalidData(reason: "HEVC stream is missing its picture parameter set")
        }
        let sps = try HEVCSequenceParameterSet.parse(spsNAL)
        let pps = try HEVCPictureParameterSet.parse(ppsNAL)

        let slices = nalUnits.filter(\.isIntraSlice)
        guard let firstSlice = slices.first else {
            throw ImageError.invalidData(reason: "HEVC stream contains no image slice")
        }
        let header = try HEVCSliceHeader.parse(firstSlice, sps: sps, pps: pps)

        // The coded size comes from the SPS; the display size may be reduced
        // further by a clean aperture (clap) property — for example, 4:2:0
        // can't express odd sizes in the SPS, so encoders write 52×38 plus a
        // clap cropping to 51×37.
        var displayWidth = sps.croppedWidth
        var displayHeight = sps.croppedHeight
        var displayLeft = sps.cropLeft
        var displayTop = sps.cropTop
        if let clap = container.property(ofType: "clap", forItem: primaryID), clap.count >= 32 {
            func u32(_ offset: Int) -> Int {
                Int(clap[offset]) << 24 | Int(clap[offset + 1]) << 16
                    | Int(clap[offset + 2]) << 8 | Int(clap[offset + 3])
            }
            func s32(_ offset: Int) -> Int {
                Int(Int32(truncatingIfNeeded: u32(offset)))
            }
            let widthNumerator = u32(0)
            let widthDenominator = u32(4)
            let heightNumerator = u32(8)
            let heightDenominator = u32(12)
            if widthDenominator > 0, heightDenominator > 0 {
                let width = widthNumerator / widthDenominator
                let height = heightNumerator / heightDenominator
                if width > 0, height > 0, width <= displayWidth, height <= displayHeight {
                    // The clean aperture is centred plus a signed rational
                    // offset; resolve to the aperture's top-left corner.
                    let horizontalDenominator = max(u32(20), 1)
                    let verticalDenominator = max(u32(28), 1)
                    let apertureX = ((displayWidth - width) * horizontalDenominator + 2 * s32(16))
                        / (2 * horizontalDenominator)
                    let apertureY = ((displayHeight - height) * verticalDenominator + 2 * s32(24))
                        / (2 * verticalDenominator)
                    displayLeft += min(max(apertureX, 0), displayWidth - width)
                    displayTop += min(max(apertureY, 0), displayHeight - height)
                    displayWidth = width
                    displayHeight = height
                }
            }
        }

        var matrixCoefficients = 6
        var fullRange = false
        if let colr = container.property(ofType: "colr", forItem: primaryID),
           colr.count >= 11,
           String(decoding: colr[0..<4], as: UTF8.self) == "nclx" {
            matrixCoefficients = Int(colr[8]) << 8 | Int(colr[9])
            fullRange = colr[10] & 0x80 != 0
        }

        var rotation = 0
        if let irot = container.property(ofType: "irot", forItem: primaryID), let first = irot.first {
            rotation = Int(first & 0x03)
        }
        var mirror: Int?
        if let imir = container.property(ofType: "imir", forItem: primaryID), let first = imir.first {
            mirror = Int(first & 0x01)
        }

        return HEVCStream(
            sps: sps,
            pps: pps,
            firstSliceHeader: header,
            sliceNALUnits: slices,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            displayLeft: displayLeft,
            displayTop: displayTop,
            rotationQuarterTurns: rotation,
            mirrorAxis: mirror,
            matrixCoefficients: matrixCoefficients,
            fullRange: fullRange
        )
    }

    /// Splits an HEIF image item's data into NAL units (each prefixed with a
    /// big-endian length of `lengthSize` bytes, per the hvcC configuration).
    static func splitLengthPrefixedNALUnits(_ data: [UInt8], lengthSize: Int) throws -> [HEVCNALUnit] {
        var units: [HEVCNALUnit] = []
        var offset = 0
        while offset + lengthSize <= data.count {
            var length = 0
            for i in 0..<lengthSize {
                length = length << 8 | Int(data[offset + i])
            }
            offset += lengthSize
            guard length >= 2, offset + length <= data.count else {
                throw ImageError.invalidData(reason: "Corrupt HEVC NAL unit length")
            }
            if let unit = HEVCNALUnit(bytes: Array(data[offset..<offset + length])) {
                units.append(unit)
            }
            offset += length
        }
        return units
    }
}

/// The HEVCDecoderConfigurationRecord from an hvcC property (ISO 14496-15).
struct HEVCDecoderConfiguration {
    let lengthSize: Int
    let parameterSetNALUnits: [HEVCNALUnit]

    init(payload: [UInt8]) throws {
        guard payload.count >= 23, payload[0] == 1 else {
            throw ImageError.invalidData(reason: "Unsupported HEVC decoder configuration")
        }
        lengthSize = Int(payload[21] & 0x03) + 1

        var units: [HEVCNALUnit] = []
        var offset = 23
        for _ in 0..<Int(payload[22]) {
            guard offset + 3 <= payload.count else {
                throw ImageError.invalidData(reason: "Corrupt HEVC decoder configuration")
            }
            let unitCount = Int(payload[offset + 1]) << 8 | Int(payload[offset + 2])
            offset += 3
            for _ in 0..<unitCount {
                guard offset + 2 <= payload.count else {
                    throw ImageError.invalidData(reason: "Corrupt HEVC decoder configuration")
                }
                let length = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                offset += 2
                guard offset + length <= payload.count else {
                    throw ImageError.invalidData(reason: "Corrupt HEVC decoder configuration")
                }
                if let unit = HEVCNALUnit(bytes: Array(payload[offset..<offset + length])) {
                    units.append(unit)
                }
                offset += length
            }
        }
        parameterSetNALUnits = units
    }
}

