/// The reconstructed frame planes and the AV1 intra prediction and
/// reconstruction processes (spec 7.11.2, 7.12, 7.13), invoked inline by
/// the tile decoder as each transform block's syntax is decoded.
final class AV1FrameBuffer {
    let bitDepth: Int
    let subX, subY: Int
    let planeCount: Int
    /// Coded-area dimensions per plane (mi-aligned).
    let width: [Int]
    let height: [Int]
    /// Superblock-aligned allocation (blocks may overhang the mi area).
    let allocatedWidth: [Int]
    let allocatedHeight: [Int]
    /// Samples per plane, row-major over the allocated size.
    var planes: [[Int]]

    // MARK: Per-position decoding state consumed by the loop filters

    let miRows, miCols: Int
    var miSizes: [[UInt8]]
    var yModes: [[UInt8]]
    var segmentIDs: [[UInt8]]
    var skips: [[Bool]]
    /// Loop filter deltas per mode-info unit (4 filter indices).
    var deltaLFs: [[[Int8]]]
    /// CDEF strength index per 64×64 (-1 = none coded).
    var cdefIndex: [[Int8]]
    /// Transform sizes per plane in plane-subsampled 4-sample units.
    var loopfilterTxSizes: [[[UInt8]]]

    init(sequence: AV1SequenceHeader, header: AV1FrameHeader) {
        bitDepth = sequence.bitDepth
        subX = sequence.subsamplingX
        subY = sequence.subsamplingY
        planeCount = sequence.monochrome ? 1 : 3
        let sb4 = sequence.use128x128Superblock ? 32 : 16
        let alignedCols = (header.miCols + sb4 - 1) & ~(sb4 - 1)
        let alignedRows = (header.miRows + sb4 - 1) & ~(sb4 - 1)
        var w: [Int] = [], h: [Int] = [], aw: [Int] = [], ah: [Int] = []
        for plane in 0..<planeCount {
            let sx = plane > 0 ? subX : 0
            let sy = plane > 0 ? subY : 0
            w.append((header.miCols * 4) >> sx)
            h.append((header.miRows * 4) >> sy)
            aw.append((alignedCols * 4) >> sx)
            ah.append((alignedRows * 4) >> sy)
        }
        width = w
        height = h
        allocatedWidth = aw
        allocatedHeight = ah
        planes = (0..<planeCount).map { [Int](repeating: 0, count: aw[$0] * ah[$0]) }

        miRows = header.miRows
        miCols = header.miCols
        miSizes = [[UInt8]](repeating: [UInt8](repeating: 0, count: miCols), count: miRows)
        yModes = [[UInt8]](repeating: [UInt8](repeating: 0, count: miCols), count: miRows)
        segmentIDs = [[UInt8]](repeating: [UInt8](repeating: 0, count: miCols), count: miRows)
        skips = [[Bool]](repeating: [Bool](repeating: false, count: miCols), count: miRows)
        deltaLFs = [[[Int8]]](
            repeating: [[Int8]](repeating: [0, 0, 0, 0], count: miCols),
            count: miRows
        )
        cdefIndex = [[Int8]](
            repeating: [Int8](repeating: -1, count: (miCols + 15) >> 4),
            count: (miRows + 15) >> 4
        )
        var txSizes: [[[UInt8]]] = []
        for plane in 0..<planeCount {
            let sx = plane > 0 ? sequence.subsamplingX : 0
            let sy = plane > 0 ? sequence.subsamplingY : 0
            txSizes.append([[UInt8]](
                repeating: [UInt8](repeating: 0, count: (header.miCols + sx) >> sx),
                count: (header.miRows + sy) >> sy
            ))
        }
        loopfilterTxSizes = txSizes
    }

    @inline(__always)
    func sample(_ plane: Int, _ y: Int, _ x: Int) -> Int {
        planes[plane][y * allocatedWidth[plane] + x]
    }

    @inline(__always)
    func setSample(_ plane: Int, _ y: Int, _ x: Int, _ value: Int) {
        planes[plane][y * allocatedWidth[plane] + x] = value
    }
}

extension AV1TileDecoder {
    // MARK: Intra prediction (7.11.2)

    /// predict_intra: fills the w×h region at (x, y) of the plane.
    func predictIntra(
        frame: AV1FrameBuffer,
        plane: Int,
        x: Int,
        y: Int,
        haveLeft: Bool,
        haveAbove: Bool,
        haveAboveRight: Bool,
        haveBelowLeft: Bool,
        mode: Int,
        log2W: Int,
        log2H: Int
    ) {
        let w = 1 << log2W
        let h = 1 << log2H
        let bitDepth = frame.bitDepth
        let maxX = frame.width[plane] - 1
        let maxY = frame.height[plane] - 1

        // AboveRow / LeftCol with indices -2 … 2(w+h): stored with offset.
        let offset = 4
        var aboveRow = [Int](repeating: 0, count: 2 * (w + h) + 8)
        var leftCol = [Int](repeating: 0, count: 2 * (w + h) + 8)

        if !haveAbove && haveLeft {
            let value = frame.sample(plane, y, x - 1)
            for i in 0..<(w + h) { aboveRow[offset + i] = value }
        } else if !haveAbove && !haveLeft {
            let value = (1 << (bitDepth - 1)) - 1
            for i in 0..<(w + h) { aboveRow[offset + i] = value }
        } else {
            let aboveLimit = min(maxX, x + (haveAboveRight ? 2 * w : w) - 1)
            for i in 0..<(w + h) {
                aboveRow[offset + i] = frame.sample(plane, y - 1, min(aboveLimit, x + i))
            }
        }
        if !haveLeft && haveAbove {
            let value = frame.sample(plane, y - 1, x)
            for i in 0..<(w + h) { leftCol[offset + i] = value }
        } else if !haveLeft && !haveAbove {
            let value = (1 << (bitDepth - 1)) + 1
            for i in 0..<(w + h) { leftCol[offset + i] = value }
        } else {
            let leftLimit = min(maxY, y + (haveBelowLeft ? 2 * h : h) - 1)
            for i in 0..<(w + h) {
                leftCol[offset + i] = frame.sample(plane, min(leftLimit, y + i), x - 1)
            }
        }
        let corner: Int
        if haveAbove && haveLeft {
            corner = frame.sample(plane, y - 1, x - 1)
        } else if haveAbove {
            corner = frame.sample(plane, y - 1, x)
        } else if haveLeft {
            corner = frame.sample(plane, y, x - 1)
        } else {
            corner = 1 << (bitDepth - 1)
        }
        aboveRow[offset - 1] = corner
        leftCol[offset - 1] = corner

        var pred = [[Int]](repeating: [Int](repeating: 0, count: w), count: h)
        if plane == 0, useFilterIntra {
            recursiveIntraPrediction(
                pred: &pred, w: w, h: h, bitDepth: bitDepth,
                aboveRow: aboveRow, leftCol: leftCol, offset: offset
            )
        } else if mode >= 1 && mode <= 8 {
            directionalIntraPrediction(
                pred: &pred, plane: plane, x: x, y: y,
                haveLeft: haveLeft, haveAbove: haveAbove,
                mode: mode, w: w, h: h, maxX: maxX, maxY: maxY, bitDepth: bitDepth,
                aboveRow: &aboveRow, leftCol: &leftCol, offset: offset
            )
        } else if mode >= 9 && mode <= 11 {
            smoothIntraPrediction(
                pred: &pred, mode: mode, log2W: log2W, log2H: log2H, w: w, h: h,
                aboveRow: aboveRow, leftCol: leftCol, offset: offset
            )
        } else if mode == 0 {
            dcIntraPrediction(
                pred: &pred, haveLeft: haveLeft, haveAbove: haveAbove,
                log2W: log2W, log2H: log2H, w: w, h: h, bitDepth: bitDepth,
                aboveRow: aboveRow, leftCol: leftCol, offset: offset
            )
        } else {
            // PAETH_PRED
            for i in 0..<h {
                for j in 0..<w {
                    let base = aboveRow[offset + j] + leftCol[offset + i] - aboveRow[offset - 1]
                    let pLeft = abs(base - leftCol[offset + i])
                    let pTop = abs(base - aboveRow[offset + j])
                    let pTopLeft = abs(base - aboveRow[offset - 1])
                    if pLeft <= pTop && pLeft <= pTopLeft {
                        pred[i][j] = leftCol[offset + i]
                    } else if pTop <= pTopLeft {
                        pred[i][j] = aboveRow[offset + j]
                    } else {
                        pred[i][j] = aboveRow[offset - 1]
                    }
                }
            }
        }
        for i in 0..<h {
            for j in 0..<w {
                frame.setSample(plane, y + i, x + j, pred[i][j])
            }
        }
    }

    /// Recursive (filter) intra prediction (7.11.2.3).
    private func recursiveIntraPrediction(
        pred: inout [[Int]],
        w: Int,
        h: Int,
        bitDepth: Int,
        aboveRow: [Int],
        leftCol: [Int],
        offset: Int
    ) {
        let taps = AV1Tables.intraFilterTaps[filterIntraMode]
        let w4 = w >> 2
        let h2 = h >> 1
        for i2 in 0..<h2 {
            for j4 in 0..<w4 {
                var p = [Int](repeating: 0, count: 7)
                for i in 0..<7 {
                    if i < 5 {
                        if i2 == 0 {
                            p[i] = aboveRow[offset + (j4 << 2) + i - 1]
                        } else if j4 == 0 && i == 0 {
                            p[i] = leftCol[offset + (i2 << 1) - 1]
                        } else {
                            p[i] = pred[(i2 << 1) - 1][(j4 << 2) + i - 1]
                        }
                    } else {
                        if j4 == 0 {
                            p[i] = leftCol[offset + (i2 << 1) + i - 5]
                        } else {
                            p[i] = pred[(i2 << 1) + i - 5][(j4 << 2) - 1]
                        }
                    }
                }
                for i1 in 0..<2 {
                    for j1 in 0..<4 {
                        var pr = 0
                        for i in 0..<7 {
                            pr += taps[(i1 << 2) + j1][i] * p[i]
                        }
                        // Round2Signed(pr, INTRA_FILTER_SCALE_BITS = 4)
                        let rounded = pr >= 0 ? (pr + 8) >> 4 : -((-pr + 8) >> 4)
                        pred[(i2 << 1) + i1][(j4 << 2) + j1] = Self.clip1(rounded, bitDepth)
                    }
                }
            }
        }
    }

    /// Directional intra prediction with edge filtering and upsampling
    /// (7.11.2.4, 7.11.2.7–12).
    private func directionalIntraPrediction(
        pred: inout [[Int]],
        plane: Int,
        x: Int,
        y: Int,
        haveLeft: Bool,
        haveAbove: Bool,
        mode: Int,
        w: Int,
        h: Int,
        maxX: Int,
        maxY: Int,
        bitDepth: Int,
        aboveRow: inout [Int],
        leftCol: inout [Int],
        offset: Int
    ) {
        let angleDelta = plane == 0 ? angleDeltaY : angleDeltaUV
        let pAngle = AV1Tables.modeToAngle[mode] + angleDelta * 3  // ANGLE_STEP
        var upsampleAbove = false
        var upsampleLeft = false

        if sequence.enableIntraEdgeFilter, pAngle != 90, pAngle != 180 {
            if pAngle > 90, pAngle < 180, w + h >= 24 {
                // Filter corner.
                let s = leftCol[offset] * 5 + aboveRow[offset - 1] * 6 + aboveRow[offset] * 5
                let filtered = (s + 8) >> 4
                leftCol[offset - 1] = filtered
                aboveRow[offset - 1] = filtered
            }
            let filterType = intraFilterType(plane: plane)
            if haveAbove {
                let strength = Self.edgeFilterStrength(w: w, h: h, filterType: filterType, delta: pAngle - 90)
                let numPx = min(w, maxX - x + 1) + (pAngle < 90 ? h : 0) + 1
                Self.intraEdgeFilter(buffer: &aboveRow, offset: offset, size: numPx, strength: strength)
            }
            if haveLeft {
                let strength = Self.edgeFilterStrength(w: w, h: h, filterType: filterType, delta: pAngle - 180)
                let numPx = min(h, maxY - y + 1) + (pAngle > 180 ? w : 0) + 1
                Self.intraEdgeFilter(buffer: &leftCol, offset: offset, size: numPx, strength: strength)
            }
            upsampleAbove = Self.useUpsample(w: w, h: h, filterType: filterType, delta: pAngle - 90)
            if upsampleAbove {
                let numPx = w + (pAngle < 90 ? h : 0)
                Self.intraEdgeUpsample(buffer: &aboveRow, offset: offset, count: numPx, bitDepth: bitDepth)
            }
            upsampleLeft = Self.useUpsample(w: w, h: h, filterType: filterType, delta: pAngle - 180)
            if upsampleLeft {
                let numPx = h + (pAngle > 180 ? w : 0)
                Self.intraEdgeUpsample(buffer: &leftCol, offset: offset, count: numPx, bitDepth: bitDepth)
            }
        }

        if pAngle < 90 {
            let dx = AV1Tables.drIntraDerivative[pAngle]
            let upA = upsampleAbove ? 1 : 0
            let maxBaseX = (w + h - 1) << upA
            for i in 0..<h {
                let idx = (i + 1) * dx
                for j in 0..<w {
                    let base = (idx >> (6 - upA)) + (j << upA)
                    if base < maxBaseX {
                        let shift = ((idx << upA) >> 1) & 0x1F
                        let value = aboveRow[offset + base] * (32 - shift) + aboveRow[offset + base + 1] * shift
                        pred[i][j] = (value + 16) >> 5
                    } else {
                        pred[i][j] = aboveRow[offset + maxBaseX]
                    }
                }
            }
        } else if pAngle > 90, pAngle < 180 {
            let dx = AV1Tables.drIntraDerivative[180 - pAngle]
            let dy = AV1Tables.drIntraDerivative[pAngle - 90]
            let upA = upsampleAbove ? 1 : 0
            let upL = upsampleLeft ? 1 : 0
            for i in 0..<h {
                for j in 0..<w {
                    let idxA = (j << 6) - (i + 1) * dx
                    let baseA = idxA >> (6 - upA)
                    if baseA >= -(1 << upA) {
                        let shift = ((idxA << upA) >> 1) & 0x1F
                        let value = aboveRow[offset + baseA] * (32 - shift) + aboveRow[offset + baseA + 1] * shift
                        pred[i][j] = (value + 16) >> 5
                    } else {
                        let idxL = (i << 6) - (j + 1) * dy
                        let baseL = idxL >> (6 - upL)
                        let shift = ((idxL << upL) >> 1) & 0x1F
                        let value = leftCol[offset + baseL] * (32 - shift) + leftCol[offset + baseL + 1] * shift
                        pred[i][j] = (value + 16) >> 5
                    }
                }
            }
        } else if pAngle > 180 {
            let dy = AV1Tables.drIntraDerivative[270 - pAngle]
            let upL = upsampleLeft ? 1 : 0
            for i in 0..<h {
                for j in 0..<w {
                    let idx = (j + 1) * dy
                    let base = (idx >> (6 - upL)) + (i << upL)
                    let shift = ((idx << upL) >> 1) & 0x1F
                    let value = leftCol[offset + base] * (32 - shift) + leftCol[offset + base + 1] * shift
                    pred[i][j] = (value + 16) >> 5
                }
            }
        } else if pAngle == 90 {
            for i in 0..<h {
                for j in 0..<w {
                    pred[i][j] = aboveRow[offset + j]
                }
            }
        } else {  // pAngle == 180
            for i in 0..<h {
                for j in 0..<w {
                    pred[i][j] = leftCol[offset + i]
                }
            }
        }
    }

    /// get_filter_type (7.11.2.8).
    private func intraFilterType(plane: Int) -> Int {
        var aboveSmooth = false
        var leftSmooth = false
        if plane == 0 ? availU : availUChroma {
            var r = miRow - 1
            var c = miCol
            if plane > 0 {
                if chromaSubX == 1, miCol & 1 == 0 {
                    c += 1
                }
                if chromaSubY == 1, miRow & 1 == 1 {
                    r -= 1
                }
            }
            aboveSmooth = isSmoothMode(row: r, column: c, plane: plane)
        }
        if plane == 0 ? availL : availLChroma {
            var r = miRow
            var c = miCol - 1
            if plane > 0 {
                if chromaSubX == 1, miCol & 1 == 1 {
                    c -= 1
                }
                if chromaSubY == 1, miRow & 1 == 0 {
                    r += 1
                }
            }
            leftSmooth = isSmoothMode(row: r, column: c, plane: plane)
        }
        return (aboveSmooth || leftSmooth) ? 1 : 0
    }

    private static func edgeFilterStrength(w: Int, h: Int, filterType: Int, delta: Int) -> Int {
        let d = abs(delta)
        let blkWh = w + h
        var strength = 0
        if filterType == 0 {
            if blkWh <= 8 {
                if d >= 56 { strength = 1 }
            } else if blkWh <= 12 {
                if d >= 40 { strength = 1 }
            } else if blkWh <= 16 {
                if d >= 40 { strength = 1 }
            } else if blkWh <= 24 {
                if d >= 8 { strength = 1 }
                if d >= 16 { strength = 2 }
                if d >= 32 { strength = 3 }
            } else if blkWh <= 32 {
                strength = 1
                if d >= 4 { strength = 2 }
                if d >= 32 { strength = 3 }
            } else {
                strength = 3
            }
        } else {
            if blkWh <= 8 {
                if d >= 40 { strength = 1 }
                if d >= 64 { strength = 2 }
            } else if blkWh <= 16 {
                if d >= 20 { strength = 1 }
                if d >= 48 { strength = 2 }
            } else if blkWh <= 24 {
                if d >= 4 { strength = 3 }
            } else {
                strength = 3
            }
        }
        return strength
    }

    private static func useUpsample(w: Int, h: Int, filterType: Int, delta: Int) -> Bool {
        let d = abs(delta)
        let blkWh = w + h
        if d <= 0 || d >= 40 {
            return false
        }
        return filterType == 0 ? blkWh <= 16 : blkWh <= 8
    }

    /// Intra edge filter (7.11.2.12): smooths entries -1…size-2 in place.
    private static func intraEdgeFilter(buffer: inout [Int], offset: Int, size: Int, strength: Int) {
        guard strength > 0 else { return }
        let kernel: [[Int]] = [
            [0, 4, 8, 4, 0],
            [0, 5, 6, 5, 0],
            [2, 4, 4, 4, 2],
        ]
        var edge = [Int](repeating: 0, count: size)
        for i in 0..<size {
            edge[i] = buffer[offset + i - 1]
        }
        for i in 1..<size {
            var s = 0
            for j in 0..<5 {
                let k = min(max(i - 2 + j, 0), size - 1)
                s += kernel[strength - 1][j] * edge[k]
            }
            buffer[offset + i - 1] = (s + 8) >> 4
        }
    }

    /// Intra edge upsample (7.11.2.11): doubles the first `count` entries.
    private static func intraEdgeUpsample(buffer: inout [Int], offset: Int, count: Int, bitDepth: Int) {
        var dup = [Int](repeating: 0, count: count + 3)
        dup[0] = buffer[offset - 1]
        for i in -1..<count {
            dup[i + 2] = buffer[offset + i]
        }
        dup[count + 2] = buffer[offset + count - 1]
        buffer[offset - 2] = dup[0]
        for i in 0..<count {
            let s = -dup[i] + 9 * dup[i + 1] + 9 * dup[i + 2] - dup[i + 3]
            buffer[offset + 2 * i - 1] = clip1((s + 8) >> 4, bitDepth)
            buffer[offset + 2 * i] = dup[i + 2]
        }
    }

    private func dcIntraPrediction(
        pred: inout [[Int]],
        haveLeft: Bool,
        haveAbove: Bool,
        log2W: Int,
        log2H: Int,
        w: Int,
        h: Int,
        bitDepth: Int,
        aboveRow: [Int],
        leftCol: [Int],
        offset: Int
    ) {
        let value: Int
        if haveLeft && haveAbove {
            var sum = 0
            for k in 0..<h { sum += leftCol[offset + k] }
            for k in 0..<w { sum += aboveRow[offset + k] }
            sum += (w + h) >> 1
            value = sum / (w + h)
        } else if haveLeft {
            var sum = 0
            for k in 0..<h { sum += leftCol[offset + k] }
            value = Self.clip1((sum + (h >> 1)) >> log2H, bitDepth)
        } else if haveAbove {
            var sum = 0
            for k in 0..<w { sum += aboveRow[offset + k] }
            value = Self.clip1((sum + (w >> 1)) >> log2W, bitDepth)
        } else {
            value = 1 << (bitDepth - 1)
        }
        for i in 0..<h {
            for j in 0..<w {
                pred[i][j] = value
            }
        }
    }

    private func smoothIntraPrediction(
        pred: inout [[Int]],
        mode: Int,
        log2W: Int,
        log2H: Int,
        w: Int,
        h: Int,
        aboveRow: [Int],
        leftCol: [Int],
        offset: Int
    ) {
        func weights(_ log2Size: Int) -> [Int] {
            AV1Tables.smoothWeights[log2Size - 2]
        }
        if mode == 9 {  // SMOOTH_PRED
            let wx = weights(log2W)
            let wy = weights(log2H)
            for i in 0..<h {
                for j in 0..<w {
                    let value = wy[i] * aboveRow[offset + j]
                        + (256 - wy[i]) * leftCol[offset + h - 1]
                        + wx[j] * leftCol[offset + i]
                        + (256 - wx[j]) * aboveRow[offset + w - 1]
                    pred[i][j] = (value + 256) >> 9
                }
            }
        } else if mode == 10 {  // SMOOTH_V_PRED
            let wy = weights(log2H)
            for i in 0..<h {
                for j in 0..<w {
                    let value = wy[i] * aboveRow[offset + j] + (256 - wy[i]) * leftCol[offset + h - 1]
                    pred[i][j] = (value + 128) >> 8
                }
            }
        } else {  // SMOOTH_H_PRED
            let wx = weights(log2W)
            for i in 0..<h {
                for j in 0..<w {
                    let value = wx[j] * leftCol[offset + i] + (256 - wx[j]) * aboveRow[offset + w - 1]
                    pred[i][j] = (value + 128) >> 8
                }
            }
        }
    }

    // MARK: Chroma from luma (7.11.5)

    func predictChromaFromLuma(frame: AV1FrameBuffer, plane: Int, startX: Int, startY: Int, txSz: Int) {
        let w = AV1Tables.txWidth[txSz]
        let h = AV1Tables.txHeight[txSz]
        let subX = chromaSubX
        let subY = chromaSubY
        let alpha = plane == 1 ? cflAlphaU : cflAlphaV
        var luma = [[Int]](repeating: [Int](repeating: 0, count: w), count: h)
        var lumaAverage = 0
        for i in 0..<h {
            var lumaY = (startY + i) << subY
            lumaY = min(lumaY, maxLumaH - (1 << subY))
            for j in 0..<w {
                var lumaX = (startX + j) << subX
                lumaX = min(lumaX, maxLumaW - (1 << subX))
                var t = 0
                for dy in 0...subY {
                    for dx in 0...subX {
                        t += frame.sample(0, lumaY + dy, lumaX + dx)
                    }
                }
                let v = t << (3 - subX - subY)
                luma[i][j] = v
                lumaAverage += v
            }
        }
        let shift = AV1Tables.txWidthLog2[txSz] + AV1Tables.txHeightLog2[txSz]
        lumaAverage = (lumaAverage + (1 << (shift - 1))) >> shift
        for i in 0..<h {
            for j in 0..<w {
                let dc = frame.sample(plane, startY + i, startX + j)
                let diff = alpha * (luma[i][j] - lumaAverage)
                let scaled = diff >= 0 ? (diff + 32) >> 6 : -((-diff + 32) >> 6)
                frame.setSample(plane, startY + i, startX + j, Self.clip1(dc + scaled, frame.bitDepth))
            }
        }
    }

    // MARK: Reconstruction (7.12)

    /// reconstruct: dequantizes the coefficient levels, inverse transforms
    /// them and adds the residual into the frame.
    func reconstruct(
        frame: AV1FrameBuffer,
        plane: Int,
        x: Int,
        y: Int,
        txSz: Int,
        txType: Int,
        quant: [Int],
        lossless: Bool,
        qIndexBase: Int,
        qmLevel: Int
    ) {
        let bitDepth = frame.bitDepth
        let dqDenom: Int
        switch txSz {
        case 3, 9, 10, 17, 18:  // 32X32, 16X32, 32X16, 16X64, 64X16
            dqDenom = 2
        case 4, 11, 12:  // 64X64, 32X64, 64X32
            dqDenom = 4
        default:
            dqDenom = 1
        }
        let log2W = AV1Tables.txWidthLog2[txSz]
        let log2H = AV1Tables.txHeightLog2[txSz]
        let w = 1 << log2W
        let h = 1 << log2H
        let tw = min(32, w)
        let th = min(32, h)
        let flipUD = txType == 4 || txType == 8 || txType == 14 || txType == 6
        let flipLR = txType == 5 || txType == 7 || txType == 15 || txType == 6

        let depthIndex = (bitDepth - 8) >> 1
        func quantValue(dc: Bool, delta: Int) -> Int {
            let table = dc ? AV1QuantTables.dcQLookup : AV1QuantTables.acQLookup
            return table[depthIndex][min(max(qIndexBase + delta, 0), 255)]
        }
        let dcDelta: Int
        let acDelta: Int
        switch plane {
        case 0:
            dcDelta = header.deltaQYDc
            acDelta = 0
        case 1:
            dcDelta = header.deltaQUDc
            acDelta = header.deltaQUAc
        default:
            dcDelta = header.deltaQVDc
            acDelta = header.deltaQVAc
        }
        let dcQuant = quantValue(dc: true, delta: dcDelta)
        let acQuant = quantValue(dc: false, delta: acDelta)

        // Quantizer matrices apply to non-identity transforms only.
        let applyMatrix = header.usingQMatrix && txType < 9 && qmLevel < 15
        let matrix = applyMatrix
            ? AV1QuantizerMatrices.matrices[qmLevel * 2 + (plane > 0 ? 1 : 0)] : []
        let matrixBase = AV1QuantizerMatrices.offset[txSz]

        var dequant = [Int](repeating: 0, count: tw * th)
        let clampLimit = 1 << (7 + bitDepth)
        for i in 0..<th {
            for j in 0..<tw {
                var q = (i == 0 && j == 0) ? dcQuant : acQuant
                if applyMatrix {
                    q = (q * Int(matrix[matrixBase + i * tw + j]) + 16) >> 5
                }
                let dq = quant[i * tw + j] * q
                let sign = dq < 0 ? -1 : 1
                let dq2 = sign * ((abs(dq) & 0xFFFFFF) / dqDenom)
                dequant[i * tw + j] = min(max(dq2, -clampLimit), clampLimit - 1)
            }
        }

        let residual = AV1Transforms.inverse2D(
            dequant: dequant, txSz: txSz, txType: txType,
            lossless: lossless, bitDepth: bitDepth
        )
        for i in 0..<h {
            let yy = flipUD ? (h - i - 1) : i
            for j in 0..<w {
                let xx = flipLR ? (w - j - 1) : j
                let value = frame.sample(plane, y + yy, x + xx) + residual[i][j]
                frame.setSample(plane, y + yy, x + xx, Self.clip1(value, bitDepth))
            }
        }
    }

    static func clip1(_ value: Int, _ bitDepth: Int) -> Int {
        min(max(value, 0), (1 << bitDepth) - 1)
    }
}
