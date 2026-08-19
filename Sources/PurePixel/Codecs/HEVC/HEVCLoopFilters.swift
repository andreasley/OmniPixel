/// In-loop filters for reconstructed HEVC intra pictures: the deblocking
/// filter (ITU-T H.265 section 8.7.2) followed by the sample-adaptive
/// offset (8.7.3). In intra pictures every block edge has boundary
/// strength 2, which removes the inter-prediction cases entirely.
enum HEVCLoopFilters {
    static func apply(
        to planes: inout HEVCReconstructedPlanes,
        picture: HEVCPictureData,
        sps: HEVCSequenceParameterSet
    ) {
        if !picture.deblockingDisabled {
            deblock(&planes, picture: picture, sps: sps)
        }
        if sps.saoEnabled {
            applySAO(&planes, picture: picture, sps: sps)
        }
    }

    // MARK: Deblocking (8.7.2)

    /// β thresholds by Q (Table 8-12).
    private static let betaTable = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44,
        46, 48, 50, 52, 54, 56, 58, 60, 62, 64,
    ]
    /// tC thresholds by Q (Table 8-12).
    private static let tcTable = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
        4, 4, 4, 5, 5, 6, 6, 7, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 24,
    ]

    private static func deblock(
        _ planes: inout HEVCReconstructedPlanes,
        picture: HEVCPictureData,
        sps: HEVCSequenceParameterSet
    ) {
        let gridWidth = (sps.width + 3) >> 2

        func lumaQP(_ x: Int, _ y: Int) -> Int {
            picture.qpGrid[(y >> 2) * gridWidth + (x >> 2)]
        }

        // Transform-block edges on the 8×8 (luma) / chroma 8×8 grid; the
        // coding and prediction edges always coincide with transform edges
        // in intra pictures.
        var lumaVertical = Set<Int>()
        var lumaHorizontal = Set<Int>()
        var chromaVertical = Set<Int>()
        var chromaHorizontal = Set<Int>()
        for block in picture.transformBlocks {
            let size = 1 << block.log2Size
            if block.componentIndex == 0 {
                if block.x > 0, block.x & 7 == 0 {
                    for y in stride(from: block.y, to: block.y + size, by: 4) {
                        lumaVertical.insert((block.x << 16) | y)
                    }
                }
                if block.y > 0, block.y & 7 == 0 {
                    for x in stride(from: block.x, to: block.x + size, by: 4) {
                        lumaHorizontal.insert((x << 16) | block.y)
                    }
                }
            } else if block.componentIndex == 1 {
                if block.x > 0, block.x & 7 == 0 {
                    for y in stride(from: block.y, to: block.y + size, by: 4) {
                        chromaVertical.insert((block.x << 16) | y)
                    }
                }
                if block.y > 0, block.y & 7 == 0 {
                    for x in stride(from: block.x, to: block.x + size, by: 4) {
                        chromaHorizontal.insert((x << 16) | block.y)
                    }
                }
            }
        }

        // Luma: all vertical edges across the picture first, then all
        // horizontal edges, in 4-line segments.
        for key in lumaVertical.sorted() {
            let x = key >> 16, y = key & 0xFFFF
            filterLumaSegment(
                &planes.luma, width: planes.lumaWidth,
                x: x, y: y, vertical: true,
                qp: (lumaQP(x - 1, y) + lumaQP(x, y) + 1) >> 1,
                betaOffset: picture.betaOffset, tcOffset: picture.tcOffset
            )
        }
        for key in lumaHorizontal.sorted() {
            let x = key >> 16, y = key & 0xFFFF
            filterLumaSegment(
                &planes.luma, width: planes.lumaWidth,
                x: x, y: y, vertical: false,
                qp: (lumaQP(x, y - 1) + lumaQP(x, y) + 1) >> 1,
                betaOffset: picture.betaOffset, tcOffset: picture.tcOffset
            )
        }

        // Chroma: boundary strength is always 2 in intra pictures, so every
        // marked edge is filtered.
        let chromaWidth = planes.chromaWidth
        func filterChromaPlane(_ plane: inout [UInt8], qpOffset: Int) {
            for key in chromaVertical.sorted() {
                let x = key >> 16, y = key & 0xFFFF
                let qp = (lumaQP(2 * x - 1, 2 * y) + lumaQP(2 * x, 2 * y) + 1) >> 1
                filterChromaSegment(
                    &plane, width: chromaWidth,
                    x: x, y: y, vertical: true,
                    chromaQP: chromaQP(fromLumaQP: qp, offset: qpOffset),
                    tcOffset: picture.tcOffset
                )
            }
            for key in chromaHorizontal.sorted() {
                let x = key >> 16, y = key & 0xFFFF
                let qp = (lumaQP(2 * x, 2 * y - 1) + lumaQP(2 * x, 2 * y) + 1) >> 1
                filterChromaSegment(
                    &plane, width: chromaWidth,
                    x: x, y: y, vertical: false,
                    chromaQP: chromaQP(fromLumaQP: qp, offset: qpOffset),
                    tcOffset: picture.tcOffset
                )
            }
        }
        filterChromaPlane(&planes.cb, qpOffset: picture.cbQPOffset)
        filterChromaPlane(&planes.cr, qpOffset: picture.crQPOffset)
    }

    /// Filters one 4-line luma segment of an edge with boundary strength 2
    /// (8.7.2.5.3 decisions, 8.7.2.5.7 filtering).
    private static func filterLumaSegment(
        _ plane: inout [UInt8], width: Int,
        x: Int, y: Int, vertical: Bool,
        qp: Int, betaOffset: Int, tcOffset: Int
    ) {
        let beta = betaTable[min(max(qp + betaOffset, 0), 51)]
        let tc = tcTable[min(max(qp + 2 + tcOffset, 0), 53)]
        guard tc > 0 || beta > 0 else { return }

        // sample(line, position): position -4…3 across the edge.
        func index(_ line: Int, _ position: Int) -> Int {
            vertical
                ? (y + line) * width + x + position
                : (y + position) * width + x + line
        }
        func sample(_ line: Int, _ position: Int) -> Int {
            Int(plane[index(line, position)])
        }

        func dP(_ line: Int) -> Int {
            abs(sample(line, -3) - 2 * sample(line, -2) + sample(line, -1))
        }
        func dQ(_ line: Int) -> Int {
            abs(sample(line, 2) - 2 * sample(line, 1) + sample(line, 0))
        }

        let dp0 = dP(0), dp3 = dP(3), dq0 = dQ(0), dq3 = dQ(3)
        let d = dp0 + dp3 + dq0 + dq3
        guard d < beta else { return }

        func strongCondition(_ line: Int) -> Bool {
            2 * (dP(line) + dQ(line)) < beta >> 2
                && abs(sample(line, -4) - sample(line, -1)) + abs(sample(line, 0) - sample(line, 3)) < beta >> 3
                && abs(sample(line, -1) - sample(line, 0)) < (5 * tc + 1) >> 1
        }
        let strong = strongCondition(0) && strongCondition(3)
        let filterP1 = dp0 + dp3 < (beta + (beta >> 1)) >> 3
        let filterQ1 = dq0 + dq3 < (beta + (beta >> 1)) >> 3

        for line in 0..<4 {
            let p3 = sample(line, -4), p2 = sample(line, -3), p1 = sample(line, -2), p0 = sample(line, -1)
            let q0 = sample(line, 0), q1 = sample(line, 1), q2 = sample(line, 2), q3 = sample(line, 3)

            func write(_ position: Int, _ value: Int) {
                plane[index(line, position)] = UInt8(min(max(value, 0), 255))
            }

            if strong {
                let bound = 2 * tc
                write(-1, min(max((p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3, p0 - bound), p0 + bound))
                write(-2, min(max((p2 + p1 + p0 + q0 + 2) >> 2, p1 - bound), p1 + bound))
                write(-3, min(max((2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3, p2 - bound), p2 + bound))
                write(0, min(max((q2 + 2 * q1 + 2 * q0 + 2 * p0 + p1 + 4) >> 3, q0 - bound), q0 + bound))
                write(1, min(max((q2 + q1 + q0 + p0 + 2) >> 2, q1 - bound), q1 + bound))
                write(2, min(max((2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) >> 3, q2 - bound), q2 + bound))
            } else {
                var delta = (9 * (q0 - p0) - 3 * (q1 - p1) + 8) >> 4
                guard abs(delta) < tc * 10 else { continue }
                delta = min(max(delta, -tc), tc)
                write(-1, p0 + delta)
                write(0, q0 - delta)
                if filterP1 {
                    let dp = min(max((((p2 + p0 + 1) >> 1) - p1 + delta) >> 1, -(tc >> 1)), tc >> 1)
                    write(-2, p1 + dp)
                }
                if filterQ1 {
                    let dq = min(max((((q2 + q0 + 1) >> 1) - q1 - delta) >> 1, -(tc >> 1)), tc >> 1)
                    write(1, q1 + dq)
                }
            }
        }
    }

    /// Filters one 4-line chroma segment (8.7.2.5.5): with boundary
    /// strength 2 only the two samples straddling the edge move.
    private static func filterChromaSegment(
        _ plane: inout [UInt8], width: Int,
        x: Int, y: Int, vertical: Bool,
        chromaQP: Int, tcOffset: Int
    ) {
        let tc = tcTable[min(max(chromaQP + 2 + tcOffset, 0), 53)]
        guard tc > 0 else { return }
        for line in 0..<4 {
            func index(_ position: Int) -> Int {
                vertical
                    ? (y + line) * width + x + position
                    : (y + position) * width + x + line
            }
            let p1 = Int(plane[index(-2)]), p0 = Int(plane[index(-1)])
            let q0 = Int(plane[index(0)]), q1 = Int(plane[index(1)])
            let delta = min(max(((((q0 - p0) << 2) + p1 - q1 + 4) >> 3), -tc), tc)
            plane[index(-1)] = UInt8(min(max(p0 + delta, 0), 255))
            plane[index(0)] = UInt8(min(max(q0 - delta, 0), 255))
        }
    }

    private static let chromaQPMapping = [29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37]

    private static func chromaQP(fromLumaQP lumaQP: Int, offset: Int) -> Int {
        let qpi = min(max(lumaQP + offset, 0), 57)
        if qpi < 30 { return qpi }
        if qpi > 43 { return qpi - 6 }
        return chromaQPMapping[qpi - 30]
    }

    // MARK: Sample-adaptive offset (8.7.3)

    private static func applySAO(
        _ planes: inout HEVCReconstructedPlanes,
        picture: HEVCPictureData,
        sps: HEVCSequenceParameterSet
    ) {
        // SAO reads the deblocked picture, so it works from a snapshot.
        let sourceLuma = planes.luma
        let sourceCb = planes.cb
        let sourceCr = planes.cr

        for ctbY in 0..<sps.ctbRows {
            for ctbX in 0..<sps.ctbColumns {
                let parameters = picture.sao[ctbY * sps.ctbColumns + ctbX]
                for component in 0..<3 {
                    guard parameters.typeIndex[component] != 0 else { continue }
                    let shift = component == 0 ? 0 : 1
                    let width = component == 0 ? planes.lumaWidth : planes.chromaWidth
                    let height = component == 0 ? planes.lumaHeight : planes.chromaHeight
                    let source = component == 0 ? sourceLuma : (component == 1 ? sourceCb : sourceCr)
                    let x0 = (ctbX << sps.log2CTBSize) >> shift
                    let y0 = (ctbY << sps.log2CTBSize) >> shift
                    let x1 = min(x0 + (sps.ctbSize >> shift), width)
                    let y1 = min(y0 + (sps.ctbSize >> shift), height)

                    var updated: [(Int, UInt8)] = []
                    if parameters.typeIndex[component] == 1 {
                        // Band offset: four consecutive bands from the band
                        // position, wrapping at 32.
                        var bandOffsets = [Int](repeating: 0, count: 32)
                        for k in 0..<4 {
                            bandOffsets[(parameters.bandPosition[component] + k) & 31] = parameters.offsets[component][k]
                        }
                        for y in y0..<y1 {
                            for x in x0..<x1 {
                                let value = Int(source[y * width + x])
                                let offset = bandOffsets[value >> 3]
                                if offset != 0 {
                                    updated.append((y * width + x, UInt8(min(max(value + offset, 0), 255))))
                                }
                            }
                        }
                    } else {
                        // Edge offset: compare against the two neighbours
                        // along the class direction.
                        let directions = [((-1, 0), (1, 0)), ((0, -1), (0, 1)), ((-1, -1), (1, 1)), ((1, -1), (-1, 1))]
                        let (first, second) = directions[parameters.eoClass[component]]
                        for y in y0..<y1 {
                            for x in x0..<x1 {
                                let ax = x + first.0, ay = y + first.1
                                let bx = x + second.0, by = y + second.1
                                guard ax >= 0, ay >= 0, ax < width, ay < height,
                                      bx >= 0, by >= 0, bx < width, by < height else {
                                    continue
                                }
                                let value = Int(source[y * width + x])
                                let a = Int(source[ay * width + ax])
                                let b = Int(source[by * width + bx])
                                let edgeIndex = 2 + (value > a ? 1 : (value < a ? -1 : 0)) + (value > b ? 1 : (value < b ? -1 : 0))
                                guard edgeIndex != 2 else { continue }
                                let offset = parameters.offsets[component][edgeIndex < 2 ? edgeIndex : edgeIndex - 1]
                                if offset != 0 {
                                    updated.append((y * width + x, UInt8(min(max(value + offset, 0), 255))))
                                }
                            }
                        }
                    }
                    switch component {
                    case 0: for (index, value) in updated { planes.luma[index] = value }
                    case 1: for (index, value) in updated { planes.cb[index] = value }
                    default: for (index, value) in updated { planes.cr[index] = value }
                    }
                }
            }
        }
    }
}
