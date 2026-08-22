import Foundation

/// AVIF (AV1 still images in a HEIF container).
///
/// The container layer is fully implemented — it is the same ISOBMFF
/// structure HEIC uses — and the AV1 configuration record, OBU framing and
/// sequence header are parsed. Reconstructing pixels requires the AV1
/// entropy decoder and prediction stages, which are being built milestone
/// by milestone; until they land, decoding throws
/// `ImageError.unsupportedFeature` naming the missing stage.
enum AVIFCodec: ImageCodec {
    private static let avifBrands: Set<String> = ["avif", "avis"]

    static func canDecode(_ data: Data) -> Bool {
        brands(of: data).contains { avifBrands.contains($0) }
    }

    /// The major and compatible brands of an ISOBMFF file type box.
    static func brands(of data: Data) -> [String] {
        guard data.count >= 16 else { return [] }
        let bytes = [UInt8](data.prefix(min(data.count, 64)))
        guard Array(bytes[4..<8]) == Array("ftyp".utf8) else { return [] }
        let boxSize = min(
            Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3]),
            bytes.count
        )
        guard boxSize >= 16 else { return [] }
        var brands = [String(decoding: bytes[8..<12], as: UTF8.self)]
        var offset = 16
        while offset + 4 <= boxSize {
            brands.append(String(decoding: bytes[offset..<offset + 4], as: UTF8.self))
            offset += 4
        }
        return brands
    }

    static func decode(_ data: Data) throws -> Image {
        guard canDecode(data) else {
            throw ImageError.invalidData(reason: "Missing AVIF file type box")
        }
        let container = try HEIFContainer(bytes: [UInt8](data))
        guard let primaryID = container.primaryItemID else {
            throw ImageError.invalidData(reason: "AVIF has no primary item")
        }
        var image = try decodeItem(container: container, itemID: primaryID)

        // Alpha auxiliary image (linked to the primary via auxl).
        if let alphaID = alphaItemID(container: container, primaryID: primaryID) {
            let alpha = try decodeItem(container: container, itemID: alphaID)
            if alpha.width == image.width, alpha.height == image.height {
                for y in 0..<image.height {
                    for x in 0..<image.width {
                        var pixel = image[x, y]
                        pixel.alpha = alpha[x, y].red
                        image[x, y] = pixel
                    }
                }
            }
        }

        // irot counts 90° anti-clockwise turns; imir mirrors.
        if let irot = container.property(ofType: "irot", forItem: primaryID),
           let first = irot.first, first & 0x03 > 0 {
            let rotation: Rotation = [.clockwise270, .clockwise180, .clockwise90][Int(first & 0x03) - 1]
            image = image.rotated(by: rotation)
        }
        if let imir = container.property(ofType: "imir", forItem: primaryID), let first = imir.first {
            image = image.mirrored(across: first & 1 == 0 ? .horizontal : .vertical)
        }
        return image
    }

    /// Decodes one item (a coded image or a grid of them) to RGB, without
    /// orientation.
    private static func decodeItem(container: HEIFContainer, itemID: Int) throws -> Image {
        if container.itemTypes[itemID] == "grid" {
            return try decodeGrid(container: container, gridID: itemID)
        }
        guard container.itemTypes[itemID] == "av01" else {
            throw ImageError.unsupportedFeature(reason: "AVIF item type '\(container.itemTypes[itemID] ?? "?")' is not supported")
        }
        let stream = try makeStream(container: container, itemID: itemID)
        let frame = try decodeFrame(stream: stream)
        return convertToRGB(frame: frame, stream: stream)
    }

    /// The auxiliary alpha item linked to the given item, if present.
    private static func alphaItemID(container: HEIFContainer, primaryID: Int) -> Int? {
        for (itemID, type) in container.itemTypes where itemID != primaryID {
            guard type == "av01" || type == "grid" else { continue }
            guard container.linkedItems(ofType: "auxl", from: itemID).contains(primaryID) else { continue }
            if let auxC = container.property(ofType: "auxC", forItem: itemID) {
                // Full box: 4 bytes of version/flags precede the URN.
                let urn = String(decoding: auxC.dropFirst(4).prefix(while: { $0 != 0 }), as: UTF8.self)
                if !urn.contains("alpha") {
                    continue
                }
            }
            return itemID
        }
        return nil
    }

    /// Decodes a tiled (grid) image: the grid item declares the layout and
    /// output size; dimg references list the tiles in row-major order.
    private static func decodeGrid(container: HEIFContainer, gridID: Int) throws -> Image {
        guard let payload = try container.itemData(for: gridID), payload.count >= 8 else {
            throw ImageError.invalidData(reason: "Corrupt AVIF grid configuration")
        }
        let rows = Int(payload[2]) + 1
        let columns = Int(payload[3]) + 1
        let fieldSize = payload[1] & 1 == 1 ? 4 : 2
        guard payload.count >= 4 + 2 * fieldSize else {
            throw ImageError.invalidData(reason: "Corrupt AVIF grid configuration")
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
            throw ImageError.invalidData(reason: "Invalid AVIF grid dimensions")
        }

        let tileIDs = container.linkedItems(ofType: "dimg", from: gridID)
        guard tileIDs.count == rows * columns else {
            throw ImageError.invalidData(reason: "AVIF grid expects \(rows * columns) tiles but references \(tileIDs.count)")
        }

        // Tiles are independent AV1 frames; decode them concurrently.
        let streams = try tileIDs.map { try makeStream(container: container, itemID: $0) }
        var results = [Result<Image, Error>?](repeating: nil, count: streams.count)
        results.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let output = buffer
            DispatchQueue.concurrentPerform(iterations: streams.count) { index in
                output[index] = Result {
                    let frame = try decodeFrame(stream: streams[index])
                    return convertToRGB(frame: frame, stream: streams[index])
                }
            }
        }
        let tiles = try results.map { try $0!.get() }

        let tileWidth = tiles[0].width
        let tileHeight = tiles[0].height
        guard columns * tileWidth >= outputWidth, rows * tileHeight >= outputHeight,
              tiles.allSatisfy({ $0.width == tileWidth && $0.height == tileHeight }) else {
            throw ImageError.invalidData(reason: "AVIF grid tiles don't cover the image")
        }

        var composite = Image(width: outputWidth, height: outputHeight)
        for (index, tile) in tiles.enumerated() {
            let originX = (index % columns) * tileWidth
            let originY = (index / columns) * tileHeight
            for y in 0..<tileHeight where originY + y < outputHeight {
                for x in 0..<tileWidth where originX + x < outputWidth {
                    composite[originX + x, originY + y] = tile[x, y]
                }
            }
        }
        return composite
    }

    /// Decodes and reconstructs the coded frame, applying the in-loop
    /// filters (deblocking, CDEF, loop restoration).
    static func decodeFrame(stream: AVIFStream) throws -> AV1FrameBuffer {
        let frame = AV1FrameBuffer(sequence: stream.sequenceHeader, header: stream.frameHeader)
        let decoders = try decodeTiles(stream: stream, frame: frame)
        AV1LoopFilters.apply(
            frame: frame,
            sequence: stream.sequenceHeader,
            header: stream.frameHeader,
            restorationUnits: decoders.flatMap(\.restorationUnits)
        )
        return frame
    }

    /// Decodes the symbol layer of every tile (validating termination) and
    /// returns the per-tile decoders holding mode info and coefficients.
    /// With a frame buffer, prediction and reconstruction run inline.
    static func decodeTiles(stream: AVIFStream, frame: AV1FrameBuffer? = nil) throws -> [AV1TileDecoder] {
        let info = stream.frameHeader.tiles
        guard stream.tileGroup.tiles.count == info.tileCount else {
            throw ImageError.invalidData(reason: "AV1 tile count mismatch")
        }
        var decoders: [AV1TileDecoder] = []
        for tileIndex in 0..<info.tileCount {
            let decoder = try AV1TileDecoder(
                tile: stream.tileGroup.tiles[tileIndex],
                sequence: stream.sequenceHeader,
                header: stream.frameHeader,
                tileRow: tileIndex / info.columnCount,
                tileColumn: tileIndex % info.columnCount,
                frame: frame
            )
            try decoder.decode()
            decoders.append(decoder)
        }
        return decoders
    }

    /// Converts the reconstructed planes to an 8-bit RGB image at the
    /// display size (nclx color description from the sequence header).
    static func convertToRGB(frame: AV1FrameBuffer, stream: AVIFStream) -> Image {
        let sequence = stream.sequenceHeader
        let width = min(stream.displayWidth, frame.width[0])
        let height = min(stream.displayHeight, frame.height[0])
        var image = Image(width: width, height: height)
        let depth = frame.bitDepth
        let maxValue = Double((1 << depth) - 1)
        let scale8 = Double(255)

        func to8(_ value: Double) -> UInt8 {
            UInt8(min(max(value + 0.5, 0), 255))
        }

        if sequence.monochrome {
            for y in 0..<height {
                for x in 0..<width {
                    let luma = normalizedLuma(frame.sample(0, y, x), depth: depth, fullRange: sequence.fullRange)
                    let v = to8(luma * scale8)
                    image[x, y] = RGBA(red: v, green: v, blue: v)
                }
            }
            return image
        }

        // Matrix coefficients: 0 = identity (GBR), 1 = BT.709, 9/10 = BT.2020,
        // everything else treated as BT.601 (avifenc writes 6).
        if sequence.matrixCoefficients == 0 {
            for y in 0..<height {
                for x in 0..<width {
                    let g = Double(frame.sample(0, y, x)) / maxValue
                    let b = Double(frame.sample(1, y >> frame.subY, x >> frame.subX)) / maxValue
                    let r = Double(frame.sample(2, y >> frame.subY, x >> frame.subX)) / maxValue
                    image[x, y] = RGBA(red: to8(r * scale8), green: to8(g * scale8), blue: to8(b * scale8))
                }
            }
            return image
        }

        let kr: Double
        let kb: Double
        switch sequence.matrixCoefficients {
        case 1: (kr, kb) = (0.2126, 0.0722)
        case 9, 10: (kr, kb) = (0.2627, 0.0593)
        default: (kr, kb) = (0.299, 0.114)
        }
        for y in 0..<height {
            let cy = min(y >> frame.subY, frame.height[1] - 1)
            for x in 0..<width {
                let cx = min(x >> frame.subX, frame.width[1] - 1)
                let luma = normalizedLuma(frame.sample(0, y, x), depth: depth, fullRange: sequence.fullRange)
                let cb = normalizedChroma(frame.sample(1, cy, cx), depth: depth, fullRange: sequence.fullRange)
                let cr = normalizedChroma(frame.sample(2, cy, cx), depth: depth, fullRange: sequence.fullRange)
                let r = luma + 2 * (1 - kr) * cr
                let b = luma + 2 * (1 - kb) * cb
                let g = (luma - kr * r - kb * b) / (1 - kr - kb)
                image[x, y] = RGBA(red: to8(r * scale8), green: to8(g * scale8), blue: to8(b * scale8))
            }
        }
        return image
    }

    private static func normalizedLuma(_ value: Int, depth: Int, fullRange: Bool) -> Double {
        if fullRange {
            return Double(value) / Double((1 << depth) - 1)
        }
        let scale = Double(1 << (depth - 8))
        return (Double(value) - 16 * scale) / (219 * scale)
    }

    private static func normalizedChroma(_ value: Int, depth: Int, fullRange: Bool) -> Double {
        let half = Double(1 << (depth - 1))
        if fullRange {
            return (Double(value) - half) / Double((1 << depth) - 1)
        }
        let scale = Double(1 << (depth - 8))
        return (Double(value) - half) / (224 * scale)
    }

    static func encode(_ image: Image) throws -> Data {
        throw ImageError.unsupportedFeature(
            reason: "AVIF encoding requires an AV1 encoder, which is not implemented"
        )
    }

    // MARK: AV1 stream extraction

    /// Everything parsed ahead of entropy decoding.
    struct AVIFStream {
        var sequenceHeader: AV1SequenceHeader
        var frameHeader: AV1FrameHeader
        /// The symbol-coded payload of each tile, in tile order.
        var tileGroup: AV1TileGroup
        /// All OBUs of the coded image (configuration OBUs first).
        var obus: [AV1OBU]
        /// The container-declared (ispe) display size, falling back to the
        /// sequence header's frame size.
        var displayWidth: Int
        var displayHeight: Int
        /// irot: number of 90° anti-clockwise turns for display (0–3).
        var rotationQuarterTurns: Int
        /// imir: raw mirror axis value, when present.
        var mirrorAxis: Int?
    }

    static func parseStream(from data: Data) throws -> AVIFStream {
        guard canDecode(data) else {
            throw ImageError.invalidData(reason: "Missing AVIF file type box")
        }
        let container = try HEIFContainer(bytes: [UInt8](data))

        guard let primaryID = container.primaryItemID else {
            throw ImageError.invalidData(reason: "AVIF has no primary item")
        }
        let primaryType = container.itemTypes[primaryID]
        if primaryType == "grid" {
            throw ImageError.unsupportedFeature(reason: "A grid AVIF holds multiple streams; decode it as an image")
        }
        guard primaryType == "av01" else {
            throw ImageError.unsupportedFeature(reason: "AVIF primary item type '\(primaryType ?? "?")' is not supported")
        }
        return try makeStream(container: container, itemID: primaryID)
    }

    /// Builds the AV1 stream of one av01 item.
    static func makeStream(container: HEIFContainer, itemID primaryID: Int) throws -> AVIFStream {
        guard let configPayload = container.property(ofType: "av1C", forItem: primaryID) else {
            throw ImageError.invalidData(reason: "AVIF is missing its AV1 decoder configuration")
        }
        let configuration = try AV1DecoderConfiguration(payload: configPayload)
        guard let itemData = try container.itemData(for: primaryID) else {
            throw ImageError.invalidData(reason: "AVIF primary item has no data")
        }

        let obus = try AV1OBU.split(configuration.configurationOBUs + itemData)
        guard let headerOBU = obus.first(where: { $0.type == AV1OBU.sequenceHeader }) else {
            throw ImageError.invalidData(reason: "AV1 stream is missing its sequence header")
        }
        let sequenceHeader = try AV1SequenceHeader.parse(headerOBU.payload)

        // The frame header and tile group live either in one frame OBU
        // (header, byte alignment, tiles) or in separate OBUs.
        let frameHeader: AV1FrameHeader
        let tileGroup: AV1TileGroup
        if let frameOBU = obus.first(where: { $0.type == AV1OBU.frame }) {
            frameHeader = try AV1FrameHeader.parse(frameOBU.payload, sequenceHeader: sequenceHeader)
            let headerBytes = (frameHeader.headerBitCount + 7) / 8
            guard headerBytes <= frameOBU.payload.count else {
                throw ImageError.invalidData(reason: "AV1 frame header exceeds its unit")
            }
            tileGroup = try AV1TileGroup.parse(
                Array(frameOBU.payload[headerBytes...]),
                tileInfo: frameHeader.tiles
            )
        } else if let frameHeaderOBU = obus.first(where: { $0.type == AV1OBU.frameHeader }),
                  let tileGroupOBU = obus.first(where: { $0.type == AV1OBU.tileGroup }) {
            frameHeader = try AV1FrameHeader.parse(frameHeaderOBU.payload, sequenceHeader: sequenceHeader)
            tileGroup = try AV1TileGroup.parse(tileGroupOBU.payload, tileInfo: frameHeader.tiles)
        } else {
            throw ImageError.invalidData(reason: "AV1 stream contains no coded frame")
        }

        var displayWidth = sequenceHeader.width
        var displayHeight = sequenceHeader.height
        if let ispe = container.property(ofType: "ispe", forItem: primaryID), ispe.count >= 12 {
            func u32(_ offset: Int) -> Int {
                Int(ispe[offset]) << 24 | Int(ispe[offset + 1]) << 16
                    | Int(ispe[offset + 2]) << 8 | Int(ispe[offset + 3])
            }
            let width = u32(4)
            let height = u32(8)
            if width > 0, height > 0 {
                displayWidth = width
                displayHeight = height
            }
        }

        var rotation = 0
        if let irot = container.property(ofType: "irot", forItem: primaryID), let first = irot.first {
            rotation = Int(first & 0x03)
        }
        var mirror: Int?
        if let imir = container.property(ofType: "imir", forItem: primaryID), let first = imir.first {
            mirror = Int(first & 0x01)
        }

        return AVIFStream(
            sequenceHeader: sequenceHeader,
            frameHeader: frameHeader,
            tileGroup: tileGroup,
            obus: obus,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            rotationQuarterTurns: rotation,
            mirrorAxis: mirror
        )
    }
}
