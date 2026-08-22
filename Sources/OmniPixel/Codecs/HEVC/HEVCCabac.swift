/// The CABAC (context-adaptive binary arithmetic coding) tables shared by
/// H.264 and H.265 (ITU-T H.265 section 9.3.4.3).
enum HEVCCabacTables {
    /// LPS range by probability state and range quantizer (Table 9-46).
    static let lpsRange: [[UInt8]] = [
        [128, 176, 208, 240], [128, 167, 197, 227], [128, 158, 187, 216], [123, 150, 178, 205],
        [116, 142, 169, 195], [111, 135, 160, 185], [105, 128, 152, 175], [100, 122, 144, 166],
        [95, 116, 137, 158], [90, 110, 130, 150], [85, 104, 123, 142], [81, 99, 117, 135],
        [77, 94, 111, 128], [73, 89, 105, 122], [69, 85, 100, 116], [66, 80, 95, 110],
        [62, 76, 90, 104], [59, 72, 86, 99], [56, 69, 81, 94], [53, 65, 77, 89],
        [51, 62, 73, 85], [48, 59, 69, 80], [46, 56, 66, 76], [43, 53, 63, 72],
        [41, 50, 59, 69], [39, 48, 56, 65], [37, 45, 54, 62], [35, 43, 51, 59],
        [33, 41, 48, 56], [32, 39, 46, 53], [30, 37, 43, 50], [29, 35, 41, 48],
        [27, 33, 39, 45], [26, 31, 37, 43], [24, 30, 35, 41], [23, 28, 33, 39],
        [22, 27, 32, 37], [21, 26, 30, 35], [20, 24, 29, 33], [19, 23, 27, 31],
        [18, 22, 26, 30], [17, 21, 25, 28], [16, 20, 23, 27], [15, 19, 22, 25],
        [14, 18, 21, 24], [14, 17, 20, 23], [13, 16, 19, 22], [12, 15, 18, 21],
        [12, 14, 17, 20], [11, 14, 16, 19], [11, 13, 15, 18], [10, 12, 15, 17],
        [10, 12, 14, 16], [9, 11, 13, 15], [9, 11, 12, 14], [8, 10, 12, 14],
        [8, 9, 11, 13], [7, 9, 11, 12], [7, 9, 10, 12], [7, 8, 10, 11],
        [6, 8, 9, 11], [6, 7, 9, 10], [6, 7, 8, 9], [2, 2, 2, 2],
    ]

    /// Probability state after decoding the most probable symbol.
    static let mpsTransition: [UInt8] = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
        49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 62, 63,
    ]

    /// Probability state after decoding the least probable symbol.
    static let lpsTransition: [UInt8] = [
        0, 0, 1, 2, 2, 4, 4, 5, 6, 7, 8, 9, 9, 11, 11, 12,
        13, 13, 15, 15, 16, 16, 18, 18, 19, 19, 21, 21, 22, 22, 23, 24,
        24, 25, 26, 26, 27, 27, 28, 29, 29, 30, 30, 30, 31, 32, 32, 33,
        33, 33, 34, 34, 35, 35, 35, 36, 36, 36, 37, 37, 37, 38, 38, 63,
    ]
}

/// One CABAC context variable: an adaptive probability state plus the value
/// of the most probable symbol.
struct CABACContext {
    var state: Int
    var mps: Int

    /// Initializes from an 8-bit init value and the slice QP
    /// (ITU-T H.265 section 9.3.2.2).
    init(initValue: Int, qp: Int) {
        let slope = (initValue >> 4) * 5 - 45
        let intercept = ((initValue & 15) << 3) - 16
        let clippedQP = min(max(qp, 0), 51)
        let preState = min(max(((slope * clippedQP) >> 4) + intercept, 1), 126)
        if preState <= 63 {
            state = 63 - preState
            mps = 0
        } else {
            state = preState - 64
            mps = 1
        }
    }
}

/// The CABAC arithmetic decoding engine (ITU-T H.265 section 9.3.4.3):
/// a 9-bit range/offset decoder with table-driven probability adaptation,
/// plus the bypass and terminate modes. Bits flow through a 64-bit cache
/// that is refilled a byte at a time; prefetching never reads past the
/// payload — only consuming beyond it throws.
struct CABACDecoder {
    private let bytes: [UInt8]
    private let totalBits: Int
    private var cache: UInt64 = 0
    private var cacheBits = 0
    private var loadedBits: Int
    private var range = 510
    private var offset = 0

    /// The bit position of the next unconsumed bit (diagnostics).
    var bitPosition: Int {
        loadedBits - cacheBits
    }

    /// Starts decoding at a byte-aligned bit position in the slice RBSP
    /// (the position after the slice header's alignment bits).
    init(bytes: [UInt8], startingAtBit bit: Int) throws {
        self.bytes = bytes
        self.totalBits = bytes.count * 8
        self.loadedBits = bit
        offset = try readBits(9)
        guard offset < 510 else {
            throw ImageError.invalidData(reason: "Invalid HEVC CABAC initialization")
        }
    }

    /// Decodes one bin using (and adapting) the given context.
    mutating func decodeBin(_ context: inout CABACContext) throws -> Int {
        let quantizedRange = (range >> 6) & 3
        let lpsRange = Int(HEVCCabacTables.lpsRange[context.state][quantizedRange])
        range -= lpsRange

        let bin: Int
        if offset >= range {
            // Least probable symbol.
            bin = 1 - context.mps
            offset -= range
            range = lpsRange
            if context.state == 0 {
                context.mps = 1 - context.mps
            }
            context.state = Int(HEVCCabacTables.lpsTransition[context.state])
        } else {
            // Most probable symbol.
            bin = context.mps
            context.state = Int(HEVCCabacTables.mpsTransition[context.state])
        }
        try renormalize()
        return bin
    }

    /// Decodes one equiprobable bin.
    mutating func decodeBypass() throws -> Int {
        offset = offset << 1 | (try readBit())
        if offset >= range {
            offset -= range
            return 1
        }
        return 0
    }

    /// Decodes `count` bypass bins as an unsigned value, first bin most
    /// significant. The bypass recurrence with a constant range collapses
    /// into one division: after n bins the value is ⌊(offset·2ⁿ + bits) / range⌋
    /// and the remainder is the new offset.
    mutating func decodeBypassBits(_ count: Int) throws -> Int {
        guard count > 0 else { return 0 }
        guard count <= 32 else {
            let high = try decodeBypassBits(count - 32)
            return high << 32 | (try decodeBypassBits(32))
        }
        let expanded = offset << count | (try readBits(count))
        offset = expanded % range
        // Valid streams keep offset < range, making the mask a no-op; on
        // corrupt data it keeps the result bounded like the bin-by-bin
        // loop did.
        return (expanded / range) & ((1 << count) - 1)
    }

    /// Decodes an end-of-slice / end-of-substream terminate bin.
    mutating func decodeTerminate() throws -> Int {
        range -= 2
        if offset >= range {
            return 1
        }
        try renormalize()
        return 0
    }

    private mutating func renormalize() throws {
        if range >= 256 {
            return
        }
        // Doublings until the range is back at 9 bits (≥ 256).
        let shift = range.leadingZeroBitCount - (Int.bitWidth - 9)
        range <<= shift
        offset = offset << shift | (try readBits(shift))
    }

    private mutating func fill() {
        while cacheBits <= 56, loadedBits < totalBits {
            cache = cache << 8 | UInt64(bytes[loadedBits >> 3])
            cacheBits += 8
            loadedBits += 8
        }
    }

    private mutating func readBit() throws -> Int {
        if cacheBits == 0 {
            fill()
            guard cacheBits > 0 else {
                throw ImageError.invalidData(reason: "HEVC CABAC data ended early")
            }
        }
        cacheBits -= 1
        return Int((cache >> UInt64(cacheBits)) & 1)
    }

    private mutating func readBits(_ count: Int) throws -> Int {
        guard count > 0 else { return 0 }
        if cacheBits < count {
            fill()
            guard cacheBits >= count else {
                throw ImageError.invalidData(reason: "HEVC CABAC data ended early")
            }
        }
        cacheBits -= count
        return Int((cache >> UInt64(cacheBits)) & ((1 << UInt64(count)) - 1))
    }
}
