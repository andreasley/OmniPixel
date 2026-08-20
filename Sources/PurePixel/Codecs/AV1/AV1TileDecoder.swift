/// Decodes the symbol layer of one AV1 intra tile (spec 5.11): superblock
/// and partition trees, intra mode info, transform sizes and coefficient
/// levels, ending with the trailing-bit check of exit_symbol. Reconstruction
/// to pixels is the next milestone; this stage records everything it decodes
/// so that stage can consume it.
final class AV1TileDecoder {
    // MARK: Decoded output

    /// One decoded transform block's coefficient levels (in raster order of
    /// the adjusted transform size), for the reconstruction stage.
    struct TransformBlock {
        var plane: Int
        var x: Int
        var y: Int
        var txSize: Int
        var txType: Int
        var eob: Int
        var quant: [Int]
    }

    /// One coded block's mode information.
    struct BlockInfo {
        var miRow: Int
        var miCol: Int
        var size: Int
        var skip: Bool
        var yMode: Int
        var uvMode: Int
        var angleDeltaY: Int
        var angleDeltaUV: Int
        var cflAlphaU: Int
        var cflAlphaV: Int
        var useFilterIntra: Bool
        var filterIntraMode: Int
        var txSize: Int
        var qIndex: Int
    }

    /// One loop-restoration unit's filter choice and parameters.
    struct RestorationUnit {
        var plane: Int
        var row: Int
        var column: Int
        /// 0 = none, 1 = Wiener, 2 = self-guided.
        var type: Int
        /// Wiener taps (both passes) or self-guided set + xqd pair.
        var parameters: [Int]
    }

    private(set) var blocks: [BlockInfo] = []
    private(set) var transformBlocks: [TransformBlock] = []
    private(set) var restorationUnits: [RestorationUnit] = []
    /// Blocks that coded a luma or chroma palette.
    private(set) var paletteBlockCount = 0

    // MARK: Constants

    private static let block8x8 = 3
    private static let block64x64 = 12
    private static let block128x128 = 15
    private static let dcPred = 0
    private static let uvCflPred = 13
    private static let numBaseLevels = 2
    private static let coeffBaseRange = 12
    private static let brCDFSize = 4

    // MARK: Configuration

    let sequence: AV1SequenceHeader
    let header: AV1FrameHeader
    private let miRowStart, miRowEnd, miColStart, miColEnd: Int
    private let miRows, miCols: Int
    private let numPlanes: Int
    let chromaSubX, chromaSubY: Int
    private let losslessArray: [Bool]
    /// 0 = ONLY_4X4, 2 = TX_MODE_SELECT, 1 = TX_MODE_LARGEST.
    private let txMode: Int
    private let sbSize: Int
    /// When set, prediction and reconstruction run inline with the syntax.
    private let frame: AV1FrameBuffer?

    private var decoder: AV1SymbolDecoder
    private var cdf: AV1TileCDFs

    // MARK: Frame-position decoding state

    var yModes: [[UInt8]]
    var uvModes: [[UInt8]]
    private var skips: [[Bool]]
    private var miSizes: [[UInt8]]
    private var segmentIDs: [[UInt8]]
    private var interTxSizes: [[UInt8]]
    private var txTypes: [[UInt8]]
    /// Coefficient contexts, per plane, indexed by absolute 4-sample units.
    private var aboveLevelContext: [[UInt8]]
    private var aboveDcContext: [[UInt8]]
    private var leftLevelContext: [[UInt8]]
    private var leftDcContext: [[UInt8]]
    /// CDEF filter strength indices on the 64×64 grid (-1 = not yet coded).
    private var cdefIndex: [[Int8]]

    private var currentQIndex: Int
    private var readDeltas = false
    /// DeltaLF state (reset per tile), stored per mode-info unit for the
    /// deblocking filter.
    private var currentDeltaLF = [0, 0, 0, 0]
    /// Loop-restoration prediction references, reset per tile.
    private var refLrWiener = [[[Int]]]()
    private var refSgrXqd = [[Int]]()

    // MARK: Current block state

    var miRow = 0, miCol = 0
    private var miSize = 0
    private var bw4 = 0, bh4 = 0
    private var hasChroma = false
    var availU = false, availL = false
    var availUChroma = false, availLChroma = false
    private var segmentID = 0
    private var lossless = false
    private var blockSkip = false
    private var yMode = 0, uvMode = 0
    var angleDeltaY = 0, angleDeltaUV = 0
    var cflAlphaU = 0, cflAlphaV = 0
    var useFilterIntra = false
    var filterIntraMode = 0
    private var txSize = 0
    /// Palette state of the current block (sizes 0 = no palette).
    private(set) var paletteSizeY = 0
    private(set) var paletteSizeUV = 0
    private var paletteColorsY = [Int]()
    private var paletteColorsU = [Int]()
    private var paletteColorsV = [Int]()
    private var colorMapY = [[Int]]()
    private var colorMapUV = [[Int]]()
    /// Neighbor palettes for the cache and contexts (Y and U only),
    /// allocated when screen-content tools are on.
    private var paletteSizes = [[[UInt8]]]()
    private var paletteStore = [[UInt16]]()
    /// Intra block copy state: current block's inter flag and displacement
    /// vector (row, col in 1/8 luma samples), plus per-mi records.
    private var blockIsInter = false
    private var blockMvRow = 0
    private var blockMvCol = 0
    private var isInters: [[Bool]]
    private var mvRowsGrid: [[Int32]]
    private var mvColsGrid: [[Int32]]
    private var decodedMi: [[Bool]]
    private(set) var intraBlockCopyCount = 0
    /// The extent of decoded luma in the current block, for CfL.
    var maxLumaW = 0, maxLumaH = 0
    /// Per-superblock decoded flags per plane, offset by 1 in each axis so
    /// index -1 is representable (clear_block_decoded_flags).
    private var blockDecoded = [[[Bool]]]()

    init(
        tile bytes: [UInt8],
        sequence: AV1SequenceHeader,
        header: AV1FrameHeader,
        tileRow: Int,
        tileColumn: Int,
        frame: AV1FrameBuffer? = nil
    ) throws {
        self.sequence = sequence
        self.header = header
        self.frame = frame
        miRows = header.miRows
        miCols = header.miCols
        miRowStart = header.tiles.miRowStarts[tileRow]
        miRowEnd = header.tiles.miRowStarts[tileRow + 1]
        miColStart = header.tiles.miColStarts[tileColumn]
        miColEnd = header.tiles.miColStarts[tileColumn + 1]
        numPlanes = sequence.monochrome ? 1 : 3
        chromaSubX = sequence.subsamplingX
        chromaSubY = sequence.subsamplingY
        sbSize = sequence.use128x128Superblock ? Self.block128x128 : Self.block64x64

        var losslessPerSegment = [Bool](repeating: false, count: 8)
        for segment in 0..<8 {
            losslessPerSegment[segment] = header.qIndex(forSegment: segment) == 0
                && header.deltaQYDc == 0 && header.deltaQUDc == 0 && header.deltaQUAc == 0
                && header.deltaQVDc == 0 && header.deltaQVAc == 0
        }
        losslessArray = losslessPerSegment
        if header.codedLossless {
            txMode = 0
        } else {
            txMode = header.txModeSelect ? 2 : 1
        }

        decoder = try AV1SymbolDecoder(bytes: bytes, count: bytes.count)
        decoder.cdfUpdatesEnabled = !header.disableCDFUpdate
        cdf = AV1TileCDFs(baseQIndex: header.baseQIndex)

        yModes = [[UInt8]](repeating: [UInt8](repeating: 0, count: miCols), count: miRows)
        uvModes = [[UInt8]](repeating: [UInt8](repeating: 0, count: miCols), count: miRows)
        skips = [[Bool]](repeating: [Bool](repeating: false, count: miCols), count: miRows)
        miSizes = [[UInt8]](repeating: [UInt8](repeating: 0, count: miCols), count: miRows)
        segmentIDs = [[UInt8]](repeating: [UInt8](repeating: 0, count: miCols), count: miRows)
        interTxSizes = [[UInt8]](repeating: [UInt8](repeating: 0, count: miCols), count: miRows)
        txTypes = [[UInt8]](repeating: [UInt8](repeating: 0, count: miCols), count: miRows)
        aboveLevelContext = [[UInt8]](repeating: [UInt8](repeating: 0, count: miCols), count: 3)
        aboveDcContext = [[UInt8]](repeating: [UInt8](repeating: 0, count: miCols), count: 3)
        leftLevelContext = [[UInt8]](repeating: [UInt8](repeating: 0, count: miRows), count: 3)
        leftDcContext = [[UInt8]](repeating: [UInt8](repeating: 0, count: miRows), count: 3)
        cdefIndex = [[Int8]](
            repeating: [Int8](repeating: -1, count: (miCols + 15) >> 4),
            count: (miRows + 15) >> 4
        )
        if header.allowScreenContentTools {
            paletteSizes = [[[UInt8]]](
                repeating: [[UInt8]](repeating: [UInt8](repeating: 0, count: miCols), count: miRows),
                count: 2
            )
            paletteStore = [[UInt16]](
                repeating: [UInt16](repeating: 0, count: miRows * miCols * 8),
                count: 2
            )
        }
        isInters = [[Bool]](repeating: [Bool](repeating: false, count: miCols), count: miRows)
        mvRowsGrid = [[Int32]](repeating: [Int32](repeating: 0, count: miCols), count: miRows)
        mvColsGrid = [[Int32]](repeating: [Int32](repeating: 0, count: miCols), count: miRows)
        decodedMi = [[Bool]](repeating: [Bool](repeating: false, count: miCols), count: miRows)
        currentQIndex = header.baseQIndex
    }

    /// decode_tile: every superblock of the tile, then the trailing-bit
    /// validation of exit_symbol.
    func decode() throws {
        // Wiener_Taps_Mid / Sgrproj_Xqd_Mid prediction references.
        refLrWiener = [[[Int]]](repeating: [[3, -7, 15], [3, -7, 15]], count: 3)
        refSgrXqd = [[Int]](repeating: [-32, 31], count: 3)
        currentDeltaLF = [0, 0, 0, 0]
        let sbSize4 = AV1Tables.blockWidth4[sbSize]
        var row = miRowStart
        while row < miRowEnd {
            clearLeftContext()
            var column = miColStart
            while column < miColEnd {
                readDeltas = header.deltaQPresent
                clearCDEF(row, column, sbSize4)
                clearBlockDecodedFlags(row, column, sbSize4)
                readLoopRestoration(row, column, sbSize4: sbSize4)
                try decodePartition(row, column, sbSize)
                column += sbSize4
            }
            row += sbSize4
        }
        try decoder.exit()
    }

    // MARK: Loop restoration syntax (5.11.57–58)

    /// read_lr: the restoration units whose top-left falls inside this
    /// superblock, per plane.
    private func readLoopRestoration(_ r: Int, _ c: Int, sbSize4: Int) {
        if header.allowIntrabc {
            return
        }
        for plane in 0..<numPlanes {
            // The header stores the coded lr_type: 0 none, 1 switchable,
            // 2 Wiener, 3 self-guided.
            let frameType = header.restorationType[plane]
            if frameType == 0 {
                continue
            }
            let subX = plane == 0 ? 0 : chromaSubX
            let subY = plane == 0 ? 0 : chromaSubY
            let unitSize = header.restorationSize[plane]
            let planeHeight = (header.frameHeight + subY) >> subY
            let planeWidth = (header.frameWidth + subX) >> subX
            let unitRows = max((planeHeight + (unitSize >> 1)) / unitSize, 1)
            let unitCols = max((planeWidth + (unitSize >> 1)) / unitSize, 1)
            let rowScale = 4 >> subY
            let colScale = 4 >> subX
            let unitRowStart = (r * rowScale + unitSize - 1) / unitSize
            let unitRowEnd = min(unitRows, ((r + sbSize4) * rowScale + unitSize - 1) / unitSize)
            let unitColStart = (c * colScale + unitSize - 1) / unitSize
            let unitColEnd = min(unitCols, ((c + sbSize4) * colScale + unitSize - 1) / unitSize)
            for unitRow in unitRowStart..<unitRowEnd {
                for unitCol in unitColStart..<unitColEnd {
                    readLoopRestorationUnit(plane: plane, frameType: frameType, row: unitRow, column: unitCol)
                }
            }
        }
    }

    private static let wienerTapsMin = [-5, -23, -17]
    private static let wienerTapsMax = [10, 8, 46]
    private static let wienerTapsK = [1, 2, 3]
    private static let sgrprojXqdMin = [-96, -32]
    private static let sgrprojXqdMax = [31, 95]
    /// Sgr_Params radii (columns 0 and 2 of the spec table).
    private static let sgrRadii: [[Int]] = [
        [2, 1], [2, 1], [2, 1], [2, 1], [2, 1], [2, 1], [2, 1], [2, 1],
        [2, 1], [2, 1], [0, 1], [0, 1], [0, 1], [0, 1], [2, 0], [2, 0],
    ]

    private func readLoopRestorationUnit(plane: Int, frameType: Int, row: Int, column: Int) {
        // 0 = none, 1 = Wiener, 2 = self-guided.
        let restorationType: Int
        switch frameType {
        case 2:  // frame-level Wiener
            restorationType = decoder.readSymbol(&cdf.useWiener[0]) == 1 ? 1 : 0
        case 3:  // frame-level self-guided
            restorationType = decoder.readSymbol(&cdf.useSgrproj[0]) == 1 ? 2 : 0
        default:  // switchable
            restorationType = decoder.readSymbol(&cdf.restorationType[0])
        }
        var parameters: [Int] = []
        if restorationType == 1 {
            for pass in 0..<2 {
                let firstCoefficient = plane > 0 ? 1 : 0
                if plane > 0 {
                    parameters.append(0)
                }
                for j in firstCoefficient..<3 {
                    let value = decodeSignedSubexp(
                        low: Self.wienerTapsMin[j],
                        high: Self.wienerTapsMax[j] + 1,
                        k: Self.wienerTapsK[j],
                        reference: refLrWiener[plane][pass][j]
                    )
                    refLrWiener[plane][pass][j] = value
                    parameters.append(value)
                }
            }
        } else if restorationType == 2 {
            let sgrSet = decoder.readLiteral(4)
            parameters.append(sgrSet)
            for i in 0..<2 {
                let radius = Self.sgrRadii[sgrSet][i]
                var value = 0
                if radius != 0 {
                    value = decodeSignedSubexp(
                        low: Self.sgrprojXqdMin[i],
                        high: Self.sgrprojXqdMax[i] + 1,
                        k: 4,  // SGRPROJ_PRJ_SUBEXP_K
                        reference: refSgrXqd[plane][i]
                    )
                } else if i == 1 {
                    // 1 << SGRPROJ_PRJ_BITS
                    value = min(max((1 << 7) - refSgrXqd[plane][0], Self.sgrprojXqdMin[1]), Self.sgrprojXqdMax[1])
                }
                refSgrXqd[plane][i] = value
                parameters.append(value)
            }
        }
        restorationUnits.append(RestorationUnit(
            plane: plane, row: row, column: column,
            type: restorationType, parameters: parameters
        ))
    }

    /// decode_signed_subexp_with_ref_bool and its helpers (5.9.27, bool-coded).
    private func decodeSignedSubexp(low: Int, high: Int, k: Int, reference: Int) -> Int {
        let mx = high - low
        let r = reference - low
        let v = decodeSubexpBool(numSyms: mx, k: k)
        let recentered: Int
        if (r << 1) <= mx {
            recentered = Self.inverseRecenter(r, v)
        } else {
            recentered = mx - 1 - Self.inverseRecenter(mx - 1 - r, v)
        }
        return recentered + low
    }

    private func decodeSubexpBool(numSyms: Int, k: Int) -> Int {
        var i = 0
        var mk = 0
        while true {
            let b2 = i != 0 ? k + i - 1 : k
            let a = 1 << b2
            if numSyms <= mk + 3 * a {
                return readNonSymmetricBool(numSyms - mk) + mk
            }
            if decoder.readLiteral(1) != 0 {
                i += 1
                mk += a
            } else {
                return decoder.readLiteral(b2) + mk
            }
        }
    }

    /// NS(n) over arithmetic-coded bools.
    private func readNonSymmetricBool(_ n: Int) -> Int {
        guard n > 1 else { return 0 }
        let w = AV1SymbolDecoder.floorLog2(n) + 1
        let m = (1 << w) - n
        let v = decoder.readLiteral(w - 1)
        if v < m {
            return v
        }
        return (v << 1) - m + decoder.readLiteral(1)
    }

    private static func inverseRecenter(_ r: Int, _ v: Int) -> Int {
        if v > 2 * r {
            return v
        }
        if v & 1 != 0 {
            return r - ((v + 1) >> 1)
        }
        return r + (v >> 1)
    }

    // MARK: Context maintenance

    private func isInside(_ row: Int, _ column: Int) -> Bool {
        column >= miColStart && column < miColEnd && row >= miRowStart && row < miRowEnd
    }

    private func clearLeftContext() {
        for plane in 0..<3 {
            for i in 0..<miRows {
                leftLevelContext[plane][i] = 0
                leftDcContext[plane][i] = 0
            }
        }
    }

    private func clearCDEF(_ row: Int, _ column: Int, _ sbSize4: Int) {
        var r = row
        while r < min(row + sbSize4, miRows) {
            var c = column
            while c < min(column + sbSize4, miCols) {
                cdefIndex[r >> 4][c >> 4] = -1
                c += 16
            }
            r += 16
        }
    }

    /// clear_block_decoded_flags: the top and left borders of the
    /// superblock count as decoded where the tile has content there.
    private func clearBlockDecodedFlags(_ r: Int, _ c: Int, _ sbSize4: Int) {
        guard frame != nil else { return }
        blockDecoded = []
        for plane in 0..<numPlanes {
            let subX = plane > 0 ? chromaSubX : 0
            let subY = plane > 0 ? chromaSubY : 0
            let sbWidth4 = (miColEnd - c) >> subX
            let sbHeight4 = (miRowEnd - r) >> subY
            let ySize = (sbSize4 >> subY) + 2
            let xSize = (sbSize4 >> subX) + 2
            var flags = [[Bool]](repeating: [Bool](repeating: false, count: xSize), count: ySize)
            for y in -1...(sbSize4 >> subY) {
                for x in -1...(sbSize4 >> subX) {
                    if y < 0 && x < sbWidth4 {
                        flags[y + 1][x + 1] = true
                    } else if x < 0 && y < sbHeight4 {
                        flags[y + 1][x + 1] = true
                    }
                }
            }
            flags[(sbSize4 >> subY) + 1][0] = false
            blockDecoded.append(flags)
        }
    }

    private func blockDecodedFlag(_ plane: Int, _ y: Int, _ x: Int) -> Bool {
        let flags = blockDecoded[plane]
        guard y + 1 >= 0, y + 1 < flags.count, x + 1 >= 0, x + 1 < flags[0].count else {
            return false
        }
        return flags[y + 1][x + 1]
    }

    // MARK: Partition tree (5.11.4)

    private func decodePartition(_ r: Int, _ c: Int, _ blockSize: Int) throws {
        if r >= miRows || c >= miCols {
            return
        }
        let availableU = isInside(r - 1, c)
        let availableL = isInside(r, c - 1)
        let num4x4 = AV1Tables.blockWidth4[blockSize]
        let halfBlock4x4 = num4x4 >> 1
        let quarterBlock4x4 = halfBlock4x4 >> 1
        let hasRows = (r + halfBlock4x4) < miRows
        let hasCols = (c + halfBlock4x4) < miCols

        let bsl = AV1Tables.miWidthLog2[blockSize]
        let above = availableU && AV1Tables.miWidthLog2[Int(miSizes[r - 1][c])] < bsl
        let left = availableL && AV1Tables.miHeightLog2[Int(miSizes[r][c - 1])] < bsl
        let context = (left ? 2 : 0) + (above ? 1 : 0)

        var partition: Int
        if blockSize < Self.block8x8 {
            partition = 0
        } else if hasRows && hasCols {
            switch bsl {
            case 1: partition = decoder.readSymbol(&cdf.partitionW8[context])
            case 2: partition = decoder.readSymbol(&cdf.partitionW16[context])
            case 3: partition = decoder.readSymbol(&cdf.partitionW32[context])
            case 4: partition = decoder.readSymbol(&cdf.partitionW64[context])
            default: partition = decoder.readSymbol(&cdf.partitionW128[context])
            }
        } else if hasCols {
            let split = readSplitOrRect(blockSize, context: context, vertical: false)
            partition = split ? 3 : 1
        } else if hasRows {
            let split = readSplitOrRect(blockSize, context: context, vertical: true)
            partition = split ? 3 : 2
        } else {
            partition = 3
        }

        let subSize = AV1Tables.partitionSubsize[partition][blockSize]
        // The split size is only meaningful for the mixed partitions (and
        // 4×4 blocks legitimately have none).
        let splitSize = AV1Tables.partitionSubsize[3][blockSize]
        guard subSize >= 0, splitSize >= 0 || partition == 0 else {
            throw ImageError.invalidData(reason: "Invalid AV1 partition")
        }

        switch partition {
        case 0:
            try decodeBlock(r, c, subSize)
        case 1:
            try decodeBlock(r, c, subSize)
            if hasRows {
                try decodeBlock(r + halfBlock4x4, c, subSize)
            }
        case 2:
            try decodeBlock(r, c, subSize)
            if hasCols {
                try decodeBlock(r, c + halfBlock4x4, subSize)
            }
        case 3:
            try decodePartition(r, c, subSize)
            try decodePartition(r, c + halfBlock4x4, subSize)
            try decodePartition(r + halfBlock4x4, c, subSize)
            try decodePartition(r + halfBlock4x4, c + halfBlock4x4, subSize)
        case 4:  // HORZ_A
            try decodeBlock(r, c, splitSize)
            try decodeBlock(r, c + halfBlock4x4, splitSize)
            try decodeBlock(r + halfBlock4x4, c, subSize)
        case 5:  // HORZ_B
            try decodeBlock(r, c, subSize)
            try decodeBlock(r + halfBlock4x4, c, splitSize)
            try decodeBlock(r + halfBlock4x4, c + halfBlock4x4, splitSize)
        case 6:  // VERT_A
            try decodeBlock(r, c, splitSize)
            try decodeBlock(r + halfBlock4x4, c, splitSize)
            try decodeBlock(r, c + halfBlock4x4, subSize)
        case 7:  // VERT_B
            try decodeBlock(r, c, subSize)
            try decodeBlock(r, c + halfBlock4x4, splitSize)
            try decodeBlock(r + halfBlock4x4, c + halfBlock4x4, splitSize)
        case 8:  // HORZ_4
            for i in 0..<4 {
                let rowI = r + quarterBlock4x4 * i
                if i == 3 && rowI >= miRows { break }
                try decodeBlock(rowI, c, subSize)
            }
        default:  // VERT_4
            for i in 0..<4 {
                let colI = c + quarterBlock4x4 * i
                if i == 3 && colI >= miCols { break }
                try decodeBlock(r, colI, subSize)
            }
        }
    }

    /// split_or_horz / split_or_vert: a synthetic two-symbol CDF built from
    /// the partition probabilities (8.3.2); bsl is never 1 here.
    private func readSplitOrRect(_ blockSize: Int, context: Int, vertical: Bool) -> Bool {
        let row: [UInt16]
        switch AV1Tables.miWidthLog2[blockSize] {
        case 2: row = cdf.partitionW16[context]
        case 3: row = cdf.partitionW32[context]
        case 4: row = cdf.partitionW64[context]
        default: row = cdf.partitionW128[context]
        }
        func probability(_ symbol: Int) -> Int {
            Int(row[symbol]) - (symbol > 0 ? Int(row[symbol - 1]) : 0)
        }
        // Partitions incompatible with the missing direction fold into the
        // split probability.
        var psum: Int
        if vertical {
            // split_or_vert: horizontally-splitting partitions.
            psum = probability(1) + probability(3) + probability(4)
                + probability(5) + probability(6)
            if blockSize != Self.block128x128 {
                psum += probability(8)
            }
        } else {
            // split_or_horz: vertically-splitting partitions.
            psum = probability(2) + probability(3) + probability(4)
                + probability(6) + probability(7)
            if blockSize != Self.block128x128 {
                psum += probability(9)
            }
        }
        var synthetic: [UInt16] = [UInt16((1 << 15) - psum), 1 << 15, 0]
        return decoder.readSymbol(&synthetic) == 1
    }

    // MARK: Block decoding (5.11.5)

    private func decodeBlock(_ r: Int, _ c: Int, _ blockSize: Int) throws {
        miRow = r
        miCol = c
        miSize = blockSize
        bw4 = AV1Tables.blockWidth4[blockSize]
        bh4 = AV1Tables.blockHeight4[blockSize]
        if bh4 == 1 && chromaSubY == 1 && (miRow & 1) == 0 {
            hasChroma = false
        } else if bw4 == 1 && chromaSubX == 1 && (miCol & 1) == 0 {
            hasChroma = false
        } else {
            hasChroma = numPlanes > 1
        }
        availU = isInside(r - 1, c)
        availL = isInside(r, c - 1)
        availUChroma = availU
        availLChroma = availL
        if hasChroma {
            if chromaSubY == 1, bh4 == 1 {
                availUChroma = isInside(r - 2, c)
            }
            if chromaSubX == 1, bw4 == 1 {
                availLChroma = isInside(r, c - 2)
            }
        } else {
            availUChroma = false
            availLChroma = false
        }

        try intraFrameModeInfo()
        paletteTokens()
        try readBlockTxSize()
        if blockSkip {
            resetBlockContext()
        }
        if blockIsInter, let frame {
            computeIntraBlockCopyPrediction(frame: frame)
        }
        try residual()

        for y in 0..<bh4 where r + y < miRows {
            for x in 0..<bw4 where c + x < miCols {
                yModes[r + y][c + x] = UInt8(yMode)
                if hasChroma {
                    uvModes[r + y][c + x] = UInt8(uvMode)
                }
                skips[r + y][c + x] = blockSkip
                miSizes[r + y][c + x] = UInt8(miSize)
                segmentIDs[r + y][c + x] = UInt8(segmentID)
                isInters[r + y][c + x] = blockIsInter
                mvRowsGrid[r + y][c + x] = Int32(blockMvRow)
                mvColsGrid[r + y][c + x] = Int32(blockMvCol)
                decodedMi[r + y][c + x] = true
                if let frame {
                    frame.yModes[r + y][c + x] = UInt8(yMode)
                    frame.skips[r + y][c + x] = blockSkip
                    frame.miSizes[r + y][c + x] = UInt8(miSize)
                    frame.segmentIDs[r + y][c + x] = UInt8(segmentID)
                    for i in 0..<4 {
                        frame.deltaLFs[r + y][c + x][i] = Int8(currentDeltaLF[i])
                    }
                }
                if !paletteSizes.isEmpty {
                    paletteSizes[0][r + y][c + x] = UInt8(paletteSizeY)
                    paletteSizes[1][r + y][c + x] = UInt8(paletteSizeUV)
                    let base = ((r + y) * miCols + c + x) * 8
                    for i in 0..<paletteSizeY {
                        paletteStore[0][base + i] = UInt16(paletteColorsY[i])
                    }
                    for i in 0..<paletteSizeUV {
                        paletteStore[1][base + i] = UInt16(paletteColorsU[i])
                    }
                }
            }
        }
        blocks.append(BlockInfo(
            miRow: r, miCol: c, size: blockSize, skip: blockSkip,
            yMode: yMode, uvMode: uvMode,
            angleDeltaY: angleDeltaY, angleDeltaUV: angleDeltaUV,
            cflAlphaU: cflAlphaU, cflAlphaV: cflAlphaV,
            useFilterIntra: useFilterIntra, filterIntraMode: filterIntraMode,
            txSize: txSize, qIndex: currentQIndex
        ))
    }

    private func intraFrameModeInfo() throws {
        blockSkip = false
        if header.segIdPreSkip {
            try intraSegmentID()
        }
        readSkip()
        if !header.segIdPreSkip {
            try intraSegmentID()
        }
        readCDEF()
        readDeltaQIndex()
        readDeltaLF()
        readDeltas = false

        blockIsInter = false
        blockMvRow = 0
        blockMvCol = 0
        if header.allowIntrabc, decoder.readSymbol(&cdf.intrabc[0]) == 1 {
            // Intra block copy: the block copies from the decoded part of
            // the frame at an integer displacement.
            blockIsInter = true
            intraBlockCopyCount += 1
            yMode = Self.dcPred
            uvMode = Self.dcPred
            angleDeltaY = 0
            angleDeltaUV = 0
            cflAlphaU = 0
            cflAlphaV = 0
            useFilterIntra = false
            paletteSizeY = 0
            paletteSizeUV = 0
            paletteColorsY = []
            paletteColorsU = []
            paletteColorsV = []
            let predicted = findIntraBlockCopyPrediction()
            readMv(predictedRow: predicted.row, predictedCol: predicted.col)
            return
        }

        // intra_frame_y_mode
        let aboveMode = availU ? Int(yModes[miRow - 1][miCol]) : Self.dcPred
        let leftMode = availL ? Int(yModes[miRow][miCol - 1]) : Self.dcPred
        let aboveContext = AV1Tables.intraModeContext[aboveMode]
        let leftContext = AV1Tables.intraModeContext[leftMode]
        yMode = decoder.readSymbol(&cdf.intraFrameYMode[aboveContext * 5 + leftContext])
        angleDeltaY = 0
        if miSize >= Self.block8x8, isDirectional(yMode) {
            angleDeltaY = decoder.readSymbol(&cdf.angleDelta[yMode - 1]) - 3
        }

        uvMode = Self.dcPred
        angleDeltaUV = 0
        cflAlphaU = 0
        cflAlphaV = 0
        paletteSizeY = 0
        paletteSizeUV = 0
        paletteColorsY = []
        paletteColorsU = []
        paletteColorsV = []
        if hasChroma {
            let blockW = 4 * bw4
            let blockH = 4 * bh4
            let cflAllowed: Bool
            if lossless {
                cflAllowed = AV1Tables.subsampledSize[miSize][chromaSubX][chromaSubY] == 0
            } else {
                cflAllowed = max(blockW, blockH) <= 32
            }
            if cflAllowed {
                uvMode = decoder.readSymbol(&cdf.uvModeCflAllowed[yMode])
            } else {
                uvMode = decoder.readSymbol(&cdf.uvModeCflNotAllowed[yMode])
            }
            if uvMode == Self.uvCflPred {
                readCflAlphas()
            }
            if miSize >= Self.block8x8, isDirectional(uvMode) {
                angleDeltaUV = decoder.readSymbol(&cdf.angleDelta[uvMode - 1]) - 3
            }
        }

        if miSize >= Self.block8x8, 4 * bw4 <= 64, 4 * bh4 <= 64,
           header.allowScreenContentTools {
            paletteModeInfo()
        }
        filterIntraModeInfo()
    }

    private func intraSegmentID() throws {
        if header.segmentationEnabled {
            try readSegmentID()
        } else {
            segmentID = 0
        }
        lossless = losslessArray[segmentID]
    }

    private func readSegmentID() throws {
        let prevUL = (availU && availL) ? Int(segmentIDs[miRow - 1][miCol - 1]) : -1
        let prevU = availU ? Int(segmentIDs[miRow - 1][miCol]) : -1
        let prevL = availL ? Int(segmentIDs[miRow][miCol - 1]) : -1
        let predicted: Int
        if prevU == -1 {
            predicted = prevL == -1 ? 0 : prevL
        } else if prevL == -1 {
            predicted = prevU
        } else {
            predicted = prevUL == prevU ? prevU : prevL
        }
        if blockSkip {
            segmentID = predicted
            return
        }
        let context: Int
        if prevUL < 0 {
            context = 0
        } else if prevUL == prevU && prevUL == prevL {
            context = 2
        } else if prevUL == prevU || prevUL == prevL || prevU == prevL {
            context = 1
        } else {
            context = 0
        }
        let coded = decoder.readSymbol(&cdf.segmentID[context])
        segmentID = Self.negDeinterleave(coded, predicted, header.lastActiveSegmentID + 1)
        guard segmentID >= 0, segmentID < 8 else {
            throw ImageError.invalidData(reason: "Invalid AV1 segment")
        }
    }

    private static func negDeinterleave(_ diff: Int, _ ref: Int, _ max: Int) -> Int {
        if ref == 0 {
            return diff
        }
        if ref >= max - 1 {
            return max - diff - 1
        }
        if 2 * ref < max {
            if diff <= 2 * ref {
                if diff & 1 != 0 {
                    return ref + ((diff + 1) >> 1)
                }
                return ref - (diff >> 1)
            }
            return diff
        } else {
            if diff <= 2 * (max - ref - 1) {
                if diff & 1 != 0 {
                    return ref + ((diff + 1) >> 1)
                }
                return ref - (diff >> 1)
            }
            return max - (diff + 1)
        }
    }

    private func readSkip() {
        if header.segIdPreSkip, segmentFeatureActive(feature: 6) {
            blockSkip = true
        } else {
            var context = 0
            if availU, skips[miRow - 1][miCol] {
                context += 1
            }
            if availL, skips[miRow][miCol - 1] {
                context += 1
            }
            blockSkip = decoder.readSymbol(&cdf.skip[context]) == 1
        }
    }

    private func segmentFeatureActive(feature: Int) -> Bool {
        header.segmentationEnabled && header.featureEnabled[segmentID][feature]
    }

    private func readCDEF() {
        if blockSkip || header.codedLossless || !sequence.enableCDEF || header.allowIntrabc {
            return
        }
        let r = miRow & ~15
        let c = miCol & ~15
        if cdefIndex[r >> 4][c >> 4] == -1 {
            let index = Int8(decoder.readLiteral(header.cdefBits))
            var i = r
            while i < min(r + bh4, miRows) {
                var j = c
                while j < min(c + bw4, miCols) {
                    cdefIndex[i >> 4][j >> 4] = index
                    frame?.cdefIndex[i >> 4][j >> 4] = index
                    j += 16
                }
                i += 16
            }
        }
    }

    private func readDeltaQIndex() {
        if miSize == sbSize && blockSkip {
            return
        }
        guard readDeltas else { return }
        var deltaQAbs = decoder.readSymbol(&cdf.deltaQ[0])
        if deltaQAbs == 3 {  // DELTA_Q_SMALL
            let remBits = decoder.readLiteral(3) + 1
            deltaQAbs = decoder.readLiteral(remBits) + (1 << remBits) + 1
        }
        if deltaQAbs != 0 {
            let sign = decoder.readLiteral(1)
            let reduced = sign != 0 ? -deltaQAbs : deltaQAbs
            currentQIndex = min(max(currentQIndex + (reduced << header.deltaQRes), 1), 255)
        }
    }

    private func readDeltaLF() {
        if miSize == sbSize && blockSkip {
            return
        }
        guard readDeltas, header.deltaLFPresent else { return }
        let count: Int
        if header.deltaLFMulti {
            count = numPlanes > 1 ? 4 : 2
        } else {
            count = 1
        }
        for i in 0..<count {
            var deltaAbs: Int
            if header.deltaLFMulti {
                deltaAbs = decoder.readSymbol(&cdf.deltaLFMulti[i])
            } else {
                deltaAbs = decoder.readSymbol(&cdf.deltaLF[0])
            }
            if deltaAbs == 3 {  // DELTA_LF_SMALL
                let n = decoder.readLiteral(3) + 1
                deltaAbs = decoder.readLiteral(n) + (1 << n) + 1
            }
            if deltaAbs != 0 {
                let sign = decoder.readLiteral(1)
                let reduced = sign != 0 ? -deltaAbs : deltaAbs
                let updated = currentDeltaLF[i] + (reduced << header.deltaLFRes)
                currentDeltaLF[i] = min(max(updated, -63), 63)  // MAX_LOOP_FILTER
            }
        }
    }

    private func isDirectional(_ mode: Int) -> Bool {
        mode >= 1 && mode <= 8
    }

    private func readCflAlphas() {
        let signs = decoder.readSymbol(&cdf.cflSign[0])
        let signU = (signs + 1) / 3
        let signV = (signs + 1) % 3
        if signU != 0 {
            let value = 1 + decoder.readSymbol(&cdf.cflAlpha[(signU - 1) * 3 + signV])
            cflAlphaU = signU == 1 ? -value : value  // CFL_SIGN_NEG = 1
        } else {
            cflAlphaU = 0
        }
        if signV != 0 {
            let value = 1 + decoder.readSymbol(&cdf.cflAlpha[(signV - 1) * 3 + signU])
            cflAlphaV = signV == 1 ? -value : value
        } else {
            cflAlphaV = 0
        }
    }

    // MARK: Palette (5.11.46, 5.11.49–50)

    private func paletteModeInfo() {
        let bsizeContext = AV1Tables.miWidthLog2[miSize] + AV1Tables.miHeightLog2[miSize] - 2
        let bitDepth = sequence.bitDepth
        if yMode == Self.dcPred {
            var context = 0
            if availU, paletteSizes[0][miRow - 1][miCol] > 0 {
                context += 1
            }
            if availL, paletteSizes[0][miRow][miCol - 1] > 0 {
                context += 1
            }
            if decoder.readSymbol(&cdf.paletteYMode[bsizeContext * 3 + context]) == 1 {
                paletteSizeY = decoder.readSymbol(&cdf.paletteYSize[bsizeContext]) + 2
                var colors = [Int]()
                for cached in paletteCache(plane: 0) where colors.count < paletteSizeY {
                    if decoder.readLiteral(1) == 1 {
                        colors.append(cached)
                    }
                }
                if colors.count < paletteSizeY {
                    colors.append(decoder.readLiteral(bitDepth))
                }
                if colors.count < paletteSizeY {
                    var paletteBits = bitDepth - 3 + decoder.readLiteral(2)
                    while colors.count < paletteSizeY {
                        let delta = decoder.readLiteral(paletteBits) + 1
                        let value = min(colors[colors.count - 1] + delta, (1 << bitDepth) - 1)
                        colors.append(value)
                        let range = (1 << bitDepth) - value - 1
                        paletteBits = min(paletteBits, Self.ceilLog2(range))
                    }
                }
                paletteColorsY = colors.sorted()
            }
        }
        if hasChroma, uvMode == Self.dcPred {
            let uvContext = paletteSizeY > 0 ? 1 : 0
            if decoder.readSymbol(&cdf.paletteUVMode[uvContext]) == 1 {
                paletteSizeUV = decoder.readSymbol(&cdf.paletteUVSize[bsizeContext]) + 2
                // U colors: cache + ascending deltas, like luma (but the
                // delta range keeps one more value).
                var uColors = [Int]()
                for cached in paletteCache(plane: 1) where uColors.count < paletteSizeUV {
                    if decoder.readLiteral(1) == 1 {
                        uColors.append(cached)
                    }
                }
                if uColors.count < paletteSizeUV {
                    uColors.append(decoder.readLiteral(bitDepth))
                }
                if uColors.count < paletteSizeUV {
                    var paletteBits = bitDepth - 3 + decoder.readLiteral(2)
                    while uColors.count < paletteSizeUV {
                        let delta = decoder.readLiteral(paletteBits)
                        let value = min(uColors[uColors.count - 1] + delta, (1 << bitDepth) - 1)
                        uColors.append(value)
                        let range = (1 << bitDepth) - value
                        paletteBits = min(paletteBits, Self.ceilLog2(range))
                    }
                }
                paletteColorsU = uColors.sorted()
                // V colors: wrapping signed deltas or raw values.
                var vColors = [Int]()
                if decoder.readLiteral(1) == 1 {
                    let paletteBits = bitDepth - 4 + decoder.readLiteral(2)
                    let maxValue = 1 << bitDepth
                    vColors.append(decoder.readLiteral(bitDepth))
                    for _ in 1..<paletteSizeUV {
                        var delta = decoder.readLiteral(paletteBits)
                        if delta != 0, decoder.readLiteral(1) == 1 {
                            delta = -delta
                        }
                        var value = vColors[vColors.count - 1] + delta
                        if value < 0 { value += maxValue }
                        if value >= maxValue { value -= maxValue }
                        vColors.append(min(max(value, 0), maxValue - 1))
                    }
                } else {
                    for _ in 0..<paletteSizeUV {
                        vColors.append(decoder.readLiteral(bitDepth))
                    }
                }
                paletteColorsV = vColors
            }
        }
    }

    /// get_palette_cache: the merged, deduplicated colors of the above
    /// (same 64-row stripe) and left neighbors, ascending.
    private func paletteCache(plane: Int) -> [Int] {
        var above = [Int]()
        if (miRow * 4) % 64 != 0 {
            let count = Int(paletteSizes[plane][miRow - 1][miCol])
            let base = ((miRow - 1) * miCols + miCol) * 8
            above = (0..<count).map { Int(paletteStore[plane][base + $0]) }
        }
        var left = [Int]()
        if availL {
            let count = Int(paletteSizes[plane][miRow][miCol - 1])
            let base = (miRow * miCols + miCol - 1) * 8
            left = (0..<count).map { Int(paletteStore[plane][base + $0]) }
        }
        var cache = [Int]()
        var aboveIdx = 0
        var leftIdx = 0
        func push(_ value: Int) {
            if cache.last != value {
                cache.append(value)
            }
        }
        while aboveIdx < above.count, leftIdx < left.count {
            if left[leftIdx] < above[aboveIdx] {
                push(left[leftIdx])
                leftIdx += 1
            } else {
                if left[leftIdx] == above[aboveIdx] {
                    leftIdx += 1
                }
                push(above[aboveIdx])
                aboveIdx += 1
            }
        }
        while aboveIdx < above.count {
            push(above[aboveIdx])
            aboveIdx += 1
        }
        while leftIdx < left.count {
            push(left[leftIdx])
            leftIdx += 1
        }
        return cache
    }

    private static func ceilLog2(_ value: Int) -> Int {
        guard value > 1 else { return 0 }
        return Int.bitWidth - (value - 1).leadingZeroBitCount
    }

    /// palette_tokens: the per-sample color index maps, read in wavefront
    /// (anti-diagonal) order with neighbor-ranked contexts.
    private func paletteTokens() {
        colorMapY = []
        colorMapUV = []
        if paletteSizeY > 0 || paletteSizeUV > 0 {
            paletteBlockCount += 1
        }
        if paletteSizeY > 0 {
            let blockWidth = 4 * bw4
            let blockHeight = 4 * bh4
            let onscreenWidth = min(blockWidth, (miCols - miCol) * 4)
            let onscreenHeight = min(blockHeight, (miRows - miRow) * 4)
            colorMapY = readColorMap(
                blockWidth: blockWidth, blockHeight: blockHeight,
                onscreenWidth: onscreenWidth, onscreenHeight: onscreenHeight,
                paletteSize: paletteSizeY, luma: true
            )
        }
        if paletteSizeUV > 0 {
            var blockWidth = (4 * bw4) >> chromaSubX
            var blockHeight = (4 * bh4) >> chromaSubY
            var onscreenWidth = min(4 * bw4, (miCols - miCol) * 4) >> chromaSubX
            var onscreenHeight = min(4 * bh4, (miRows - miRow) * 4) >> chromaSubY
            if blockWidth < 4 {
                blockWidth += 2
                onscreenWidth += 2
            }
            if blockHeight < 4 {
                blockHeight += 2
                onscreenHeight += 2
            }
            colorMapUV = readColorMap(
                blockWidth: blockWidth, blockHeight: blockHeight,
                onscreenWidth: onscreenWidth, onscreenHeight: onscreenHeight,
                paletteSize: paletteSizeUV, luma: false
            )
        }
    }

    private func readColorMap(
        blockWidth: Int, blockHeight: Int,
        onscreenWidth: Int, onscreenHeight: Int,
        paletteSize: Int, luma: Bool
    ) -> [[Int]] {
        var map = [[Int]](repeating: [Int](repeating: 0, count: blockWidth), count: blockHeight)
        map[0][0] = readNonSymmetricBool(paletteSize)
        for i in 1..<(onscreenHeight + onscreenWidth - 1) {
            var j = min(i, onscreenWidth - 1)
            while j >= max(0, i - onscreenHeight + 1) {
                let (context, order) = Self.paletteColorContext(map: map, r: i - j, c: j, n: paletteSize)
                let symbol: Int
                if luma {
                    symbol = decoder.readSymbol(&cdf.paletteYColor[paletteSize - 2][context])
                } else {
                    symbol = decoder.readSymbol(&cdf.paletteUVColor[paletteSize - 2][context])
                }
                map[i - j][j] = order[symbol]
                j -= 1
            }
        }
        for i in 0..<onscreenHeight {
            for j in onscreenWidth..<blockWidth {
                map[i][j] = map[i][onscreenWidth - 1]
            }
        }
        for i in onscreenHeight..<blockHeight {
            for j in 0..<blockWidth {
                map[i][j] = map[onscreenHeight - 1][j]
            }
        }
        return map
    }

    /// get_palette_color_context: neighbor scores rank the colors; the
    /// score hash picks the CDF context.
    private static let paletteColorContextTable = [-1, -1, 0, -1, -1, 4, 3, 2, 1]

    private static func paletteColorContext(map: [[Int]], r: Int, c: Int, n: Int) -> (context: Int, order: [Int]) {
        var scores = [Int](repeating: 0, count: 8)  // PALETTE_COLORS
        var order = Array(0..<8)
        if c > 0 {
            scores[map[r][c - 1]] += 2
        }
        if r > 0, c > 0 {
            scores[map[r - 1][c - 1]] += 1
        }
        if r > 0 {
            scores[map[r - 1][c]] += 2
        }
        for i in 0..<3 {  // PALETTE_NUM_NEIGHBORS
            var maxScore = scores[i]
            var maxIdx = i
            var j = i + 1
            while j < n {
                if scores[j] > maxScore {
                    maxScore = scores[j]
                    maxIdx = j
                }
                j += 1
            }
            if maxIdx != i {
                let maxOrder = order[maxIdx]
                var k = maxIdx
                while k > i {
                    scores[k] = scores[k - 1]
                    order[k] = order[k - 1]
                    k -= 1
                }
                scores[i] = maxScore
                order[i] = maxOrder
            }
        }
        // Palette_Color_Hash_Multipliers = [1, 2, 2]
        let hash = scores[0] + 2 * scores[1] + 2 * scores[2]
        return (Self.paletteColorContextTable[hash], order)
    }

    private func filterIntraModeInfo() {
        useFilterIntra = false
        filterIntraMode = 0
        if sequence.enableFilterIntra,
           yMode == Self.dcPred,
           paletteSizeY == 0,
           max(4 * bw4, 4 * bh4) <= 32 {
            useFilterIntra = decoder.readSymbol(&cdf.filterIntra[miSize]) == 1
            if useFilterIntra {
                filterIntraMode = decoder.readSymbol(&cdf.filterIntraMode[0])
            }
        }
    }

    // MARK: Transform sizes (5.11.15–16)

    private func readBlockTxSize() throws {
        if txMode == 2, miSize > 0, blockIsInter, !blockSkip, !lossless {
            // Inter (intra-block-copy) blocks code a transform split tree.
            let maxTxSz = AV1Tables.maxTxSizeRect[miSize]
            let txW4 = AV1Tables.txWidth[maxTxSz] / 4
            let txH4 = AV1Tables.txHeight[maxTxSz] / 4
            var row = miRow
            while row < miRow + bh4 {
                var column = miCol
                while column < miCol + bw4 {
                    readVarTxSize(row: row, column: column, txSz: maxTxSz, depth: 0)
                    column += txW4
                }
                row += txH4
            }
        } else {
            try readTxSize(allowSelect: !blockSkip || !blockIsInter)
            for row in miRow..<min(miRow + bh4, miRows) {
                for column in miCol..<min(miCol + bw4, miCols) {
                    interTxSizes[row][column] = UInt8(txSize)
                }
            }
        }
    }

    /// read_var_tx_size (5.11.17): the transform split tree of inter blocks.
    private func readVarTxSize(row: Int, column: Int, txSz: Int, depth: Int) {
        if row >= miRows || column >= miCols {
            return
        }
        var split = false
        if txSz != 0, depth != 2 {  // TX_4X4, MAX_VARTX_DEPTH
            let above = aboveTxWidth(row: row, column: column) < AV1Tables.txWidth[txSz]
            let left = leftTxHeight(row: row, column: column) < AV1Tables.txHeight[txSz]
            let size = min(64, max(4 * bw4, 4 * bh4))
            // The square transform size with this side length.
            let maxSquare = size.trailingZeroBitCount - 2
            let context = (AV1Tables.txSizeSqrUp[txSz] != maxSquare ? 3 : 0)
                + (5 - 1 - maxSquare) * 6 + (above ? 1 : 0) + (left ? 1 : 0)  // TX_SIZES = 5
            split = decoder.readSymbol(&cdf.txfmSplit[context]) == 1
        }
        let w4 = AV1Tables.txWidth[txSz] / 4
        let h4 = AV1Tables.txHeight[txSz] / 4
        if split {
            let subTxSz = AV1Tables.splitTxSize[txSz]
            let stepW = AV1Tables.txWidth[subTxSz] / 4
            let stepH = AV1Tables.txHeight[subTxSz] / 4
            var i = 0
            while i < h4 {
                var j = 0
                while j < w4 {
                    readVarTxSize(row: row + i, column: column + j, txSz: subTxSz, depth: depth + 1)
                    j += stepW
                }
                i += stepH
            }
        } else {
            for i in 0..<h4 where row + i < miRows {
                for j in 0..<w4 where column + j < miCols {
                    interTxSizes[row + i][column + j] = UInt8(txSz)
                }
            }
            txSize = txSz
        }
    }

    /// get_above_tx_width / get_left_tx_height (8.3.2, txfm_split).
    private func aboveTxWidth(row: Int, column: Int) -> Int {
        if row == miRow {
            if !availU {
                return 64
            }
            if skips[row - 1][column], isInters[row - 1][column] {
                return 4 * AV1Tables.blockWidth4[Int(miSizes[row - 1][column])]
            }
        }
        return AV1Tables.txWidth[Int(interTxSizes[row - 1][column])]
    }

    private func leftTxHeight(row: Int, column: Int) -> Int {
        if column == miCol {
            if !availL {
                return 64
            }
            if skips[row][column - 1], isInters[row][column - 1] {
                return 4 * AV1Tables.blockHeight4[Int(miSizes[row][column - 1])]
            }
        }
        return AV1Tables.txHeight[Int(interTxSizes[row][column - 1])]
    }

    private func readTxSize(allowSelect: Bool) throws {
        if lossless {
            txSize = 0  // TX_4X4
            return
        }
        let maxRectTxSize = AV1Tables.maxTxSizeRect[miSize]
        let maxTxDepth = AV1Tables.maxTxDepth[miSize]
        txSize = maxRectTxSize
        if miSize > 0, allowSelect, txMode == 2 {  // TX_MODE_SELECT
            let context = txDepthContext(maxRectTxSize: maxRectTxSize)
            let depth: Int
            switch maxTxDepth {
            case 4: depth = decoder.readSymbol(&cdf.tx64x64[context])
            case 3: depth = decoder.readSymbol(&cdf.tx32x32[context])
            case 2: depth = decoder.readSymbol(&cdf.tx16x16[context])
            default: depth = decoder.readSymbol(&cdf.tx8x8[context])
            }
            for _ in 0..<depth {
                txSize = AV1Tables.splitTxSize[txSize]
            }
        }
    }

    private func txDepthContext(maxRectTxSize: Int) -> Int {
        let maxTxWidth = AV1Tables.txWidth[maxRectTxSize]
        let maxTxHeight = AV1Tables.txHeight[maxRectTxSize]
        let aboveW: Int
        if availU, isInters[miRow - 1][miCol] {
            aboveW = 4 * AV1Tables.blockWidth4[Int(miSizes[miRow - 1][miCol])]
        } else if availU {
            aboveW = aboveTxWidth(row: miRow, column: miCol)
        } else {
            aboveW = 0
        }
        let leftH: Int
        if availL, isInters[miRow][miCol - 1] {
            leftH = 4 * AV1Tables.blockHeight4[Int(miSizes[miRow][miCol - 1])]
        } else if availL {
            leftH = leftTxHeight(row: miRow, column: miCol)
        } else {
            leftH = 0
        }
        return (aboveW >= maxTxWidth ? 1 : 0) + (leftH >= maxTxHeight ? 1 : 0)
    }

    private func resetBlockContext() {
        for plane in 0..<(1 + (hasChroma ? 2 : 0)) {
            let subX = plane > 0 ? chromaSubX : 0
            let subY = plane > 0 ? chromaSubY : 0
            for i in (miCol >> subX)..<min((miCol + bw4) >> subX, miCols) {
                aboveLevelContext[plane][i] = 0
                aboveDcContext[plane][i] = 0
            }
            for i in (miRow >> subY)..<min((miRow + bh4) >> subY, miRows) {
                leftLevelContext[plane][i] = 0
                leftDcContext[plane][i] = 0
            }
        }
    }

    // MARK: Residual (5.11.34–36)

    private func residual() throws {
        let widthChunks = max(1, (4 * bw4) >> 6)
        let heightChunks = max(1, (4 * bh4) >> 6)
        let miSizeChunk = (widthChunks > 1 || heightChunks > 1) ? Self.block64x64 : miSize
        for chunkY in 0..<heightChunks {
            for chunkX in 0..<widthChunks {
                for plane in 0..<(1 + (hasChroma ? 2 : 0)) {
                    let txSz = lossless ? 0 : planeTxSize(plane)
                    let stepX = AV1Tables.txWidth[txSz] >> 2
                    let stepY = AV1Tables.txHeight[txSz] >> 2
                    let subX = plane > 0 ? chromaSubX : 0
                    let subY = plane > 0 ? chromaSubY : 0
                    let planeSize = AV1Tables.subsampledSize[miSizeChunk][subX][subY]
                    guard planeSize >= 0 else {
                        throw ImageError.invalidData(reason: "Invalid AV1 plane block size")
                    }
                    let num4x4W = AV1Tables.blockWidth4[planeSize]
                    let num4x4H = AV1Tables.blockHeight4[planeSize]
                    if blockIsInter, !lossless, plane == 0 {
                        // Inter luma follows the coded transform split tree.
                        let miRowChunk = miRow + (chunkY << 4)
                        let miColChunk = miCol + (chunkX << 4)
                        try transformTree(
                            startX: miColChunk * 4,
                            startY: miRowChunk * 4,
                            width: num4x4W * 4,
                            height: num4x4H * 4
                        )
                        continue
                    }
                    let baseXBlock = (miCol >> subX) * 4
                    let baseYBlock = (miRow >> subY) * 4
                    var y = 0
                    while y < num4x4H {
                        var x = 0
                        while x < num4x4W {
                            try transformBlock(
                                plane: plane,
                                baseX: baseXBlock,
                                baseY: baseYBlock,
                                txSz: txSz,
                                x: x + ((chunkX << 4) >> subX),
                                y: y + ((chunkY << 4) >> subY)
                            )
                            x += stepX
                        }
                        y += stepY
                    }
                }
            }
        }
    }

    /// get_tx_size: the chroma transform size for the block.
    private func planeTxSize(_ plane: Int) -> Int {
        if plane == 0 {
            return txSize
        }
        let planeSize = AV1Tables.subsampledSize[miSize][chromaSubX][chromaSubY]
        let uvTx = AV1Tables.maxTxSizeRect[planeSize]
        if AV1Tables.txWidth[uvTx] == 64 || AV1Tables.txHeight[uvTx] == 64 {
            if AV1Tables.txWidth[uvTx] == 16 {
                return 9  // TX_16X32
            }
            if AV1Tables.txHeight[uvTx] == 16 {
                return 10  // TX_32X16
            }
            return 3  // TX_32X32
        }
        return uvTx
    }

    /// transform_tree (5.11.37): visits the coded transform blocks of an
    /// inter luma region.
    private func transformTree(startX: Int, startY: Int, width: Int, height: Int) throws {
        let maxX = miCols * 4
        let maxY = miRows * 4
        if startX >= maxX || startY >= maxY {
            return
        }
        let lumaTxSz = Int(interTxSizes[startY >> 2][startX >> 2])
        let lumaW = AV1Tables.txWidth[lumaTxSz]
        let lumaH = AV1Tables.txHeight[lumaTxSz]
        if width <= lumaW, height <= lumaH {
            let txSz = Self.findTxSize(width, height)
            try transformBlock(plane: 0, baseX: startX, baseY: startY, txSz: txSz, x: 0, y: 0)
        } else if width > height {
            try transformTree(startX: startX, startY: startY, width: width / 2, height: height)
            try transformTree(startX: startX + width / 2, startY: startY, width: width / 2, height: height)
        } else if width < height {
            try transformTree(startX: startX, startY: startY, width: width, height: height / 2)
            try transformTree(startX: startX, startY: startY + height / 2, width: width, height: height / 2)
        } else {
            try transformTree(startX: startX, startY: startY, width: width / 2, height: height / 2)
            try transformTree(startX: startX + width / 2, startY: startY, width: width / 2, height: height / 2)
            try transformTree(startX: startX, startY: startY + height / 2, width: width / 2, height: height / 2)
            try transformTree(startX: startX + width / 2, startY: startY + height / 2, width: width / 2, height: height / 2)
        }
    }

    private static func findTxSize(_ width: Int, _ height: Int) -> Int {
        for txSz in 0..<19 where AV1Tables.txWidth[txSz] == width && AV1Tables.txHeight[txSz] == height {
            return txSz
        }
        return 0
    }

    private func transformBlock(plane: Int, baseX: Int, baseY: Int, txSz: Int, x: Int, y: Int) throws {
        let startX = baseX + 4 * x
        let startY = baseY + 4 * y
        let subX = plane > 0 ? chromaSubX : 0
        let subY = plane > 0 ? chromaSubY : 0
        let maxX = (miCols * 4) >> subX
        let maxY = (miRows * 4) >> subY
        if startX >= maxX || startY >= maxY {
            return
        }
        let row = (startY << subY) >> 2
        let col = (startX << subX) >> 2
        let sbMask = sequence.use128x128Superblock ? 31 : 15
        let subBlockMiRow = (row & sbMask) >> subY
        let subBlockMiCol = (col & sbMask) >> subX
        let stepX = AV1Tables.txWidth[txSz] >> 2
        let stepY = AV1Tables.txHeight[txSz] >> 2

        if let frame, !blockIsInter {
            let usesPalette = plane == 0 ? paletteSizeY > 0 : paletteSizeUV > 0
            if usesPalette {
                predictPalette(frame: frame, plane: plane, startX: startX, startY: startY, x: x, y: y, txSz: txSz)
            } else {
                let isCfl = plane > 0 && uvMode == 13  // UV_CFL_PRED
                let mode: Int
                if plane == 0 {
                    mode = yMode
                } else {
                    mode = isCfl ? 0 : uvMode
                }
                predictIntra(
                    frame: frame,
                    plane: plane,
                    x: startX,
                    y: startY,
                    haveLeft: (plane == 0 ? availL : availLChroma) || x > 0,
                    haveAbove: (plane == 0 ? availU : availUChroma) || y > 0,
                    haveAboveRight: blockDecodedFlag(plane, subBlockMiRow - 1, subBlockMiCol + stepX),
                    haveBelowLeft: blockDecodedFlag(plane, subBlockMiRow + stepY, subBlockMiCol - 1),
                    mode: mode,
                    log2W: AV1Tables.txWidthLog2[txSz],
                    log2H: AV1Tables.txHeightLog2[txSz]
                )
                if isCfl {
                    predictChromaFromLuma(frame: frame, plane: plane, startX: startX, startY: startY, txSz: txSz)
                }
            }
            if plane == 0 {
                maxLumaW = startX + stepX * 4
                maxLumaH = startY + stepY * 4
            }
        }

        if !blockSkip {
            let (eob, txType, quant) = try coefficients(plane: plane, startX: startX, startY: startY, txSz: txSz)
            if eob > 0, let frame {
                let qmLevel: Int
                if lossless {
                    qmLevel = 15
                } else {
                    qmLevel = plane == 0 ? header.qmY : (plane == 1 ? header.qmU : header.qmV)
                }
                reconstruct(
                    frame: frame, plane: plane, x: startX, y: startY,
                    txSz: txSz, txType: txType, quant: quant,
                    lossless: lossless, qIndexBase: blockQIndex, qmLevel: qmLevel
                )
            }
        }

        if let frame {
            for i in 0..<stepY where subBlockMiRow + i + 1 < blockDecoded[plane].count {
                for j in 0..<stepX where subBlockMiCol + j + 1 < blockDecoded[plane][0].count {
                    blockDecoded[plane][subBlockMiRow + i + 1][subBlockMiCol + j + 1] = true
                }
            }
            let x4 = startX >> 2
            let y4 = startY >> 2
            let sizes = frame.loopfilterTxSizes[plane]
            for i in 0..<stepY where y4 + i < sizes.count {
                for j in 0..<stepX where x4 + j < sizes[0].count {
                    frame.loopfilterTxSizes[plane][y4 + i][x4 + j] = UInt8(txSz)
                }
            }
        }
    }

    /// predict_palette (7.11.4): maps color indices to palette colors.
    private func predictPalette(frame: AV1FrameBuffer, plane: Int, startX: Int, startY: Int, x: Int, y: Int, txSz: Int) {
        let w = AV1Tables.txWidth[txSz]
        let h = AV1Tables.txHeight[txSz]
        let palette: [Int]
        switch plane {
        case 0: palette = paletteColorsY
        case 1: palette = paletteColorsU
        default: palette = paletteColorsV
        }
        let map = plane == 0 ? colorMapY : colorMapUV
        for i in 0..<h {
            for j in 0..<w {
                frame.setSample(plane, startY + i, startX + j, palette[map[y * 4 + i][x * 4 + j]])
            }
        }
    }

    // MARK: Intra block copy (7.10.2 restricted to intra frames, 5.11.26)

    /// find_mv_stack for the intra-block-copy case (single prediction of
    /// INTRA_FRAME on an intra frame: no temporal or global candidates),
    /// followed by the intrabc branch of assign_mv. Returns the predicted
    /// displacement vector.
    private func findIntraBlockCopyPrediction() -> (row: Int, col: Int) {
        var stack: [(row: Int, col: Int)] = []
        var weights: [Int] = []

        func addCandidate(_ mvRow: Int, _ mvCol: Int, weight: Int) {
            guard isInters[mvRow][mvCol] else { return }
            // Only list 0 can match INTRA_FRAME on an intra frame.
            let candidate = (row: Int(mvRowsGrid[mvRow][mvCol]), col: Int(mvColsGrid[mvRow][mvCol]))
            for index in 0..<stack.count where stack[index] == candidate {
                weights[index] += weight
                return
            }
            if stack.count < 8 {  // MAX_REF_MV_STACK_SIZE
                stack.append(candidate)
                weights.append(weight)
            }
        }

        func scanRow(_ deltaRowIn: Int) {
            var deltaRow = deltaRowIn
            var deltaCol = 0
            let end4 = min(min(bw4, miCols - miCol), 16)
            let useStep16 = bw4 >= 16
            if abs(deltaRow) > 1 {
                deltaRow += miRow & 1
                deltaCol = 1 - (miCol & 1)
            }
            var i = 0
            while i < end4 {
                let mvRow = miRow + deltaRow
                let mvCol = miCol + deltaCol + i
                guard isInside(mvRow, mvCol) else { break }
                var length = min(bw4, AV1Tables.blockWidth4[Int(miSizes[mvRow][mvCol])])
                if abs(deltaRowIn) > 1 {
                    length = max(2, length)
                }
                if useStep16 {
                    length = max(4, length)
                }
                addCandidate(mvRow, mvCol, weight: length * 2)
                i += length
            }
        }

        func scanCol(_ deltaColIn: Int) {
            var deltaCol = deltaColIn
            var deltaRow = 0
            let end4 = min(min(bh4, miRows - miRow), 16)
            let useStep16 = bh4 >= 16
            if abs(deltaCol) > 1 {
                deltaRow = 1 - (miRow & 1)
                deltaCol += miCol & 1
            }
            var i = 0
            while i < end4 {
                let mvRow = miRow + deltaRow + i
                let mvCol = miCol + deltaCol
                guard isInside(mvRow, mvCol) else { break }
                var length = min(bh4, AV1Tables.blockHeight4[Int(miSizes[mvRow][mvCol])])
                if abs(deltaColIn) > 1 {
                    length = max(2, length)
                }
                if useStep16 {
                    length = max(4, length)
                }
                addCandidate(mvRow, mvCol, weight: length * 2)
                i += length
            }
        }

        func scanPoint(_ deltaRow: Int, _ deltaCol: Int) {
            let mvRow = miRow + deltaRow
            let mvCol = miCol + deltaCol
            if isInside(mvRow, mvCol), decodedMi[mvRow][mvCol] {
                addCandidate(mvRow, mvCol, weight: 4)
            }
        }

        scanRow(-1)
        scanCol(-1)
        if max(bw4, bh4) <= 16 {
            scanPoint(-1, bw4)
        }
        let numNearest = stack.count
        for index in 0..<numNearest {
            weights[index] += 640  // REF_CAT_LEVEL
        }
        scanPoint(-1, -1)
        scanRow(-3)
        scanCol(-3)
        if bh4 > 1 {
            scanRow(-5)
        }
        if bw4 > 1 {
            scanCol(-5)
        }

        // Stable weight sort within each partition (7.10.2.11).
        func sortRange(_ start: Int, _ endIn: Int) {
            var end = endIn
            while end > start {
                var newEnd = start
                for index in (start + 1)..<end where weights[index - 1] < weights[index] {
                    weights.swapAt(index - 1, index)
                    stack.swapAt(index - 1, index)
                    newEnd = index
                }
                end = newEnd
            }
        }
        sortRange(0, numNearest)
        sortRange(numNearest, stack.count)

        // Extra search adds nothing on intra frames (no candidate has a
        // reference frame beyond INTRA_FRAME); missing entries are the
        // (zero) global motion vector without growing the count.
        let numMvFound = stack.count
        while stack.count < 2 {
            stack.append((0, 0))
        }

        // Clamping (7.10.2.14) applies to the found entries only.
        let border = 128  // MV_BORDER
        for index in 0..<numMvFound {
            let rowLow = -(miRow * 4) * 8 - (border + bh4 * 4 * 8)
            let rowHigh = ((miRows - bh4 - miRow) * 4) * 8 + (border + bh4 * 4 * 8)
            let colLow = -(miCol * 4) * 8 - (border + bw4 * 4 * 8)
            let colHigh = ((miCols - bw4 - miCol) * 4) * 8 + (border + bw4 * 4 * 8)
            stack[index].row = min(max(stack[index].row, rowLow), rowHigh)
            stack[index].col = min(max(stack[index].col, colLow), colHigh)
        }

        // assign_mv, intrabc branch (5.11.26).
        var predicted = stack[0]
        if predicted == (0, 0) {
            predicted = stack[1]
        }
        if predicted == (0, 0) {
            let sbSize4 = AV1Tables.blockHeight4[sbSize]
            if miRow - sbSize4 < miRowStart {
                predicted = (0, -(sbSize4 * 4 + 256) * 8)  // INTRABC_DELAY_PIXELS
            } else {
                predicted = (-(sbSize4 * 4 * 8), 0)
            }
        }
        return predicted
    }

    /// read_mv + read_mv_component (5.11.31–32) with the intra-block-copy
    /// context; intra frames force integer precision.
    private func readMv(predictedRow: Int, predictedCol: Int) {
        let context = 1  // MV_INTRABC_CONTEXT
        var diffRow = 0
        var diffCol = 0
        let joint = decoder.readSymbol(&cdf.mvJoint[context])
        if joint == 2 || joint == 3 {  // MV_JOINT_HZVNZ / HNZVNZ: row changes
            diffRow = readMvComponent(context: context, component: 0)
        }
        if joint == 1 || joint == 3 {  // MV_JOINT_HNZVZ / HNZVNZ: col changes
            diffCol = readMvComponent(context: context, component: 1)
        }
        blockMvRow = predictedRow + diffRow
        blockMvCol = predictedCol + diffCol
    }

    private func readMvComponent(context: Int, component: Int) -> Int {
        let base = context * 2 + component
        let sign = decoder.readSymbol(&cdf.mvSign[base])
        let mvClass = decoder.readSymbol(&cdf.mvClass[base])
        var magnitude: Int
        if mvClass == 0 {
            let bit = decoder.readSymbol(&cdf.mvClass0Bit[base])
            // Intra frames force integer motion: fr = 3, hp = 1.
            magnitude = ((bit << 3) | (3 << 1) | 1) + 1
        } else {
            var d = 0
            for i in 0..<mvClass {
                let bit = decoder.readSymbol(&cdf.mvBit[base * 10 + i])
                d |= bit << i
            }
            magnitude = 2 << (mvClass + 2)  // CLASS0_SIZE << (class + 2)
            magnitude += ((d << 3) | (3 << 1) | 1) + 1
        }
        return sign == 1 ? -magnitude : magnitude
    }

    /// compute_prediction (5.11.33) for intra block copy: one whole-block
    /// inter prediction per plane (all neighbors are INTRA_FRAME, so the
    /// spec's whole-block path always applies).
    private func computeIntraBlockCopyPrediction(frame: AV1FrameBuffer) {
        for plane in 0..<(1 + (hasChroma ? 2 : 0)) {
            let subX = plane > 0 ? chromaSubX : 0
            let subY = plane > 0 ? chromaSubY : 0
            let planeSize = AV1Tables.subsampledSize[miSize][subX][subY]
            let width = AV1Tables.blockWidth4[planeSize] * 4
            let height = AV1Tables.blockHeight4[planeSize] * 4
            let baseX = (miCol >> subX) * 4
            let baseY = (miRow >> subY) * 4
            predictIntraBlockCopy(
                frame: frame, plane: plane, x: baseX, y: baseY,
                width: width, height: height, subX: subX, subY: subY
            )
        }
    }

    /// Block inter prediction (7.11.3.3–4) restricted to intra block copy:
    /// no scaling, bilinear filtering (only chroma can land off-sample).
    private func predictIntraBlockCopy(
        frame: AV1FrameBuffer, plane: Int, x: Int, y: Int,
        width: Int, height: Int, subX: Int, subY: Int
    ) {
        let bitDepth = frame.bitDepth
        let round0 = bitDepth == 12 ? 5 : 3
        let round1 = bitDepth == 12 ? 9 : 11
        // The reference area for intra block copy is the mi-aligned frame.
        let lastX = ((miCols * 4) >> subX) - 1
        let lastY = ((miRows * 4) >> subY) - 1
        // Motion vector scaling degenerates to a fixed-point offset.
        let startX = (((x << 4) + ((2 * blockMvCol) >> subX)) << 6) + 32
        let startY = (((y << 4) + ((2 * blockMvRow) >> subY)) << 6) + 32
        let filter = AV1Tables.subpelFilters[3]  // BILINEAR

        let stride = frame.allocatedWidth[plane]
        let samples = frame.planes[plane]
        var intermediate = [Int](repeating: 0, count: (height + 7) * width)
        for r in 0..<(height + 7) {
            let refY = min(max((startY >> 10) + r - 3, 0), lastY)
            for c in 0..<width {
                let p = startX + 1024 * c
                let taps = filter[(p >> 6) & 15]
                var s = 0
                for t in 0..<8 where taps[t] != 0 {
                    let refX = min(max((p >> 10) + t - 3, 0), lastX)
                    s += taps[t] * samples[refY * stride + refX]
                }
                intermediate[r * width + c] = (s + (1 << (round0 - 1))) >> round0
            }
        }
        for r in 0..<height {
            let p = (startY & 1023) + 1024 * r
            let taps = filter[(p >> 6) & 15]
            let baseRow = p >> 10
            for c in 0..<width {
                var s = 0
                for t in 0..<8 where taps[t] != 0 {
                    s += taps[t] * intermediate[(baseRow + t) * width + c]
                }
                let value = (s + (1 << (round1 - 1))) >> round1
                frame.setSample(plane, y + r, x + c, Self.clip1(value, bitDepth))
            }
        }
    }

    /// get_qindex(0, segment_id): the block's effective quantizer index.
    private var blockQIndex: Int {
        if header.segmentationEnabled, header.featureEnabled[segmentID][0] {
            let data = header.featureData[segmentID][0]
            let base = header.deltaQPresent ? currentQIndex : header.baseQIndex
            return min(max(base + data, 0), 255)
        }
        return header.deltaQPresent ? currentQIndex : header.baseQIndex
    }

    /// is_smooth for the intra edge filter type.
    func isSmoothMode(row: Int, column: Int, plane: Int) -> Bool {
        let mode = plane == 0 ? Int(yModes[row][column]) : Int(uvModes[row][column])
        return mode >= 9 && mode <= 11
    }

    // MARK: Coefficients (5.11.39)

    @discardableResult
    private func coefficients(
        plane: Int, startX: Int, startY: Int, txSz: Int
    ) throws -> (eob: Int, txType: Int, quant: [Int]) {
        let x4 = startX >> 2
        let y4 = startY >> 2
        let w4 = AV1Tables.txWidth[txSz] >> 2
        let h4 = AV1Tables.txHeight[txSz] >> 2
        let txSzCtx = (AV1Tables.txSizeSqr[txSz] + AV1Tables.txSizeSqrUp[txSz] + 1) >> 1
        let ptype = plane > 0 ? 1 : 0
        let segEob = (txSz == 17 || txSz == 18) ? 512 : min(1024, AV1Tables.txWidth[txSz] * AV1Tables.txHeight[txSz])
        var quant = [Int](repeating: 0, count: segEob)
        var eob = 0
        var culLevel = 0
        var dcCategory = 0

        let allZeroContext = allZeroCtx(plane: plane, txSz: txSz, x4: x4, y4: y4, w4: w4, h4: h4)
        let allZero = decoder.readSymbol(&cdf.txbSkip[txSzCtx * 13 + allZeroContext]) == 1

        var planeTxType = 0
        if allZero {
            if plane == 0 {
                for i in 0..<w4 where x4 + i < miCols {
                    for j in 0..<h4 where y4 + j < miRows {
                        txTypes[y4 + j][x4 + i] = 0  // DCT_DCT
                    }
                }
            }
        } else {
            if plane == 0 {
                readTransformType(x4: x4, y4: y4, txSz: txSz)
            }
            planeTxType = computeTxType(plane: plane, txSz: txSz, x4: x4, y4: y4)
            let scan = Self.scan(for: txSz, txType: planeTxType)
            let txClass = Self.txClass(planeTxType)

            // EOB position
            let eobMultisize = min(AV1Tables.txWidthLog2[txSz], 5) + min(AV1Tables.txHeightLog2[txSz], 5) - 4
            let eobPtContext = txClass == 0 ? 0 : 1
            let eobPt: Int
            switch eobMultisize {
            case 0: eobPt = decoder.readSymbol(&cdf.eobPt16[ptype * 2 + eobPtContext]) + 1
            case 1: eobPt = decoder.readSymbol(&cdf.eobPt32[ptype * 2 + eobPtContext]) + 1
            case 2: eobPt = decoder.readSymbol(&cdf.eobPt64[ptype * 2 + eobPtContext]) + 1
            case 3: eobPt = decoder.readSymbol(&cdf.eobPt128[ptype * 2 + eobPtContext]) + 1
            case 4: eobPt = decoder.readSymbol(&cdf.eobPt256[ptype * 2 + eobPtContext]) + 1
            case 5: eobPt = decoder.readSymbol(&cdf.eobPt512[ptype]) + 1
            default: eobPt = decoder.readSymbol(&cdf.eobPt1024[ptype]) + 1
            }
            eob = eobPt < 2 ? eobPt : (1 << (eobPt - 2)) + 1
            if eobPt >= 3 {
                var eobShift = eobPt - 3
                let extra = decoder.readSymbol(&cdf.eobExtra[(txSzCtx * 2 + ptype) * 9 + (eobPt - 3)])
                if extra != 0 {
                    eob += 1 << eobShift
                }
                for i in 1..<max(0, eobPt - 2) {
                    eobShift = max(0, eobPt - 2) - 1 - i
                    if decoder.readLiteral(1) != 0 {
                        eob += 1 << eobShift
                    }
                }
            }
            guard eob <= segEob else {
                throw ImageError.invalidData(reason: "AV1 end-of-block exceeds its transform")
            }

            // Base levels and range extensions (reverse scan order).
            let adjTxSz = AV1Tables.adjustedTxSize[txSz]
            let bwl = AV1Tables.txWidthLog2[adjTxSz]
            let adjHeight = AV1Tables.txHeight[adjTxSz]
            var c = eob - 1
            while c >= 0 {
                let pos = scan[c]
                var level: Int
                if c == eob - 1 {
                    let context = coeffBaseEobCtx(c: c, bwl: bwl, height: adjHeight)
                    level = decoder.readSymbol(&cdf.coeffBaseEOB[(txSzCtx * 2 + ptype) * 4 + context]) + 1
                } else {
                    let context = coeffBaseCtx(
                        txSz: txSz, pos: pos, bwl: bwl, width: 1 << bwl, height: adjHeight,
                        txClass: txClass, quant: quant
                    )
                    level = decoder.readSymbol(&cdf.coeffBase[(txSzCtx * 2 + ptype) * 42 + context])
                }
                if level > Self.numBaseLevels {
                    for _ in 0..<(Self.coeffBaseRange / (Self.brCDFSize - 1)) {
                        let context = coeffBrCtx(pos: pos, bwl: bwl, txClass: txClass, adjTxSz: adjTxSz, quant: quant)
                        let br = decoder.readSymbol(&cdf.coeffBr[(min(txSzCtx, 3) * 2 + ptype) * 21 + context])
                        level += br
                        if br < Self.brCDFSize - 1 {
                            break
                        }
                    }
                }
                quant[pos] = level
                c -= 1
            }

            // Signs and Exp-Golomb suffixes (forward scan order).
            for c in 0..<eob {
                let pos = scan[c]
                var sign = 0
                if quant[pos] != 0 {
                    if c == 0 {
                        sign = decoder.readSymbol(&cdf.dcSign[ptype * 3 + dcSignCtx(plane: plane, x4: x4, y4: y4, w4: w4, h4: h4)])
                    } else {
                        sign = decoder.readLiteral(1)
                    }
                }
                if quant[pos] > Self.numBaseLevels + Self.coeffBaseRange {
                    var length = 0
                    repeat {
                        length += 1
                        guard length <= 32 else {
                            throw ImageError.invalidData(reason: "Corrupt AV1 coefficient suffix")
                        }
                    } while decoder.readLiteral(1) == 0
                    var value = 1
                    for _ in 0..<(length - 1) {
                        value = value << 1 | decoder.readLiteral(1)
                    }
                    quant[pos] = value + Self.coeffBaseRange + Self.numBaseLevels
                }
                if pos == 0, quant[pos] > 0 {
                    dcCategory = sign != 0 ? 1 : 2
                }
                quant[pos] &= 0xFFFFF
                culLevel += quant[pos]
                if sign != 0 {
                    quant[pos] = -quant[pos]
                }
            }
            culLevel = min(63, culLevel)
        }

        // Publish the block's coefficient context.
        let maxX4 = miCols >> (plane > 0 ? chromaSubX : 0)
        let maxY4 = miRows >> (plane > 0 ? chromaSubY : 0)
        for i in 0..<w4 where x4 + i < maxX4 {
            aboveLevelContext[plane][x4 + i] = UInt8(culLevel)
            aboveDcContext[plane][x4 + i] = UInt8(dcCategory)
        }
        for i in 0..<h4 where y4 + i < maxY4 {
            leftLevelContext[plane][y4 + i] = UInt8(culLevel)
            leftDcContext[plane][y4 + i] = UInt8(dcCategory)
        }

        if eob > 0 {
            transformBlocks.append(TransformBlock(
                plane: plane, x: startX, y: startY, txSize: txSz,
                txType: planeTxType, eob: eob, quant: quant
            ))
        }
        return (eob, planeTxType, quant)
    }

    // MARK: Transform types (5.11.47–48)

    private func readTransformType(x4: Int, y4: Int, txSz: Int) {
        let set = transformSet(txSz)
        var txType = 0
        let qIndexForSyntax = header.segmentationEnabled
            ? header.qIndex(forSegment: segmentID) : header.baseQIndex
        if set > 0, qIndexForSyntax > 0 {
            let sqr = AV1Tables.txSizeSqr[txSz]
            if blockIsInter {
                switch set {
                case 1:
                    let symbol = decoder.readSymbol(&cdf.interTxTypeSet1[sqr])
                    txType = AV1Tables.interTxTypeInvSet1[symbol]
                case 2:
                    let symbol = decoder.readSymbol(&cdf.interTxTypeSet2[0])
                    txType = AV1Tables.interTxTypeInvSet2[symbol]
                default:
                    let symbol = decoder.readSymbol(&cdf.interTxTypeSet3[sqr])
                    txType = AV1Tables.interTxTypeInvSet3[symbol]
                }
            } else {
                let intraDir: Int
                if useFilterIntra {
                    intraDir = AV1Tables.filterIntraModeToIntraDir[filterIntraMode]
                } else {
                    intraDir = yMode
                }
                if set == 1 {
                    let symbol = decoder.readSymbol(&cdf.intraTxTypeSet1[sqr * 13 + intraDir])
                    txType = AV1Tables.intraTxTypeInvSet1[symbol]
                } else {
                    let symbol = decoder.readSymbol(&cdf.intraTxTypeSet2[sqr * 13 + intraDir])
                    txType = AV1Tables.intraTxTypeInvSet2[symbol]
                }
            }
        }
        let w4 = AV1Tables.txWidth[txSz] >> 2
        let h4 = AV1Tables.txHeight[txSz] >> 2
        for i in 0..<w4 where x4 + i < miCols {
            for j in 0..<h4 where y4 + j < miRows {
                txTypes[y4 + j][x4 + i] = UInt8(txType)
            }
        }
    }

    /// get_tx_set: for intra, 0 = DCT only, 1/2 = TX_SET_INTRA_1/2; for
    /// inter, 1…3 = TX_SET_INTER_1…3.
    private func transformSet(_ txSz: Int) -> Int {
        let sqrUp = AV1Tables.txSizeSqrUp[txSz]
        if sqrUp > 3 {  // beyond TX_32X32
            return 0
        }
        if blockIsInter {
            if header.reducedTxSet || sqrUp == 3 {
                return 3  // TX_SET_INTER_3
            }
            if AV1Tables.txSizeSqr[txSz] == 2 {  // TX_16X16
                return 2
            }
            return 1
        }
        if sqrUp == 3 {  // TX_32X32
            return 0
        }
        if header.reducedTxSet {
            return 2
        }
        if AV1Tables.txSizeSqr[txSz] == 2 {  // TX_16X16
            return 2
        }
        return 1
    }

    private func computeTxType(plane: Int, txSz: Int, x4: Int, y4: Int) -> Int {
        if lossless || AV1Tables.txSizeSqrUp[txSz] > 3 {
            return 0
        }
        let txSet = transformSet(txSz)
        if plane == 0 {
            return Int(txTypes[y4][x4])
        }
        if blockIsInter {
            let lumaX4 = max(miCol, x4 << chromaSubX)
            let lumaY4 = max(miRow, y4 << chromaSubY)
            let txType = Int(txTypes[lumaY4][lumaX4])
            if AV1Tables.txTypeInSetInter[txSet][txType] == 0 {
                return 0
            }
            return txType
        }
        let txType = AV1Tables.modeToTxfm[uvMode]
        if AV1Tables.txTypeInSetIntra[txSet][txType] == 0 {
            return 0
        }
        return txType
    }

    /// get_tx_class: 0 = 2D, 1 = horizontal, 2 = vertical.
    private static func txClass(_ txType: Int) -> Int {
        switch txType {
        case 10, 12, 14:  // V_DCT, V_ADST, V_FLIPADST
            return 2
        case 11, 13, 15:  // H_DCT, H_ADST, H_FLIPADST
            return 1
        default:
            return 0
        }
    }

    // MARK: Coefficient contexts (8.3.2)

    private func allZeroCtx(plane: Int, txSz: Int, x4: Int, y4: Int, w4: Int, h4: Int) -> Int {
        let subX = plane > 0 ? chromaSubX : 0
        let subY = plane > 0 ? chromaSubY : 0
        let maxX4 = miCols >> subX
        let maxY4 = miRows >> subY
        let w = AV1Tables.txWidth[txSz]
        let h = AV1Tables.txHeight[txSz]
        let planeSize = AV1Tables.subsampledSize[miSize][subX][subY]
        let bw = 4 * AV1Tables.blockWidth4[planeSize]
        let bh = 4 * AV1Tables.blockHeight4[planeSize]

        if plane == 0 {
            var top = 0
            var left = 0
            for k in 0..<w4 where x4 + k < maxX4 {
                top = max(top, Int(aboveLevelContext[plane][x4 + k]))
            }
            for k in 0..<h4 where y4 + k < maxY4 {
                left = max(left, Int(leftLevelContext[plane][y4 + k]))
            }
            top = min(top, 255)
            left = min(left, 255)
            if bw == w && bh == h {
                return 0
            }
            if top == 0 && left == 0 {
                return 1
            }
            if top == 0 || left == 0 {
                return 2 + (max(top, left) > 3 ? 1 : 0)
            }
            if max(top, left) <= 3 {
                return 4
            }
            if min(top, left) <= 3 {
                return 5
            }
            return 6
        } else {
            var above = 0
            var left = 0
            for i in 0..<w4 where x4 + i < maxX4 {
                above |= Int(aboveLevelContext[plane][x4 + i])
                above |= Int(aboveDcContext[plane][x4 + i])
            }
            for i in 0..<h4 where y4 + i < maxY4 {
                left |= Int(leftLevelContext[plane][y4 + i])
                left |= Int(leftDcContext[plane][y4 + i])
            }
            var context = (above != 0 ? 1 : 0) + (left != 0 ? 1 : 0)
            context += 7
            if bw * bh > w * h {
                context += 3
            }
            return context
        }
    }

    private func coeffBaseEobCtx(c: Int, bwl: Int, height: Int) -> Int {
        if c == 0 {
            return 0
        }
        if c <= (height << bwl) / 8 {
            return 1
        }
        if c <= (height << bwl) / 4 {
            return 2
        }
        return 3
    }

    private func coeffBaseCtx(txSz: Int, pos: Int, bwl: Int, width: Int, height: Int, txClass: Int, quant: [Int]) -> Int {
        let row = pos >> bwl
        let col = pos - (row << bwl)
        var mag = 0
        for idx in 0..<5 {
            let refRow = row + AV1Tables.sigRefDiffOffset[txClass][idx][0]
            let refCol = col + AV1Tables.sigRefDiffOffset[txClass][idx][1]
            if refRow >= 0, refCol >= 0, refRow < height, refCol < width {
                mag += min(abs(quant[(refRow << bwl) + refCol]), 3)
            }
        }
        let context = min((mag + 1) >> 1, 4)
        if txClass == 0 {
            if row == 0 && col == 0 {
                return 0
            }
            return context + AV1Tables.coeffBaseCtxOffset[txSz][min(row, 4) * 5 + min(col, 4)]
        }
        let index = txClass == 2 ? row : col
        return context + AV1Tables.coeffBasePosCtxOffset[min(index, 2)]
    }

    private func coeffBrCtx(pos: Int, bwl: Int, txClass: Int, adjTxSz: Int, quant: [Int]) -> Int {
        let txw = AV1Tables.txWidth[adjTxSz]
        let txh = AV1Tables.txHeight[adjTxSz]
        let row = pos >> bwl
        let col = pos - (row << bwl)
        var mag = 0
        for idx in 0..<3 {
            let refRow = row + AV1Tables.magRefOffset[txClass][idx][0]
            let refCol = col + AV1Tables.magRefOffset[txClass][idx][1]
            if refRow >= 0, refCol >= 0, refRow < txh, refCol < (1 << bwl) {
                mag += min(quant[refRow * txw + refCol], Self.coeffBaseRange + Self.numBaseLevels + 1)
            }
        }
        mag = min((mag + 1) >> 1, 6)
        if pos == 0 {
            return mag
        }
        if txClass == 0 {
            return (row < 2 && col < 2) ? mag + 7 : mag + 14
        }
        if txClass == 1 {
            return col == 0 ? mag + 7 : mag + 14
        }
        return row == 0 ? mag + 7 : mag + 14
    }

    private func dcSignCtx(plane: Int, x4: Int, y4: Int, w4: Int, h4: Int) -> Int {
        let subX = plane > 0 ? chromaSubX : 0
        let subY = plane > 0 ? chromaSubY : 0
        let maxX4 = miCols >> subX
        let maxY4 = miRows >> subY
        var dcSign = 0
        for k in 0..<w4 where x4 + k < maxX4 {
            let sign = aboveDcContext[plane][x4 + k]
            if sign == 1 {
                dcSign -= 1
            } else if sign == 2 {
                dcSign += 1
            }
        }
        for k in 0..<h4 where y4 + k < maxY4 {
            let sign = leftDcContext[plane][y4 + k]
            if sign == 1 {
                dcSign -= 1
            } else if sign == 2 {
                dcSign += 1
            }
        }
        if dcSign < 0 {
            return 1
        }
        if dcSign > 0 {
            return 2
        }
        return 0
    }

    // MARK: Scan selection (5.11.41)

    private static func scan(for txSz: Int, txType: Int) -> [Int] {
        if txSz == 17 {  // TX_16X64
            return AV1Tables.defaultScan16x32
        }
        if txSz == 18 {  // TX_64X16
            return AV1Tables.defaultScan32x16
        }
        if AV1Tables.txSizeSqrUp[txSz] == 4 {  // TX_64X64
            return AV1Tables.defaultScan32x32
        }
        if txType == 9 {  // IDTX
            return defaultScan(txSz)
        }
        let preferRow = txType == 10 || txType == 12 || txType == 14  // V_*
        let preferCol = txType == 11 || txType == 13 || txType == 15  // H_*
        if preferRow {
            return mrowScan(txSz)
        }
        if preferCol {
            return mcolScan(txSz)
        }
        return defaultScan(txSz)
    }

    private static func defaultScan(_ txSz: Int) -> [Int] {
        switch txSz {
        case 0: return AV1Tables.defaultScan4x4
        case 5: return AV1Tables.defaultScan4x8
        case 6: return AV1Tables.defaultScan8x4
        case 1: return AV1Tables.defaultScan8x8
        case 7: return AV1Tables.defaultScan8x16
        case 8: return AV1Tables.defaultScan16x8
        case 2: return AV1Tables.defaultScan16x16
        case 9: return AV1Tables.defaultScan16x32
        case 10: return AV1Tables.defaultScan32x16
        case 13: return AV1Tables.defaultScan4x16
        case 14: return AV1Tables.defaultScan16x4
        case 15: return AV1Tables.defaultScan8x32
        case 16: return AV1Tables.defaultScan32x8
        default: return AV1Tables.defaultScan32x32
        }
    }

    private static func mrowScan(_ txSz: Int) -> [Int] {
        switch txSz {
        case 0: return AV1Tables.mrowScan4x4
        case 5: return AV1Tables.mrowScan4x8
        case 6: return AV1Tables.mrowScan8x4
        case 1: return AV1Tables.mrowScan8x8
        case 7: return AV1Tables.mrowScan8x16
        case 8: return AV1Tables.mrowScan16x8
        case 2: return AV1Tables.mrowScan16x16
        case 13: return AV1Tables.mrowScan4x16
        default: return AV1Tables.mrowScan16x4
        }
    }

    private static func mcolScan(_ txSz: Int) -> [Int] {
        switch txSz {
        case 0: return AV1Tables.mcolScan4x4
        case 5: return AV1Tables.mcolScan4x8
        case 6: return AV1Tables.mcolScan8x4
        case 1: return AV1Tables.mcolScan8x8
        case 7: return AV1Tables.mcolScan8x16
        case 8: return AV1Tables.mcolScan16x8
        case 2: return AV1Tables.mcolScan16x16
        case 13: return AV1Tables.mcolScan4x16
        default: return AV1Tables.mcolScan16x4
        }
    }
}
