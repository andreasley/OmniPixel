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

    static func deblock(frame: AV1FrameBuffer, sequence: AV1SequenceHeader, header: AV1FrameHeader) {
        for plane in 0..<frame.planeCount {
            if plane > 0 && header.loopFilterLevel[1 + plane] == 0 {
                continue
            }
            let subX = plane > 0 ? frame.subX : 0
            let subY = plane > 0 ? frame.subY : 0
            frame.planes[plane].withUnsafeMutableBufferPointer { buffer in
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
                                subX: subX, subY: subY, buffer: buffer
                            )
                            col += colStep
                        }
                        row += rowStep
                    }
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
        subY: Int,
        buffer: UnsafeMutableBufferPointer<Int>
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
        // Unreachable for data that decoded: `decodeBlock` rejects the 4:2:2
        // block sizes whose subsampled size is undefined. Guarded anyway
        // because this runs over the whole frame buffer, one step removed
        // from that check.
        guard planeSize >= 0 else { return }
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
        let stride = frame.allocatedWidth[plane]
        let step = dy * stride + dx
        for i in 0..<4 {
            let base = (yP + dx * i) * stride + (xP + dy * i)
            filterSamples(
                buffer: buffer, base: base, step: step, plane: plane,
                bitDepth: frame.bitDepth,
                limit: limit, blimit: blimit, thresh: thresh,
                filterSize: filterSize
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
            deltaLF = Int(frame.deltaLFs[(row * frame.miCols + col) * 4 + index])
        } else {
            deltaLF = Int(frame.deltaLFs[(row * frame.miCols + col) * 4])
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
    /// Operates on the plane buffer at `base` with `step` between samples
    /// perpendicular to the edge.
    private static func filterSamples(
        buffer: UnsafeMutableBufferPointer<Int>,
        base: Int,
        step: Int,
        plane: Int,
        bitDepth: Int,
        limit: Int,
        blimit: Int,
        thresh: Int,
        filterSize: Int
    ) {
        @inline(__always) func sample(_ offset: Int) -> Int {
            buffer[base + offset * step]
        }
        @inline(__always) func setSample(_ offset: Int, _ value: Int) {
            buffer[base + offset * step] = value
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
            // At most 12 outputs (n = 6); a fixed tuple-backed array avoids
            // a heap allocation per filtered segment.
            var filtered = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            withUnsafeMutableBytes(of: &filtered) { raw in
                let scratch = raw.bindMemory(to: Int.self)
                for i in -n..<n {
                    var t = 0
                    for j in -n...n {
                        let p = min(max(i + j, -(n + 1)), n)
                        let tap = abs(j) <= n2 ? 2 : 1
                        t += sample(p) * tap
                    }
                    scratch[i + n] = (t + (1 << (log2Size - 1))) >> log2Size
                }
                for i in -n..<n {
                    setSample(i, scratch[i + n])
                }
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

    /// One filtered 8×8 block's per-plane parameters.
    private struct CDEFBlock {
        var r: Int
        var c: Int
        var lumaPri: Int
        var lumaSec: Int
        var lumaDir: Int
        var chromaPri: Int
        var chromaSec: Int
        var chromaDir: Int
    }

    static func applyCDEF(
        frame: AV1FrameBuffer,
        sequence: AV1SequenceHeader,
        header: AV1FrameHeader
    ) -> [[Int]] {
        var output = frame.planes
        guard sequence.enableCDEF, !header.codedLossless, !header.allowIntrabc else {
            return output
        }
        let coeffShift = frame.bitDepth - 8

        // Pass 1: per-block filter decisions (direction from luma).
        var blocks: [CDEFBlock] = []
        var partialScratch = [Int](repeating: 0, count: 8 * 15)
        var r = 0
        while r < frame.miRows {
            var c = 0
            while c < frame.miCols {
                defer { c += 2 }
                let index = Int(frame.cdefIndex[(r & ~15) >> 4][(c & ~15) >> 4])
                if index == -1 {
                    continue
                }
                let r1 = min(r + 1, frame.miRows - 1)
                let c1 = min(c + 1, frame.miCols - 1)
                if frame.skips[r][c], frame.skips[r1][c], frame.skips[r][c1], frame.skips[r1][c1] {
                    continue
                }
                let (yDir, variance) = cdefDirection(frame: frame, r: r, c: c, partial: &partialScratch)
                var lumaPri = header.cdefYPrimary[index] << coeffShift
                let lumaSec = header.cdefYSecondary[index] << coeffShift
                let lumaDir = lumaPri == 0 ? 0 : yDir
                let varStr = (variance >> 6) != 0 ? min(floorLog2(variance >> 6), 12) : 0
                lumaPri = variance != 0 ? (lumaPri * (4 + varStr) + 8) >> 4 : 0
                let chromaPri = header.cdefUVPrimary[index] << coeffShift
                let chromaSec = header.cdefUVSecondary[index] << coeffShift
                let chromaDir = chromaPri == 0 ? 0 : cdefUvDir[frame.subX][frame.subY][yDir]
                blocks.append(CDEFBlock(
                    r: r, c: c,
                    lumaPri: lumaPri, lumaSec: lumaSec, lumaDir: lumaDir,
                    chromaPri: chromaPri, chromaSec: chromaSec, chromaDir: chromaDir
                ))
            }
            r += 2
        }
        guard !blocks.isEmpty else { return output }

        // Pass 2: filter each plane across all blocks with one buffer scope.
        for plane in 0..<frame.planeCount {
            let subX = plane > 0 ? frame.subX : 0
            let subY = plane > 0 ? frame.subY : 0
            let stride = frame.allocatedWidth[plane]
            let damping = header.cdefDamping + coeffShift - (plane > 0 ? 1 : 0)
            let miRows = frame.miRows
            let miCols = frame.miCols
            // Sample-level bounds equivalent to the mi-position check.
            let extentX = (miCols * 4) >> subX
            let extentY = (miRows * 4) >> subY
            // Per tap: signed offset in samples, weight, strength, shift.
            var tapData = [Int](repeating: 0, count: 6 * 5)
            frame.planes[plane].withUnsafeBufferPointer { source in
                output[plane].withUnsafeMutableBufferPointer { dest in
                    for block in blocks {
                        let priStr = plane == 0 ? block.lumaPri : block.chromaPri
                        let secStr = plane == 0 ? block.lumaSec : block.chromaSec
                        // Zero strengths leave every sample clamped to
                        // itself; the output copy is already in place.
                        if priStr == 0, secStr == 0 {
                            continue
                        }
                        let dir = plane == 0 ? block.lumaDir : block.chromaDir
                        let x0 = (block.c * 4) >> subX
                        let y0 = (block.r * 4) >> subY
                        let w = 8 >> subX
                        let h = 8 >> subY
                        let tapSelector = (priStr >> coeffShift) & 1
                        // Damping adjustments are constant per strength.
                        let priShift = priStr != 0 ? max(0, damping - floorLog2(priStr)) : 0
                        let secShift = secStr != 0 ? max(0, damping - floorLog2(secStr)) : 0
                        // Six taps: primary k0/k1, secondary (dir±2) k0/k1.
                        let d1 = (dir + 2) & 7
                        let d2 = (dir - 2) & 7
                        for k in 0..<2 {
                            tapData[k * 5] = cdefDirections[dir][k][0]
                            tapData[k * 5 + 1] = cdefDirections[dir][k][1]
                            tapData[k * 5 + 2] = cdefPriTaps[tapSelector][k]
                            tapData[k * 5 + 3] = priStr
                            tapData[k * 5 + 4] = priShift
                            tapData[(2 + k) * 5] = cdefDirections[d1][k][0]
                            tapData[(2 + k) * 5 + 1] = cdefDirections[d1][k][1]
                            tapData[(2 + k) * 5 + 2] = cdefSecTaps[tapSelector][k]
                            tapData[(2 + k) * 5 + 3] = secStr
                            tapData[(2 + k) * 5 + 4] = secShift
                            tapData[(4 + k) * 5] = cdefDirections[d2][k][0]
                            tapData[(4 + k) * 5 + 1] = cdefDirections[d2][k][1]
                            tapData[(4 + k) * 5 + 2] = cdefSecTaps[tapSelector][k]
                            tapData[(4 + k) * 5 + 3] = secStr
                            tapData[(4 + k) * 5 + 4] = secShift
                        }
                        // Taps reach ±2 samples in each direction.
                        let interior = y0 >= 2 && x0 >= 2
                            && y0 + h + 2 <= extentY && x0 + w + 2 <= extentX
                        tapData.withUnsafeBufferPointer { taps in
                            if interior {
                                // All taps in bounds: address by pure
                                // sample offsets from the center.
                                for i in 0..<h {
                                    let rowBase = (y0 + i) * stride
                                    for j in 0..<w {
                                        let centerIndex = rowBase + (x0 + j)
                                        let center = source[centerIndex]
                                        var sum = 0
                                        var maxValue = center
                                        var minValue = center
                                        for t in 0..<6 {
                                            let offset = taps[t * 5] * stride + taps[t * 5 + 1]
                                            let tap = taps[t * 5 + 2]
                                            let strength = taps[t * 5 + 3]
                                            let shift = taps[t * 5 + 4]
                                            let p0 = source[centerIndex - offset]
                                            let p1 = source[centerIndex + offset]
                                            if strength != 0 {
                                                let d0 = p0 - center
                                                let d1 = p1 - center
                                                let m0 = min(abs(d0), max(0, strength - (abs(d0) >> shift)))
                                                let m1 = min(abs(d1), max(0, strength - (abs(d1) >> shift)))
                                                sum += tap * ((d0 < 0 ? -m0 : m0) + (d1 < 0 ? -m1 : m1))
                                            }
                                            maxValue = max(maxValue, max(p0, p1))
                                            minValue = min(minValue, min(p0, p1))
                                        }
                                        let filtered = center + ((8 + sum - (sum < 0 ? 1 : 0)) >> 4)
                                        dest[centerIndex] = min(max(filtered, minValue), maxValue)
                                    }
                                }
                            } else {
                                for i in 0..<h {
                                    let rowBase = (y0 + i) * stride
                                    for j in 0..<w {
                                        let center = source[rowBase + (x0 + j)]
                                        var sum = 0
                                        var maxValue = center
                                        var minValue = center
                                        for t in 0..<6 {
                                            let dy = taps[t * 5]
                                            let dx = taps[t * 5 + 1]
                                            let tap = taps[t * 5 + 2]
                                            let strength = taps[t * 5 + 3]
                                            let shift = taps[t * 5 + 4]
                                            var sign = -1
                                            while sign <= 1 {
                                                let yy = y0 + i + sign * dy
                                                let xx = x0 + j + sign * dx
                                                if yy >= 0, yy < extentY, xx >= 0, xx < extentX {
                                                    let p = source[yy * stride + xx]
                                                    if strength != 0 {
                                                        let diff = p - center
                                                        let magnitude = min(abs(diff), max(0, strength - (abs(diff) >> shift)))
                                                        sum += tap * (diff < 0 ? -magnitude : magnitude)
                                                    }
                                                    maxValue = max(p, maxValue)
                                                    minValue = min(p, minValue)
                                                }
                                                sign += 2
                                            }
                                        }
                                        let filtered = center + ((8 + sum - (sum < 0 ? 1 : 0)) >> 4)
                                        dest[rowBase + (x0 + j)] =
                                            min(max(filtered, minValue), maxValue)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return output
    }

    private static func cdefDirection(
        frame: AV1FrameBuffer, r: Int, c: Int, partial: inout [Int]
    ) -> (dir: Int, variance: Int) {
        var cost = (0, 0, 0, 0, 0, 0, 0, 0)
        for i in 0..<(8 * 15) {
            partial[i] = 0
        }
        let x0 = c << 2
        let y0 = r << 2
        let shift = frame.bitDepth - 8
        let strideY = frame.allocatedWidth[0]
        frame.planes[0].withUnsafeBufferPointer { luma in
            for i in 0..<8 {
                let rowBase = (y0 + i) * strideY + x0
                for j in 0..<8 {
                    let x = (luma[rowBase + j] >> shift) - 128
                    partial[0 * 15 + i + j] += x
                    partial[1 * 15 + i + j / 2] += x
                    partial[2 * 15 + i] += x
                    partial[3 * 15 + 3 + i - j / 2] += x
                    partial[4 * 15 + 7 + i - j] += x
                    partial[5 * 15 + 3 - i / 2 + j] += x
                    partial[6 * 15 + j] += x
                    partial[7 * 15 + i / 2 + j] += x
                }
            }
        }
        return partial.withUnsafeBufferPointer { p in
            withUnsafeMutableBytes(of: &cost) { raw in
                let cost = raw.bindMemory(to: Int.self)
                for i in 0..<8 {
                    cost[2] += p[2 * 15 + i] * p[2 * 15 + i]
                    cost[6] += p[6 * 15 + i] * p[6 * 15 + i]
                }
                cost[2] *= divTable[8]
                cost[6] *= divTable[8]
                for i in 0..<7 {
                    cost[0] += (p[i] * p[i] + p[14 - i] * p[14 - i]) * divTable[i + 1]
                    cost[4] += (p[4 * 15 + i] * p[4 * 15 + i] + p[4 * 15 + 14 - i] * p[4 * 15 + 14 - i]) * divTable[i + 1]
                }
                cost[0] += p[7] * p[7] * divTable[8]
                cost[4] += p[4 * 15 + 7] * p[4 * 15 + 7] * divTable[8]
                var i = 1
                while i < 8 {
                    for j in 0..<5 {
                        cost[i] += p[i * 15 + 3 + j] * p[i * 15 + 3 + j]
                    }
                    cost[i] *= divTable[8]
                    for j in 0..<3 {
                        cost[i] += (p[i * 15 + j] * p[i * 15 + j] + p[i * 15 + 10 - j] * p[i * 15 + 10 - j]) * divTable[2 * j + 2]
                    }
                    i += 2
                }
                var bestCost = 0
                var yDir = 0
                for i in 0..<8 where cost[i] > bestCost {
                    bestCost = cost[i]
                    yDir = i
                }
                return (yDir, (bestCost - cost[(yDir + 4) & 7]) >> 10)
            }
        }
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

    static func applyLoopRestoration(
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

        // The spec's per-4x4 loop produces identical output for any block
        // decomposition whose blocks stay within one stripe and one unit,
        // so process each stripe/unit-column intersection at once.
        let deblocked = frame.planes
        for plane in 0..<frame.planeCount where header.restorationType[plane] != 0 {
            let subX = plane == 0 ? 0 : frame.subX
            let subY = plane == 0 ? 0 : frame.subY
            let planeWidth = (header.frameWidth + subX) >> subX
            let planeHeight = (header.frameHeight + subY) >> subY
            let unitSize = header.restorationSize[plane]
            let unitRows = unitRowsPerPlane[plane]
            let unitCols = unitColsPerPlane[plane]
            var stripe = 0
            while true {
                let yStart = stripe == 0 ? 0 : (stripe * 64 - 8) >> subY
                if yStart >= planeHeight {
                    break
                }
                let yEnd = min(planeHeight, (stripe * 64 + 56) >> subY)
                // The first mode-info row of this stripe determines the
                // unit row (constant across the stripe).
                let firstMiRow = max(0, 16 * stripe - 2)
                let unitRow = min(unitRows - 1, ((firstMiRow * 4 + 8) >> subY) / unitSize)
                for unitCol in 0..<unitCols {
                    let xStart = unitCol * unitSize
                    let xEnd = unitCol == unitCols - 1 ? planeWidth : (unitCol + 1) * unitSize
                    guard let unit = unitGrid[plane][unitRow][unitCol], unit.type != 0 else { continue }
                    restoreRegion(
                        frame: frame, header: header, plane: plane,
                        x: xStart, y: yStart, w: xEnd - xStart, h: yEnd - yStart,
                        stripe: stripe, subX: subX, subY: subY,
                        planeEndX: planeWidth - 1, planeEndY: planeHeight - 1,
                        unit: unit,
                        deblocked: deblocked, cdefPlanes: cdefPlanes, output: &output
                    )
                }
                stripe += 1
            }
        }
        return output
    }

    private static func restoreRegion(
        frame: AV1FrameBuffer,
        header: AV1FrameHeader,
        plane: Int,
        x: Int,
        y: Int,
        w: Int,
        h: Int,
        stripe: Int,
        subX: Int,
        subY: Int,
        planeEndX: Int,
        planeEndY: Int,
        unit: AV1TileDecoder.RestorationUnit,
        deblocked: [[Int]],
        cdefPlanes: [[Int]],
        output: inout [[Int]]
    ) {
        guard w > 0, h > 0 else { return }
        let stripeStartY = (-8 + stripe * 64) >> subY
        let stripeEndY = stripeStartY + (64 >> subY) - 1

        let stride = frame.allocatedWidth[plane]
        // Prefetch the source neighborhood once (stripe-aware): rows
        // y-3…y+h+2, columns x-3…x+w+3 cover both the Wiener taps and the
        // widest box filter.
        let patchWidth = w + 7
        let patchHeight = h + 6
        var patch = [Int](repeating: 0, count: patchWidth * patchHeight)
        deblocked[plane].withUnsafeBufferPointer { deblockedBuffer in
            cdefPlanes[plane].withUnsafeBufferPointer { cdefBuffer in
                for row in 0..<patchHeight {
                    let sy = y + row - 3
                    var py = min(max(sy, 0), planeEndY)
                    let source: UnsafeBufferPointer<Int>
                    if py < stripeStartY {
                        py = max(stripeStartY - 2, py)
                        source = deblockedBuffer
                    } else if py > stripeEndY {
                        py = min(stripeEndY + 2, py)
                        source = deblockedBuffer
                    } else {
                        source = cdefBuffer
                    }
                    let rowBase = py * stride
                    for column in 0..<patchWidth {
                        let px = min(max(x + column - 3, 0), planeEndX)
                        patch[row * patchWidth + column] = source[rowBase + px]
                    }
                }
            }
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
            var intermediate = [Int](repeating: 0, count: (h + 6) * w)
            for r in 0..<(h + 6) {
                for c in 0..<w {
                    var s = 0
                    for t in 0..<7 {
                        s += hfilter[t] * patch[r * patchWidth + c + t]
                    }
                    let v = (s + (1 << (round0 - 1))) >> round0
                    intermediate[r * w + c] = min(max(v, -offset), limit - offset)
                }
            }
            for r in 0..<h {
                for c in 0..<w {
                    var s = 0
                    for t in 0..<7 {
                        s += vfilter[t] * intermediate[(r + t) * w + c]
                    }
                    let v = (s + (1 << (round1 - 1))) >> round1
                    output[plane][(y + r) * stride + (x + c)] =
                        min(max(v, 0), (1 << bitDepth) - 1)
                }
            }
        } else {
            // Self-guided filter (7.17.2–3)
            // Per 7.17.3 the two coded coefficients are w0 and w2; w1, the
            // weight of the unfiltered sample, is what the triple must sum
            // to 1 << SGRPROJ_PRJ_BITS.
            let set = unit.parameters[0]
            let w0 = unit.parameters[1]
            let w2 = unit.parameters[2]
            let w1 = (1 << 7) - w0 - w2  // SGRPROJ_PRJ_BITS
            let r0 = Self.sgrParams[set][0]
            let r1 = Self.sgrParams[set][2]
            let flt0 = r0 != 0 ? boxFilter(
                bitDepth: frame.bitDepth, w: w, h: h, set: set, pass: 0,
                patch: patch, patchWidth: patchWidth
            ) : []
            let flt1 = r1 != 0 ? boxFilter(
                bitDepth: frame.bitDepth, w: w, h: h, set: set, pass: 1,
                patch: patch, patchWidth: patchWidth
            ) : []
            for i in 0..<h {
                for j in 0..<w {
                    let u = cdefPlanes[plane][(y + i) * stride + (x + j)] << 4  // SGRPROJ_RST_BITS
                    var v = w1 * u
                    v += r0 != 0 ? w0 * flt0[i * w + j] : w0 * u
                    v += r1 != 0 ? w2 * flt1[i * w + j] : w2 * u
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

    /// The box filter over a prefetched source patch; the patch holds the
    /// stripe-aware samples for rows -3…h+2 and columns -3…w+3 relative to
    /// the block, so sample (sy, sx) lives at patch[(sy+3) row][(sx+3) col].
    private static func boxFilter(
        bitDepth: Int,
        w: Int,
        h: Int,
        set: Int,
        pass: Int,
        patch: [Int],
        patchWidth: Int
    ) -> [Int] {
        let r = sgrParams[set][pass * 2]
        let eps = sgrParams[set][pass * 2 + 1]
        let n = (2 * r + 1) * (2 * r + 1)
        let n2e = n * n * eps
        let s = ((1 << 20) + n2e / 2) / n2e  // SGRPROJ_MTABLE_BITS
        let oneOverN = ((1 << 12) + n / 2) / n  // SGRPROJ_RECIP_BITS

        // A and B are valid for -1…h / -1…w (offset by 1). The box sums
        // are separable: vertical column sums first, then a horizontal
        // slide per grid cell.
        let gridWidth = w + 2
        var a2Array = [Int](repeating: 0, count: (h + 2) * gridWidth)
        var b2Array = [Int](repeating: 0, count: (h + 2) * gridWidth)
        var columnSquares = [Int](repeating: 0, count: patchWidth)
        var columnSums = [Int](repeating: 0, count: patchWidth)
        patch.withUnsafeBufferPointer { src in
            for i in -1...h {
                // Grid cell (i, j) covers patch columns j+3-r … j+3+r.
                let firstColumn = 2 - r
                let lastColumn = min(patchWidth - 1, w + 3 + r)
                for pcol in firstColumn...lastColumn {
                    var sumSquares = 0
                    var sum = 0
                    for dy in -r...r {
                        let c = src[(i + dy + 3) * patchWidth + pcol]
                        sumSquares += c * c
                        sum += c
                    }
                    columnSquares[pcol] = sumSquares
                    columnSums[pcol] = sum
                }
                for j in -1...w {
                    var a = 0
                    var b = 0
                    for dx in -r...r {
                        a += columnSquares[j + 3 + dx]
                        b += columnSums[j + 3 + dx]
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
                    let b2 = (256 - a2) * b * oneOverN
                    a2Array[(i + 1) * gridWidth + (j + 1)] = a2
                    b2Array[(i + 1) * gridWidth + (j + 1)] = (b2 + (1 << 11)) >> 12
                }
            }
        }

        var result = [Int](repeating: 0, count: h * w)
        for i in 0..<h {
            let shift = (pass == 0 && (i & 1) == 1) ? 4 : 5
            let totalShift = 8 + shift - 4  // SGR_BITS + shift - RST_BITS
            for j in 0..<w {
                var a = 0
                var b = 0
                for dy in -1...1 {
                    let gridBase = (i + dy + 1) * gridWidth + (j + 1)
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
                        a += weight * a2Array[gridBase + dx]
                        b += weight * b2Array[gridBase + dx]
                    }
                }
                // The center sample is the CDEF output, which the patch
                // holds for all in-block rows (blocks never straddle their
                // own stripe).
                let v = a * patch[(i + 3) * patchWidth + (j + 3)] + b
                result[i * w + j] = (v + (1 << (totalShift - 1))) >> totalShift
            }
        }
        return result
    }
}
