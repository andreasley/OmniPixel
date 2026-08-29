/// Everything the slice syntax layer extracts from a coded picture, in
/// decode order, ready for the prediction/reconstruction milestone.
struct HEVCPictureData {
    struct TransformBlock {
        var componentIndex: Int  // 0 luma, 1 Cb, 2 Cr (chroma in chroma coordinates)
        var x: Int
        var y: Int
        var log2Size: Int
        var intraMode: Int
        var transformSkip: Bool
        var transquantBypass: Bool
        var qp: Int
        var coefficients: [Int]  // natural (row-major) order
    }

    struct SAOParameters {
        var typeIndex: [Int]      // per component: 0 off, 1 band, 2 edge
        var offsets: [[Int]]      // per component: 4 signed offsets
        var bandPosition: [Int]   // per component
        var eoClass: [Int]        // per component
    }

    var decodedCTBCount = 0
    var transformBlocks: [TransformBlock] = []
    var sao: [SAOParameters] = []
    /// Intra prediction mode per 4×4 luma block (raster grid).
    var lumaModeGrid: [Int] = []
    var chromaModeGrid: [Int] = []
    /// Luma QP per 4×4 block, for the deblocking filter.
    var qpGrid: [Int] = []
    /// Combined PPS + slice chroma quantization offsets.
    var cbQPOffset = 0
    var crQPOffset = 0
    /// Deblocking parameters from the slice header.
    var deblockingDisabled = false
    var betaOffset = 0
    var tcOffset = 0
}

/// Decodes the CABAC-coded slice data of an intra picture: SAO parameters,
/// the coding quadtree, intra prediction modes, the transform tree and all
/// residual coefficients (ITU-T H.265 sections 7.3.8.3–7.3.8.11).
final class HEVCPictureDecoder {
    private let sps: HEVCSequenceParameterSet
    private let pps: HEVCPictureParameterSet

    // Dynamic exclusivity enforcement on the hot mutable state costs a TLS
    // lookup per decoded bin; decoding is strictly single-threaded per
    // instance and never forms aliasing inout pairs.
    @exclusivity(unchecked) private var cabac: CABACDecoder
    @exclusivity(unchecked) private var contexts: HEVCContextSet
    @exclusivity(unchecked) private var savedWPPContexts: HEVCContextSet?

    // Picture-level grids at 4×4 granularity for context derivations.
    private let grid4Width: Int
    private let grid4Height: Int
    @exclusivity(unchecked) private var depthGrid: [Int8]      // coding-tree depth, -1 = undecoded
    @exclusivity(unchecked) private var modeGrid: [Int8]       // luma intra mode, -1 = unavailable
    @exclusivity(unchecked) private var chromaGrid: [Int8]
    @exclusivity(unchecked) private var qpGrid: [Int8]         // luma QP of the covering CU
    @exclusivity(unchecked) private var ctbSliceIndex: [Int]   // slice index per CTB, -1 = undecoded

    // Per-slice state.
    private var sliceQP = 26
    private var currentSliceIndex = 0
    private var currentHeader: HEVCSliceHeader
    private var cuQPDeltaCoded = false
    private var currentQP = 26
    private var predictedQGQP = 26
    private var previousQGQP = 26
    private var qgOrigin = (x: 0, y: 0)
    private var qgPredicted = true
    private var currentTransquantBypass = false
    private var currentChromaMode = 1

    // Residual-decoding scratch, reused for every sub-block.
    @exclusivity(unchecked) private var positionScratch = [Int](repeating: 0, count: 16)
    @exclusivity(unchecked) private var levelScratch = [Int](repeating: 0, count: 16)
    // Coded-sub-block map scratch, reused per TU (max 8×8 sub-blocks).
    @exclusivity(unchecked) private var subBlockCodedScratch = [Bool](repeating: false, count: 64)
    // Intra-mode scratch, reused per CU (max 4 partitions).
    @exclusivity(unchecked) private var prevIntraFlagScratch = [Bool](repeating: false, count: 4)
    @exclusivity(unchecked) private var lumaModeScratch = [Int](repeating: 1, count: 4)

    @exclusivity(unchecked) private(set) var picture = HEVCPictureData()

    /// Diagnostic hook for decoder bring-up: receives coarse syntax events.
    var trace: ((String) -> Void)?
    /// Bin-level diagnostic hook: sub-block and level events inside residuals.
    var fineTrace: ((String) -> Void)?

    init(sps: HEVCSequenceParameterSet, pps: HEVCPictureParameterSet) throws {
        self.sps = sps
        self.pps = pps
        grid4Width = (sps.width + 3) >> 2
        grid4Height = (sps.height + 3) >> 2
        depthGrid = [Int8](repeating: -1, count: grid4Width * grid4Height)
        modeGrid = [Int8](repeating: -1, count: grid4Width * grid4Height)
        chromaGrid = [Int8](repeating: -1, count: grid4Width * grid4Height)
        qpGrid = [Int8](repeating: 26, count: grid4Width * grid4Height)
        ctbSliceIndex = [Int](repeating: -1, count: sps.ctbColumns * sps.ctbRows)
        picture.sao = [HEVCPictureData.SAOParameters](
            repeating: HEVCPictureData.SAOParameters(
                typeIndex: [0, 0, 0],
                offsets: [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]],
                bandPosition: [0, 0, 0],
                eoClass: [0, 0, 0]
            ),
            count: sps.ctbColumns * sps.ctbRows
        )
        // Placeholder values; each slice re-creates these.
        cabac = try CABACDecoder(bytes: [0, 0], startingAtBit: 0)
        contexts = HEVCContextSet(qp: 26)
        currentHeader = HEVCSliceHeader()
    }

    /// Decodes every slice of the picture; throws if the syntax desynchronizes.
    func decodePicture(sliceNALUnits: [HEVCNALUnit]) throws -> HEVCPictureData {
        guard !pps.tilesEnabled else {
            throw ImageError.unsupportedFeature(reason: "Tiled HEVC streams are not supported yet")
        }
        guard sps.chromaFormat == 1 else {
            throw ImageError.unsupportedFeature(reason: "Only 4:2:0 HEVC is supported yet (this stream is chroma format \(sps.chromaFormat))")
        }
        for (index, nal) in sliceNALUnits.enumerated() {
            let header = try HEVCSliceHeader.parse(nal, sps: sps, pps: pps)
            try decodeSlice(nal: nal, header: header, sliceIndex: index)
        }
        guard picture.decodedCTBCount == sps.ctbColumns * sps.ctbRows else {
            throw ImageError.invalidData(reason: "HEVC slices don't cover the picture")
        }
        picture.lumaModeGrid = modeGrid.map(Int.init)
        picture.chromaModeGrid = chromaGrid.map(Int.init)
        picture.qpGrid = qpGrid.map(Int.init)
        return picture
    }

    private func decodeSlice(nal: HEVCNALUnit, header: HEVCSliceHeader, sliceIndex: Int) throws {
        currentHeader = header
        currentSliceIndex = sliceIndex
        sliceQP = header.qp
        currentQP = header.qp
        picture.cbQPOffset = pps.cbQPOffset + header.cbQPOffset
        picture.crQPOffset = pps.crQPOffset + header.crQPOffset
        picture.deblockingDisabled = header.deblockingFilterDisabled
        picture.betaOffset = header.betaOffset
        picture.tcOffset = header.tcOffset
        contexts = HEVCContextSet(qp: sliceQP)
        savedWPPContexts = nil
        cabac = try CABACDecoder(bytes: nal.payload, startingAtBit: header.dataBitOffset)

        // Wavefront substreams start at byte offsets given by the entry
        // points, which count raw (escaped) bytes; map them into the
        // unescaped payload.
        var substreamStarts: [Int] = []
        if pps.entropyCodingSyncEnabled {
            var rawOffset = nal.rawOffset(forUnescaped: header.dataBitOffset / 8)
            for entryPoint in header.entryPointOffsets {
                rawOffset += entryPoint
                substreamStarts.append(nal.unescapedOffset(forRaw: rawOffset) * 8)
            }
        }
        var nextSubstream = 0

        var ctbAddress = header.segmentAddress
        let totalCTBs = sps.ctbColumns * sps.ctbRows
        while true {
            guard ctbAddress < totalCTBs else {
                throw ImageError.invalidData(reason: "HEVC slice runs past the picture")
            }
            let ctbX = ctbAddress % sps.ctbColumns
            let ctbY = ctbAddress / sps.ctbColumns

            // Wavefront: at each row start, restore the contexts saved after
            // the second CTB of the row above and jump to the next substream.
            if pps.entropyCodingSyncEnabled, ctbX == 0, ctbAddress != header.segmentAddress {
                if let saved = savedWPPContexts {
                    contexts = saved
                }
                guard nextSubstream < substreamStarts.count else {
                    throw ImageError.invalidData(reason: "HEVC wavefront substream missing")
                }
                cabac = try CABACDecoder(bytes: nal.payload, startingAtBit: substreamStarts[nextSubstream])
                nextSubstream += 1
                // QP prediction restarts from the slice QP at each row.
                currentQP = sliceQP
            }

            ctbSliceIndex[ctbAddress] = sliceIndex
            trace?("CTB \(ctbAddress) (\(ctbX),\(ctbY)) @bit \(cabac.bitPosition)")
            if sps.saoEnabled, currentHeader.saoLuma || currentHeader.saoChroma {
                try decodeSAO(ctbX: ctbX, ctbY: ctbY)
                let sao = picture.sao[ctbAddress]
                trace?("  SAO types \(sao.typeIndex) offsets \(sao.offsets)")
            }
            try decodeCodingQuadtree(
                x: ctbX << sps.log2CTBSize,
                y: ctbY << sps.log2CTBSize,
                log2Size: sps.log2CTBSize,
                depth: 0
            )
            picture.decodedCTBCount += 1

            if pps.entropyCodingSyncEnabled, ctbX == min(1, sps.ctbColumns - 1) {
                savedWPPContexts = contexts
            }

            let endOfSlice = try cabac.decodeTerminate()
            if endOfSlice == 1 {
                return
            }
            if pps.entropyCodingSyncEnabled, ctbX == sps.ctbColumns - 1 {
                guard try cabac.decodeTerminate() == 1 else {
                    throw ImageError.invalidData(reason: "HEVC wavefront row did not terminate")
                }
            }
            ctbAddress += 1
        }
    }

    // MARK: Neighbor availability

    private func isAvailable(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < sps.width, y < sps.height else { return false }
        let ctb = (y >> sps.log2CTBSize) * sps.ctbColumns + (x >> sps.log2CTBSize)
        return ctbSliceIndex[ctb] == currentSliceIndex
    }

    private func gridIndex(x: Int, y: Int) -> Int {
        (y >> 2) * grid4Width + (x >> 2)
    }

    // MARK: SAO syntax (7.3.8.3)

    private func decodeSAO(ctbX: Int, ctbY: Int) throws {
        let ctbAddress = ctbY * sps.ctbColumns + ctbX
        var merged = false

        if ctbX > 0, isAvailable(x: (ctbX << sps.log2CTBSize) - 1, y: ctbY << sps.log2CTBSize) {
            if try cabac.decodeBin(&contexts.saoMerge) == 1 {
                picture.sao[ctbAddress] = picture.sao[ctbAddress - 1]
                merged = true
            }
        }
        if !merged, ctbY > 0, isAvailable(x: ctbX << sps.log2CTBSize, y: (ctbY << sps.log2CTBSize) - 1) {
            if try cabac.decodeBin(&contexts.saoMerge) == 1 {
                picture.sao[ctbAddress] = picture.sao[ctbAddress - sps.ctbColumns]
                merged = true
            }
        }
        guard !merged else { return }

        var parameters = picture.sao[ctbAddress]
        for component in 0..<3 {
            if component == 0, !currentHeader.saoLuma { continue }
            if component > 0, !currentHeader.saoChroma { continue }

            if component <= 1 {
                var typeIndex = 0
                if try cabac.decodeBin(&contexts.saoTypeIndex) == 1 {
                    typeIndex = try cabac.decodeBypass() == 1 ? 2 : 1
                }
                parameters.typeIndex[component] = typeIndex
                if component == 1 {
                    parameters.typeIndex[2] = typeIndex  // Cr shares Cb's type
                }
            }
            let typeIndex = parameters.typeIndex[component]
            guard typeIndex != 0 else { continue }

            var offsets = [0, 0, 0, 0]
            for i in 0..<4 {
                // Truncated Rice, cMax 7, all bypass.
                var magnitude = 0
                while magnitude < 7, try cabac.decodeBypass() == 1 {
                    magnitude += 1
                }
                offsets[i] = magnitude
            }
            if typeIndex == 1 {  // band offset
                for i in 0..<4 where offsets[i] != 0 {
                    if try cabac.decodeBypass() == 1 {
                        offsets[i] = -offsets[i]
                    }
                }
                parameters.bandPosition[component] = try cabac.decodeBypassBits(5)
            } else {  // edge offset: first two positive, last two negative
                offsets[2] = -offsets[2]
                offsets[3] = -offsets[3]
                if component <= 1 {
                    parameters.eoClass[component] = try cabac.decodeBypassBits(2)
                    if component == 1 {
                        parameters.eoClass[2] = parameters.eoClass[1]
                    }
                }
            }
            parameters.offsets[component] = offsets
        }
        picture.sao[ctbAddress] = parameters
    }

    // MARK: Coding quadtree (7.3.8.4)

    private func decodeCodingQuadtree(x: Int, y: Int, log2Size: Int, depth: Int) throws {
        let size = 1 << log2Size

        // Quantization group boundary: nested nodes narrow the group's
        // origin to the deepest node of at least the group size; the QP
        // prediction itself happens at the group's first coding unit.
        if pps.cuQPDeltaEnabled, log2Size >= sps.log2CTBSize - pps.diffCUQPDeltaDepth {
            cuQPDeltaCoded = false
            qgOrigin = (x, y)
            qgPredicted = false
        }

        var split: Bool
        if x + size <= sps.width, y + size <= sps.height, log2Size > sps.log2MinCodingBlockSize {
            var contextIndex = 0
            if isAvailable(x: x - 1, y: y), depthGrid[gridIndex(x: x - 1, y: y)] > Int8(depth) {
                contextIndex += 1
            }
            if isAvailable(x: x, y: y - 1), depthGrid[gridIndex(x: x, y: y - 1)] > Int8(depth) {
                contextIndex += 1
            }
            split = try cabac.decodeBin(&contexts.splitCUFlag[contextIndex]) == 1
        } else {
            split = log2Size > sps.log2MinCodingBlockSize
        }

        if split {
            let half = size >> 1
            for quadrant in 0..<4 {
                let childX = x + (quadrant & 1) * half
                let childY = y + (quadrant >> 1) * half
                if childX < sps.width, childY < sps.height {
                    try decodeCodingQuadtree(x: childX, y: childY, log2Size: log2Size - 1, depth: depth + 1)
                }
            }
        } else {
            // Record depth for split-flag context derivation.
            for blockY in stride(from: y, to: min(y + size, sps.height), by: 4) {
                for blockX in stride(from: x, to: min(x + size, sps.width), by: 4) {
                    depthGrid[gridIndex(x: blockX, y: blockY)] = Int8(depth)
                }
            }
            try decodeCodingUnit(x: x, y: y, log2Size: log2Size)
        }
    }

    // MARK: Coding unit (7.3.8.5)

    private func decodeCodingUnit(x: Int, y: Int, log2Size: Int) throws {
        // First coding unit of a quantization group: derive the predicted
        // QP from the left/above neighbours of the group origin (8.6.1);
        // qPY_PREV is the previous group's final QP in decode order.
        if pps.cuQPDeltaEnabled, !qgPredicted {
            qgPredicted = true
            previousQGQP = currentQP
            predictedQGQP = predictQP(x: qgOrigin.x, y: qgOrigin.y)
            currentQP = predictedQGQP
            fineTrace?("      QG (\(qgOrigin.x),\(qgOrigin.y)) predicted \(predictedQGQP) prev \(previousQGQP)")
        }
        currentTransquantBypass = false
        if pps.transquantBypassEnabled {
            currentTransquantBypass = try cabac.decodeBin(&contexts.transquantBypass) == 1
        }

        // I-slices contain only intra CUs; the partitioning is 2N×2N unless
        // the CU is at minimum size, where N×N is possible.
        var partsAcross = 1
        if log2Size == sps.log2MinCodingBlockSize {
            if try cabac.decodeBin(&contexts.partMode) == 0 {
                partsAcross = 2
            }
        }
        if sps.pcmEnabled, partsAcross == 1 {
            throw ImageError.unsupportedFeature(reason: "HEVC PCM coding is not supported yet")
        }

        let partSize = (1 << log2Size) >> (partsAcross - 1)
        let partCount = partsAcross * partsAcross

        for part in 0..<partCount {
            prevIntraFlagScratch[part] = try cabac.decodeBin(&contexts.prevIntraLumaPred) == 1
        }

        for part in 0..<partCount {
            let partX = x + (part & 1) * partSize
            let partY = y + (part >> 1) * partSize
            let candidates = mostProbableModes(x: partX, y: partY)
            if prevIntraFlagScratch[part] {
                // mpm_idx: truncated unary of up to two bypass bins.
                var index = 0
                if try cabac.decodeBypass() == 1 {
                    index = try cabac.decodeBypass() == 1 ? 2 : 1
                }
                lumaModeScratch[part] = candidates[index]
            } else {
                var mode = try cabac.decodeBypassBits(5)
                // The three most probable modes are removed from the code space.
                for candidate in candidates.sorted() where mode >= candidate {
                    mode += 1
                }
                lumaModeScratch[part] = mode
            }
            for blockY in stride(from: partY, to: min(partY + partSize, sps.height), by: 4) {
                for blockX in stride(from: partX, to: min(partX + partSize, sps.width), by: 4) {
                    modeGrid[gridIndex(x: blockX, y: blockY)] = Int8(lumaModeScratch[part])
                }
            }
        }

        // Chroma mode (4:2:0: one for the whole CU).
        var chromaMode: Int
        if try cabac.decodeBin(&contexts.intraChromaPredMode) == 1 {
            let index = try cabac.decodeBypassBits(2)
            var candidates = [0, 26, 10, 1]
            for i in 0..<4 where candidates[i] == lumaModeScratch[0] {
                candidates[i] = 34
            }
            chromaMode = candidates[index]
        } else {
            chromaMode = lumaModeScratch[0]
        }
        currentChromaMode = chromaMode
        trace?("  CU (\(x),\(y)) size \(1 << log2Size) modes \(Array(lumaModeScratch[0..<partCount])) chroma \(chromaMode) tqb \(currentTransquantBypass)")
        let size = 1 << log2Size
        for blockY in stride(from: y, to: min(y + size, sps.height), by: 4) {
            for blockX in stride(from: x, to: min(x + size, sps.width), by: 4) {
                chromaGrid[gridIndex(x: blockX, y: blockY)] = Int8(chromaMode)
            }
        }

        try decodeTransformTree(
            x: x, y: y, baseX: x, baseY: y,
            log2Size: log2Size, depth: 0, blockIndex: 0,
            intraSplit: partsAcross == 2,
            parentCbfCb: true, parentCbfCr: true
        )

        // Record the CU's final QP for neighbouring QP prediction.
        for blockY in stride(from: y, to: min(y + size, sps.height), by: 4) {
            for blockX in stride(from: x, to: min(x + size, sps.width), by: 4) {
                qpGrid[gridIndex(x: blockX, y: blockY)] = Int8(currentQP)
            }
        }
    }

    /// Derives the three most probable intra modes (8.4.2).
    private func mostProbableModes(x: Int, y: Int) -> [Int] {
        func neighborMode(x nx: Int, y ny: Int, forceDC: Bool) -> Int {
            guard !forceDC, isAvailable(x: nx, y: ny) else { return 1 }  // DC
            let mode = modeGrid[gridIndex(x: nx, y: ny)]
            return mode < 0 ? 1 : Int(mode)
        }
        let left = neighborMode(x: x - 1, y: y, forceDC: false)
        let aboveOutsideCTB = (y - 1) >> sps.log2CTBSize != y >> sps.log2CTBSize
        let above = neighborMode(x: x, y: y - 1, forceDC: aboveOutsideCTB)

        if left == above {
            if left < 2 {
                return [0, 1, 26]
            }
            return [left, 2 + ((left + 29) % 32), 2 + ((left - 2 + 1) % 32)]
        }
        let third: Int
        if left != 0 && above != 0 {
            third = 0
        } else if left != 1 && above != 1 {
            third = 1
        } else {
            third = 26
        }
        return [left, above, third]
    }

    // MARK: Transform tree (7.3.8.8)

    private func decodeTransformTree(
        x: Int, y: Int, baseX: Int, baseY: Int,
        log2Size: Int, depth: Int, blockIndex: Int,
        intraSplit: Bool,
        parentCbfCb: Bool, parentCbfCr: Bool
    ) throws {
        let maxDepth = sps.maxTransformHierarchyDepthIntra + (intraSplit ? 1 : 0)

        let mayReadSplit = log2Size <= sps.log2MaxTransformBlockSize
            && log2Size > sps.log2MinTransformBlockSize
            && depth < maxDepth
            && !(intraSplit && depth == 0)
        let split: Bool
        if mayReadSplit {
            split = try cabac.decodeBin(&contexts.splitTransformFlag[5 - log2Size]) == 1
        } else {
            split = log2Size > sps.log2MaxTransformBlockSize || (intraSplit && depth == 0)
        }

        var cbfCb = parentCbfCb
        var cbfCr = parentCbfCr
        if log2Size > 2 {
            if depth == 0 || parentCbfCb {
                cbfCb = try cabac.decodeBin(&contexts.cbfChroma[min(depth, 3)]) == 1
            }
            if depth == 0 || parentCbfCr {
                cbfCr = try cabac.decodeBin(&contexts.cbfChroma[min(depth, 3)]) == 1
            }
        }

        if split {
            let half = (1 << log2Size) >> 1
            for quadrant in 0..<4 {
                try decodeTransformTree(
                    x: x + (quadrant & 1) * half,
                    y: y + (quadrant >> 1) * half,
                    baseX: x, baseY: y,
                    log2Size: log2Size - 1, depth: depth + 1, blockIndex: quadrant,
                    intraSplit: intraSplit,
                    parentCbfCb: cbfCb, parentCbfCr: cbfCr
                )
            }
            return
        }

        // Leaf transform unit; intra blocks always code the luma cbf.
        let cbfLuma = try cabac.decodeBin(&contexts.cbfLuma[depth == 0 ? 1 : 0]) == 1

        let chromaHere = log2Size > 2
        let chromaAtLastBlock = log2Size == 2 && blockIndex == 3

        // The delta-QP condition counts the parent's chroma cbf at EVERY
        // 4×4 block index, not just the one that carries the chroma
        // residual (7.3.8.10).
        let anyCbf = cbfLuma
            || (chromaHere && (cbfCb || cbfCr))
            || (log2Size == 2 && (parentCbfCb || parentCbfCr))
        if anyCbf, pps.cuQPDeltaEnabled, !cuQPDeltaCoded {
            try decodeQPDelta()
        }

        // Every leaf becomes a transform block, with or without residual,
        // so the reconstruction stage can predict all samples in decode
        // order.
        let mode = Int(modeGrid[gridIndex(x: x, y: y)])
        if cbfLuma {
            try decodeResidual(x: x, y: y, log2Size: log2Size, componentIndex: 0, intraMode: mode)
        } else {
            appendEmptyBlock(x: x, y: y, log2Size: log2Size, componentIndex: 0, intraMode: mode)
        }
        if chromaHere {
            if cbfCb {
                try decodeResidual(x: x >> 1, y: y >> 1, log2Size: log2Size - 1, componentIndex: 1, intraMode: currentChromaMode)
            } else {
                appendEmptyBlock(x: x >> 1, y: y >> 1, log2Size: log2Size - 1, componentIndex: 1, intraMode: currentChromaMode)
            }
            if cbfCr {
                try decodeResidual(x: x >> 1, y: y >> 1, log2Size: log2Size - 1, componentIndex: 2, intraMode: currentChromaMode)
            } else {
                appendEmptyBlock(x: x >> 1, y: y >> 1, log2Size: log2Size - 1, componentIndex: 2, intraMode: currentChromaMode)
            }
        } else if chromaAtLastBlock {
            if parentCbfCb {
                try decodeResidual(x: baseX >> 1, y: baseY >> 1, log2Size: 2, componentIndex: 1, intraMode: currentChromaMode)
            } else {
                appendEmptyBlock(x: baseX >> 1, y: baseY >> 1, log2Size: 2, componentIndex: 1, intraMode: currentChromaMode)
            }
            if parentCbfCr {
                try decodeResidual(x: baseX >> 1, y: baseY >> 1, log2Size: 2, componentIndex: 2, intraMode: currentChromaMode)
            } else {
                appendEmptyBlock(x: baseX >> 1, y: baseY >> 1, log2Size: 2, componentIndex: 2, intraMode: currentChromaMode)
            }
        }
    }

    private func appendEmptyBlock(x: Int, y: Int, log2Size: Int, componentIndex: Int, intraMode: Int) {
        picture.transformBlocks.append(HEVCPictureData.TransformBlock(
            componentIndex: componentIndex,
            x: x, y: y,
            log2Size: log2Size,
            intraMode: intraMode,
            transformSkip: false,
            transquantBypass: currentTransquantBypass,
            qp: currentQP,
            coefficients: []
        ))
    }

    /// Predicts the quantization-group QP from the left and above neighbours
    /// when they lie in the same CTB, falling back to the previous group's
    /// QP in decode order (8.6.1).
    private func predictQP(x: Int, y: Int) -> Int {
        let ctbMask = sps.ctbSize - 1
        var left = previousQGQP
        if x & ctbMask != 0, isAvailable(x: x - 1, y: y) {
            left = Int(qpGrid[gridIndex(x: x - 1, y: y)])
        }
        var above = previousQGQP
        if y & ctbMask != 0, isAvailable(x: x, y: y - 1) {
            above = Int(qpGrid[gridIndex(x: x, y: y - 1)])
        }
        return (left + above + 1) >> 1
    }

    private func decodeQPDelta() throws {
        cuQPDeltaCoded = true
        // Prefix: truncated unary, cMax 5; the first bin has its own context.
        var prefix = 0
        while prefix < 5 {
            let bin = try cabac.decodeBin(&contexts.cuQPDeltaAbs[prefix == 0 ? 0 : 1])
            if bin == 0 {
                break
            }
            prefix += 1
        }
        var magnitude = prefix
        if prefix == 5 {
            // Suffix: zeroth-order Exp-Golomb, bypass.
            var leadingOnes = 0
            while try cabac.decodeBypass() == 1 {
                leadingOnes += 1
                guard leadingOnes <= 16 else {
                    throw ImageError.invalidData(reason: "Invalid HEVC delta-QP")
                }
            }
            let suffix = (1 << leadingOnes) - 1 + (try cabac.decodeBypassBits(leadingOnes))
            magnitude = 5 + suffix
        }
        var delta = magnitude
        if magnitude > 0, try cabac.decodeBypass() == 1 {
            delta = -magnitude
        }
        // 7.4.9.14 bounds CuQpDeltaVal to −26...25 for 8-bit video (the only
        // depth this decoder reconstructs). The Exp-Golomb escape above can
        // otherwise reach ±8000, and since Swift's % takes the dividend's
        // sign, a large negative delta makes currentQP negative — which the
        // levelScale lookup in dequantization then indexes with.
        guard (-26...25).contains(delta) else {
            throw ImageError.invalidData(reason: "HEVC delta quantization parameter out of range")
        }
        currentQP = (predictedQGQP + delta + 52) % 52
        fineTrace?("      qpDelta \(delta) -> \(currentQP) @bit \(cabac.bitPosition)")
    }

    // MARK: Residual coding (7.3.8.11)

    private func decodeResidual(x: Int, y: Int, log2Size: Int, componentIndex: Int, intraMode: Int) throws {
        let size = 1 << log2Size

        // Intra 4×4 (and 8×8 luma) blocks use mode-dependent scans.
        var scanIndex = 0
        if log2Size == 2 || (log2Size == 3 && componentIndex == 0) {
            if intraMode >= 6 && intraMode <= 14 {
                scanIndex = 2  // vertical
            } else if intraMode >= 22 && intraMode <= 30 {
                scanIndex = 1  // horizontal
            }
        }

        var transformSkip = false
        if pps.transformSkipEnabled, log2Size == 2, !currentTransquantBypass {
            transformSkip = try cabac.decodeBin(&contexts.transformSkip[componentIndex == 0 ? 0 : 1]) == 1
        }

        // Last significant coefficient position: both context-coded prefixes
        // precede both bypass-coded suffixes (7.3.8.11).
        let lastXPrefix = try decodeLastPrefix(log2Size: log2Size, componentIndex: componentIndex, isX: true)
        let lastYPrefix = try decodeLastPrefix(log2Size: log2Size, componentIndex: componentIndex, isX: false)
        let lastX = try decodeLastSuffix(prefix: lastXPrefix)
        let lastY = try decodeLastSuffix(prefix: lastYPrefix)
        guard lastX < size, lastY < size else {
            throw ImageError.invalidData(reason: "HEVC last coefficient outside its block")
        }
        var lastColumn = lastX
        var lastRow = lastY
        if scanIndex == 2 {
            swap(&lastColumn, &lastRow)
        }

        let subBlockCount = size >> 2
        let subBlockScan = HEVCScan.order(size: subBlockCount, scan: scanIndex)
        let coefficientScan = HEVCScan.order(size: 4, scan: scanIndex)

        // Locate the last coefficient in scan terms.
        var lastSubBlock = 0
        var lastScanPosition = 0
        for (index, position) in subBlockScan.enumerated()
        where position.x == lastColumn >> 2 && position.y == lastRow >> 2 {
            lastSubBlock = index
            break
        }
        for (index, position) in coefficientScan.enumerated()
        where position.x == (lastColumn & 3) && position.y == (lastRow & 3) {
            lastScanPosition = index
            break
        }

        var coefficients = [Int](repeating: 0, count: size * size)
        for i in 0..<(subBlockCount * subBlockCount) {
            subBlockCodedScratch[i] = false
        }
        var previousGreater1Context: Int?

        var subBlockIndex = lastSubBlock
        while subBlockIndex >= 0 {
            let subBlock = subBlockScan[subBlockIndex]
            let isLast = subBlockIndex == lastSubBlock
            let isFirst = subBlockIndex == 0

            var previousCoded = 0
            if subBlock.x + 1 < subBlockCount, subBlockCodedScratch[subBlock.y * subBlockCount + subBlock.x + 1] {
                previousCoded |= 1
            }
            if subBlock.y + 1 < subBlockCount, subBlockCodedScratch[(subBlock.y + 1) * subBlockCount + subBlock.x] {
                previousCoded |= 2
            }

            var coded = true
            var inferDCSignificance = false
            if !isLast && !isFirst {
                let contextIndex = (previousCoded != 0 ? 1 : 0) + (componentIndex > 0 ? 2 : 0)
                coded = try cabac.decodeBin(&contexts.codedSubBlock[contextIndex]) == 1
                inferDCSignificance = coded
            }
            subBlockCodedScratch[subBlock.y * subBlockCount + subBlock.x] = coded
            fineTrace?("      sb (\(subBlock.x),\(subBlock.y)) coded \(coded) prev \(previousCoded) @bit \(cabac.bitPosition)")

            if coded {
                // Significant positions collected in decode order (highest
                // scan position first) into a reused scratch buffer.
                var positionCount = 0
                var startPosition = 15
                if isLast {
                    positionScratch[0] = lastScanPosition
                    positionCount = 1
                    startPosition = lastScanPosition - 1
                }
                var position = startPosition
                while position >= 0 {
                    if position == 0 && inferDCSignificance && positionCount == 0 {
                        positionScratch[0] = 0
                        positionCount = 1
                    } else {
                        let coordinate = coefficientScan[position]
                        let context = significanceContext(
                            componentIndex: componentIndex,
                            x: (subBlock.x << 2) | coordinate.x,
                            y: (subBlock.y << 2) | coordinate.y,
                            log2Size: log2Size,
                            scanIndex: scanIndex,
                            previousCoded: previousCoded
                        )
                        if try cabac.decodeBin(&contexts.significantCoefficient[context]) == 1 {
                            positionScratch[positionCount] = position
                            positionCount += 1
                        }
                    }
                    position -= 1
                }

                if positionCount > 0 {
                    // Context set for the greater-than-1 flags.
                    var contextSet = (isFirst || componentIndex > 0) ? 0 : 2
                    if let previous = previousGreater1Context, previous == 0 {
                        contextSet += 1
                    }
                    var greater1Context = 1

                    var greater1Mask = 0  // bit per rank
                    var greater2Rank = -1
                    for rank in 0..<min(positionCount, 8) {
                        let contextIndex = (componentIndex > 0 ? 16 : 0) + contextSet * 4 + min(greater1Context, 3)
                        if try cabac.decodeBin(&contexts.greater1[contextIndex]) == 1 {
                            greater1Mask |= 1 << rank
                            if greater2Rank < 0 {
                                greater2Rank = rank
                            }
                            greater1Context = 0
                        } else if greater1Context > 0 {
                            greater1Context = min(greater1Context + 1, 3)
                        }
                    }
                    previousGreater1Context = greater1Context

                    var greater2 = false
                    if greater2Rank >= 0 {
                        let contextIndex = (componentIndex > 0 ? 4 : 0) + contextSet
                        greater2 = try cabac.decodeBin(&contexts.greater2[contextIndex]) == 1
                    }

                    // Signs, batched into one bypass read (the hidden sign of
                    // the lowest-frequency coefficient is the last rank).
                    let hiddenRank = pps.signDataHidingEnabled
                        && !currentTransquantBypass
                        && positionScratch[0] - positionScratch[positionCount - 1] > 3
                        ? positionCount - 1 : -1
                    let signCount = hiddenRank >= 0 ? positionCount - 1 : positionCount
                    let signBits = try cabac.decodeBypassBits(signCount)

                    // Absolute levels: coeff_abs_level_remaining is present
                    // only when the decoded flags saturated — greater1 == 0
                    // pins the level at exactly 1, greater2 == 0 at 2.
                    var riceParameter = 0
                    var sumOfLevels = 0
                    for rank in 0..<positionCount {
                        let baseLevel: Int
                        let needsRemaining: Bool
                        if rank < 8 {
                            if greater1Mask & (1 << rank) != 0 {
                                if rank == greater2Rank {
                                    baseLevel = greater2 ? 3 : 2
                                    needsRemaining = greater2
                                } else {
                                    baseLevel = 2
                                    needsRemaining = true
                                }
                            } else {
                                baseLevel = 1
                                needsRemaining = false
                            }
                        } else {
                            baseLevel = 1
                            needsRemaining = true
                        }
                        var level = baseLevel
                        if needsRemaining {
                            let remaining = try decodeRemainingLevel(riceParameter: riceParameter)
                            level = baseLevel + remaining
                            if level > 3 << riceParameter {
                                riceParameter = min(riceParameter + 1, 4)
                            }
                        }
                        levelScratch[rank] = level
                        sumOfLevels += level
                    }
                    if fineTrace != nil {
                        let levels = (0..<positionCount).map { levelScratch[$0] }
                        let flags = (0..<positionCount).map { greater1Mask & (1 << $0) != 0 ? 1 : 0 }
                        fineTrace?("      levels \(levels) gt1 \(flags) gt2 \(greater2 ? 1 : 0) set \(contextSet) @bit \(cabac.bitPosition)")
                    }

                    for rank in 0..<positionCount {
                        let coordinate = coefficientScan[positionScratch[rank]]
                        let absoluteX = (subBlock.x << 2) | coordinate.x
                        let absoluteY = (subBlock.y << 2) | coordinate.y
                        var value = levelScratch[rank]
                        let isNegative: Bool
                        if rank == hiddenRank {
                            isNegative = sumOfLevels % 2 == 1
                        } else {
                            isNegative = signBits >> (signCount - 1 - rank) & 1 == 1
                        }
                        if isNegative {
                            value = -value
                        }
                        coefficients[absoluteY * size + absoluteX] = value
                    }
                }
            }
            subBlockIndex -= 1
        }

        if trace != nil {
            let nonZeroCount = coefficients.count(where: { $0 != 0 })
            trace?("    RES c\(componentIndex) (\(x),\(y)) size \(size) scan \(scanIndex) last (\(lastX),\(lastY)) nz \(nonZeroCount) @bit \(cabac.bitPosition)")
        }

        picture.transformBlocks.append(HEVCPictureData.TransformBlock(
            componentIndex: componentIndex,
            x: x, y: y,
            log2Size: log2Size,
            intraMode: intraMode,
            transformSkip: transformSkip,
            transquantBypass: currentTransquantBypass,
            qp: currentQP,
            coefficients: coefficients
        ))
    }

    private func decodeLastPrefix(log2Size: Int, componentIndex: Int, isX: Bool) throws -> Int {
        let contextOffset: Int
        let contextShift: Int
        if componentIndex == 0 {
            contextOffset = 3 * (log2Size - 2) + ((log2Size - 1) >> 2)
            contextShift = (log2Size + 1) >> 2
        } else {
            contextOffset = 15
            contextShift = log2Size - 2
        }
        let maximumPrefix = (log2Size << 1) - 1

        var prefix = 0
        while prefix < maximumPrefix {
            let contextIndex = contextOffset + (prefix >> contextShift)
            let bin = isX
                ? try cabac.decodeBin(&contexts.lastXPrefix[contextIndex])
                : try cabac.decodeBin(&contexts.lastYPrefix[contextIndex])
            if bin == 0 {
                break
            }
            prefix += 1
        }
        return prefix
    }

    private func decodeLastSuffix(prefix: Int) throws -> Int {
        guard prefix > 3 else {
            return prefix
        }
        let suffixLength = (prefix >> 1) - 1
        let suffix = try cabac.decodeBypassBits(suffixLength)
        return ((2 + (prefix & 1)) << suffixLength) + suffix
    }

    private func significanceContext(
        componentIndex: Int,
        x: Int, y: Int,
        log2Size: Int,
        scanIndex: Int,
        previousCoded: Int
    ) -> Int {
        if log2Size == 2 {
            let map = [0, 1, 4, 5, 2, 3, 4, 5, 6, 6, 8, 8, 7, 7, 8, 8]
            let context = map[(y << 2) | x]
            return componentIndex == 0 ? context : 27 + context
        }
        if x == 0 && y == 0 {
            return componentIndex == 0 ? 0 : 27
        }
        let innerX = x & 3
        let innerY = y & 3
        var context: Int
        switch previousCoded {
        case 0:
            context = innerX + innerY == 0 ? 2 : (innerX + innerY < 3 ? 1 : 0)
        case 1:
            context = innerY == 0 ? 2 : (innerY == 1 ? 1 : 0)
        case 2:
            context = innerX == 0 ? 2 : (innerX == 1 ? 1 : 0)
        default:
            context = 2
        }
        if componentIndex == 0, (x >> 2) + (y >> 2) > 0 {
            context += 3
        }
        if log2Size == 3 {
            context += scanIndex == 0 ? 9 : 15
        } else {
            context += componentIndex == 0 ? 21 : 12
        }
        return componentIndex == 0 ? context : 27 + context
    }

    /// coeff_abs_level_remaining: truncated Rice prefix with an Exp-Golomb
    /// escape (9.3.3.13).
    private func decodeRemainingLevel(riceParameter: Int) throws -> Int {
        var prefix = 0
        while prefix < 20, try cabac.decodeBypass() == 1 {
            prefix += 1
        }
        guard prefix < 20 else {
            throw ImageError.invalidData(reason: "Invalid HEVC coefficient level")
        }
        if prefix <= 3 {
            let suffix = try cabac.decodeBypassBits(riceParameter)
            return (prefix << riceParameter) + suffix
        }
        let suffixLength = prefix - 3 + riceParameter
        guard suffixLength <= 31 else {
            throw ImageError.invalidData(reason: "Invalid HEVC coefficient level")
        }
        let suffix = try cabac.decodeBypassBits(suffixLength)
        return (((1 << (prefix - 3)) + 3 - 1) << riceParameter) + suffix
    }
}
