/// The adaptive CDF state of one AV1 tile (spec 8.2.3/8.2.5).
///
/// Every tile starts from the frame defaults: still pictures never carry
/// forward adapted state, so initialization is a straight copy of the
/// default tables, with the coefficient tables chosen by base_q_idx
/// (init_coeff_cdfs). Multi-dimensional spec tables are stored as flat row
/// arrays; the decoder computes row indices from the context variables.
struct AV1TileCDFs {
    // MARK: Mode and partition CDFs

    var intraFrameYMode: [[UInt16]]       // [aboveCtx × 5 + leftCtx]
    var uvModeCflNotAllowed: [[UInt16]]   // [yMode]
    var uvModeCflAllowed: [[UInt16]]      // [yMode]
    var angleDelta: [[UInt16]]            // [directionalMode - V_PRED]
    var intrabc: [[UInt16]]
    var partitionW8: [[UInt16]]           // [ctx]
    var partitionW16: [[UInt16]]
    var partitionW32: [[UInt16]]
    var partitionW64: [[UInt16]]
    var partitionW128: [[UInt16]]
    var tx8x8: [[UInt16]]                 // [ctx]
    var tx16x16: [[UInt16]]
    var tx32x32: [[UInt16]]
    var tx64x64: [[UInt16]]
    var skip: [[UInt16]]                  // [ctx]
    var segmentID: [[UInt16]]             // [ctx]
    var filterIntra: [[UInt16]]           // [blockSize]
    var filterIntraMode: [[UInt16]]
    var paletteYMode: [[UInt16]]          // [bsizeCtx × 3 + ctx]
    var paletteUVMode: [[UInt16]]         // [ctx]
    var paletteYSize: [[UInt16]]          // [bsizeCtx]
    var paletteUVSize: [[UInt16]]         // [bsizeCtx]
    /// Color-index CDFs, indexed [paletteSize - 2][ctx].
    var paletteYColor: [[[UInt16]]]
    var paletteUVColor: [[[UInt16]]]
    var deltaQ: [[UInt16]]
    var deltaLF: [[UInt16]]
    var deltaLFMulti: [[UInt16]]          // [frameLfIndex]
    var intraTxTypeSet1: [[UInt16]]       // [txSizeSqr × 13 + intraDir]
    var intraTxTypeSet2: [[UInt16]]       // [txSizeSqr × 13 + intraDir]
    var cflSign: [[UInt16]]
    var cflAlpha: [[UInt16]]              // [ctx]
    var useWiener: [[UInt16]]
    var useSgrproj: [[UInt16]]
    var restorationType: [[UInt16]]
    // Motion vectors (intra block copy uses context 1). Row layouts:
    var mvJoint: [[UInt16]]               // [ctx]
    var mvClass: [[UInt16]]               // [ctx × 2 + comp]
    var mvClass0Bit: [[UInt16]]           // [ctx × 2 + comp]
    var mvClass0Fr: [[UInt16]]            // [(ctx × 2 + comp) × 2 + class0Bit]
    var mvClass0Hp: [[UInt16]]            // [ctx × 2 + comp]
    var mvFr: [[UInt16]]                  // [ctx × 2 + comp]
    var mvHp: [[UInt16]]                  // [ctx × 2 + comp]
    var mvSign: [[UInt16]]                // [ctx × 2 + comp]
    var mvBit: [[UInt16]]                 // [(ctx × 2 + comp) × 10 + i]
    var txfmSplit: [[UInt16]]             // [ctx]
    var interTxTypeSet1: [[UInt16]]       // [txSizeSqr]
    var interTxTypeSet2: [[UInt16]]
    var interTxTypeSet3: [[UInt16]]       // [txSizeSqr]

    // MARK: Coefficient CDFs (quality-selected by init_coeff_cdfs)

    var txbSkip: [[UInt16]]               // [txSzCtx × 13 + ctx]
    var eobPt16: [[UInt16]]               // [ptype × 2 + ctx]
    var eobPt32: [[UInt16]]
    var eobPt64: [[UInt16]]
    var eobPt128: [[UInt16]]
    var eobPt256: [[UInt16]]
    var eobPt512: [[UInt16]]              // [ptype]
    var eobPt1024: [[UInt16]]             // [ptype]
    var eobExtra: [[UInt16]]              // [(txSzCtx × 2 + ptype) × 9 + eobPt - 3]
    var dcSign: [[UInt16]]                // [ptype × 3 + ctx]
    var coeffBaseEOB: [[UInt16]]          // [(txSzCtx × 2 + ptype) × 4 + ctx]
    var coeffBase: [[UInt16]]             // [(txSzCtx × 2 + ptype) × 42 + ctx]
    var coeffBr: [[UInt16]]               // [(min(txSzCtx, 3) × 2 + ptype) × 21 + ctx]

    init(baseQIndex: Int) {
        intraFrameYMode = AV1DefaultCDFs.intraFrameYMode
        uvModeCflNotAllowed = AV1DefaultCDFs.uvModeCflNotAllowed
        uvModeCflAllowed = AV1DefaultCDFs.uvModeCflAllowed
        angleDelta = AV1DefaultCDFs.angleDelta
        intrabc = AV1DefaultCDFs.intrabc
        partitionW8 = AV1DefaultCDFs.partitionW8
        partitionW16 = AV1DefaultCDFs.partitionW16
        partitionW32 = AV1DefaultCDFs.partitionW32
        partitionW64 = AV1DefaultCDFs.partitionW64
        partitionW128 = AV1DefaultCDFs.partitionW128
        tx8x8 = AV1DefaultCDFs.tx8x8
        tx16x16 = AV1DefaultCDFs.tx16x16
        tx32x32 = AV1DefaultCDFs.tx32x32
        tx64x64 = AV1DefaultCDFs.tx64x64
        skip = AV1DefaultCDFs.skip
        segmentID = AV1DefaultCDFs.segmentID
        filterIntra = AV1DefaultCDFs.filterIntra
        filterIntraMode = AV1DefaultCDFs.filterIntraMode
        paletteYMode = AV1DefaultCDFs.paletteYMode
        paletteUVMode = AV1DefaultCDFs.paletteUVMode
        paletteYSize = AV1DefaultCDFs.paletteYSize
        paletteUVSize = AV1DefaultCDFs.paletteUVSize
        paletteYColor = [
            AV1DefaultCDFs.paletteSize2YColor, AV1DefaultCDFs.paletteSize3YColor,
            AV1DefaultCDFs.paletteSize4YColor, AV1DefaultCDFs.paletteSize5YColor,
            AV1DefaultCDFs.paletteSize6YColor, AV1DefaultCDFs.paletteSize7YColor,
            AV1DefaultCDFs.paletteSize8YColor,
        ]
        paletteUVColor = [
            AV1DefaultCDFs.paletteSize2UVColor, AV1DefaultCDFs.paletteSize3UVColor,
            AV1DefaultCDFs.paletteSize4UVColor, AV1DefaultCDFs.paletteSize5UVColor,
            AV1DefaultCDFs.paletteSize6UVColor, AV1DefaultCDFs.paletteSize7UVColor,
            AV1DefaultCDFs.paletteSize8UVColor,
        ]
        deltaQ = AV1DefaultCDFs.deltaQ
        deltaLF = AV1DefaultCDFs.deltaLF
        deltaLFMulti = [[UInt16]](repeating: AV1DefaultCDFs.deltaLF[0], count: 4)
        intraTxTypeSet1 = AV1DefaultCDFs.intraTxTypeSet1
        intraTxTypeSet2 = AV1DefaultCDFs.intraTxTypeSet2
        cflSign = AV1DefaultCDFs.cflSign
        cflAlpha = AV1DefaultCDFs.cflAlpha
        useWiener = AV1DefaultCDFs.useWiener
        useSgrproj = AV1DefaultCDFs.useSgrproj
        restorationType = AV1DefaultCDFs.restorationType
        // MV tables replicate the defaults per context (and per component
        // where the defaults don't already carry that dimension).
        mvJoint = [[UInt16]](repeating: AV1DefaultCDFs.mvJoint[0], count: 2)
        mvClass = [AV1DefaultCDFs.mvClass[0], AV1DefaultCDFs.mvClass[1],
                   AV1DefaultCDFs.mvClass[0], AV1DefaultCDFs.mvClass[1]]
        mvClass0Bit = [[UInt16]](repeating: AV1DefaultCDFs.mvClass0Bit[0], count: 4)
        mvClass0Fr = AV1DefaultCDFs.mvClass0Fr + AV1DefaultCDFs.mvClass0Fr
        mvClass0Hp = [[UInt16]](repeating: AV1DefaultCDFs.mvClass0Hp[0], count: 4)
        mvFr = AV1DefaultCDFs.mvFr + AV1DefaultCDFs.mvFr
        mvHp = [[UInt16]](repeating: AV1DefaultCDFs.mvHp[0], count: 4)
        mvSign = [[UInt16]](repeating: AV1DefaultCDFs.mvSign[0], count: 4)
        mvBit = AV1DefaultCDFs.mvBit + AV1DefaultCDFs.mvBit
            + AV1DefaultCDFs.mvBit + AV1DefaultCDFs.mvBit
        txfmSplit = AV1DefaultCDFs.txfmSplit
        interTxTypeSet1 = AV1DefaultCDFs.interTxTypeSet1
        interTxTypeSet2 = AV1DefaultCDFs.interTxTypeSet2
        interTxTypeSet3 = AV1DefaultCDFs.interTxTypeSet3

        // init_coeff_cdfs: quality context from base_q_idx.
        let qContext: Int
        if baseQIndex <= 20 {
            qContext = 0
        } else if baseQIndex <= 60 {
            qContext = 1
        } else if baseQIndex <= 120 {
            qContext = 2
        } else {
            qContext = 3
        }
        func slice(_ table: [[UInt16]]) -> [[UInt16]] {
            let perContext = table.count / 4
            return Array(table[qContext * perContext..<(qContext + 1) * perContext])
        }
        txbSkip = slice(AV1DefaultCDFs.txbSkip)
        eobPt16 = slice(AV1DefaultCDFs.eobPt16)
        eobPt32 = slice(AV1DefaultCDFs.eobPt32)
        eobPt64 = slice(AV1DefaultCDFs.eobPt64)
        eobPt128 = slice(AV1DefaultCDFs.eobPt128)
        eobPt256 = slice(AV1DefaultCDFs.eobPt256)
        eobPt512 = slice(AV1DefaultCDFs.eobPt512)
        eobPt1024 = slice(AV1DefaultCDFs.eobPt1024)
        eobExtra = slice(AV1DefaultCDFs.eobExtra)
        dcSign = slice(AV1DefaultCDFs.dcSign)
        coeffBaseEOB = slice(AV1DefaultCDFs.coeffBaseEOB)
        coeffBase = slice(AV1DefaultCDFs.coeffBase)
        coeffBr = slice(AV1DefaultCDFs.coeffBr)
    }
}
