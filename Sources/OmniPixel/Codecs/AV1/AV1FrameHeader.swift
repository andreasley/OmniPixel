/// The AV1 uncompressed frame header for intra pictures (AV1 specification
/// section 5.9), plus the tile-group framing (5.11.1).
struct AV1FrameHeader {
    var disableCDFUpdate = false
    var allowScreenContentTools = false
    var allowIntrabc = false
    var frameWidth = 0
    var frameHeight = 0
    var renderWidth = 0
    var renderHeight = 0
    var disableFrameEndUpdateCDF = true

    // Quantization (5.9.12)
    var baseQIndex = 0
    var deltaQYDc = 0
    var deltaQUDc = 0
    var deltaQUAc = 0
    var deltaQVDc = 0
    var deltaQVAc = 0
    var usingQMatrix = false
    var qmY = 0
    var qmU = 0
    var qmV = 0

    // Segmentation (5.9.14)
    var segmentationEnabled = false
    var featureEnabled = [[Bool]](repeating: [Bool](repeating: false, count: 8), count: 8)
    var featureData = [[Int]](repeating: [Int](repeating: 0, count: 8), count: 8)
    var segIdPreSkip = false
    var lastActiveSegmentID = 0

    // Delta Q / delta LF (5.9.17/5.9.18)
    var deltaQPresent = false
    var deltaQRes = 0
    var deltaLFPresent = false
    var deltaLFRes = 0
    var deltaLFMulti = false

    var codedLossless = false
    var allLossless = false

    // Loop filter (5.9.11)
    var loopFilterLevel = [0, 0, 0, 0]
    var loopFilterSharpness = 0
    var loopFilterDeltaEnabled = false
    var loopFilterRefDeltas = [1, 0, 0, 0, 0, -1, -1, -1]
    var loopFilterModeDeltas = [0, 0]

    // CDEF (5.9.19)
    var cdefDamping = 3
    var cdefBits = 0
    var cdefYPrimary = [0, 0, 0, 0, 0, 0, 0, 0]
    var cdefYSecondary = [0, 0, 0, 0, 0, 0, 0, 0]
    var cdefUVPrimary = [0, 0, 0, 0, 0, 0, 0, 0]
    var cdefUVSecondary = [0, 0, 0, 0, 0, 0, 0, 0]

    // Loop restoration (5.9.20): 0 none, 1 switchable, 2 wiener, 3 sgrproj
    var restorationType = [0, 0, 0]
    var restorationSize = [256, 256, 256]

    /// True = TX_MODE_SELECT (per-block sizes), false = largest per block.
    var txModeSelect = false
    var reducedTxSet = false

    var tiles = AV1TileInfo()
    var miCols = 0
    var miRows = 0
    /// Bits consumed by the header (the frame OBU aligns to a byte here).
    var headerBitCount = 0

    static func parse(
        _ payload: [UInt8],
        sequenceHeader sequence: AV1SequenceHeader
    ) throws -> AV1FrameHeader {
        var reader = HEVCBitReader(payload)
        var header = AV1FrameHeader()
        let planeCount = sequence.monochrome ? 1 : 3

        // Reduced still-picture headers imply a shown key frame.
        var isShownKeyFrame = true
        var errorResilient = true
        var sizeOverride = false
        if !sequence.reducedStillPictureHeader {
            guard try reader.readFlag() == false else {
                throw ImageError.unsupportedFeature(reason: "AV1 show-existing-frame is not supported (still images only)")
            }
            let frameType = try reader.readBits(2)
            guard frameType == 0 || frameType == 2 else {  // KEY / INTRA_ONLY
                throw ImageError.unsupportedFeature(reason: "Only intra-coded AV1 frames are supported (still images)")
            }
            let showFrame = try reader.readFlag()
            if !showFrame {
                _ = try reader.readFlag()  // showable_frame
            }
            isShownKeyFrame = frameType == 0 && showFrame
            errorResilient = isShownKeyFrame ? true : try reader.readFlag()
        }

        header.disableCDFUpdate = try reader.readFlag()
        if sequence.forceScreenContentTools == 2 {
            header.allowScreenContentTools = try reader.readFlag()
        } else {
            header.allowScreenContentTools = sequence.forceScreenContentTools == 1
        }
        if header.allowScreenContentTools, sequence.forceIntegerMV == 2 {
            _ = try reader.readFlag()  // force_integer_mv (intra forces 1)
        }
        if sequence.frameIDNumbersPresent {
            let idLength = sequence.additionalFrameIDLength + sequence.deltaFrameIDLength
            _ = try reader.readBits(idLength)  // current_frame_id
        }
        if !sequence.reducedStillPictureHeader {
            sizeOverride = try reader.readFlag()
        }
        _ = try reader.readBits(sequence.orderHintBits)  // order_hint
        // Intra frames always use PRIMARY_REF_NONE (no primary_ref field).
        if !isShownKeyFrame {
            _ = try reader.readBits(8)  // refresh_frame_flags
            if errorResilient, sequence.enableOrderHint {
                for _ in 0..<8 {
                    _ = try reader.readBits(sequence.orderHintBits)
                }
            }
        }
        try header.parseFrameAndRenderSize(&reader, sequence: sequence, sizeOverride: sizeOverride)
        if header.allowScreenContentTools {
            header.allowIntrabc = try reader.readFlag()
        }
        if sequence.reducedStillPictureHeader || header.disableCDFUpdate {
            header.disableFrameEndUpdateCDF = true
        } else {
            header.disableFrameEndUpdateCDF = try reader.readFlag()
        }

        try header.parseTileInfo(&reader, sequence: sequence)
        try header.parseQuantizationParams(&reader, sequence: sequence, planeCount: planeCount)
        try header.parseSegmentationParams(&reader)
        // delta_q_params
        if header.baseQIndex > 0 {
            header.deltaQPresent = try reader.readFlag()
        }
        if header.deltaQPresent {
            header.deltaQRes = try reader.readBits(2)
        }
        // delta_lf_params
        if header.deltaQPresent {
            if !header.allowIntrabc {
                header.deltaLFPresent = try reader.readFlag()
            }
            if header.deltaLFPresent {
                header.deltaLFRes = try reader.readBits(2)
                header.deltaLFMulti = try reader.readFlag()
            }
        }

        // CodedLossless: every segment's effective qindex is 0 and all
        // delta-quantizers are 0.
        header.codedLossless = true
        for segment in 0..<8 {
            let qindex = header.qIndex(forSegment: segment)
            let lossless = qindex == 0 && header.deltaQYDc == 0
                && header.deltaQUAc == 0 && header.deltaQUDc == 0
                && header.deltaQVAc == 0 && header.deltaQVDc == 0
            if !lossless {
                header.codedLossless = false
            }
        }
        header.allLossless = header.codedLossless  // superres is unsupported

        try header.parseLoopFilterParams(&reader, planeCount: planeCount)
        try header.parseCDEFParams(&reader, sequence: sequence, planeCount: planeCount)
        try header.parseRestorationParams(&reader, sequence: sequence, planeCount: planeCount)

        // read_tx_mode
        if header.codedLossless {
            header.txModeSelect = false  // ONLY_4X4
        } else {
            header.txModeSelect = try reader.readFlag()
        }
        // frame_reference_mode / skip_mode / warped motion: nothing coded
        // for intra frames.
        header.reducedTxSet = try reader.readFlag()
        // global_motion_params: nothing coded for intra frames.
        if sequence.filmGrainPresent {
            throw ImageError.unsupportedFeature(reason: "AV1 film grain synthesis is not supported yet")
        }

        header.headerBitCount = reader.bitPosition
        return header
    }

    /// The effective quantizer index for a segment (7.12.2, intra frames).
    func qIndex(forSegment segment: Int) -> Int {
        if segmentationEnabled, featureEnabled[segment][0] {
            return min(max(baseQIndex + featureData[segment][0], 0), 255)
        }
        return baseQIndex
    }

    // MARK: Sub-parsers

    private mutating func parseFrameAndRenderSize(
        _ reader: inout HEVCBitReader,
        sequence: AV1SequenceHeader,
        sizeOverride: Bool
    ) throws {
        if sizeOverride {
            let widthBits = 1 + (try reader.readBits(4))
            let heightBits = 1 + (try reader.readBits(4))
            frameWidth = 1 + (try reader.readBits(widthBits))
            frameHeight = 1 + (try reader.readBits(heightBits))
        } else {
            frameWidth = sequence.width
            frameHeight = sequence.height
        }
        // superres_params
        if sequence.enableSuperres, try reader.readFlag() {
            throw ImageError.unsupportedFeature(reason: "AV1 super-resolution is not supported yet")
        }
        miCols = 2 * ((frameWidth + 7) >> 3)
        miRows = 2 * ((frameHeight + 7) >> 3)
        // render_size
        if try reader.readFlag() {
            renderWidth = 1 + (try reader.readBits(16))
            renderHeight = 1 + (try reader.readBits(16))
        } else {
            renderWidth = frameWidth
            renderHeight = frameHeight
        }
    }

    private mutating func parseQuantizationParams(
        _ reader: inout HEVCBitReader,
        sequence: AV1SequenceHeader,
        planeCount: Int
    ) throws {
        baseQIndex = try reader.readBits(8)
        deltaQYDc = try reader.readDeltaQ()
        if planeCount > 1 {
            var diffUVDelta = false
            if sequence.separateUVDeltaQ {
                diffUVDelta = try reader.readFlag()
            }
            deltaQUDc = try reader.readDeltaQ()
            deltaQUAc = try reader.readDeltaQ()
            if diffUVDelta {
                deltaQVDc = try reader.readDeltaQ()
                deltaQVAc = try reader.readDeltaQ()
            } else {
                deltaQVDc = deltaQUDc
                deltaQVAc = deltaQUAc
            }
        }
        usingQMatrix = try reader.readFlag()
        if usingQMatrix {
            qmY = try reader.readBits(4)
            qmU = try reader.readBits(4)
            qmV = sequence.separateUVDeltaQ ? try reader.readBits(4) : qmU
        }
    }

    private mutating func parseSegmentationParams(_ reader: inout HEVCBitReader) throws {
        segmentationEnabled = try reader.readFlag()
        if segmentationEnabled {
            // Intra frames always use PRIMARY_REF_NONE: the map and data
            // are always updated.
            let featureBits = [8, 6, 6, 6, 6, 3, 0, 0]
            let featureSigned = [true, true, true, true, true, false, false, false]
            let featureMax = [255, 63, 63, 63, 63, 7, 0, 0]
            for segment in 0..<8 {
                for feature in 0..<8 {
                    let enabled = try reader.readFlag()
                    featureEnabled[segment][feature] = enabled
                    var value = 0
                    if enabled {
                        if featureSigned[feature] {
                            let raw = try reader.readSigned(1 + featureBits[feature])
                            value = min(max(raw, -featureMax[feature]), featureMax[feature])
                        } else {
                            let raw = try reader.readBits(featureBits[feature])
                            value = min(max(raw, 0), featureMax[feature])
                        }
                    }
                    featureData[segment][feature] = value
                }
            }
        }
        for segment in 0..<8 {
            for feature in 0..<8 where featureEnabled[segment][feature] {
                lastActiveSegmentID = segment
                if feature >= 5 {  // SEG_LVL_REF_FRAME
                    segIdPreSkip = true
                }
            }
        }
    }

    private mutating func parseLoopFilterParams(
        _ reader: inout HEVCBitReader,
        planeCount: Int
    ) throws {
        if codedLossless || allowIntrabc {
            loopFilterLevel = [0, 0, 0, 0]
            return
        }
        loopFilterLevel[0] = try reader.readBits(6)
        loopFilterLevel[1] = try reader.readBits(6)
        if planeCount > 1, loopFilterLevel[0] != 0 || loopFilterLevel[1] != 0 {
            loopFilterLevel[2] = try reader.readBits(6)
            loopFilterLevel[3] = try reader.readBits(6)
        }
        loopFilterSharpness = try reader.readBits(3)
        loopFilterDeltaEnabled = try reader.readFlag()
        if loopFilterDeltaEnabled, try reader.readFlag() {
            for i in 0..<8 {
                if try reader.readFlag() {
                    loopFilterRefDeltas[i] = try reader.readSigned(7)
                }
            }
            for i in 0..<2 {
                if try reader.readFlag() {
                    loopFilterModeDeltas[i] = try reader.readSigned(7)
                }
            }
        }
    }

    private mutating func parseCDEFParams(
        _ reader: inout HEVCBitReader,
        sequence: AV1SequenceHeader,
        planeCount: Int
    ) throws {
        guard !codedLossless, !allowIntrabc, sequence.enableCDEF else {
            return
        }
        cdefDamping = 3 + (try reader.readBits(2))
        cdefBits = try reader.readBits(2)
        for i in 0..<(1 << cdefBits) {
            cdefYPrimary[i] = try reader.readBits(4)
            cdefYSecondary[i] = try reader.readBits(2)
            if cdefYSecondary[i] == 3 {
                cdefYSecondary[i] += 1
            }
            if planeCount > 1 {
                cdefUVPrimary[i] = try reader.readBits(4)
                cdefUVSecondary[i] = try reader.readBits(2)
                if cdefUVSecondary[i] == 3 {
                    cdefUVSecondary[i] += 1
                }
            }
        }
    }

    private mutating func parseRestorationParams(
        _ reader: inout HEVCBitReader,
        sequence: AV1SequenceHeader,
        planeCount: Int
    ) throws {
        guard !allLossless, !allowIntrabc, sequence.enableRestoration else {
            return
        }
        let remap = [0, 1, 2, 3]  // none, switchable, wiener, sgrproj
        var usesRestoration = false
        var usesChromaRestoration = false
        for plane in 0..<planeCount {
            restorationType[plane] = remap[try reader.readBits(2)]
            if restorationType[plane] != 0 {
                usesRestoration = true
                if plane > 0 {
                    usesChromaRestoration = true
                }
            }
        }
        if usesRestoration {
            var unitShift: Int
            if sequence.use128x128Superblock {
                unitShift = 1 + (try reader.readBit())
            } else {
                unitShift = try reader.readBit()
                if unitShift == 1 {
                    unitShift += try reader.readBit()
                }
            }
            restorationSize[0] = 256 >> (2 - unitShift)
            var uvShift = 0
            if sequence.subsamplingX == 1, sequence.subsamplingY == 1, usesChromaRestoration {
                uvShift = try reader.readBit()
            }
            restorationSize[1] = restorationSize[0] >> uvShift
            restorationSize[2] = restorationSize[0] >> uvShift
        }
    }

    private mutating func parseTileInfo(
        _ reader: inout HEVCBitReader,
        sequence: AV1SequenceHeader
    ) throws {
        var info = AV1TileInfo()
        let sbShift = sequence.use128x128Superblock ? 5 : 4
        let sbCols = (miCols + (1 << sbShift) - 1) >> sbShift
        let sbRows = (miRows + (1 << sbShift) - 1) >> sbShift
        let sbSize = sbShift + 2
        let maxTileWidthSb = 4096 >> sbSize
        var maxTileAreaSb = (4096 * 2304) >> (2 * sbSize)
        let minLog2TileCols = Self.tileLog2(maxTileWidthSb, sbCols)
        let maxLog2TileCols = Self.tileLog2(1, min(sbCols, 64))
        let maxLog2TileRows = Self.tileLog2(1, min(sbRows, 64))
        let minLog2Tiles = max(minLog2TileCols, Self.tileLog2(maxTileAreaSb, sbRows * sbCols))

        if try reader.readFlag() {  // uniform_tile_spacing_flag
            info.colsLog2 = minLog2TileCols
            while info.colsLog2 < maxLog2TileCols {
                if try reader.readFlag() {
                    info.colsLog2 += 1
                } else {
                    break
                }
            }
            let tileWidthSb = (sbCols + (1 << info.colsLog2) - 1) >> info.colsLog2
            var startSb = 0
            while startSb < sbCols {
                info.miColStarts.append(startSb << sbShift)
                startSb += tileWidthSb
            }
            info.miColStarts.append(miCols)

            let minLog2TileRows = max(minLog2Tiles - info.colsLog2, 0)
            info.rowsLog2 = minLog2TileRows
            while info.rowsLog2 < maxLog2TileRows {
                if try reader.readFlag() {
                    info.rowsLog2 += 1
                } else {
                    break
                }
            }
            let tileHeightSb = (sbRows + (1 << info.rowsLog2) - 1) >> info.rowsLog2
            startSb = 0
            while startSb < sbRows {
                info.miRowStarts.append(startSb << sbShift)
                startSb += tileHeightSb
            }
            info.miRowStarts.append(miRows)
        } else {
            var widestTileSb = 0
            var startSb = 0
            while startSb < sbCols {
                info.miColStarts.append(startSb << sbShift)
                let maxWidth = min(sbCols - startSb, maxTileWidthSb)
                let sizeSb = 1 + (try reader.readNonSymmetric(maxWidth))
                widestTileSb = max(sizeSb, widestTileSb)
                startSb += sizeSb
            }
            info.miColStarts.append(miCols)
            info.colsLog2 = Self.tileLog2(1, info.miColStarts.count - 1)
            if minLog2Tiles > 0 {
                maxTileAreaSb = (sbRows * sbCols) >> (minLog2Tiles + 1)
            } else {
                maxTileAreaSb = sbRows * sbCols
            }
            let maxTileHeightSb = max(maxTileAreaSb / max(widestTileSb, 1), 1)
            startSb = 0
            while startSb < sbRows {
                info.miRowStarts.append(startSb << sbShift)
                let maxHeight = min(sbRows - startSb, maxTileHeightSb)
                startSb += 1 + (try reader.readNonSymmetric(maxHeight))
            }
            info.miRowStarts.append(miRows)
            info.rowsLog2 = Self.tileLog2(1, info.miRowStarts.count - 1)
        }
        if info.colsLog2 > 0 || info.rowsLog2 > 0 {
            info.contextUpdateTileID = try reader.readBits(info.rowsLog2 + info.colsLog2)
            info.sizeBytes = 1 + (try reader.readBits(2))
        }
        tiles = info
    }

    /// tile_log2: the smallest k with blkSize << k ≥ target.
    private static func tileLog2(_ blockSize: Int, _ target: Int) -> Int {
        var k = 0
        while (blockSize << k) < target {
            k += 1
        }
        return k
    }
}

/// Tile layout: mode-info-unit start positions per tile column/row.
struct AV1TileInfo {
    var colsLog2 = 0
    var rowsLog2 = 0
    var miColStarts: [Int] = []
    var miRowStarts: [Int] = []
    var contextUpdateTileID = 0
    var sizeBytes = 1

    var columnCount: Int { max(miColStarts.count - 1, 0) }
    var rowCount: Int { max(miRowStarts.count - 1, 0) }
    var tileCount: Int { columnCount * rowCount }
}

/// The framing of a tile group (5.11.1): the byte ranges of each tile's
/// symbol-coded data.
struct AV1TileGroup {
    var tiles: [[UInt8]] = []

    /// `payload` is the tile-group portion (byte-aligned, after the frame
    /// header for frame OBUs).
    static func parse(
        _ payload: [UInt8],
        tileInfo: AV1TileInfo
    ) throws -> AV1TileGroup {
        var group = AV1TileGroup()
        var reader = HEVCBitReader(payload)
        let tileCount = tileInfo.tileCount
        var tileStart = 0
        var tileEnd = tileCount - 1
        if tileCount > 1 {
            if try reader.readFlag() {  // tile_start_and_end_present_flag
                let bits = tileInfo.colsLog2 + tileInfo.rowsLog2
                tileStart = try reader.readBits(bits)
                tileEnd = try reader.readBits(bits)
            }
        }
        guard tileStart == 0, tileEnd == tileCount - 1 else {
            throw ImageError.unsupportedFeature(reason: "AV1 multi-group tile lists are not supported")
        }
        reader.alignToByte()
        var offset = reader.bitPosition / 8

        for tileIndex in 0..<tileCount {
            let size: Int
            if tileIndex == tileCount - 1 {
                size = payload.count - offset
            } else {
                guard offset + tileInfo.sizeBytes <= payload.count else {
                    throw ImageError.invalidData(reason: "Truncated AV1 tile group")
                }
                // tile_size_minus_1: little-endian.
                var value = 0
                for i in 0..<tileInfo.sizeBytes {
                    value |= Int(payload[offset + i]) << (8 * i)
                }
                offset += tileInfo.sizeBytes
                size = value + 1
            }
            guard size >= 1, offset + size <= payload.count else {
                throw ImageError.invalidData(reason: "AV1 tile exceeds its group")
            }
            group.tiles.append(Array(payload[offset..<offset + size]))
            offset += size
        }
        return group
    }
}

extension HEVCBitReader {
    /// su(n): an n-bit two's-complement style signed value (AV1 4.10.6).
    mutating func readSigned(_ bits: Int) throws -> Int {
        let value = try readBits(bits)
        let signMask = 1 << (bits - 1)
        return value & signMask != 0 ? value - 2 * signMask : value
    }

    /// read_delta_q (5.9.13): a presence flag then su(7).
    mutating func readDeltaQ() throws -> Int {
        if try readFlag() {
            return try readSigned(7)
        }
        return 0
    }

    /// ns(n): non-symmetric unsigned value < n (AV1 4.10.7).
    mutating func readNonSymmetric(_ limit: Int) throws -> Int {
        guard limit > 1 else { return 0 }
        let width = Int.bitWidth - limit.leadingZeroBitCount  // FloorLog2(limit) + 1
        let m = (1 << width) - limit
        let value = try readBits(width - 1)
        if value < m {
            return value
        }
        let extra = try readBit()
        return (value << 1) - m + extra
    }
}
