/// The AV1 in-loop filters (spec 7.14 deblocking, 7.15 CDEF, 7.17 loop
/// restoration), applied to the reconstructed frame in that order. The
/// final filtered samples replace the frame buffer's planes.
enum AV1LoopFilters {
    static func apply(
        frame: AV1FrameBuffer,
        sequence: AV1SequenceHeader,
        header: AV1FrameHeader,
        restorationUnits: [AV1TileDecoder.RestorationUnit]
    ) {
        // decode_frame_wrapup: deblocking runs only when a luma filter
        // level is nonzero.
        if header.loopFilterLevel[0] != 0 || header.loopFilterLevel[1] != 0 {
            deblock(frame: frame, sequence: sequence, header: header)
        }
        let cdefPlanes = applyCDEF(frame: frame, sequence: sequence, header: header)
        let restored = applyLoopRestoration(
            frame: frame, sequence: sequence, header: header,
            cdefPlanes: cdefPlanes, units: restorationUnits
        )
        frame.planes = restored
    }

    // MARK: Deblocking (7.14)

    private static func deblock(frame: AV1FrameBuffer, sequence: AV1SequenceHeader, header: AV1FrameHeader) {
        for plane in 0..<frame.planeCount {
            if plane > 0 && header.loopFilterLevel[1 + plane] == 0 {
                continue
            }
            let subX = plane > 0 ? frame.subX : 0
            let subY = plane > 0 ? frame.subY : 0
            for pass in 0..<2 {
                let rowStep = plane == 0 ? 1 : (1 << subY)
                let colStep = plane == 0 ? 1 : (1 << subX)
                var row = 0
                while row < frame.miRows {
                    var col = 0
                    while col < frame.miCols {
                        filterEdge(
                            frame: frame, sequence: sequence, header: header,
                            plane: plane, pass: pass, row: row, col: col,
                            subX: subX, subY: subY
                        )
                        col += colStep
                    }
                    row += rowStep
                }
            }
        }
    }

    private static func filterEdge(
        frame: AV1FrameBuffer,
        sequence: AV1SequenceHeader,
        header: AV1FrameHeader,
        plane: Int,
        pass: Int,
        row rowIn: Int,
        col colIn: Int,
        subX: Int,
        subY: Int
    ) {
        let dx = pass == 0 ? 1 : 0
        let dy = pass == 0 ? 0 : 1
        let x = colIn * 4
        let y = rowIn * 4
        let row = rowIn | subY
        let col = colIn | subX

        // onScreen
        if x >= header.frameWidth || y >= header.frameHeight {
            return
        }
        if pass == 0 && x == 0 {
            return
        }
        if pass == 1 && y == 0 {
            return
        }

        let xP = x >> subX
        let yP = y >> subY
        let prevRow = row - (dy << subY)
        let prevCol = col - (dx << subX)

        let miSize = Int(frame.miSizes[row][col])
        let txSz = Int(frame.loopfilterTxSizes[plane][row >> subY][col >> subX])
        let planeSize = AV1Tables.subsampledSize[miSize][subX][subY]
        let skip = frame.skips[row][col]
        let isIntra = true  // intra-only frames
        let prevTxSz = Int(frame.loopfilterTxSizes[plane][prevRow >> subY][prevCol >> subX])

        let isBlockEdge: Bool
        if pass == 0 {
            isBlockEdge = xP % (4 * AV1Tables.blockWidth4[planeSize]) == 0
        } else {
            isBlockEdge = yP % (4 * AV1Tables.blockHeight4[planeSize]) == 0
        }
        let isTxEdge: Bool
        if pass == 0 {
            isTxEdge = xP % AV1Tables.txWidth[txSz] == 0
        } else {
            isTxEdge = yP % AV1Tables.txHeight[txSz] == 0
        }
        let applyFilter = isTxEdge && (isBlockEdge || !skip || isIntra)

        // Filter size
        let baseSize: Int
        if pass == 0 {
            baseSize = min(AV1Tables.txWidth[prevTxSz], AV1Tables.txWidth[txSz])
        } else {
            baseSize = min(AV1Tables.txHeight[prevTxSz], AV1Tables.txHeight[txSz])
        }
        let filterSize = plane == 0 ? min(16, baseSize) : min(8, baseSize)

        var (lvl, limit, blimit, thresh) = adaptiveFilterStrength(
            frame: frame, header: header, row: row, col: col, plane: plane, pass: pass
        )
        if lvl == 0 {
            (lvl, limit, blimit, thresh) = adaptiveFilterStrength(
                frame: frame, header: header, row: prevRow, col: prevCol, plane: plane, pass: pass
            )
        }

        guard applyFilter, lvl > 0 else { return }
        for i in 0..<4 {
            filterSamples(
                frame: frame, plane: plane,
                x: xP + dy * i, y: yP + dx * i,
                limit: limit, blimit: blimit, thresh: thresh,
                dx: dx, dy: dy, filterSize: filterSize
            )
        }
    }

    private static func adaptiveFilterStrength(
        frame: AV1FrameBuffer,
        header: AV1FrameHeader,
        row: Int,
        col: Int,
        plane: Int,
        pass: Int
    ) -> (lvl: Int, limit: Int, blimit: Int, thresh: Int) {
        let segment = Int(frame.segmentIDs[row][col])
        let index = plane == 0 ? pass : plane + 1
        let deltaLF: Int
        if header.deltaLFMulti {
            deltaLF = Int(frame.deltaLFs[row][col][index])
        } else {
            deltaLF = Int(frame.deltaLFs[row][col][0])
        }

        // Strength selection (7.14.5); intra frames only reference
        // INTRA_FRAME and mode type 0.
        var lvlSeg = min(max(deltaLF + header.loopFilterLevel[index], 0), 63)
        let feature = 1 + index  // SEG_LVL_ALT_LF_Y_V + i
        if header.segmentationEnabled, header.featureEnabled[segment][feature] {
            lvlSeg = min(max(header.featureData[segment][feature] + lvlSeg, 0), 63)
        }
        if header.loopFilterDeltaEnabled {
            let nShift = lvlSeg >> 5
            lvlSeg += header.loopFilterRefDeltas[0] << nShift  // INTRA_FRAME
            lvlSeg = min(max(lvlSeg, 0), 63)
        }
        let lvl = lvlSeg

        let sharpness = header.loopFilterSharpness
        let shift: Int
        if sharpness > 4 {
            shift = 2
        } else if sharpness > 0 {
            shift = 1
        } else {
            shift = 0
        }
        let limit: Int
        if sharpness > 0 {
            limit = min(max(lvl >> shift, 1), 9 - sharpness)
        } else {
            limit = max(1, lvl >> shift)
        }
        return (lvl, limit, 2 * (lvl + 2) + limit, lvl >> 4)
    }

    /// Sample filtering (7.14.6): masks then the narrow or wide filter.
    private static func filterSamples(
        frame: AV1FrameBuffer,
        plane: Int,
        x: Int,
        y: Int,
        limit: Int,
        blimit: Int,
        thresh: Int,
        dx: Int,
        dy: Int,
        filterSize: Int
    ) {
        let bitDepth = frame.bitDepth
        @inline(__always) func sample(_ offset: Int) -> Int {
            frame.sample(plane, y + offset * dy, x + offset * dx)
        }
        @inline(__always) func setSample(_ offset: Int, _ value: Int) {
            frame.setSample(plane, y + offset * dy, x + offset * dx, value)
        }

        let q0 = sample(0), q1 = sample(1), q2 = sample(2), q3 = sample(3)
        let p0 = sample(-1), p1 = sample(-2), p2 = sample(-3), p3 = sample(-4)

        // hevMask
        let threshBd = thresh << (bitDepth - 8)
        let hevMask = abs(p1 - p0) > threshBd || abs(q1 - q0) > threshBd

        let filterLen: Int
        if filterSize == 4 {
            filterLen = 4
        } else if plane != 0 {
            filterLen = 6
        } else if filterSize == 8 {
            filterLen = 8
        } else {
            filterLen = 16
        }

        // filterMask
        let limitBd = limit << (bitDepth - 8)
        let blimitBd = blimit << (bitDepth - 8)
        var mask = abs(p1 - p0) > limitBd || abs(q1 - q0) > limitBd
        mask = mask || abs(p0 - q0) * 2 + abs(p1 - q1) / 2 > blimitBd
        if filterLen >= 6 {
            mask = mask || abs(p2 - p1) > limitBd || abs(q2 - q1) > limitBd
        }
        if filterLen >= 8 {
            mask = mask || abs(p3 - p2) > limitBd || abs(q3 - q2) > limitBd
        }
        guard !mask else { return }

        // flatMask / flatMask2
        let thresholdBd = 1 << (bitDepth - 8)
        var flat = true
        if filterSize >= 8 {
            var m = abs(p1 - p0) > thresholdBd || abs(q1 - q0) > thresholdBd
            m = m || abs(p2 - p0) > thresholdBd || abs(q2 - q0) > thresholdBd
            if filterLen >= 8 {
                m = m || abs(p3 - p0) > thresholdBd || abs(q3 - q0) > thresholdBd
            }
            flat = !m
        }
        var flat2 = true
        if filterSize >= 16 {
            let q4 = sample(4), q5 = sample(5), q6 = sample(6)
            let p4 = sample(-5), p5 = sample(-6), p6 = sample(-7)
            var m = abs(p6 - p0) > thresholdBd || abs(q6 - q0) > thresholdBd
            m = m || abs(p5 - p0) > thresholdBd || abs(q5 - q0) > thresholdBd
            m = m || abs(p4 - p0) > thresholdBd || abs(q4 - q0) > thresholdBd
            flat2 = !m
        }

        if filterSize == 4 || !flat {
            // Narrow filter (7.14.6.3)
            let mid = 0x80 << (bitDepth - 8)
            let low = -(1 << (bitDepth - 1))
            let high = (1 << (bitDepth - 1)) - 1
            @inline(__always) func clamp4(_ v: Int) -> Int { min(max(v, low), high) }
            let ps1 = p1 - mid, ps0 = p0 - mid, qs0 = q0 - mid, qs1 = q1 - mid
            var filter = hevMask ? clamp4(ps1 - qs1) : 0
            filter = clamp4(filter + 3 * (qs0 - ps0))
            let filter1 = clamp4(filter + 4) >> 3
            let filter2 = clamp4(filter + 3) >> 3
            setSample(0, clamp4(qs0 - filter1) + mid)
            setSample(-1, clamp4(ps0 + filter2) + mid)
            if !hevMask {
                let adjust = (filter1 + 1) >> 1
                setSample(1, clamp4(qs1 - adjust) + mid)
                setSample(-2, clamp4(ps1 + adjust) + mid)
            }
        } else {
            // Wide filter (7.14.6.4)
            let log2Size = (filterSize == 8 || !flat2) ? 3 : 4
            let n: Int
            if log2Size == 4 {
                n = 6
            } else if plane == 0 {
                n = 3
            } else {
                n = 2
            }
            let n2 = (log2Size == 3 && plane == 0) ? 0 : 1
            var filtered = [Int](repeating: 0, count: 2 * n)
            for i in -n..<n {
                var t = 0
                for j in -n...n {
                    let p = min(max(i + j, -(n + 1)), n)
                    let tap = abs(j) <= n2 ? 2 : 1
                    t += sample(p) * tap
                }
                filtered[i + n] = (t + (1 << (log2Size - 1))) >> log2Size
            }
            for i in -n..<n {
                setSample(i, filtered[i + n])
            }
        }
    }

    // MARK: CDEF (7.15)

    private static let cdefUvDir: [[[Int]]] = [
        [[0, 1, 2, 3, 4, 5, 6, 7], [1, 2, 2, 2, 3, 4, 6, 0]],
        [[7, 0, 2, 4, 5, 6, 6, 6], [0, 1, 2, 3, 4, 5, 6, 7]],
    ]
    private static let cdefDirections: [[[Int]]] = [
        [[-1, 1], [-2, 2]], [[0, 1], [-1, 2]], [[0, 1], [0, 2]], [[0, 1], [1, 2]],
        [[1, 1], [2, 2]], [[1, 0], [2, 1]], [[1, 0], [2, 0]], [[1, 0], [2, -1]],
    ]
    private static let cdefPriTaps = [[4, 2], [3, 3]]
    private static let cdefSecTaps = [[2, 1], [2, 1]]
    private static let divTable = [0, 840, 420, 280, 210, 168, 140, 120, 105]

    private static func applyCDEF(
        frame: AV1FrameBuffer,
        sequence: AV1SequenceHeader,
        header: AV1FrameHeader
    ) -> [[Int]] {
        var output = frame.planes
        guard sequence.enableCDEF, !header.codedLossless, !header.allowIntrabc else {
            return output
        }
        var r = 0
        while r < frame.miRows {
            var c = 0
            while c < frame.miCols {
                cdefBlock(frame: frame, sequence: sequence, header: header, r: r, c: c, output: &output)
                c += 2
            }
            r += 2
        }
        return output
    }

    private static func cdefBlock(
        frame: AV1FrameBuffer,
        sequence: AV1SequenceHeader,
        header: AV1FrameHeader,
        r: Int,
        c: Int,
        output: inout [[Int]]
    ) {
        let index = Int(frame.cdefIndex[(r & ~15) >> 4][(c & ~15) >> 4])
        if index == -1 {
            return
        }
        let r1 = min(r + 1, frame.miRows - 1)
        let c1 = min(c + 1, frame.miCols - 1)
        let allSkip = frame.skips[r][c] && frame.skips[r1][c] && frame.skips[r][c1] && frame.skips[r1][c1]
        if allSkip {
            return
        }

        let coeffShift = frame.bitDepth - 8
        let (yDir, variance) = cdefDirection(frame: frame, r: r, c: c)

        // is_inside_filter_region: the whole frame is available (the
        // filter region is not restricted to the tile).
        let miRowStart = 0
        let miRowEnd = frame.miRows
        let miColStart = 0
        let miColEnd = frame.miCols

        func filterPlane(_ plane: Int, priStrBase: Int, secStrBase: Int, damping: Int, dir: Int) {
            let subX = plane > 0 ? frame.subX : 0
            let subY = plane > 0 ? frame.subY : 0
            let x0 = (c * 4) >> subX
            let y0 = (r * 4) >> subY
            let w = 8 >> subX
            let h = 8 >> subY
            let priStr = priStrBase
            let secStr = secStrBase
            for i in 0..<h {
                for j in 0..<w {
                    var sum = 0
                    let center = frame.sample(plane, y0 + i, x0 + j)
                    var maxValue = center
                    var minValue = center
                    for k in 0..<2 {
                        for sign in [-1, 1] {
                            // Primary direction
                            do {
                                let yy = y0 + i + sign * cdefDirections[dir][k][0]
                                let xx = x0 + j + sign * cdefDirections[dir][k][1]
                                let candidateR = (yy << subY) >> 2
                                let candidateC = (xx << subX) >> 2
                                if candidateR >= miRowStart, candidateR < miRowEnd,
                                   candidateC >= miColStart, candidateC < miColEnd {
                                    let p = frame.sample(plane, yy, xx)
                                    sum += cdefPriTaps[(priStr >> coeffShift) & 1][k]
                                        * constrain(p - center, priStr, damping)
                                    maxValue = max(p, maxValue)
                                    minValue = min(p, minValue)
                                }
                            }
                            // Secondary directions
                            for dirOffset in [-2, 2] {
                                let d = (dir + dirOffset) & 7
                                let yy = y0 + i + sign * cdefDirections[d][k][0]
                                let xx = x0 + j + sign * cdefDirections[d][k][1]
                                let candidateR = (yy << subY) >> 2
                                let candidateC = (xx << subX) >> 2
                                if candidateR >= miRowStart, candidateR < miRowEnd,
                                   candidateC >= miColStart, candidateC < miColEnd {
                                    let s = frame.sample(plane, yy, xx)
                                    sum += cdefSecTaps[(priStr >> coeffShift) & 1][k]
                                        * constrain(s - center, secStr, damping)
                                    maxValue = max(s, maxValue)
                                    minValue = min(s, minValue)
                                }
                            }
                        }
                    }
                    let filtered = center + ((8 + sum - (sum < 0 ? 1 : 0)) >> 4)
                    output[plane][(y0 + i) * frame.allocatedWidth[plane] + (x0 + j)] =
                        min(max(filtered, minValue), maxValue)
                }
            }
        }

        // Luma
        var priStr = header.cdefYPrimary[index] << coeffShift
        var secStr = header.cdefYSecondary[index] << coeffShift
        var dir = priStr == 0 ? 0 : yDir
        let varStr = (variance >> 6) != 0 ? min(floorLog2(variance >> 6), 12) : 0
        priStr = variance != 0 ? (priStr * (4 + varStr) + 8) >> 4 : 0
        filterPlane(0, priStrBase: priStr, secStrBase: secStr, damping: header.cdefDamping + coeffShift, dir: dir)

        guard frame.planeCount > 1 else { return }
        priStr = header.cdefUVPrimary[index] << coeffShift
        secStr = header.cdefUVSecondary[index] << coeffShift
        dir = priStr == 0 ? 0 : cdefUvDir[frame.subX][frame.subY][yDir]
        let damping = header.cdefDamping + coeffShift - 1
        filterPlane(1, priStrBase: priStr, secStrBase: secStr, damping: damping, dir: dir)
        filterPlane(2, priStrBase: priStr, secStrBase: secStr, damping: damping, dir: dir)
    }

    private static func cdefDirection(frame: AV1FrameBuffer, r: Int, c: Int) -> (dir: Int, variance: Int) {
        var cost = [Int](repeating: 0, count: 8)
        var partial = [[Int]](repeating: [Int](repeating: 0, count: 15), count: 8)
        let x0 = c << 2
        let y0 = r << 2
        let shift = frame.bitDepth - 8
        for i in 0..<8 {
            for j in 0..<8 {
                let x = (frame.sample(0, y0 + i, x0 + j) >> shift) - 128
                partial[0][i + j] += x
                partial[1][i + j / 2] += x
                partial[2][i] += x
                partial[3][3 + i - j / 2] += x
                partial[4][7 + i - j] += x
                partial[5][3 - i / 2 + j] += x
                partial[6][j] += x
                partial[7][i / 2 + j] += x
            }
        }
        for i in 0..<8 {
            cost[2] += partial[2][i] * partial[2][i]
            cost[6] += partial[6][i] * partial[6][i]
        }
        cost[2] *= divTable[8]
        cost[6] *= divTable[8]
        for i in 0..<7 {
            cost[0] += (partial[0][i] * partial[0][i] + partial[0][14 - i] * partial[0][14 - i]) * divTable[i + 1]
            cost[4] += (partial[4][i] * partial[4][i] + partial[4][14 - i] * partial[4][14 - i]) * divTable[i + 1]
        }
        cost[0] += partial[0][7] * partial[0][7] * divTable[8]
        cost[4] += partial[4][7] * partial[4][7] * divTable[8]
        for i in stride(from: 1, to: 8, by: 2) {
            for j in 0..<5 {
                cost[i] += partial[i][3 + j] * partial[i][3 + j]
            }
            cost[i] *= divTable[8]
            for j in 0..<3 {
                cost[i] += (partial[i][j] * partial[i][j] + partial[i][10 - j] * partial[i][10 - j]) * divTable[2 * j + 2]
            }
        }
        var bestCost = 0
        var yDir = 0
        for i in 0..<8 {
            if cost[i] > bestCost {
                bestCost = cost[i]
                yDir = i
            }
        }
        return (yDir, (bestCost - cost[(yDir + 4) & 7]) >> 10)
    }

    private static func constrain(_ diff: Int, _ threshold: Int, _ damping: Int) -> Int {
        guard threshold != 0 else { return 0 }
        let dampingAdjusted = max(0, damping - floorLog2(threshold))
        let magnitude = min(abs(diff), max(0, threshold - (abs(diff) >> dampingAdjusted)))
        return diff < 0 ? -magnitude : magnitude
    }

    private static func floorLog2(_ value: Int) -> Int {
        Int.bitWidth - 1 - value.leadingZeroBitCount
    }

    // MARK: Loop restoration (7.17)

    private static func applyLoopRestoration(
        frame: AV1FrameBuffer,
        sequence: AV1SequenceHeader,
        header: AV1FrameHeader,
        cdefPlanes: [[Int]],
        units: [AV1TileDecoder.RestorationUnit]
    ) -> [[Int]] {
        var output = cdefPlanes
        guard header.restorationType.contains(where: { $0 != 0 }) else {
            return output
        }

        // Unit grids per plane from the recorded per-tile reads.
        var unitGrid: [[[AV1TileDecoder.RestorationUnit?]]] = []
        var unitRowsPerPlane: [Int] = []
        var unitColsPerPlane: [Int] = []
        for plane in 0..<frame.planeCount {
            let subX = plane == 0 ? 0 : frame.subX
            let subY = plane == 0 ? 0 : frame.subY
            let unitSize = header.restorationSize[plane]
            let planeHeight = (header.frameHeight + subY) >> subY
            let planeWidth = (header.frameWidth + subX) >> subX
            let rows = max((planeHeight + (unitSize >> 1)) / unitSize, 1)
            let cols = max((planeWidth + (unitSize >> 1)) / unitSize, 1)
            unitRowsPerPlane.append(rows)
            unitColsPerPlane.append(cols)
            unitGrid.append([[AV1TileDecoder.RestorationUnit?]](
                repeating: [AV1TileDecoder.RestorationUnit?](repeating: nil, count: cols),
                count: rows
            ))
        }
        for unit in units where unit.row < unitRowsPerPlane[unit.plane] && unit.column < unitColsPerPlane[unit.plane] {
            unitGrid[unit.plane][unit.row][unit.column] = unit
        }

        let deblocked = frame.planes
        var y = 0
        while y < header.frameHeight {
            var x = 0
            while x < header.frameWidth {
                for plane in 0..<frame.planeCount where header.restorationType[plane] != 0 {
                    restoreBlock(
                        frame: frame, header: header, plane: plane,
                        row: y >> 2, col: x >> 2,
                        unitRows: unitRowsPerPlane[plane], unitCols: unitColsPerPlane[plane],
                        grid: unitGrid[plane],
                        deblocked: deblocked, cdefPlanes: cdefPlanes, output: &output
                    )
                }
                x += 4
            }
            y += 4
        }
        return output
    }

    private static func restoreBlock(
        frame: AV1FrameBuffer,
        header: AV1FrameHeader,
        plane: Int,
        row: Int,
        col: Int,
        unitRows: Int,
        unitCols: Int,
        grid: [[AV1TileDecoder.RestorationUnit?]],
        deblocked: [[Int]],
        cdefPlanes: [[Int]],
        output: inout [[Int]]
    ) {
        let lumaY = row * 4
        let stripeNum = (lumaY + 8) / 64
        let subX = plane == 0 ? 0 : frame.subX
        let subY = plane == 0 ? 0 : frame.subY
        let stripeStartY = (-8 + stripeNum * 64) >> subY
        let stripeEndY = stripeStartY + (64 >> subY) - 1
        let unitSize = header.restorationSize[plane]
        let unitRow = min(unitRows - 1, ((row * 4 + 8) >> subY) / unitSize)
        let unitCol = min(unitCols - 1, ((col * 4) >> subX) / unitSize)
        let planeEndX = ((header.frameWidth + subX) >> subX) - 1
        let planeEndY = ((header.frameHeight + subY) >> subY) - 1
        let x = (col * 4) >> subX
        let y = (row * 4) >> subY
        let w = min(4 >> subX, planeEndX - x + 1)
        let h = min(4 >> subY, planeEndY - y + 1)
        guard w > 0, h > 0 else { return }
        guard let unit = grid[unitRow][unitCol], unit.type != 0 else { return }

        let stride = frame.allocatedWidth[plane]
        func sourceSample(_ sx: Int, _ sy: Int) -> Int {
            var px = min(max(sx, 0), planeEndX)
            var py = min(max(sy, 0), planeEndY)
            if py < stripeStartY {
                py = max(stripeStartY - 2, py)
                return deblocked[plane][py * stride + px]
            }
            if py > stripeEndY {
                py = min(stripeEndY + 2, py)
                return deblocked[plane][py * stride + px]
            }
            return cdefPlanes[plane][py * stride + px]
        }

        if unit.type == 1 {
            // Wiener filter (7.17.4)
            let bitDepth = frame.bitDepth
            let round0 = bitDepth == 12 ? 5 : 3
            let round1 = bitDepth == 12 ? 9 : 11
            func expand(_ coeffs: ArraySlice<Int>) -> [Int] {
                let c = Array(coeffs)
                var filter = [Int](repeating: 0, count: 7)
                filter[3] = 128
                for i in 0..<3 {
                    filter[i] = c[i]
                    filter[6 - i] = c[i]
                    filter[3] -= 2 * c[i]
                }
                return filter
            }
            let vfilter = expand(unit.parameters[0..<3])
            let hfilter = expand(unit.parameters[3..<6])
            let offset = 1 << (bitDepth + 7 - round0 - 1)  // FILTER_BITS = 7
            let limit = (1 << (bitDepth + 1 + 7 - round0)) - 1
            var intermediate = [[Int]](repeating: [Int](repeating: 0, count: w), count: h + 6)
            for r in 0..<(h + 6) {
                for c in 0..<w {
                    var s = 0
                    for t in 0..<7 {
                        s += hfilter[t] * sourceSample(x + c + t - 3, y + r - 3)
                    }
                    let v = (s + (1 << (round0 - 1))) >> round0
                    intermediate[r][c] = min(max(v, -offset), limit - offset)
                }
            }
            for r in 0..<h {
                for c in 0..<w {
                    var s = 0
                    for t in 0..<7 {
                        s += vfilter[t] * intermediate[r + t][c]
                    }
                    let v = (s + (1 << (round1 - 1))) >> round1
                    output[plane][(y + r) * stride + (x + c)] =
                        min(max(v, 0), (1 << bitDepth) - 1)
                }
            }
        } else {
            // Self-guided filter (7.17.2–3)
            let set = unit.parameters[0]
            let w0 = unit.parameters[1]
            let w1Coefficient = unit.parameters[2]
            let w2 = (1 << 7) - w0 - w1Coefficient  // SGRPROJ_PRJ_BITS
            let r0 = Self.sgrParams[set][0]
            let r1 = Self.sgrParams[set][2]
            let flt0 = r0 != 0 ? boxFilter(
                frame: frame, plane: plane, x: x, y: y, w: w, h: h,
                set: set, pass: 0, stride: stride, cdefPlanes: cdefPlanes, source: sourceSample
            ) : []
            let flt1 = r1 != 0 ? boxFilter(
                frame: frame, plane: plane, x: x, y: y, w: w, h: h,
                set: set, pass: 1, stride: stride, cdefPlanes: cdefPlanes, source: sourceSample
            ) : []
            for i in 0..<h {
                for j in 0..<w {
                    let u = cdefPlanes[plane][(y + i) * stride + (x + j)] << 4  // SGRPROJ_RST_BITS
                    var v = w1Coefficient * u
                    v += r0 != 0 ? w0 * flt0[i][j] : w0 * u
                    v += r1 != 0 ? w2 * flt1[i][j] : w2 * u
                    let s = (v + (1 << 10)) >> 11  // RST_BITS + PRJ_BITS
                    output[plane][(y + i) * stride + (x + j)] =
                        min(max(s, 0), (1 << frame.bitDepth) - 1)
                }
            }
        }
    }

    static let sgrParams: [[Int]] = [
        [2, 12, 1, 4], [2, 15, 1, 6], [2, 18, 1, 8], [2, 21, 1, 9],
        [2, 24, 1, 10], [2, 29, 1, 11], [2, 36, 1, 12], [2, 45, 1, 13],
        [2, 56, 1, 14], [2, 68, 1, 15], [0, 0, 1, 5], [0, 0, 1, 8],
        [0, 0, 1, 11], [0, 0, 1, 14], [2, 30, 0, 0], [2, 75, 0, 0],
    ]

    private static func boxFilter(
        frame: AV1FrameBuffer,
        plane: Int,
        x: Int,
        y: Int,
        w: Int,
        h: Int,
        set: Int,
        pass: Int,
        stride: Int,
        cdefPlanes: [[Int]],
        source: (Int, Int) -> Int
    ) -> [[Int]] {
        let bitDepth = frame.bitDepth
        let r = sgrParams[set][pass * 2]
        let eps = sgrParams[set][pass * 2 + 1]
        let n = (2 * r + 1) * (2 * r + 1)
        let n2e = n * n * eps
        let s = ((1 << 20) + n2e / 2) / n2e  // SGRPROJ_MTABLE_BITS

        // A and B are valid for -1…h / -1…w (offset by 1).
        var a2Array = [[Int]](repeating: [Int](repeating: 0, count: w + 2), count: h + 2)
        var b2Array = [[Int]](repeating: [Int](repeating: 0, count: w + 2), count: h + 2)
        for i in -1...h {
            for j in -1...w {
                var a = 0
                var b = 0
                for dy in -r...r {
                    for dx in -r...r {
                        let c = source(x + j + dx, y + i + dy)
                        a += c * c
                        b += c
                    }
                }
                var d = b
                if bitDepth > 8 {
                    a = (a + (1 << (2 * (bitDepth - 8) - 1))) >> (2 * (bitDepth - 8))
                    d = (b + (1 << (bitDepth - 8 - 1))) >> (bitDepth - 8)
                }
                let p = max(0, a * n - d * d)
                let z = (p * s + (1 << 19)) >> 20
                let a2: Int
                if z >= 255 {
                    a2 = 256
                } else if z == 0 {
                    a2 = 1
                } else {
                    a2 = ((z << 8) + z / 2) / (z + 1)  // SGRPROJ_SGR_BITS
                }
                let oneOverN = ((1 << 12) + n / 2) / n  // SGRPROJ_RECIP_BITS
                let b2 = (256 - a2) * b * oneOverN
                a2Array[i + 1][j + 1] = a2
                b2Array[i + 1][j + 1] = (b2 + (1 << 11)) >> 12
            }
        }

        var result = [[Int]](repeating: [Int](repeating: 0, count: w), count: h)
        for i in 0..<h {
            let shift = (pass == 0 && (i & 1) == 1) ? 4 : 5
            for j in 0..<w {
                var a = 0
                var b = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let weight: Int
                        if pass == 0 {
                            if (i + dy) & 1 == 1 {
                                weight = dx == 0 ? 6 : 5
                            } else {
                                weight = 0
                            }
                        } else {
                            weight = (dx == 0 || dy == 0) ? 4 : 3
                        }
                        a += weight * a2Array[i + dy + 1][j + dx + 1]
                        b += weight * b2Array[i + dy + 1][j + dx + 1]
                    }
                }
                let v = a * cdefPlanes[plane][(y + i) * stride + (x + j)] + b
                // Round2(v, SGRPROJ_SGR_BITS + shift - SGRPROJ_RST_BITS)
                let totalShift = 8 + shift - 4
                result[i][j] = (v + (1 << (totalShift - 1))) >> totalShift
            }
        }
        return result
    }
}
