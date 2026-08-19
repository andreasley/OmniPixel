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

        // The major brand plus any compatible brand may mark the file as HEIF.
        var brands = [String(decoding: bytes[8..<12], as: UTF8.self)]
        var offset = 16
        while offset + 4 <= boxSize {
            brands.append(String(decoding: bytes[offset..<offset + 4], as: UTF8.self))
            offset += 4
        }
        return brands.contains { heifBrands.contains($0) }
    }

    static func decode(_ data: Data) throws -> Image {
        let stream = try parseStream(from: data)
        let decoder = try HEVCPictureDecoder(sps: stream.sps, pps: stream.pps)
        let picture = try decoder.decodePicture(sliceNALUnits: stream.sliceNALUnits)
        var planes = HEVCReconstruction.reconstruct(picture: picture, sps: stream.sps)
        HEVCLoopFilters.apply(to: &planes, picture: picture, sps: stream.sps)

        var image = convertToRGB(planes, stream: stream)
        if stream.rotationQuarterTurns > 0 {
            // irot counts 90° anti-clockwise turns.
            let rotation: Rotation = [.clockwise270, .clockwise180, .clockwise90][stream.rotationQuarterTurns - 1]
            image = image.rotated(by: rotation)
        }
        if let axis = stream.mirrorAxis {
            image = image.mirrored(across: axis == 0 ? .horizontal : .vertical)
        }
        return image
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

        var pixels = [RGBA](repeating: .transparent, count: stream.displayWidth * stream.displayHeight)
        let chromaWidth = planes.chromaWidth

        // Chroma sampling must stay inside the display window: the coded
        // picture is padded with arbitrary samples that must not bleed into
        // the visible edge pixels.
        let chromaMinX = stream.displayLeft >> 1
        let chromaMaxX = (stream.displayLeft + stream.displayWidth - 1) >> 1
        let chromaMinY = stream.displayTop >> 1
        let chromaMaxY = (stream.displayTop + stream.displayHeight - 1) >> 1

        for row in 0..<stream.displayHeight {
            let lumaY = row + stream.displayTop
            for column in 0..<stream.displayWidth {
                let lumaX = column + stream.displayLeft
                let y = Double(planes.luma[lumaY * planes.lumaWidth + lumaX])

                // Bilinear chroma upsampling for default 4:2:0 siting.
                func chroma(_ plane: [UInt8]) -> Double {
                    let baseX = lumaX >> 1
                    let horizontal: Double = lumaX & 1 == 0 ? 0 : 0.5
                    // Chroma rows sit midway between the two luma rows they
                    // cover: luma row 2r maps to chroma position r − 0.25.
                    let position = Double(lumaY) / 2 - 0.25
                    let topRow = min(max(Int(position.rounded(.down)), chromaMinY), chromaMaxY)
                    let bottomRow = min(topRow + 1, chromaMaxY)
                    let verticalWeight = min(max(position - Double(topRow), 0), 1)

                    func sampleRow(_ chromaRow: Int) -> Double {
                        let left = Double(plane[chromaRow * chromaWidth + baseX])
                        guard horizontal > 0 else { return left }
                        let right = Double(plane[chromaRow * chromaWidth + min(baseX + 1, chromaMaxX)])
                        return left * (1 - horizontal) + right * horizontal
                    }
                    return sampleRow(topRow) * (1 - verticalWeight) + sampleRow(bottomRow) * verticalWeight
                }
                let cb = chroma(planes.cb)
                let cr = chroma(planes.cr)

                let yScaled: Double
                let cbScaled: Double
                let crScaled: Double
                if stream.fullRange {
                    yScaled = y
                    cbScaled = cb - 128
                    crScaled = cr - 128
                } else {
                    yScaled = (y - 16) * 255 / 219
                    cbScaled = (cb - 128) * 255 / 224
                    crScaled = (cr - 128) * 255 / 224
                }

                let red = yScaled + 2 * (1 - kr) * crScaled
                let blue = yScaled + 2 * (1 - kb) * cbScaled
                let green = (yScaled - kr * red - kb * blue) / (1 - kr - kb)

                func clip(_ value: Double) -> UInt8 {
                    UInt8(min(max(value.rounded(), 0), 255))
                }
                pixels[row * stream.displayWidth + column] = RGBA(
                    red: clip(red), green: clip(green), blue: clip(blue), alpha: 255
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
        let primaryType = container.itemTypes[primaryID]
        if primaryType == "grid" {
            throw ImageError.unsupportedFeature(reason: "Grid (tiled) HEIC is not supported yet")
        }
        guard primaryType == "hvc1" else {
            throw ImageError.unsupportedFeature(reason: "HEIF primary item type '\(primaryType ?? "?")' is not supported")
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

/// Parsed HEIF/ISOBMFF structure: the pieces needed to locate and extract
/// the primary item's HEVC bitstream and display properties.
private struct HEIFContainer {
    struct ItemLocation {
        var constructionMethod = 0
        var baseOffset = 0
        var extents: [(offset: Int, length: Int)] = []
    }

    private(set) var primaryItemID: Int?
    private(set) var itemTypes: [Int: String] = [:]
    private(set) var itemLocations: [Int: ItemLocation] = [:]
    private(set) var properties: [(type: String, payload: [UInt8])] = []
    private(set) var associations: [Int: [Int]] = [:]
    private(set) var idat: [UInt8] = []
    private let bytes: [UInt8]

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        try walkBoxes(from: 0, to: bytes.count, container: "", depth: 0)
    }

    // MARK: Lookups

    /// Returns the payload of the first property of `type` associated with
    /// the item (falling back to a global search for lenient parsing).
    func property(ofType type: String, forItem itemID: Int) -> [UInt8]? {
        if let indices = associations[itemID] {
            for index in indices where index >= 1 && index <= properties.count {
                if properties[index - 1].type == type {
                    return properties[index - 1].payload
                }
            }
        }
        return properties.first { $0.type == type }?.payload
    }

    /// Assembles an item's data from its iloc extents.
    func itemData(for itemID: Int) throws -> [UInt8]? {
        guard let location = itemLocations[itemID] else { return nil }
        var data: [UInt8] = []
        for extent in location.extents {
            let start = location.baseOffset + extent.offset
            let source: [UInt8]
            switch location.constructionMethod {
            case 0:
                source = bytes
            case 1:
                source = idat
            default:
                throw ImageError.unsupportedFeature(reason: "HEIC item construction method \(location.constructionMethod) is not supported")
            }
            // A zero-length single extent means "to the end of the resource".
            let length = extent.length == 0 && location.extents.count == 1
                ? source.count - start
                : extent.length
            guard start >= 0, length >= 0, start + length <= source.count else {
                throw ImageError.invalidData(reason: "HEIC item data lies outside the file")
            }
            data += source[start..<start + length]
        }
        return data
    }

    // MARK: Box parsing

    private func readU16(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else {
            throw ImageError.invalidData(reason: "HEIF box offset out of range")
        }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    private func readU32(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw ImageError.invalidData(reason: "HEIF box offset out of range")
        }
        return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    private func readSized(_ offset: Int, byteCount: Int) throws -> Int {
        guard byteCount >= 0, byteCount <= 8, offset >= 0, offset + byteCount <= bytes.count else {
            throw ImageError.invalidData(reason: "HEIF box offset out of range")
        }
        var value = 0
        for i in 0..<byteCount {
            let byte = Int(bytes[offset + i])
            guard value <= (Int.max - byte) >> 8 else {
                throw ImageError.invalidData(reason: "HEIF offset too large")
            }
            value = value << 8 | byte
        }
        return value
    }

    private mutating func walkBoxes(from start: Int, to end: Int, container: String, depth: Int) throws {
        guard depth < 10 else { return }
        var offset = start
        while offset + 8 <= end {
            var size = try readU32(offset)
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            var headerSize = 8
            if size == 1 {  // 64-bit size
                guard offset + 16 <= end, try readU32(offset + 8) == 0 else {
                    throw ImageError.invalidData(reason: "HEIF box too large")
                }
                size = try readU32(offset + 12)
                headerSize = 16
            } else if size == 0 {  // extends to the end of the enclosing box
                size = end - offset
            }
            guard size >= headerSize, offset + size <= end else {
                throw ImageError.invalidData(reason: "HEIF box exceeds its container")
            }
            let payloadStart = offset + headerSize
            let payloadEnd = offset + size

            switch (container, type) {
            case ("", "meta"):  // full box
                try walkBoxes(from: payloadStart + 4, to: payloadEnd, container: "meta", depth: depth + 1)
            case ("meta", "pitm"):
                try parsePrimaryItem(payloadStart)
            case ("meta", "iinf"):
                guard payloadStart < payloadEnd else { break }
                let version = Int(bytes[payloadStart])
                let childStart = payloadStart + 4 + (version == 0 ? 2 : 4)
                if childStart <= payloadEnd {
                    try walkBoxes(from: childStart, to: payloadEnd, container: "iinf", depth: depth + 1)
                }
            case ("meta", "iloc"):
                try parseItemLocations(payloadStart, payloadEnd)
            case ("meta", "iprp"):
                try walkBoxes(from: payloadStart, to: payloadEnd, container: "iprp", depth: depth + 1)
            case ("meta", "idat"):
                idat = Array(bytes[payloadStart..<payloadEnd])
            case ("iprp", "ipco"):
                try collectProperties(payloadStart, payloadEnd)
            case ("iprp", "ipma"):
                try parseAssociations(payloadStart, payloadEnd)
            case ("iinf", "infe"):
                try parseItemInfo(payloadStart, payloadEnd)
            default:
                break
            }
            offset += size
        }
    }

    private mutating func parsePrimaryItem(_ start: Int) throws {
        guard start < bytes.count else {
            throw ImageError.invalidData(reason: "Corrupt HEIF primary item box")
        }
        let version = Int(bytes[start])
        primaryItemID = version == 0 ? try readU16(start + 4) : try readU32(start + 4)
    }

    private mutating func parseItemInfo(_ start: Int, _ end: Int) throws {
        guard start < end else { return }
        let version = Int(bytes[start])
        guard version >= 2 else { return }  // pre-HEIF layouts carry no item type
        let itemID: Int
        var offset: Int
        if version == 2 {
            itemID = try readU16(start + 4)
            offset = start + 6
        } else {
            itemID = try readU32(start + 4)
            offset = start + 8
        }
        offset += 2  // item_protection_index
        guard offset + 4 <= end else { return }
        itemTypes[itemID] = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
    }

    private mutating func parseItemLocations(_ start: Int, _ end: Int) throws {
        guard start + 8 <= end else {
            throw ImageError.invalidData(reason: "Corrupt HEIF item location box")
        }
        let version = Int(bytes[start])
        let offsetSize = Int(bytes[start + 4]) >> 4
        let lengthSize = Int(bytes[start + 4]) & 0x0F
        let baseOffsetSize = Int(bytes[start + 5]) >> 4
        let indexSize = version >= 1 ? Int(bytes[start + 5]) & 0x0F : 0

        var offset: Int
        let itemCount: Int
        if version < 2 {
            itemCount = try readU16(start + 6)
            offset = start + 8
        } else {
            itemCount = try readU32(start + 6)
            offset = start + 10
        }
        guard itemCount <= 4096 else {
            throw ImageError.invalidData(reason: "Unreasonable HEIF item count")
        }

        for _ in 0..<itemCount {
            let itemID: Int
            if version < 2 {
                itemID = try readU16(offset)
                offset += 2
            } else {
                itemID = try readU32(offset)
                offset += 4
            }
            var location = ItemLocation()
            if version == 1 || version == 2 {
                location.constructionMethod = try readU16(offset) & 0x0F
                offset += 2
            }
            let dataReferenceIndex = try readU16(offset)
            offset += 2
            guard dataReferenceIndex == 0 else {
                throw ImageError.unsupportedFeature(reason: "HEIC with external data references is not supported")
            }
            location.baseOffset = try readSized(offset, byteCount: baseOffsetSize)
            offset += baseOffsetSize
            let extentCount = try readU16(offset)
            offset += 2
            guard extentCount <= 4096 else {
                throw ImageError.invalidData(reason: "Unreasonable HEIF extent count")
            }
            for _ in 0..<extentCount {
                if version >= 1, indexSize > 0 {
                    offset += indexSize  // extent_index, unused
                }
                let extentOffset = try readSized(offset, byteCount: offsetSize)
                offset += offsetSize
                let extentLength = try readSized(offset, byteCount: lengthSize)
                offset += lengthSize
                location.extents.append((extentOffset, extentLength))
            }
            itemLocations[itemID] = location
        }
    }

    private mutating func collectProperties(_ start: Int, _ end: Int) throws {
        var offset = start
        while offset + 8 <= end {
            let size = try readU32(offset)
            guard size >= 8, offset + size <= end else {
                throw ImageError.invalidData(reason: "Corrupt HEIF property container")
            }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            properties.append((type, Array(bytes[offset + 8..<offset + size])))
            offset += size
        }
    }

    private mutating func parseAssociations(_ start: Int, _ end: Int) throws {
        guard start + 8 <= end else {
            throw ImageError.invalidData(reason: "Corrupt HEIF property associations")
        }
        let version = Int(bytes[start])
        let wideIndices = bytes[start + 3] & 0x01 == 1
        let entryCount = try readU32(start + 4)
        guard entryCount <= 4096 else {
            throw ImageError.invalidData(reason: "Unreasonable HEIF association count")
        }
        var offset = start + 8
        for _ in 0..<entryCount {
            let itemID: Int
            if version < 1 {
                itemID = try readU16(offset)
                offset += 2
            } else {
                itemID = try readU32(offset)
                offset += 4
            }
            guard offset < end else {
                throw ImageError.invalidData(reason: "Corrupt HEIF property associations")
            }
            let associationCount = Int(bytes[offset])
            offset += 1
            var indices: [Int] = []
            for _ in 0..<associationCount {
                if wideIndices {
                    indices.append(try readU16(offset) & 0x7FFF)
                    offset += 2
                } else {
                    guard offset < end else {
                        throw ImageError.invalidData(reason: "Corrupt HEIF property associations")
                    }
                    indices.append(Int(bytes[offset]) & 0x7F)
                    offset += 1
                }
            }
            associations[itemID] = indices
        }
    }
}
