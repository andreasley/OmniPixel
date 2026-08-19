/// Reconstructs the pixel planes of a decoded HEVC intra picture:
/// dequantization with the default scaling matrices, inverse DST/DCT
/// transforms and intra prediction (ITU-T H.265 sections 8.4.4 and 8.6).
/// In-loop filters (deblocking, SAO) are applied in a later stage.
struct HEVCReconstructedPlanes {
    var lumaWidth: Int
    var lumaHeight: Int
    var luma: [UInt8]
    var cb: [UInt8]   // half resolution (4:2:0)
    var cr: [UInt8]

    var chromaWidth: Int { lumaWidth >> 1 }
    var chromaHeight: Int { lumaHeight >> 1 }
}

enum HEVCReconstruction {
    static func reconstruct(
        picture: HEVCPictureData,
        sps: HEVCSequenceParameterSet
    ) -> HEVCReconstructedPlanes {
        var planes = HEVCReconstructedPlanes(
            lumaWidth: sps.width,
            lumaHeight: sps.height,
            luma: [UInt8](repeating: 0, count: sps.width * sps.height),
            cb: [UInt8](repeating: 0, count: (sps.width >> 1) * (sps.height >> 1)),
            cr: [UInt8](repeating: 0, count: (sps.width >> 1) * (sps.height >> 1))
        )

        // Per-plane "already reconstructed" masks at 4×4 granularity gate
        // intra reference availability; blocks are processed in decode
        // order, so the masks realize the z-scan availability rule.
        var lumaMask = ReconstructionMask(width: sps.width, height: sps.height)
        var chromaMask = ReconstructionMask(width: sps.width >> 1, height: sps.height >> 1)

        for block in picture.transformBlocks {
            let size = 1 << block.log2Size
            let isLuma = block.componentIndex == 0
            let planeWidth = isLuma ? sps.width : sps.width >> 1
            let planeHeight = isLuma ? sps.height : sps.height >> 1

            var prediction = [Int](repeating: 0, count: size * size)
            withPlane(&planes, component: block.componentIndex) { plane in
                predictIntra(
                    into: &prediction,
                    plane: plane, planeWidth: planeWidth, planeHeight: planeHeight,
                    mask: isLuma ? lumaMask : chromaMask,
                    x: block.x, y: block.y, size: size,
                    mode: block.intraMode,
                    isLuma: isLuma,
                    strongSmoothing: sps.strongIntraSmoothingEnabled
                )
            }

            let residual = residualSamples(for: block, picture: picture, sps: sps)

            withPlane(&planes, component: block.componentIndex) { plane in
                for row in 0..<size {
                    let planeRow = (block.y + row) * planeWidth
                    for column in 0..<size {
                        let value = prediction[row * size + column] + residual[row * size + column]
                        plane[planeRow + block.x + column] = UInt8(min(max(value, 0), 255))
                    }
                }
            }
            if isLuma {
                lumaMask.markReconstructed(x: block.x, y: block.y, size: size)
            } else {
                chromaMask.markReconstructed(x: block.x, y: block.y, size: size)
            }
        }
        return planes
    }

    private static func withPlane(
        _ planes: inout HEVCReconstructedPlanes,
        component: Int,
        _ body: (inout [UInt8]) -> Void
    ) {
        switch component {
        case 0: body(&planes.luma)
        case 1: body(&planes.cb)
        default: body(&planes.cr)
        }
    }

    // MARK: Residual (dequantization + inverse transform, 8.6)

    private static func residualSamples(
        for block: HEVCPictureData.TransformBlock,
        picture: HEVCPictureData,
        sps: HEVCSequenceParameterSet
    ) -> [Int] {
        let size = 1 << block.log2Size
        if block.coefficients.isEmpty {
            return [Int](repeating: 0, count: size * size)
        }
        if block.transquantBypass {
            return block.coefficients
        }

        let qp: Int
        if block.componentIndex == 0 {
            qp = block.qp
        } else {
            let offset = block.componentIndex == 1 ? picture.cbQPOffset : picture.crQPOffset
            qp = chromaQP(fromLumaQP: block.qp, offset: offset)
        }

        let scaling = scalingFactors(log2Size: block.log2Size, enabled: sps.scalingListEnabled)
        let levelScale = [40, 45, 51, 57, 64, 72][qp % 6]
        let shift = 8 + block.log2Size - 5  // bitDepth + log2(nTbS) − 5
        let rounding = 1 << (shift - 1)

        var dequantized = [Int](repeating: 0, count: size * size)
        for index in 0..<(size * size) where block.coefficients[index] != 0 {
            let scaled = block.coefficients[index] * scaling[index] * levelScale << (qp / 6)
            dequantized[index] = clip16((scaled + rounding) >> shift)
        }

        if block.transformSkip {
            // r = (d << 7), then the same final scaling as the second
            // transform stage (8.6.4.1).
            return dequantized.map { (($0 << 7) + 2048) >> 12 }
        }

        let usesDST = block.componentIndex == 0 && block.log2Size == 2
        return inverseTransform(dequantized, size: size, usesDST: usesDST)
    }

    /// Two-stage inverse transform: columns with a 7-bit shift clipped to 16
    /// bits, then rows with the bit-depth shift of 12 (8.6.4.2 for 8-bit).
    private static func inverseTransform(_ input: [Int], size: Int, usesDST: Bool) -> [Int] {
        var intermediate = [Int](repeating: 0, count: size * size)
        for column in 0..<size {
            for position in 0..<size {
                var sum = 0
                for frequency in 0..<size {
                    sum += input[frequency * size + column] * basis(frequency, position, size, usesDST)
                }
                intermediate[position * size + column] = clip16((sum + 64) >> 7)
            }
        }
        var output = [Int](repeating: 0, count: size * size)
        for row in 0..<size {
            for position in 0..<size {
                var sum = 0
                for frequency in 0..<size {
                    sum += intermediate[row * size + frequency] * basis(frequency, position, size, usesDST)
                }
                output[row * size + position] = clip16((sum + 2048) >> 12)
            }
        }
        return output
    }

    /// First column of the 32-point transform matrix (H.265 8.6.4.2); every
    /// entry of every DCT matrix is one of these values with a sign given by
    /// cosine symmetry.
    private static let cosineTable: [Int] = [
        64, 90, 90, 90, 89, 88, 87, 85, 83, 82, 80, 78, 75, 73, 70, 67,
        64, 61, 57, 54, 50, 46, 43, 38, 36, 31, 25, 22, 18, 13, 9, 4, 0,
    ]

    /// The alternative 4×4 transform for intra luma blocks (H.265 8.6.4.1),
    /// indexed [frequency][position].
    private static let dstMatrix: [[Int]] = [
        [29, 55, 74, 84],
        [74, 74, 0, -74],
        [84, -29, -74, 55],
        [55, -84, 74, -29],
    ]

    private static func basis(_ frequency: Int, _ position: Int, _ size: Int, _ usesDST: Bool) -> Int {
        if usesDST {
            return dstMatrix[frequency][position]
        }
        // cos(π·frequency·(2·position+1) / (2·size)) in units of π/64.
        let angle = frequency * (2 * position + 1) * (32 / size) % 128
        if angle <= 32 { return cosineTable[angle] }
        if angle <= 64 { return -cosineTable[64 - angle] }
        if angle <= 96 { return -cosineTable[angle - 64] }
        return cosineTable[128 - angle]
    }

    private static func clip16(_ value: Int) -> Int {
        min(max(value, -32768), 32767)
    }

    // MARK: Scaling lists (7.4.5, Table 7-5/7-6)

    /// Default intra scaling matrix for 8×8 blocks; 16×16 and 32×32 use it
    /// upsampled 2×/4× with the DC entry replaced by 16.
    private static let defaultIntraScaling8: [Int] = [
        16, 16, 16, 16, 17, 18, 21, 24,
        16, 16, 16, 16, 17, 19, 22, 25,
        16, 16, 17, 18, 20, 22, 25, 29,
        16, 16, 18, 21, 24, 27, 31, 36,
        17, 17, 20, 24, 30, 35, 41, 47,
        18, 19, 22, 27, 35, 44, 54, 65,
        21, 22, 25, 31, 41, 54, 70, 88,
        24, 25, 29, 36, 47, 65, 88, 115,
    ]

    private static let scalingCache: [[Int]] = (2...5).map { log2Size in
        let size = 1 << log2Size
        if log2Size == 2 {
            return [Int](repeating: 16, count: 16)
        }
        let shift = log2Size - 3  // upsampling factor from the 8×8 matrix
        var factors = [Int](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                factors[y * size + x] = defaultIntraScaling8[(y >> shift) * 8 + (x >> shift)]
            }
        }
        if log2Size > 3 {
            factors[0] = 16  // default DC value
        }
        return factors
    }

    private static func scalingFactors(log2Size: Int, enabled: Bool) -> [Int] {
        guard enabled else {
            return [Int](repeating: 16, count: 1 << (log2Size << 1))
        }
        return scalingCache[log2Size - 2]
    }

    // MARK: Chroma QP (8.6.1, Table 8-10 for 4:2:0)

    private static let chromaQPTable = [29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37]

    private static func chromaQP(fromLumaQP lumaQP: Int, offset: Int) -> Int {
        let qpi = min(max(lumaQP + offset, 0), 57)
        if qpi < 30 { return qpi }
        if qpi > 43 { return qpi - 6 }
        return chromaQPTable[qpi - 30]
    }

    // MARK: Intra prediction (8.4.4.2)

    /// Prediction angles for modes 2…34 (Table 8-4).
    private static let intraAngles = [
        32, 26, 21, 17, 13, 9, 5, 2, 0, -2, -5, -9, -13, -17, -21, -26, -32,
        -26, -21, -17, -13, -9, -5, -2, 0, 2, 5, 9, 13, 17, 21, 26, 32,
    ]
    /// Inverse angles for the negative-angle modes 11…25 (Table 8-5).
    private static let inverseAngles = [
        -4096, -1638, -910, -630, -482, -390, -315, -256,
        -315, -390, -482, -630, -910, -1638, -4096,
    ]

    private static func predictIntra(
        into prediction: inout [Int],
        plane: [UInt8], planeWidth: Int, planeHeight: Int,
        mask: ReconstructionMask,
        x: Int, y: Int, size: Int,
        mode: Int,
        isLuma: Bool,
        strongSmoothing: Bool
    ) {
        // Gather the reference samples: left[0..2N-1] runs downward from
        // (x-1, y), top[0..2N-1] rightward from (x, y-1), plus the corner.
        let extent = 2 * size
        var left = [Int](repeating: -1, count: extent)     // -1 = unavailable
        var top = [Int](repeating: -1, count: extent)
        var corner = -1

        func sample(_ sampleX: Int, _ sampleY: Int) -> Int {
            guard sampleX >= 0, sampleY >= 0, sampleX < planeWidth, sampleY < planeHeight,
                  mask.isReconstructed(x: sampleX, y: sampleY) else {
                return -1
            }
            return Int(plane[sampleY * planeWidth + sampleX])
        }

        for i in 0..<extent {
            left[i] = sample(x - 1, y + i)
            top[i] = sample(x + i, y - 1)
        }
        corner = sample(x - 1, y - 1)

        // Reference substitution (8.4.4.2.2): scan from the bottom-left up
        // and then across; unavailable samples take the previous value.
        if corner < 0 && !left.contains(where: { $0 >= 0 }) && !top.contains(where: { $0 >= 0 }) {
            let mid = 128  // 1 << (bitDepth - 1)
            left = [Int](repeating: mid, count: extent)
            top = [Int](repeating: mid, count: extent)
            corner = mid
        } else {
            if left[extent - 1] < 0 {
                var substitute = -1
                for i in stride(from: extent - 2, through: 0, by: -1) where left[i] >= 0 {
                    substitute = left[i]
                    break
                }
                if substitute < 0 { substitute = corner }
                if substitute < 0 {
                    for i in 0..<extent where top[i] >= 0 {
                        substitute = top[i]
                        break
                    }
                }
                left[extent - 1] = substitute
            }
            for i in stride(from: extent - 2, through: 0, by: -1) where left[i] < 0 {
                left[i] = left[i + 1]
            }
            if corner < 0 { corner = left[0] }
            if top[0] < 0 { top[0] = corner }
            for i in 1..<extent where top[i] < 0 {
                top[i] = top[i - 1]
            }
        }

        // Reference smoothing (8.4.4.2.3), luma only.
        if isLuma, size >= 8, mode != 1 {
            let distance = min(abs(mode - 26), abs(mode - 10))
            let threshold = size == 8 ? 7 : (size == 16 ? 1 : 0)
            if mode == 0 || distance > threshold {
                let strong = strongSmoothing && size == 32
                    && abs(corner + top[extent - 1] - 2 * top[size - 1]) < 8
                    && abs(corner + left[extent - 1] - 2 * left[size - 1]) < 8
                if strong {
                    let topEnd = top[extent - 1]
                    let leftEnd = left[extent - 1]
                    let savedCorner = corner
                    for i in 0..<(extent - 1) {
                        top[i] = ((63 - (i + 1)) * savedCorner + (i + 1) * topEnd + 32) >> 6
                        left[i] = ((63 - (i + 1)) * savedCorner + (i + 1) * leftEnd + 32) >> 6
                    }
                } else {
                    var filteredLeft = left
                    var filteredTop = top
                    let filteredCorner = (left[0] + 2 * corner + top[0] + 2) >> 2
                    filteredLeft[0] = (corner + 2 * left[0] + left[1] + 2) >> 2
                    filteredTop[0] = (corner + 2 * top[0] + top[1] + 2) >> 2
                    for i in 1..<(extent - 1) {
                        filteredLeft[i] = (left[i - 1] + 2 * left[i] + left[i + 1] + 2) >> 2
                        filteredTop[i] = (top[i - 1] + 2 * top[i] + top[i + 1] + 2) >> 2
                    }
                    left = filteredLeft
                    top = filteredTop
                    corner = filteredCorner
                }
            }
        }

        switch mode {
        case 0:  // planar (8.4.4.2.4)
            let log2Size = size.trailingZeroBitCount
            for row in 0..<size {
                for column in 0..<size {
                    prediction[row * size + column] = (
                        (size - 1 - column) * left[row] + (column + 1) * top[size]
                        + (size - 1 - row) * top[column] + (row + 1) * left[size]
                        + size
                    ) >> (log2Size + 1)
                }
            }
        case 1:  // DC (8.4.4.2.5)
            var sum = size
            for i in 0..<size {
                sum += left[i] + top[i]
            }
            let dc = sum >> (size.trailingZeroBitCount + 1)
            for i in 0..<(size * size) {
                prediction[i] = dc
            }
            if isLuma, size < 32 {
                prediction[0] = (left[0] + 2 * dc + top[0] + 2) >> 2
                for column in 1..<size {
                    prediction[column] = (top[column] + 3 * dc + 2) >> 2
                }
                for row in 1..<size {
                    prediction[row * size] = (left[row] + 3 * dc + 2) >> 2
                }
            }
        default:  // angular (8.4.4.2.6)
            let angle = intraAngles[mode - 2]
            let vertical = mode >= 18
            // Main reference: index 0 is the corner, 1… the top row (or the
            // left column for horizontal modes), extended below index 0 via
            // the inverse angle when the angle is negative.
            var reference = [Int](repeating: 0, count: 3 * size + 2)
            let referenceBase = size
            let main = vertical ? top : left
            let side = vertical ? left : top
            reference[referenceBase] = corner
            for i in 0..<extent {
                reference[referenceBase + 1 + i] = main[i]
            }
            if angle < 0 {
                let inverseAngle = inverseAngles[mode - 11]
                let lowest = (size * angle) >> 5
                if lowest < -1 {
                    for i in stride(from: -1, through: lowest, by: -1) {
                        let sideIndex = ((i * inverseAngle + 128) >> 8) - 1
                        reference[referenceBase + i] = sideIndex < 0 ? corner : side[min(sideIndex, extent - 1)]
                    }
                }
            }
            for row in 0..<size {
                for column in 0..<size {
                    let position = vertical ? row : column
                    let offset = vertical ? column : row
                    let intercept = ((position + 1) * angle) >> 5
                    let fraction = ((position + 1) * angle) & 31
                    let base = referenceBase + 1 + offset + intercept
                    let value: Int
                    if fraction == 0 {
                        value = reference[base]
                    } else {
                        value = ((32 - fraction) * reference[base] + fraction * reference[base + 1] + 16) >> 5
                    }
                    prediction[row * size + column] = value
                }
            }
            // Boundary smoothing for the purely vertical/horizontal modes
            // (luma, blocks under 32 samples).
            if isLuma, size < 32 {
                if mode == 26 {
                    for row in 0..<size {
                        let value = top[0] + ((left[row] - corner) >> 1)
                        prediction[row * size] = min(max(value, 0), 255)
                    }
                } else if mode == 10 {
                    for column in 0..<size {
                        let value = left[0] + ((top[column] - corner) >> 1)
                        prediction[column] = min(max(value, 0), 255)
                    }
                }
            }
        }
    }
}

/// Tracks which samples of a plane have been reconstructed, at 4×4
/// granularity (the minimum transform block size).
private struct ReconstructionMask {
    private var blocks: [Bool]
    private let blocksAcross: Int

    init(width: Int, height: Int) {
        blocksAcross = (width + 3) >> 2
        blocks = [Bool](repeating: false, count: blocksAcross * ((height + 3) >> 2))
    }

    func isReconstructed(x: Int, y: Int) -> Bool {
        blocks[(y >> 2) * blocksAcross + (x >> 2)]
    }

    mutating func markReconstructed(x: Int, y: Int, size: Int) {
        for blockY in (y >> 2)..<((y + size) >> 2) {
            for blockX in (x >> 2)..<((x + size) >> 2) {
                blocks[blockY * blocksAcross + blockX] = true
            }
        }
    }
}
