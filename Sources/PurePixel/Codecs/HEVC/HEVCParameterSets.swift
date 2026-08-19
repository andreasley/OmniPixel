/// Quantization scaling matrices (ITU-T H.265 sections 7.3.4 and 7.4.5):
/// per transform size and matrix ID, at full block resolution in raster
/// order. Sizes 16 and 32 are coded as an 8×8 base matrix plus a DC value
/// and upsampled here.
struct HEVCScalingLists {
    /// [log2Size − 2][matrixID][y·size + x]. Matrix IDs 0–2 are intra
    /// Y/Cb/Cr, 3–5 inter; 32×32 has only the two luma matrices.
    private var scalingFactors: [[[Int]]]

    func factors(log2Size: Int, matrixID: Int) -> [Int] {
        let matrices = scalingFactors[log2Size - 2]
        return matrices[min(matrixID, matrices.count - 1)]
    }

    static let flat4: [Int] = [Int](repeating: 16, count: 16)
    static let defaultIntra8: [Int] = [
        16, 16, 16, 16, 17, 18, 21, 24,
        16, 16, 16, 16, 17, 19, 22, 25,
        16, 16, 17, 18, 20, 22, 25, 29,
        16, 16, 18, 21, 24, 27, 31, 36,
        17, 17, 20, 24, 30, 35, 41, 47,
        18, 19, 22, 27, 35, 44, 54, 65,
        21, 22, 25, 31, 41, 54, 70, 88,
        24, 25, 29, 36, 47, 65, 88, 115,
    ]
    static let defaultInter8: [Int] = [
        16, 16, 16, 16, 17, 18, 20, 24,
        16, 16, 16, 17, 18, 20, 24, 25,
        16, 16, 17, 18, 20, 24, 25, 28,
        16, 17, 18, 20, 24, 25, 28, 33,
        17, 18, 20, 24, 25, 28, 33, 41,
        18, 20, 24, 25, 28, 33, 41, 54,
        20, 24, 25, 28, 33, 41, 54, 71,
        24, 25, 28, 33, 41, 54, 71, 91,
    ]

    private static func defaultBase(sizeID: Int, matrixID: Int) -> [Int] {
        if sizeID == 0 {
            return flat4
        }
        return matrixID < 3 ? defaultIntra8 : defaultInter8
    }

    private init(scalingFactors: [[[Int]]]) {
        self.scalingFactors = scalingFactors
    }

    /// The specification's default matrices (used when scaling lists are
    /// enabled without explicit data).
    static let defaults: HEVCScalingLists = {
        var bases: [[[Int]]] = []
        var dcs: [[Int]] = []
        for sizeID in 0..<4 {
            let count = sizeID == 3 ? 2 : 6
            bases.append((0..<count).map { defaultBase(sizeID: sizeID, matrixID: sizeID == 3 ? $0 * 3 : $0) })
            dcs.append([Int](repeating: 16, count: count))
        }
        return HEVCScalingLists(scalingFactors: deriveFactors(bases: bases, dcValues: dcs))
    }()

    /// Parses scaling_list_data (7.3.4).
    init(reader: inout HEVCBitReader) throws {
        var bases: [[[Int]]] = []
        var dcValues: [[Int]] = []
        for sizeID in 0..<4 {
            let matrixCount = sizeID == 3 ? 2 : 6
            var sizeBases: [[Int]] = []
            var sizeDCs: [Int] = []
            for matrixIndex in 0..<matrixCount {
                let matrixID = sizeID == 3 ? matrixIndex * 3 : matrixIndex
                if try reader.readFlag() == false {
                    // Predicted: delta 0 selects the default matrix, other
                    // values copy an earlier matrix of the same size.
                    let delta = try reader.readUnsignedExpGolomb()
                    if delta == 0 {
                        sizeBases.append(Self.defaultBase(sizeID: sizeID, matrixID: matrixID))
                        sizeDCs.append(16)
                    } else {
                        let reference = matrixIndex - delta
                        guard reference >= 0 else {
                            throw ImageError.invalidData(reason: "Invalid HEVC scaling list reference")
                        }
                        sizeBases.append(sizeBases[reference])
                        sizeDCs.append(sizeDCs[reference])
                    }
                } else {
                    // Explicit: delta-coded coefficients in up-right
                    // diagonal order over the base matrix.
                    var nextCoefficient = 8
                    var dc = 16
                    if sizeID > 1 {
                        dc = 8 + (try reader.readSignedExpGolomb())
                        guard (1...255).contains(dc) else {
                            throw ImageError.invalidData(reason: "Invalid HEVC scaling list DC value")
                        }
                        nextCoefficient = dc
                    }
                    let baseSize = sizeID == 0 ? 4 : 8
                    let scan = HEVCScan.order(size: baseSize, scan: 0)
                    var base = [Int](repeating: 0, count: baseSize * baseSize)
                    for i in 0..<(baseSize * baseSize) {
                        let delta = try reader.readSignedExpGolomb()
                        nextCoefficient = (nextCoefficient + delta + 256) % 256
                        guard nextCoefficient > 0 else {
                            throw ImageError.invalidData(reason: "Invalid HEVC scaling list coefficient")
                        }
                        base[scan[i].y * baseSize + scan[i].x] = nextCoefficient
                    }
                    sizeBases.append(base)
                    sizeDCs.append(dc)
                }
            }
            bases.append(sizeBases)
            dcValues.append(sizeDCs)
        }
        scalingFactors = Self.deriveFactors(bases: bases, dcValues: dcValues)
    }

    /// Expands base matrices to full-resolution factors (7.4.5): 4×4 and
    /// 8×8 directly; 16×16 and 32×32 upsample the 8×8 base 2×/4× and take
    /// their DC entry from the coded DC value.
    private static func deriveFactors(bases: [[[Int]]], dcValues: [[Int]]) -> [[[Int]]] {
        var result: [[[Int]]] = []
        for sizeID in 0..<4 {
            var matrices: [[Int]] = []
            for (index, base) in bases[sizeID].enumerated() {
                if sizeID < 2 {
                    matrices.append(base)
                    continue
                }
                let size = sizeID == 2 ? 16 : 32
                let shift = sizeID == 2 ? 1 : 2
                var factors = [Int](repeating: 0, count: size * size)
                for y in 0..<size {
                    for x in 0..<size {
                        factors[y * size + x] = base[(y >> shift) * 8 + (x >> shift)]
                    }
                }
                factors[0] = dcValues[sizeID][index]
                matrices.append(factors)
            }
            result.append(matrices)
        }
        return result
    }
}

/// H.265 sequence parameter set — the fields a still-picture decoder needs
/// (ITU-T H.265 section 7.3.2.2).
struct HEVCSequenceParameterSet {
    var id = 0
    var profileIDC = 0
    var levelIDC = 0
    var chromaFormat = 1  // 1 = 4:2:0
    var width = 0
    var height = 0
    var croppedWidth = 0
    var croppedHeight = 0
    var cropLeft = 0
    var cropTop = 0
    var bitDepthLuma = 8
    var bitDepthChroma = 8
    var log2MaxPicOrderCount = 8
    var log2MinCodingBlockSize = 3
    var log2CTBSize = 6
    var log2MinTransformBlockSize = 2
    var log2MaxTransformBlockSize = 5
    var maxTransformHierarchyDepthInter = 0
    var maxTransformHierarchyDepthIntra = 0
    var scalingListEnabled = false
    var scalingLists: HEVCScalingLists?
    var ampEnabled = false
    var saoEnabled = false
    var pcmEnabled = false
    var temporalMVPEnabled = false
    var strongIntraSmoothingEnabled = false

    var ctbSize: Int { 1 << log2CTBSize }
    var ctbColumns: Int { (width + ctbSize - 1) >> log2CTBSize }
    var ctbRows: Int { (height + ctbSize - 1) >> log2CTBSize }

    static func parse(_ nal: HEVCNALUnit) throws -> HEVCSequenceParameterSet {
        var reader = HEVCBitReader(nal.payload)
        var sps = HEVCSequenceParameterSet()

        _ = try reader.readBits(4)  // sps_video_parameter_set_id
        let maxSubLayersMinus1 = try reader.readBits(3)
        _ = try reader.readBit()  // sps_temporal_id_nesting_flag
        (sps.profileIDC, sps.levelIDC) = try parseProfileTierLevel(&reader, maxSubLayersMinus1: maxSubLayersMinus1)

        sps.id = try reader.readUnsignedExpGolomb()
        sps.chromaFormat = try reader.readUnsignedExpGolomb()
        guard (0...3).contains(sps.chromaFormat) else {
            throw ImageError.invalidData(reason: "Invalid HEVC chroma format")
        }
        if sps.chromaFormat == 3 {
            guard try reader.readBit() == 0 else {
                throw ImageError.unsupportedFeature(reason: "HEVC with separate colour planes is not supported")
            }
        }

        sps.width = try reader.readUnsignedExpGolomb()
        sps.height = try reader.readUnsignedExpGolomb()
        let (pixelCount, overflow) = sps.width.multipliedReportingOverflow(by: sps.height)
        guard sps.width > 0, sps.height > 0, !overflow, pixelCount <= Image.maxPixelCount else {
            throw ImageError.invalidData(reason: "Invalid HEVC picture dimensions")
        }
        sps.croppedWidth = sps.width
        sps.croppedHeight = sps.height

        if try reader.readFlag() {  // conformance window
            let left = try reader.readUnsignedExpGolomb()
            let right = try reader.readUnsignedExpGolomb()
            let top = try reader.readUnsignedExpGolomb()
            let bottom = try reader.readUnsignedExpGolomb()
            let subWidth = sps.chromaFormat == 1 || sps.chromaFormat == 2 ? 2 : 1
            let subHeight = sps.chromaFormat == 1 ? 2 : 1
            sps.croppedWidth = sps.width - subWidth * (left + right)
            sps.croppedHeight = sps.height - subHeight * (top + bottom)
            sps.cropLeft = subWidth * left
            sps.cropTop = subHeight * top
            guard sps.croppedWidth > 0, sps.croppedHeight > 0 else {
                throw ImageError.invalidData(reason: "Invalid HEVC conformance window")
            }
        }

        sps.bitDepthLuma = 8 + (try reader.readUnsignedExpGolomb())
        sps.bitDepthChroma = 8 + (try reader.readUnsignedExpGolomb())
        sps.log2MaxPicOrderCount = 4 + (try reader.readUnsignedExpGolomb())

        let orderingInfoPresent = try reader.readFlag()
        for _ in (orderingInfoPresent ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 {
            _ = try reader.readUnsignedExpGolomb()  // sps_max_dec_pic_buffering_minus1
            _ = try reader.readUnsignedExpGolomb()  // sps_max_num_reorder_pics
            _ = try reader.readUnsignedExpGolomb()  // sps_max_latency_increase_plus1
        }

        sps.log2MinCodingBlockSize = 3 + (try reader.readUnsignedExpGolomb())
        sps.log2CTBSize = sps.log2MinCodingBlockSize + (try reader.readUnsignedExpGolomb())
        sps.log2MinTransformBlockSize = 2 + (try reader.readUnsignedExpGolomb())
        sps.log2MaxTransformBlockSize = sps.log2MinTransformBlockSize + (try reader.readUnsignedExpGolomb())
        sps.maxTransformHierarchyDepthInter = try reader.readUnsignedExpGolomb()
        sps.maxTransformHierarchyDepthIntra = try reader.readUnsignedExpGolomb()
        guard sps.log2CTBSize <= 6, sps.log2MaxTransformBlockSize <= 5 else {
            throw ImageError.invalidData(reason: "Invalid HEVC block size configuration")
        }

        sps.scalingListEnabled = try reader.readFlag()
        if sps.scalingListEnabled, try reader.readFlag() {
            sps.scalingLists = try HEVCScalingLists(reader: &reader)
        }
        sps.ampEnabled = try reader.readFlag()
        sps.saoEnabled = try reader.readFlag()
        sps.pcmEnabled = try reader.readFlag()
        if sps.pcmEnabled {
            _ = try reader.readBits(4)  // pcm_sample_bit_depth_luma_minus1
            _ = try reader.readBits(4)  // pcm_sample_bit_depth_chroma_minus1
            _ = try reader.readUnsignedExpGolomb()  // log2_min_pcm_luma_coding_block_size_minus3
            _ = try reader.readUnsignedExpGolomb()  // log2_diff_max_min_pcm_luma_coding_block_size
            _ = try reader.readFlag()  // pcm_loop_filter_disabled_flag
        }

        let shortTermRefPicSets = try reader.readUnsignedExpGolomb()
        guard shortTermRefPicSets == 0 else {
            throw ImageError.unsupportedFeature(reason: "HEVC streams with reference picture sets are not supported (still images only)")
        }
        guard try reader.readFlag() == false else {  // long_term_ref_pics_present_flag
            throw ImageError.unsupportedFeature(reason: "HEVC streams with long-term reference pictures are not supported")
        }
        sps.temporalMVPEnabled = try reader.readFlag()
        sps.strongIntraSmoothingEnabled = try reader.readFlag()
        // VUI parameters and extensions follow; nothing there affects decoding.
        return sps
    }

    /// profile_tier_level: fixed 96-bit general block plus per-sub-layer data.
    private static func parseProfileTierLevel(
        _ reader: inout HEVCBitReader,
        maxSubLayersMinus1: Int
    ) throws -> (profileIDC: Int, levelIDC: Int) {
        _ = try reader.readBits(2)  // general_profile_space
        _ = try reader.readBit()  // general_tier_flag
        let profileIDC = try reader.readBits(5)
        _ = try reader.readBits(32)  // compatibility flags
        _ = try reader.readBits(32)  // source/constraint and reserved bits…
        _ = try reader.readBits(16)  // …48 in total
        let levelIDC = try reader.readBits(8)

        if maxSubLayersMinus1 > 0 {
            var profilePresent: [Bool] = []
            var levelPresent: [Bool] = []
            for _ in 0..<maxSubLayersMinus1 {
                profilePresent.append(try reader.readFlag())
                levelPresent.append(try reader.readFlag())
            }
            for _ in maxSubLayersMinus1..<8 {
                _ = try reader.readBits(2)  // reserved alignment
            }
            for index in 0..<maxSubLayersMinus1 {
                if profilePresent[index] {
                    _ = try reader.readBits(32)
                    _ = try reader.readBits(32)
                    _ = try reader.readBits(24)  // 88-bit sub-layer profile
                }
                if levelPresent[index] {
                    _ = try reader.readBits(8)
                }
            }
        }
        return (profileIDC, levelIDC)
    }

}

/// H.265 picture parameter set (ITU-T H.265 section 7.3.2.3).
struct HEVCPictureParameterSet {
    var id = 0
    var spsID = 0
    var dependentSliceSegmentsEnabled = false
    var outputFlagPresent = false
    var numExtraSliceHeaderBits = 0
    var signDataHidingEnabled = false
    var cabacInitPresent = false
    var initQP = 26
    var constrainedIntraPrediction = false
    var transformSkipEnabled = false
    var scalingLists: HEVCScalingLists?
    var cuQPDeltaEnabled = false
    var diffCUQPDeltaDepth = 0
    var cbQPOffset = 0
    var crQPOffset = 0
    var sliceChromaQPOffsetsPresent = false
    var transquantBypassEnabled = false
    var tilesEnabled = false
    var entropyCodingSyncEnabled = false
    var tileColumns = 1
    var tileRows = 1
    var loopFilterAcrossSlicesEnabled = false
    var deblockingFilterControlPresent = false
    var deblockingFilterOverrideEnabled = false
    var deblockingFilterDisabled = false
    var betaOffset = 0
    var tcOffset = 0
    var log2ParallelMergeLevel = 2
    var sliceSegmentHeaderExtensionPresent = false

    static func parse(_ nal: HEVCNALUnit) throws -> HEVCPictureParameterSet {
        var reader = HEVCBitReader(nal.payload)
        var pps = HEVCPictureParameterSet()

        pps.id = try reader.readUnsignedExpGolomb()
        pps.spsID = try reader.readUnsignedExpGolomb()
        pps.dependentSliceSegmentsEnabled = try reader.readFlag()
        pps.outputFlagPresent = try reader.readFlag()
        pps.numExtraSliceHeaderBits = try reader.readBits(3)
        pps.signDataHidingEnabled = try reader.readFlag()
        pps.cabacInitPresent = try reader.readFlag()
        _ = try reader.readUnsignedExpGolomb()  // num_ref_idx_l0_default_active_minus1
        _ = try reader.readUnsignedExpGolomb()  // num_ref_idx_l1_default_active_minus1
        pps.initQP = 26 + (try reader.readSignedExpGolomb())
        pps.constrainedIntraPrediction = try reader.readFlag()
        pps.transformSkipEnabled = try reader.readFlag()
        pps.cuQPDeltaEnabled = try reader.readFlag()
        if pps.cuQPDeltaEnabled {
            pps.diffCUQPDeltaDepth = try reader.readUnsignedExpGolomb()
        }
        pps.cbQPOffset = try reader.readSignedExpGolomb()
        pps.crQPOffset = try reader.readSignedExpGolomb()
        pps.sliceChromaQPOffsetsPresent = try reader.readFlag()
        _ = try reader.readFlag()  // weighted_pred_flag
        _ = try reader.readFlag()  // weighted_bipred_flag
        pps.transquantBypassEnabled = try reader.readFlag()
        pps.tilesEnabled = try reader.readFlag()
        pps.entropyCodingSyncEnabled = try reader.readFlag()

        if pps.tilesEnabled {
            pps.tileColumns = 1 + (try reader.readUnsignedExpGolomb())
            pps.tileRows = 1 + (try reader.readUnsignedExpGolomb())
            let uniformSpacing = try reader.readFlag()
            if !uniformSpacing {
                for _ in 0..<(pps.tileColumns - 1) {
                    _ = try reader.readUnsignedExpGolomb()
                }
                for _ in 0..<(pps.tileRows - 1) {
                    _ = try reader.readUnsignedExpGolomb()
                }
            }
            _ = try reader.readFlag()  // loop_filter_across_tiles_enabled_flag
        }

        pps.loopFilterAcrossSlicesEnabled = try reader.readFlag()
        pps.deblockingFilterControlPresent = try reader.readFlag()
        if pps.deblockingFilterControlPresent {
            pps.deblockingFilterOverrideEnabled = try reader.readFlag()
            pps.deblockingFilterDisabled = try reader.readFlag()
            if !pps.deblockingFilterDisabled {
                pps.betaOffset = 2 * (try reader.readSignedExpGolomb())
                pps.tcOffset = 2 * (try reader.readSignedExpGolomb())
            }
        }
        if try reader.readFlag() {  // pps_scaling_list_data_present_flag
            pps.scalingLists = try HEVCScalingLists(reader: &reader)
        }
        _ = try reader.readFlag()  // lists_modification_present_flag
        pps.log2ParallelMergeLevel = 2 + (try reader.readUnsignedExpGolomb())
        pps.sliceSegmentHeaderExtensionPresent = try reader.readFlag()
        // pps_extension_present_flag and extensions follow; ignored.
        return pps
    }
}

/// One slice segment header of an intra slice (ITU-T H.265 section 7.3.6.1).
struct HEVCSliceHeader {
    var firstSliceInPicture = true
    var segmentAddress = 0
    var ppsID = 0
    var sliceType = 2
    var saoLuma = false
    var saoChroma = false
    var qp = 26
    var cbQPOffset = 0
    var crQPOffset = 0
    var deblockingFilterDisabled = false
    var betaOffset = 0
    var tcOffset = 0
    var loopFilterAcrossSlices = false
    var entryPointOffsets: [Int] = []
    /// Bit position in the RBSP where the CABAC-coded slice data begins.
    var dataBitOffset = 0

    static func parse(
        _ nal: HEVCNALUnit,
        sps: HEVCSequenceParameterSet,
        pps: HEVCPictureParameterSet
    ) throws -> HEVCSliceHeader {
        var reader = HEVCBitReader(nal.payload)
        var header = HEVCSliceHeader()

        header.firstSliceInPicture = try reader.readFlag()
        if nal.isIRAP {
            _ = try reader.readFlag()  // no_output_of_prior_pics_flag
        }
        header.ppsID = try reader.readUnsignedExpGolomb()

        if !header.firstSliceInPicture {
            if pps.dependentSliceSegmentsEnabled {
                guard try reader.readFlag() == false else {
                    throw ImageError.unsupportedFeature(reason: "HEVC dependent slice segments are not supported yet")
                }
            }
            let picSizeInCTBs = sps.ctbColumns * sps.ctbRows
            var addressBits = 0
            while (1 << addressBits) < picSizeInCTBs {
                addressBits += 1
            }
            header.segmentAddress = try reader.readBits(addressBits)
        }

        for _ in 0..<pps.numExtraSliceHeaderBits {
            _ = try reader.readBit()
        }
        header.sliceType = try reader.readUnsignedExpGolomb()
        guard header.sliceType == 2 else {
            throw ImageError.unsupportedFeature(reason: "Only intra-coded HEVC slices are supported (still images)")
        }
        if pps.outputFlagPresent {
            _ = try reader.readFlag()  // pic_output_flag
        }

        if !nal.isIDR {
            // CRA and other non-IDR intra pictures carry POC and an inline
            // (necessarily empty, since the SPS has none) reference pic set.
            _ = try reader.readBits(sps.log2MaxPicOrderCount)  // slice_pic_order_cnt_lsb
            guard try reader.readFlag() == false else {  // short_term_ref_pic_set_sps_flag
                throw ImageError.invalidData(reason: "HEVC slice references a missing reference picture set")
            }
            let negativePictures = try reader.readUnsignedExpGolomb()
            let positivePictures = try reader.readUnsignedExpGolomb()
            guard negativePictures == 0, positivePictures == 0 else {
                throw ImageError.unsupportedFeature(reason: "HEVC streams with reference pictures are not supported (still images only)")
            }
            if sps.temporalMVPEnabled {
                _ = try reader.readFlag()  // slice_temporal_mvp_enabled_flag
            }
        }

        if sps.saoEnabled {
            header.saoLuma = try reader.readFlag()
            header.saoChroma = try reader.readFlag()
        }

        header.qp = pps.initQP + (try reader.readSignedExpGolomb())
        guard (0...51).contains(header.qp) else {
            throw ImageError.invalidData(reason: "HEVC slice quantization parameter out of range")
        }
        if pps.sliceChromaQPOffsetsPresent {
            header.cbQPOffset = try reader.readSignedExpGolomb()
            header.crQPOffset = try reader.readSignedExpGolomb()
        }

        header.deblockingFilterDisabled = pps.deblockingFilterDisabled
        header.betaOffset = pps.betaOffset
        header.tcOffset = pps.tcOffset
        if pps.deblockingFilterControlPresent {
            var overridden = false
            if pps.deblockingFilterOverrideEnabled {
                overridden = try reader.readFlag()
            }
            if overridden {
                header.deblockingFilterDisabled = try reader.readFlag()
                if !header.deblockingFilterDisabled {
                    header.betaOffset = 2 * (try reader.readSignedExpGolomb())
                    header.tcOffset = 2 * (try reader.readSignedExpGolomb())
                }
            }
        }

        if pps.loopFilterAcrossSlicesEnabled,
           header.saoLuma || header.saoChroma || !header.deblockingFilterDisabled {
            header.loopFilterAcrossSlices = try reader.readFlag()
        } else {
            header.loopFilterAcrossSlices = pps.loopFilterAcrossSlicesEnabled
        }

        if pps.tilesEnabled || pps.entropyCodingSyncEnabled {
            let entryPointCount = try reader.readUnsignedExpGolomb()
            if entryPointCount > 0 {
                let offsetBits = 1 + (try reader.readUnsignedExpGolomb())
                guard offsetBits <= 32, entryPointCount <= 1 << 16 else {
                    throw ImageError.invalidData(reason: "Invalid HEVC entry point table")
                }
                for _ in 0..<entryPointCount {
                    header.entryPointOffsets.append(1 + (try reader.readBits(offsetBits)))
                }
            }
        }

        if pps.sliceSegmentHeaderExtensionPresent {
            let extensionLength = try reader.readUnsignedExpGolomb()
            guard extensionLength <= 256 else {
                throw ImageError.invalidData(reason: "Invalid HEVC slice header extension")
            }
            for _ in 0..<extensionLength {
                _ = try reader.readBits(8)
            }
        }

        // byte_alignment(): a one bit, then zeros to the byte boundary.
        guard try reader.readBit() == 1 else {
            throw ImageError.invalidData(reason: "Corrupt HEVC slice header alignment")
        }
        reader.alignToByte()
        header.dataBitOffset = reader.bitPosition
        return header
    }
}
