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
    /// Working buffers sized for the largest transform block, allocated
    /// once per picture and reused for every block.
    private struct Scratch {
        var prediction = [Int](repeating: 0, count: 1024)
        var residual = [Int](repeating: 0, count: 1024)
        var dequantized = [Int](repeating: 0, count: 1024)
        var intermediate = [Int](repeating: 0, count: 1024)
        var accumulator = [Int](repeating: 0, count: 32)
        var left = [Int](repeating: -1, count: 64)
        var top = [Int](repeating: -1, count: 64)
        var reference = [Int](repeating: 0, count: 3 * 32 + 2)
    }

    static func reconstruct(
        picture: HEVCPictureData,
        sps: HEVCSequenceParameterSet,
        pps: HEVCPictureParameterSet
    ) -> HEVCReconstructedPlanes {
        // Picture-level scaling lists override sequence-level ones; enabled
        // streams without explicit lists use the default matrices.
        let scalingLists: HEVCScalingLists? = sps.scalingListEnabled
            ? (pps.scalingLists ?? sps.scalingLists ?? .defaults)
            : nil
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
        var scratch = Scratch()

        for block in picture.transformBlocks {
            let size = 1 << block.log2Size
            let isLuma = block.componentIndex == 0
            let planeWidth = isLuma ? sps.width : sps.width >> 1
            let planeHeight = isLuma ? sps.height : sps.height >> 1

            withPlane(&planes, component: block.componentIndex) { plane in
                predictIntra(
                    scratch: &scratch,
                    plane: plane, planeWidth: planeWidth, planeHeight: planeHeight,
                    mask: isLuma ? lumaMask : chromaMask,
                    x: block.x, y: block.y, size: size,
                    mode: block.intraMode,
                    isLuma: isLuma,
                    strongSmoothing: sps.strongIntraSmoothingEnabled
                )
            }

            let hasResidual = residualSamples(
                for: block, picture: picture, scalingLists: scalingLists, scratch: &scratch
            )

            withPlane(&planes, component: block.componentIndex) { plane in
                for row in 0..<size {
                    let planeRow = (block.y + row) * planeWidth + block.x
                    let blockRow = row * size
                    if hasResidual {
                        for column in 0..<size {
                            let value = scratch.prediction[blockRow + column] + scratch.residual[blockRow + column]
                            plane[planeRow + column] = UInt8(min(max(value, 0), 255))
                        }
                    } else {
                        for column in 0..<size {
                            let value = scratch.prediction[blockRow + column]
                            plane[planeRow + column] = UInt8(min(max(value, 0), 255))
                        }
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

    /// Fills `scratch.residual` for the block; returns false when the block
    /// has no coded coefficients (the residual is all zero).
    private static func residualSamples(
        for block: HEVCPictureData.TransformBlock,
        picture: HEVCPictureData,
        scalingLists: HEVCScalingLists?,
        scratch: inout Scratch
    ) -> Bool {
        if block.coefficients.isEmpty {
            return false
        }
        let size = 1 << block.log2Size
        if block.transquantBypass {
            for index in 0..<(size * size) {
                scratch.residual[index] = block.coefficients[index]
            }
            return true
        }

        let qp: Int
        if block.componentIndex == 0 {
            qp = block.qp
        } else {
            let offset = block.componentIndex == 1 ? picture.cbQPOffset : picture.crQPOffset
            qp = chromaQP(fromLumaQP: block.qp, offset: offset)
        }

        // Intra matrix IDs are the component indices (0 = Y, 1 = Cb, 2 = Cr).
        let scaling = scalingLists?.factors(log2Size: block.log2Size, matrixID: block.componentIndex)
        let levelScale = [40, 45, 51, 57, 64, 72][qp % 6] << (qp / 6)
        let shift = 8 + block.log2Size - 5  // bitDepth + log2(nTbS) − 5
        let rounding = 1 << (shift - 1)

        for index in 0..<(size * size) {
            let coefficient = block.coefficients[index]
            if coefficient == 0 {
                scratch.dequantized[index] = 0
            } else {
                let scaled = coefficient * (scaling?[index] ?? 16) * levelScale
                scratch.dequantized[index] = clip16((scaled + rounding) >> shift)
            }
        }

        if block.transformSkip {
            // r = (d << 7), then the same final scaling as the second
            // transform stage (8.6.4.1).
            for index in 0..<(size * size) {
                scratch.residual[index] = ((scratch.dequantized[index] << 7) + 2048) >> 12
            }
            return true
        }

        let usesDST = block.componentIndex == 0 && block.log2Size == 2
        inverseTransform(size: size, usesDST: usesDST, scratch: &scratch)
        return true
    }

    /// Two-stage inverse transform: columns with a 7-bit shift clipped to 16
    /// bits, then rows with the bit-depth shift of 12 (8.6.4.2 for 8-bit).
    /// Both stages scatter-accumulate over the nonzero inputs only, so cost
    /// scales with the coefficient count rather than the block area.
    private static func inverseTransform(size: Int, usesDST: Bool, scratch: inout Scratch) {
        let matrix = usesDST ? dstMatrix : dctMatrices[size.trailingZeroBitCount - 2]
        let count = size * size

        for index in 0..<count {
            scratch.intermediate[index] = 0
        }
        for frequency in 0..<size {
            let rowBase = frequency * size
            let matrixRow = frequency * size
            for column in 0..<size {
                let value = scratch.dequantized[rowBase + column]
                if value == 0 { continue }
                for position in 0..<size {
                    scratch.intermediate[position * size + column] += value * matrix[matrixRow + position]
                }
            }
        }
        for index in 0..<count {
            scratch.intermediate[index] = clip16((scratch.intermediate[index] + 64) >> 7)
        }

        for row in 0..<size {
            let rowBase = row * size
            for position in 0..<size {
                scratch.accumulator[position] = 0
            }
            for frequency in 0..<size {
                let value = scratch.intermediate[rowBase + frequency]
                if value == 0 { continue }
                let matrixRow = frequency * size
                for position in 0..<size {
                    scratch.accumulator[position] += value * matrix[matrixRow + position]
                }
            }
            for position in 0..<size {
                scratch.residual[rowBase + position] = clip16((scratch.accumulator[position] + 2048) >> 12)
            }
        }
    }

    /// First column of the 32-point transform matrix (H.265 8.6.4.2); every
    /// entry of every DCT matrix is one of these values with a sign given by
    /// cosine symmetry.
    private static let cosineTable: [Int] = [
        64, 90, 90, 90, 89, 88, 87, 85, 83, 82, 80, 78, 75, 73, 70, 67,
        64, 61, 57, 54, 50, 46, 43, 38, 36, 31, 25, 22, 18, 13, 9, 4, 0,
    ]

    /// The 4/8/16/32-point matrices expanded once, [frequency·size + position].
    private static let dctMatrices: [[Int]] = (2...5).map { log2Size in
        let size = 1 << log2Size
        var matrix = [Int](repeating: 0, count: size * size)
        for frequency in 0..<size {
            for position in 0..<size {
                // cos(π·frequency·(2·position+1) / (2·size)) in units of π/64.
                let angle = frequency * (2 * position + 1) * (32 / size) % 128
                let value: Int
                if angle <= 32 {
                    value = cosineTable[angle]
                } else if angle <= 64 {
                    value = -cosineTable[64 - angle]
                } else if angle <= 96 {
                    value = -cosineTable[angle - 64]
                } else {
                    value = cosineTable[128 - angle]
                }
                matrix[frequency * size + position] = value
            }
        }
        return matrix
    }

    /// The alternative 4×4 transform for intra luma blocks (H.265 8.6.4.1),
    /// [frequency·4 + position].
    private static let dstMatrix: [Int] = [
        29, 55, 74, 84,
        74, 74, 0, -74,
        84, -29, -74, 55,
        55, -84, 74, -29,
    ]

    private static func clip16(_ value: Int) -> Int {
        min(max(value, -32768), 32767)
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
        scratch: inout Scratch,
        plane: [UInt8], planeWidth: Int, planeHeight: Int,
        mask: ReconstructionMask,
        x: Int, y: Int, size: Int,
        mode: Int,
        isLuma: Bool,
        strongSmoothing: Bool
    ) {
        // Gather the reference samples: left[0..2N-1] runs downward from
        // (x-1, y), top[0..2N-1] rightward from (x, y-1), plus the corner.
        // Availability is constant within each 4-sample group (the mask's
        // granularity, and block coordinates are 4-aligned), so it is
        // checked once per group.
        let extent = 2 * size
        for i in 0..<extent {
            scratch.left[i] = -1     // -1 = unavailable
            scratch.top[i] = -1
        }
        var corner = -1
        var anyAvailable = false

        let leftX = x - 1
        if leftX >= 0 {
            let rowLimit = min(extent, planeHeight - y)
            var i = 0
            while i < rowLimit {
                if mask.isReconstructed(x: leftX, y: y + i) {
                    let end = min(i + 4, rowLimit)
                    var index = (y + i) * planeWidth + leftX
                    for j in i..<end {
                        scratch.left[j] = Int(plane[index])
                        index += planeWidth
                    }
                    anyAvailable = true
                    i = end
                } else {
                    i += 4
                }
            }
        }
        if y > 0 {
            let rowBase = (y - 1) * planeWidth
            let columnLimit = min(extent, planeWidth - x)
            var i = 0
            while i < columnLimit {
                if mask.isReconstructed(x: x + i, y: y - 1) {
                    let end = min(i + 4, columnLimit)
                    for j in i..<end {
                        scratch.top[j] = Int(plane[rowBase + x + j])
                    }
                    anyAvailable = true
                    i = end
                } else {
                    i += 4
                }
            }
            if leftX >= 0, mask.isReconstructed(x: leftX, y: y - 1) {
                corner = Int(plane[rowBase + leftX])
                anyAvailable = true
            }
        }

        // Reference substitution (8.4.4.2.2): scan from the bottom-left up
        // and then across; unavailable samples take the previous value.
        if !anyAvailable {
            let mid = 128  // 1 << (bitDepth - 1)
            for i in 0..<extent {
                scratch.left[i] = mid
                scratch.top[i] = mid
            }
            corner = mid
        } else {
            if scratch.left[extent - 1] < 0 {
                var substitute = -1
                for i in stride(from: extent - 2, through: 0, by: -1) where scratch.left[i] >= 0 {
                    substitute = scratch.left[i]
                    break
                }
                if substitute < 0 { substitute = corner }
                if substitute < 0 {
                    for i in 0..<extent where scratch.top[i] >= 0 {
                        substitute = scratch.top[i]
                        break
                    }
                }
                scratch.left[extent - 1] = substitute
            }
            for i in stride(from: extent - 2, through: 0, by: -1) where scratch.left[i] < 0 {
                scratch.left[i] = scratch.left[i + 1]
            }
            if corner < 0 { corner = scratch.left[0] }
            if scratch.top[0] < 0 { scratch.top[0] = corner }
            for i in 1..<extent where scratch.top[i] < 0 {
                scratch.top[i] = scratch.top[i - 1]
            }
        }

        // Reference smoothing (8.4.4.2.3), luma only.
        if isLuma, size >= 8, mode != 1 {
            let distance = min(abs(mode - 26), abs(mode - 10))
            let threshold = size == 8 ? 7 : (size == 16 ? 1 : 0)
            if mode == 0 || distance > threshold {
                let strong = strongSmoothing && size == 32
                    && abs(corner + scratch.top[extent - 1] - 2 * scratch.top[size - 1]) < 8
                    && abs(corner + scratch.left[extent - 1] - 2 * scratch.left[size - 1]) < 8
                if strong {
                    let topEnd = scratch.top[extent - 1]
                    let leftEnd = scratch.left[extent - 1]
                    let savedCorner = corner
                    for i in 0..<(extent - 1) {
                        scratch.top[i] = ((63 - (i + 1)) * savedCorner + (i + 1) * topEnd + 32) >> 6
                        scratch.left[i] = ((63 - (i + 1)) * savedCorner + (i + 1) * leftEnd + 32) >> 6
                    }
                } else {
                    // [1 2 1] filtering in place, carrying each original
                    // value into the next tap.
                    let filteredCorner = (scratch.left[0] + 2 * corner + scratch.top[0] + 2) >> 2
                    var previous = corner
                    for i in 0..<(extent - 1) {
                        let current = scratch.left[i]
                        scratch.left[i] = (previous + 2 * current + scratch.left[i + 1] + 2) >> 2
                        previous = current
                    }
                    previous = corner
                    for i in 0..<(extent - 1) {
                        let current = scratch.top[i]
                        scratch.top[i] = (previous + 2 * current + scratch.top[i + 1] + 2) >> 2
                        previous = current
                    }
                    corner = filteredCorner
                }
            }
        }

        switch mode {
        case 0:  // planar (8.4.4.2.4)
            let log2Size = size.trailingZeroBitCount
            for row in 0..<size {
                let rowBase = row * size
                let leftSample = scratch.left[row]
                for column in 0..<size {
                    scratch.prediction[rowBase + column] = (
                        (size - 1 - column) * leftSample + (column + 1) * scratch.top[size]
                        + (size - 1 - row) * scratch.top[column] + (row + 1) * scratch.left[size]
                        + size
                    ) >> (log2Size + 1)
                }
            }
        case 1:  // DC (8.4.4.2.5)
            var sum = size
            for i in 0..<size {
                sum += scratch.left[i] + scratch.top[i]
            }
            let dc = sum >> (size.trailingZeroBitCount + 1)
            for i in 0..<(size * size) {
                scratch.prediction[i] = dc
            }
            if isLuma, size < 32 {
                scratch.prediction[0] = (scratch.left[0] + 2 * dc + scratch.top[0] + 2) >> 2
                for column in 1..<size {
                    scratch.prediction[column] = (scratch.top[column] + 3 * dc + 2) >> 2
                }
                for row in 1..<size {
                    scratch.prediction[row * size] = (scratch.left[row] + 3 * dc + 2) >> 2
                }
            }
        default:  // angular (8.4.4.2.6)
            let angle = intraAngles[mode - 2]
            let vertical = mode >= 18
            // Main reference: index 0 is the corner, 1… the top row (or the
            // left column for horizontal modes), extended below index 0 via
            // the inverse angle when the angle is negative.
            let referenceBase = size
            scratch.reference[referenceBase] = corner
            if vertical {
                for i in 0..<extent {
                    scratch.reference[referenceBase + 1 + i] = scratch.top[i]
                }
            } else {
                for i in 0..<extent {
                    scratch.reference[referenceBase + 1 + i] = scratch.left[i]
                }
            }
            if angle < 0 {
                let inverseAngle = inverseAngles[mode - 11]
                let lowest = (size * angle) >> 5
                if lowest < -1 {
                    for i in stride(from: -1, through: lowest, by: -1) {
                        let sideIndex = ((i * inverseAngle + 128) >> 8) - 1
                        let side: Int
                        if sideIndex < 0 {
                            side = corner
                        } else if vertical {
                            side = scratch.left[min(sideIndex, extent - 1)]
                        } else {
                            side = scratch.top[min(sideIndex, extent - 1)]
                        }
                        scratch.reference[referenceBase + i] = side
                    }
                }
            }
            for row in 0..<size {
                let rowBase = row * size
                for column in 0..<size {
                    let position = vertical ? row : column
                    let offset = vertical ? column : row
                    let intercept = ((position + 1) * angle) >> 5
                    let fraction = ((position + 1) * angle) & 31
                    let base = referenceBase + 1 + offset + intercept
                    let value: Int
                    if fraction == 0 {
                        value = scratch.reference[base]
                    } else {
                        value = ((32 - fraction) * scratch.reference[base] + fraction * scratch.reference[base + 1] + 16) >> 5
                    }
                    scratch.prediction[rowBase + column] = value
                }
            }
            // Boundary smoothing for the purely vertical/horizontal modes
            // (luma, blocks under 32 samples).
            if isLuma, size < 32 {
                if mode == 26 {
                    for row in 0..<size {
                        let value = scratch.top[0] + ((scratch.left[row] - corner) >> 1)
                        scratch.prediction[row * size] = min(max(value, 0), 255)
                    }
                } else if mode == 10 {
                    for column in 0..<size {
                        let value = scratch.left[0] + ((scratch.top[column] - corner) >> 1)
                        scratch.prediction[column] = min(max(value, 0), 255)
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
