/// AV1 inverse transforms (specification section 7.13): the butterfly
/// inverse DCT (sizes 4–64), inverse ADST (4/8/16), the scaled identity
/// transforms, the lossless Walsh–Hadamard transform, and the 2D row/column
/// process combining them.
enum AV1Transforms {
    /// 4096 · cos(angle·π/128) for angle 0…64.
    private static let cos128Lookup: [Int] = [
        4096, 4095, 4091, 4085, 4076, 4065, 4052, 4036,
        4017, 3996, 3973, 3948, 3920, 3889, 3857, 3822,
        3784, 3745, 3703, 3659, 3612, 3564, 3513, 3461,
        3406, 3349, 3290, 3229, 3166, 3102, 3035, 2967,
        2896, 2824, 2751, 2675, 2598, 2520, 2440, 2359,
        2276, 2191, 2106, 2019, 1931, 1842, 1751, 1660,
        1567, 1474, 1380, 1285, 1189, 1092, 995, 897,
        799, 700, 601, 501, 401, 301, 201, 101, 0,
    ]

    private static func cos128(_ angle: Int) -> Int {
        let angle2 = angle & 255
        if angle2 <= 64 {
            return cos128Lookup[angle2]
        }
        if angle2 <= 128 {
            return -cos128Lookup[128 - angle2]
        }
        if angle2 <= 192 {
            return -cos128Lookup[angle2 - 128]
        }
        return cos128Lookup[256 - angle2]
    }

    private static func sin128(_ angle: Int) -> Int {
        cos128(angle - 64)
    }

    private static func round2(_ x: Int, _ n: Int) -> Int {
        n == 0 ? x : (x + (1 << (n - 1))) >> n
    }

    /// Bit reversals, precomputed per width (brev is on every butterfly's
    /// index path).
    private static let brevTables: [[Int]] = (0...6).map { numBits in
        (0..<(1 << numBits)).map { x in
            var t = 0
            for i in 0..<numBits {
                t += ((x >> i) & 1) << (numBits - 1 - i)
            }
            return t
        }
    }

    @inline(__always)
    private static func brev(_ numBits: Int, _ x: Int) -> Int {
        brevTables[numBits][x]
    }

    /// The working array shared by the 1D transforms.
    struct Lane {
        var t = [Int](repeating: 0, count: 64)

        /// B(a, b, angle, flip, r): butterfly rotation.
        private mutating func butterfly(_ a: Int, _ b: Int, _ angle: Int, _ flip: Bool) {
            let x = t[a] * AV1Transforms.cos128(angle) - t[b] * AV1Transforms.sin128(angle)
            let y = t[a] * AV1Transforms.sin128(angle) + t[b] * AV1Transforms.cos128(angle)
            t[a] = AV1Transforms.round2(x, 12)
            t[b] = AV1Transforms.round2(y, 12)
            if flip {
                t.swapAt(a, b)
            }
        }

        /// H(a, b, flip, r): Hadamard rotation with clamping.
        private mutating func hadamard(_ a: Int, _ b: Int, _ flip: Bool, _ r: Int) {
            let (i, j) = flip ? (b, a) : (a, b)
            let x = t[i]
            let y = t[j]
            let limit = 1 << (r - 1)
            t[i] = min(max(x + y, -limit), limit - 1)
            t[j] = min(max(x - y, -limit), limit - 1)
        }

        /// Inverse DCT of length 1 << n (7.13.2.2–3).
        mutating func inverseDCT(n: Int, r: Int) {
            // Permutation.
            let count = 1 << n
            let copy = t
            for i in 0..<count {
                t[i] = copy[AV1Transforms.brev(n, i)]
            }
            if n == 6 {
                for i in 0...15 { butterfly(32 + i, 63 - i, 63 - 4 * AV1Transforms.brev(4, i), false) }
            }
            if n >= 5 {
                for i in 0...7 { butterfly(16 + i, 31 - i, 6 + (AV1Transforms.brev(3, 7 - i) << 3), false) }
            }
            if n == 6 {
                for i in 0...15 { hadamard(32 + i * 2, 33 + i * 2, i & 1 == 1, r) }
            }
            if n >= 4 {
                for i in 0...3 { butterfly(8 + i, 15 - i, 12 + (AV1Transforms.brev(2, 3 - i) << 4), false) }
            }
            if n >= 5 {
                for i in 0...7 { hadamard(16 + 2 * i, 17 + 2 * i, i & 1 == 1, r) }
            }
            if n == 6 {
                for i in 0...3 {
                    for j in 0...1 {
                        butterfly(62 - i * 4 - j, 33 + i * 4 + j, 60 - 16 * AV1Transforms.brev(2, i) + 64 * j, true)
                    }
                }
            }
            if n >= 3 {
                for i in 0...1 { butterfly(4 + i, 7 - i, 56 - 32 * i, false) }
            }
            if n >= 4 {
                for i in 0...3 { hadamard(8 + 2 * i, 9 + 2 * i, i & 1 == 1, r) }
            }
            if n >= 5 {
                for i in 0...1 {
                    for j in 0...1 {
                        butterfly(30 - 4 * i - j, 17 + 4 * i + j, 24 + (j << 6) + ((1 - i) << 5), true)
                    }
                }
            }
            if n == 6 {
                for i in 0...7 {
                    for j in 0...1 {
                        hadamard(32 + i * 4 + j, 35 + i * 4 - j, i & 1 == 1, r)
                    }
                }
            }
            for i in 0...1 { butterfly(2 * i, 2 * i + 1, 32 + 16 * i, i == 0) }
            if n >= 3 {
                for i in 0...1 { hadamard(4 + 2 * i, 5 + 2 * i, i == 1, r) }
            }
            if n >= 4 {
                for i in 0...1 { butterfly(14 - i, 9 + i, 48 + 64 * i, true) }
            }
            if n >= 5 {
                for i in 0...3 {
                    for j in 0...1 {
                        hadamard(16 + 4 * i + j, 19 + 4 * i - j, i & 1 == 1, r)
                    }
                }
            }
            if n == 6 {
                for i in 0...1 {
                    for j in 0...3 {
                        butterfly(61 - i * 8 - j, 34 + i * 8 + j, 56 - i * 32 + (j >> 1) * 64, true)
                    }
                }
            }
            for i in 0...1 { hadamard(i, 3 - i, false, r) }
            if n >= 3 {
                butterfly(6, 5, 32, true)
            }
            if n >= 4 {
                for i in 0...1 {
                    for j in 0...1 {
                        hadamard(8 + 4 * i + j, 11 + 4 * i - j, i == 1, r)
                    }
                }
            }
            if n >= 5 {
                for i in 0...3 { butterfly(29 - i, 18 + i, 48 + (i >> 1) * 64, true) }
            }
            if n == 6 {
                for i in 0...3 {
                    for j in 0...3 {
                        hadamard(32 + 8 * i + j, 39 + 8 * i - j, i & 1 == 1, r)
                    }
                }
            }
            if n >= 3 {
                for i in 0...3 { hadamard(i, 7 - i, false, r) }
            }
            if n >= 4 {
                for i in 0...1 { butterfly(13 - i, 10 + i, 32, true) }
            }
            if n >= 5 {
                for i in 0...1 {
                    for j in 0...3 {
                        hadamard(16 + i * 8 + j, 23 + i * 8 - j, i == 1, r)
                    }
                }
            }
            if n == 6 {
                for i in 0...7 { butterfly(59 - i, 36 + i, i < 4 ? 48 : 112, true) }
            }
            if n >= 4 {
                for i in 0...7 { hadamard(i, 15 - i, false, r) }
            }
            if n >= 5 {
                for i in 0...3 { butterfly(27 - i, 20 + i, 32, true) }
            }
            if n == 6 {
                for i in 0...7 {
                    hadamard(32 + i, 47 - i, false, r)
                    hadamard(48 + i, 63 - i, true, r)
                }
            }
            if n >= 5 {
                for i in 0...15 { hadamard(i, 31 - i, false, r) }
            }
            if n == 6 {
                for i in 0...7 { butterfly(55 - i, 40 + i, 32, true) }
                for i in 0...31 { hadamard(i, 63 - i, false, r) }
            }
        }

        /// Inverse ADST of length 1 << n for n 2…4 (7.13.2.4–9).
        mutating func inverseADST(n: Int, r: Int) {
            if n == 2 {
                inverseADST4()
                return
            }
            // Input permutation.
            let n0 = 1 << n
            var copy = t
            for i in 0..<n0 {
                let idx = (i & 1) != 0 ? (i - 1) : (n0 - i - 1)
                t[i] = copy[idx]
            }
            if n == 3 {
                for i in 0...3 { butterfly(2 * i, 2 * i + 1, 60 - 16 * i, true) }
                for i in 0...3 { hadamard(i, 4 + i, false, r) }
                for i in 0...1 { butterfly(4 + 3 * i, 5 + i, 48 - 32 * i, true) }
                for j in 0...1 {
                    for i in 0...1 {
                        hadamard(4 * j + i, 2 + 4 * j + i, false, r)
                    }
                }
                for i in 0...1 { butterfly(2 + 4 * i, 3 + 4 * i, 32, true) }
            } else {
                for i in 0...7 { butterfly(2 * i, 2 * i + 1, 62 - 8 * i, true) }
                for i in 0...7 { hadamard(i, 8 + i, false, r) }
                for i in 0...1 {
                    butterfly(8 + 2 * i, 9 + 2 * i, 56 - 32 * i, true)
                    butterfly(13 + 2 * i, 12 + 2 * i, 8 + 32 * i, true)
                }
                for j in 0...1 {
                    for i in 0...3 {
                        hadamard(8 * j + i, 4 + 8 * j + i, false, r)
                    }
                }
                for j in 0...1 {
                    for i in 0...1 {
                        butterfly(4 + 8 * j + 3 * i, 5 + 8 * j + i, 48 - 32 * i, true)
                    }
                }
                for j in 0...3 {
                    for i in 0...1 {
                        hadamard(4 * j + i, 2 + 4 * j + i, false, r)
                    }
                }
                for i in 0...3 { butterfly(2 + 4 * i, 3 + 4 * i, 32, true) }
            }
            // Output permutation.
            copy = t
            for i in 0..<n0 {
                let a = (i >> 3) & 1
                let b = ((i >> 2) & 1) ^ ((i >> 3) & 1)
                let c = ((i >> 1) & 1) ^ ((i >> 2) & 1)
                let d = (i & 1) ^ ((i >> 1) & 1)
                let idx = ((d << 3) | (c << 2) | (b << 1) | a) >> (4 - n)
                t[i] = (i & 1) != 0 ? -copy[idx] : copy[idx]
            }
        }

        private mutating func inverseADST4() {
            let sinPi1 = 1321, sinPi2 = 2482, sinPi3 = 3344, sinPi4 = 3803
            var s0 = sinPi1 * t[0]
            var s1 = sinPi2 * t[0]
            let s2in = sinPi3 * t[1]
            let s3in = sinPi4 * t[2]
            let s4 = sinPi1 * t[2]
            let s5 = sinPi2 * t[3]
            let s6 = sinPi4 * t[3]
            let a7 = t[0] - t[2]
            let b7 = a7 + t[3]
            s0 += s3in
            s1 -= s4
            let s3 = s2in
            let s2 = sinPi3 * b7
            s0 += s5
            s1 -= s6
            let x0 = s0 + s3
            let x1 = s1 + s3
            let x2 = s2
            let x3 = s0 + s1 - s3
            t[0] = AV1Transforms.round2(x0, 12)
            t[1] = AV1Transforms.round2(x1, 12)
            t[2] = AV1Transforms.round2(x2, 12)
            t[3] = AV1Transforms.round2(x3, 12)
        }

        /// Inverse Walsh–Hadamard (lossless), length 4 (7.13.2.10).
        mutating func inverseWHT(shift: Int) {
            var a = t[0] >> shift
            var c = t[1] >> shift
            var d = t[2] >> shift
            var b = t[3] >> shift
            a += c
            d -= b
            let e = (a - d) >> 1
            b = e - b
            c = e - c
            a -= b
            d += c
            t[0] = a
            t[1] = b
            t[2] = c
            t[3] = d
        }

        /// Inverse identity transform of length 1 << n for n 2…5.
        mutating func inverseIdentity(n: Int) {
            switch n {
            case 2:
                for i in 0...3 { t[i] = AV1Transforms.round2(t[i] * 5793, 12) }
            case 3:
                for i in 0...7 { t[i] *= 2 }
            case 4:
                for i in 0...15 { t[i] = AV1Transforms.round2(t[i] * 11586, 12) }
            default:
                for i in 0...31 { t[i] *= 4 }
            }
        }
    }

    /// Transform_Row_Shift.
    private static let rowShiftTable = [0, 1, 2, 2, 2, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2]

    /// Row transform families by transform type: 0 = DCT, 1 = ADST, 2 = identity.
    private static let rowFamily = [0, 0, 1, 1, 0, 1, 1, 1, 1, 2, 2, 0, 2, 1, 2, 1]
    /// Column transform families by transform type.
    private static let columnFamily = [0, 1, 0, 1, 1, 0, 1, 1, 1, 2, 0, 2, 1, 2, 1, 2]

    /// 2D inverse transform process (7.13.3): consumes the dequantized
    /// coefficients (tw × th, ≤ 32 per axis, in raster order) and fills the
    /// caller's flat h × w residual scratch (stride w).
    static func inverse2D(
        dequant: [Int],
        txSz: Int,
        txType: Int,
        lossless: Bool,
        bitDepth: Int,
        lane: inout Lane,
        residual: inout [Int]
    ) {
        let log2W = AV1Tables.txWidthLog2[txSz]
        let log2H = AV1Tables.txHeightLog2[txSz]
        let w = 1 << log2W
        let h = 1 << log2H
        let tw = min(32, w)
        let rowShift = lossless ? 0 : rowShiftTable[txSz]
        let colShift = lossless ? 0 : 4
        let rowClampRange = bitDepth + 8
        let colClampRange = max(bitDepth + 6, 16)
        let rectangular = abs(log2W - log2H) == 1

        for i in 0..<h {
            for j in 0..<w {
                lane.t[j] = (i < 32 && j < 32) ? dequant[i * tw + j] : 0
            }
            if rectangular {
                for j in 0..<w {
                    lane.t[j] = round2(lane.t[j] * 2896, 12)
                }
            }
            if lossless {
                lane.inverseWHT(shift: 2)
            } else {
                switch rowFamily[txType] {
                case 0: lane.inverseDCT(n: log2W, r: rowClampRange)
                case 1: lane.inverseADST(n: log2W, r: rowClampRange)
                default: lane.inverseIdentity(n: log2W)
                }
            }
            let clampLimit = 1 << (colClampRange - 1)
            for j in 0..<w {
                let value = round2(lane.t[j], rowShift)
                residual[i * w + j] = min(max(value, -clampLimit), clampLimit - 1)
            }
        }

        for j in 0..<w {
            for i in 0..<h {
                lane.t[i] = residual[i * w + j]
            }
            if lossless {
                lane.inverseWHT(shift: 0)
            } else {
                switch columnFamily[txType] {
                case 0: lane.inverseDCT(n: log2H, r: colClampRange)
                case 1: lane.inverseADST(n: log2H, r: colClampRange)
                default: lane.inverseIdentity(n: log2H)
                }
            }
            for i in 0..<h {
                residual[i * w + j] = round2(lane.t[i], colShift)
            }
        }
    }
}
