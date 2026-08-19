/// The complete set of CABAC context variables for decoding an I-slice,
/// with initialization values from ITU-T H.265 tables 9-5…9-32 (initType 0,
/// verified against libde265's contextmodel.cc).
struct HEVCContextSet {
    var saoMerge: CABACContext
    var saoTypeIndex: CABACContext
    var splitCUFlag: [CABACContext]           // 3, by neighbor depth
    var transquantBypass: CABACContext
    var partMode: CABACContext
    var prevIntraLumaPred: CABACContext
    var intraChromaPredMode: CABACContext
    var splitTransformFlag: [CABACContext]    // 3, by transform size
    var cbfLuma: [CABACContext]               // 2, by transform depth
    var cbfChroma: [CABACContext]             // 4, by transform depth
    var transformSkip: [CABACContext]         // luma, chroma
    var lastXPrefix: [CABACContext]           // 18
    var lastYPrefix: [CABACContext]           // 18
    var codedSubBlock: [CABACContext]         // 4
    var significantCoefficient: [CABACContext]  // 42 (27 luma + 15 chroma)
    var greater1: [CABACContext]              // 24 (16 luma + 8 chroma)
    var greater2: [CABACContext]              // 6 (4 luma + 2 chroma)
    var cuQPDeltaAbs: [CABACContext]          // 2

    init(qp: Int) {
        func make(_ values: [Int]) -> [CABACContext] {
            values.map { CABACContext(initValue: $0, qp: qp) }
        }
        saoMerge = CABACContext(initValue: 153, qp: qp)
        saoTypeIndex = CABACContext(initValue: 200, qp: qp)
        splitCUFlag = make([139, 141, 157])
        transquantBypass = CABACContext(initValue: 154, qp: qp)
        partMode = CABACContext(initValue: 184, qp: qp)
        prevIntraLumaPred = CABACContext(initValue: 184, qp: qp)
        intraChromaPredMode = CABACContext(initValue: 63, qp: qp)
        splitTransformFlag = make([153, 138, 138])
        cbfLuma = make([111, 141])
        cbfChroma = make([94, 138, 182, 154])
        transformSkip = make([139, 139])
        lastXPrefix = make(Self.lastPrefixInitValues)
        lastYPrefix = make(Self.lastPrefixInitValues)
        codedSubBlock = make([91, 171, 134, 141])
        significantCoefficient = make(Self.significantCoefficientInitValues)
        greater1 = make(Self.greater1InitValues)
        greater2 = make([138, 153, 136, 167, 152, 152])
        cuQPDeltaAbs = make([154, 154])
    }

    static let lastPrefixInitValues = [
        110, 110, 124, 125, 140, 153, 125, 127, 140,
        109, 111, 143, 127, 111, 79, 108, 123, 63,
    ]

    static let significantCoefficientInitValues = [
        111, 111, 125, 110, 110, 94, 124, 108, 124, 107, 125, 141, 179, 153,
        125, 107, 125, 141, 179, 153, 125, 107, 125, 141, 179, 153, 125, 140,
        139, 182, 182, 152, 136, 152, 136, 153, 136, 139, 111, 136, 139, 111,
    ]

    static let greater1InitValues = [
        140, 92, 137, 138, 140, 152, 138, 139, 153, 74, 149, 92,
        139, 107, 122, 152, 140, 179, 166, 182, 140, 227, 122, 197,
    ]
}

/// Coefficient scan order generation (ITU-T H.265 section 6.5.3):
/// 0 = up-right diagonal, 1 = horizontal, 2 = vertical.
enum HEVCScan {
    static func order(size: Int, scan: Int) -> [(x: Int, y: Int)] {
        switch scan {
        case 1:  // horizontal: row by row
            var result: [(x: Int, y: Int)] = []
            for y in 0..<size {
                for x in 0..<size {
                    result.append((x, y))
                }
            }
            return result
        case 2:  // vertical: column by column
            var result: [(x: Int, y: Int)] = []
            for x in 0..<size {
                for y in 0..<size {
                    result.append((x, y))
                }
            }
            return result
        default:  // up-right diagonal
            var result: [(x: Int, y: Int)] = []
            var x = 0
            var y = 0
            while true {
                while y >= 0 {
                    if x < size && y < size {
                        result.append((x, y))
                    }
                    y -= 1
                    x += 1
                }
                y = x
                x = 0
                if result.count >= size * size {
                    return result
                }
            }
        }
    }
}
