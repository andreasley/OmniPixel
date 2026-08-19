import Foundation
import Testing
@testable import PurePixel

#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

@Suite struct HEVCTests {
    @Test func unsignedExpGolombDecoding() throws {
        // Codes for 0, 1, 2, 3, 4: "1", "010", "011", "00100", "00101"
        // → 1010 0110 0100 0010 1(pad) → 0xA6, 0x42, 0x80.
        var reader = HEVCBitReader([0xA6, 0x42, 0x80])
        #expect(try reader.readUnsignedExpGolomb() == 0)
        #expect(try reader.readUnsignedExpGolomb() == 1)
        #expect(try reader.readUnsignedExpGolomb() == 2)
        #expect(try reader.readUnsignedExpGolomb() == 3)
        #expect(try reader.readUnsignedExpGolomb() == 4)
    }

    @Test func signedExpGolombDecoding() throws {
        // Codes 1, 2, 3 → values 1, −1, 2: "010 011 00100" → 0x4C, 0x80.
        var reader = HEVCBitReader([0x4C, 0x80])
        #expect(try reader.readSignedExpGolomb() == 1)
        #expect(try reader.readSignedExpGolomb() == -1)
        #expect(try reader.readSignedExpGolomb() == 2)
    }

    @Test func expGolombRejectsTruncatedCode() {
        var reader = HEVCBitReader([0x00])  // eight leading zeros, then nothing
        #expect(throws: ImageError.self) {
            _ = try reader.readUnsignedExpGolomb()
        }
    }

    @Test func nalUnitHeaderAndEmulationPrevention() throws {
        // 0x42 0x01 = SPS (type 33), temporal ID 0. The payload contains two
        // emulation-prevention sequences whose 0x03 bytes must be removed.
        let nal = try #require(HEVCNALUnit(bytes: [0x42, 0x01, 0, 0, 3, 1, 0, 0, 3, 0]))
        #expect(nal.type == HEVCNALUnit.sps)
        #expect(nal.temporalID == 0)
        #expect(nal.payload == [0, 0, 1, 0, 0, 0])
    }

    @Test func nalUnitRejectsForbiddenBit() {
        #expect(HEVCNALUnit(bytes: [0x80, 0x01, 0x00]) == nil)
    }

    // MARK: CABAC

    @Test func contextInitializationMatchesSpecification() {
        // initValue 154 is the "neutral" value: slope 9 → m = 0, offset 10 →
        // n = 64, so preCtxState = 64 at any QP → state 0, MPS 1.
        for qp in [0, 17, 26, 40, 51] {
            let context = CABACContext(initValue: 154, qp: qp)
            #expect(context.state == 0)
            #expect(context.mps == 1)
        }
        // initValue 0 at QP 26: m = −45, n = −16 → (−45·26) >> 4 = −74
        // (arithmetic shift floors), preCtxState = clip(−90) = 1 → MPS 0,
        // state 62.
        let low = CABACContext(initValue: 0, qp: 26)
        #expect(low.state == 62)
        #expect(low.mps == 0)
    }

    @Test func cabacTableSpotChecks() {
        #expect(HEVCCabacTables.lpsRange.count == 64)
        #expect(HEVCCabacTables.lpsRange[0] == [128, 176, 208, 240])
        #expect(HEVCCabacTables.lpsRange[63] == [2, 2, 2, 2])
        // LPS ranges shrink as confidence grows, per column.
        for column in 0..<4 {
            for state in 1..<63 {
                #expect(HEVCCabacTables.lpsRange[state][column] <= HEVCCabacTables.lpsRange[state - 1][column])
            }
        }
        // The LPS transition never increases confidence; MPS saturates at 62.
        for state in 0..<64 {
            #expect(Int(HEVCCabacTables.lpsTransition[state]) <= max(state, 63 == state ? 63 : state))
        }
        #expect(HEVCCabacTables.mpsTransition[61] == 62)
        #expect(HEVCCabacTables.mpsTransition[62] == 62)
        #expect(HEVCCabacTables.mpsTransition[63] == 63)
    }

    @Test func cabacEncoderDecoderRoundTrip() throws {
        // A spec-conformant CABAC encoder (test-only) produces a stream of
        // pseudo-random context-coded bins, bypass bins and terminate bins;
        // the decoder must reproduce every bin and end with identical
        // context states. This exercises renormalization, LPS/MPS paths,
        // state adaptation and the bypass/terminate modes.
        var lcg: UInt32 = 0x1234_5678
        func random(_ bound: Int) -> Int {
            lcg = lcg &* 1_664_525 &+ 1_013_904_223
            return Int(lcg >> 16) % bound
        }

        let initValues = [154, 79, 63, 111, 200, 31, 140, 197, 15, 244]
        var encoderContexts = initValues.map { CABACContext(initValue: $0, qp: 30) }
        var decoderContexts = initValues.map { CABACContext(initValue: $0, qp: 30) }

        var encoder = TestCABACEncoder()
        var record: [(kind: Int, context: Int, bin: Int)] = []
        for _ in 0..<20_000 {
            switch random(4) {
            case 0, 1:
                let contextIndex = random(encoderContexts.count)
                let bin = random(2)
                encoder.encodeBin(&encoderContexts[contextIndex], bin)
                record.append((0, contextIndex, bin))
            case 2:
                let bin = random(2)
                encoder.encodeBypass(bin)
                record.append((1, 0, bin))
            default:
                encoder.encodeTerminate(0)
                record.append((2, 0, 0))
            }
        }
        encoder.encodeTerminate(1)  // ends and flushes the stream

        var decoder = try CABACDecoder(bytes: encoder.packedBytes(), startingAtBit: 0)
        var mismatches = 0
        for entry in record {
            let decoded: Int
            switch entry.kind {
            case 0:
                decoded = try decoder.decodeBin(&decoderContexts[entry.context])
            case 1:
                decoded = try decoder.decodeBypass()
            default:
                decoded = try decoder.decodeTerminate()
            }
            if decoded != entry.bin {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
        #expect(try decoder.decodeTerminate() == 1)
        for (encoded, decoded) in zip(encoderContexts, decoderContexts) {
            #expect(encoded.state == decoded.state)
            #expect(encoded.mps == decoded.mps)
        }
    }

    #if canImport(ImageIO)
    /// Builds a real HEVC-compressed HEIC through ImageIO.
    private func makeHEIC(
        width: Int,
        height: Int,
        quality: Double = 1.0,
        solidGray: UInt8? = nil
    ) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = solidGray ?? UInt8((x * 5) % 256)
                pixels[i + 1] = solidGray ?? UInt8((y * 7) % 256)
                pixels[i + 2] = solidGray ?? UInt8((x + y) % 256)
                pixels[i + 3] = 255
            }
        }
        let context = try #require(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.heic.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func parsesRealHEVCParameterSets() throws {
        // Quality 1.0 makes VideoToolbox switch to 4:4:4; 0.9 codes 4:2:0.
        let data = try makeHEIC(width: 64, height: 48, quality: 0.9)
        let stream = try HEICCodec.parseStream(from: data)

        // The SPS must describe exactly the encoded picture.
        #expect(stream.sps.croppedWidth == 64)
        #expect(stream.sps.croppedHeight == 48)
        #expect(stream.sps.chromaFormat == 1)  // 4:2:0
        #expect(stream.sps.bitDepthLuma == 8)
        #expect(stream.sps.bitDepthChroma == 8)
        #expect((4...6).contains(stream.sps.log2CTBSize))
        #expect(stream.sps.log2MinCodingBlockSize >= 3)
        #expect(stream.sps.log2MaxTransformBlockSize <= 5)

        // The first slice must be an intra slice with a sane QP.
        #expect(stream.firstSliceHeader.sliceType == 2)
        #expect(stream.firstSliceHeader.firstSliceInPicture)
        #expect((0...51).contains(stream.firstSliceHeader.qp))
        #expect(!stream.sliceNALUnits.isEmpty)
        #expect(stream.firstSliceHeader.dataBitOffset > 0)
        #expect(stream.firstSliceHeader.dataBitOffset % 8 == 0)
    }

    @Test(arguments: [
        (33, 21, 0.3), (33, 21, 0.8),
        (64, 48, 0.3), (64, 48, 0.5), (64, 48, 0.9),
        (128, 96, 0.5), (256, 200, 0.5),
    ])
    func decodesRealSliceSyntaxToTermination(size: (Int, Int, Double)) throws {
        // The acid test for the syntax layer: any wrong context index, init
        // value or binarization desynchronizes CABAC within a few bins, so
        // decoding every CTB of a real ImageIO stream (including wavefront
        // row boundaries) to a clean end-of-slice is a strong signal.
        let (width, height, quality) = size
        let data = try makeHEIC(width: width, height: height, quality: quality)
        let stream = try HEICCodec.parseStream(from: data)
        let decoder = try HEVCPictureDecoder(sps: stream.sps, pps: stream.pps)
        let picture = try decoder.decodePicture(sliceNALUnits: stream.sliceNALUnits)

        #expect(picture.decodedCTBCount == stream.sps.ctbColumns * stream.sps.ctbRows)
        #expect(picture.lumaModeGrid.allSatisfy { (0...34).contains($0) })
        #expect(!picture.transformBlocks.isEmpty)
        let nonZero = picture.transformBlocks.reduce(0) { count, block in
            count + block.coefficients.count(where: { $0 != 0 })
        }
        #expect(nonZero > 0)
        for block in picture.transformBlocks {
            #expect((2...5).contains(block.log2Size))
            #expect((0...51).contains(block.qp))
        }
    }

    @Test func reconstructsSolidGrayToFlatPlanes() throws {
        // A solid gray image maps to a constant luma value with both chroma
        // planes at exactly 128 under every RGB→YCbCr matrix and range, so
        // flat reconstructed planes validate prediction, dequantization and
        // the inverse transforms without knowing the encoder's color setup.
        // (Full sample-exact conformance is checked against a reference
        // decoder during bring-up; see the project notes.)
        let data = try makeHEIC(width: 64, height: 48, quality: 0.8, solidGray: 128)
        let stream = try HEICCodec.parseStream(from: data)
        let decoder = try HEVCPictureDecoder(sps: stream.sps, pps: stream.pps)
        let picture = try decoder.decodePicture(sliceNALUnits: stream.sliceNALUnits)
        let planes = HEVCReconstruction.reconstruct(picture: picture, sps: stream.sps, pps: stream.pps)

        #expect(planes.luma.count == stream.sps.width * stream.sps.height)
        #expect(planes.cb.count == planes.chromaWidth * planes.chromaHeight)

        // Only the conformance-window content is meaningful; the encoder
        // pads the coded picture with arbitrary samples.
        var lumaValues: [UInt8] = []
        for y in 0..<stream.sps.croppedHeight {
            for x in 0..<stream.sps.croppedWidth {
                lumaValues.append(planes.luma[y * planes.lumaWidth + x])
            }
        }
        let lumaMin = Int(lumaValues.min() ?? 0)
        let lumaMax = Int(lumaValues.max() ?? 255)
        #expect(lumaMax - lumaMin <= 4)
        #expect((100...160).contains(lumaMin))
        for y in 0..<(stream.sps.croppedHeight / 2) {
            for x in 0..<(stream.sps.croppedWidth / 2) {
                #expect((124...132).contains(Int(planes.cb[y * planes.chromaWidth + x])))
                #expect((124...132).contains(Int(planes.cr[y * planes.chromaWidth + x])))
            }
        }
    }

    @Test func reconstructsRealStreamsWithoutError() throws {
        // Reconstruction of full pictures across content-heavy streams;
        // sample-exactness is validated against a reference decoder during
        // bring-up, this guards the pipeline end to end.
        for (width, height, quality) in [(33, 21, 0.3), (64, 48, 0.5), (128, 96, 0.9)] {
            let data = try makeHEIC(width: width, height: height, quality: quality)
            let stream = try HEICCodec.parseStream(from: data)
            let decoder = try HEVCPictureDecoder(sps: stream.sps, pps: stream.pps)
            let picture = try decoder.decodePicture(sliceNALUnits: stream.sliceNALUnits)
            let planes = HEVCReconstruction.reconstruct(picture: picture, sps: stream.sps, pps: stream.pps)
            #expect(planes.luma.count == stream.sps.width * stream.sps.height)
            // Content is not flat, so the reconstruction should not be either.
            #expect(Set(planes.luma).count > 16)
        }
    }

    @Test func decodesExplicitScalingLists() throws {
        // VideoToolbox never writes explicit scaling lists, so splice
        // crafted scaling_list_data into a real SPS at the bit level: flip
        // sps_scaling_list_data_present_flag from 0 to 1 and insert list
        // data covering all three coding paths (explicit coefficients,
        // copy-by-delta, default-by-delta-zero). The slice data parses
        // unchanged; only dequantization differs. The result was verified
        // sample-exactly against a reference decoder during bring-up.
        let data = try makeHEIC(width: 64, height: 48, quality: 0.5)
        let stream = try HEICCodec.parseStream(from: data)

        // Locate the SPS NAL and the bit position of the present flag by
        // mirroring the parser's field order.
        let spsNAL = try #require(findParameterNAL(ofType: 33, in: data))
        let payload = HEVCNALUnit(bytes: spsNAL)!.payload
        var reader = HEVCBitReader(payload)
        _ = try reader.readBits(8)  // vps id, sublayers, nesting
        _ = try reader.readBits(96)  // profile_tier_level (no sublayers)
        _ = try reader.readUnsignedExpGolomb()  // sps id
        let chroma = try reader.readUnsignedExpGolomb()
        try #require(chroma != 3)
        _ = try reader.readUnsignedExpGolomb()  // width
        _ = try reader.readUnsignedExpGolomb()  // height
        if try reader.readFlag() {
            for _ in 0..<4 { _ = try reader.readUnsignedExpGolomb() }
        }
        for _ in 0..<3 { _ = try reader.readUnsignedExpGolomb() }  // depths, poc
        let orderingPresent = try reader.readFlag()
        try #require(orderingPresent || !orderingPresent)  // one sub-layer either way
        for _ in 0..<3 { _ = try reader.readUnsignedExpGolomb() }
        for _ in 0..<6 { _ = try reader.readUnsignedExpGolomb() }  // block sizes
        try #require(try reader.readFlag())  // scaling_list_enabled
        let presentFlagPosition = reader.bitPosition
        try #require(try reader.readFlag() == false)

        // scaling_list_data: explicit flat-24 luma 4×4 (DC 30 at 16×16,
        // 24 at 32×32), chroma copied from luma, inter lists defaulted.
        var lists = TestBitWriter()
        for sizeID in 0..<4 {
            for matrixIndex in 0..<(sizeID == 3 ? 2 : 6) {
                switch (sizeID, matrixIndex) {
                case (0, 0), (1, 0), (2, 0), (3, 0):
                    lists.bit(1)
                    var next = 8
                    if sizeID > 1 {
                        let dc = sizeID == 2 ? 30 : 24
                        lists.signedExpGolomb(dc - 8)
                        next = dc
                    }
                    let target = [24, 20, 20, 18][sizeID]
                    for i in 0..<min(64, 1 << (4 + (sizeID << 1))) {
                        lists.signedExpGolomb(i == 0 ? target - next : 0)
                    }
                case (0, 1), (0, 2):
                    lists.bit(0)
                    lists.unsignedExpGolomb(matrixIndex)  // copy luma
                case (1, 2), (2, 2), (3, 1):
                    lists.bit(0)
                    lists.unsignedExpGolomb(1)  // copy previous
                default:
                    lists.bit(0)
                    lists.unsignedExpGolomb(0)  // default list
                }
            }
        }

        // Reassemble the payload with the flag flipped and the data inserted.
        var outBits: [Bool] = []
        var copier = HEVCBitReader(payload)
        for _ in 0..<presentFlagPosition { outBits.append(try copier.readBit() == 1) }
        _ = try copier.readBit()
        outBits.append(true)
        outBits.append(contentsOf: lists.bits)
        for _ in (presentFlagPosition + 1)..<(payload.count * 8) {
            outBits.append(try copier.readBit() == 1)
        }
        while outBits.count % 8 != 0 { outBits.append(false) }
        var newPayload = [UInt8]()
        for byteIndex in stride(from: 0, to: outBits.count, by: 8) {
            var byte = 0
            for i in 0..<8 { byte = byte << 1 | (outBits[byteIndex + i] ? 1 : 0) }
            newPayload.append(UInt8(byte))
        }
        var escaped: [UInt8] = [spsNAL[0], spsNAL[1]]
        var zeroRun = 0
        for byte in newPayload {
            if zeroRun >= 2, byte <= 3 {
                escaped.append(3)
                zeroRun = 0
            }
            escaped.append(byte)
            zeroRun = byte == 0 ? zeroRun + 1 : 0
        }

        let scaledSPS = try HEVCSequenceParameterSet.parse(try #require(HEVCNALUnit(bytes: escaped)))
        let parsed = try #require(scaledSPS.scalingLists)
        #expect(parsed.factors(log2Size: 2, matrixID: 0) == [Int](repeating: 24, count: 16))
        #expect(parsed.factors(log2Size: 2, matrixID: 1)[7] == 24)   // copied from luma
        #expect(parsed.factors(log2Size: 3, matrixID: 0)[0] == 20)   // explicit
        #expect(parsed.factors(log2Size: 3, matrixID: 1)[0] == 16)   // default list
        #expect(parsed.factors(log2Size: 3, matrixID: 1)[63] == 115) // default list tail
        #expect(parsed.factors(log2Size: 4, matrixID: 0)[0] == 30)   // explicit DC
        #expect(parsed.factors(log2Size: 4, matrixID: 0)[1] == 20)
        #expect(parsed.factors(log2Size: 5, matrixID: 0)[0] == 24)   // explicit DC

        // Decoding with the explicit lists must succeed and produce pixels
        // different from the default-list decode of the same slice data.
        func decode(with sps: HEVCSequenceParameterSet) throws -> [UInt8] {
            let decoder = try HEVCPictureDecoder(sps: sps, pps: stream.pps)
            let picture = try decoder.decodePicture(sliceNALUnits: stream.sliceNALUnits)
            var planes = HEVCReconstruction.reconstruct(picture: picture, sps: sps, pps: stream.pps)
            HEVCLoopFilters.apply(to: &planes, picture: picture, sps: sps)
            return planes.luma
        }
        let scaledLuma = try decode(with: scaledSPS)
        let defaultLuma = try decode(with: stream.sps)
        #expect(scaledLuma != defaultLuma)
    }

    private func findParameterNAL(ofType type: Int, in data: Data) -> [UInt8]? {
        let bytes = [UInt8](data)
        for i in 0..<(bytes.count - 4)
        where bytes[i] == 0x68 && bytes[i+1] == 0x76 && bytes[i+2] == 0x63 && bytes[i+3] == 0x43 {
            let arrayCount = Int(bytes[i + 4 + 22])
            var offset = i + 4 + 23
            for _ in 0..<arrayCount {
                let unitCount = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
                offset += 3
                for _ in 0..<unitCount {
                    let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                    offset += 2
                    let nal = Array(bytes[offset..<offset + length])
                    if Int(nal[0] >> 1) & 0x3F == type {
                        return nal
                    }
                    offset += length
                }
            }
        }
        return nil
    }

    @Test func parsesRealHEVCStreamAtOddDimensions() throws {
        // 51×37: in 4:2:0 the SPS conformance window can only crop in
        // two-pixel steps, so the bitstream rounds up to 52×38 and the
        // container's ispe property carries the true display size.
        let data = try makeHEIC(width: 51, height: 37)
        let stream = try HEICCodec.parseStream(from: data)
        #expect(stream.displayWidth == 51)
        #expect(stream.displayHeight == 37)
        #expect((51...52).contains(stream.sps.croppedWidth))
        #expect((37...38).contains(stream.sps.croppedHeight))
        #expect(stream.sps.width % (1 << stream.sps.log2MinCodingBlockSize) == 0)
        #expect(stream.sps.height % (1 << stream.sps.log2MinCodingBlockSize) == 0)
    }
    #endif
}

/// A CABAC encoder implementing ITU-T H.265 section 9.3.4.4, used only to
/// generate round-trip vectors for the decoder. It shares the library's
/// probability tables, so it validates the engine logic (renormalization,
/// outstanding-bit handling, state adaptation), while the tables themselves
/// are covered by spot checks and, end to end, by conformance decoding.
/// MSB-first bit assembly with Exp-Golomb coding, for building test
/// bitstream fragments.
private struct TestBitWriter {
    var bits: [Bool] = []

    mutating func bit(_ value: Int) {
        bits.append(value == 1)
    }

    mutating func unsignedExpGolomb(_ value: Int) {
        let coded = value + 1
        let length = coded.bitWidth - coded.leadingZeroBitCount
        for _ in 0..<(length - 1) {
            bit(0)
        }
        for i in stride(from: length - 1, through: 0, by: -1) {
            bit((coded >> i) & 1)
        }
    }

    mutating func signedExpGolomb(_ value: Int) {
        unsignedExpGolomb(value > 0 ? 2 * value - 1 : -2 * value)
    }
}

private struct TestCABACEncoder {
    private var low = 0
    private var range = 510
    private var outstandingBits = 0
    private var isFirstBit = true
    private var bits: [Int] = []

    mutating func encodeBin(_ context: inout CABACContext, _ bin: Int) {
        let quantizedRange = (range >> 6) & 3
        let lpsRange = Int(HEVCCabacTables.lpsRange[context.state][quantizedRange])
        range -= lpsRange
        if bin != context.mps {
            low += range
            range = lpsRange
            if context.state == 0 {
                context.mps = 1 - context.mps
            }
            context.state = Int(HEVCCabacTables.lpsTransition[context.state])
        } else {
            context.state = Int(HEVCCabacTables.mpsTransition[context.state])
        }
        renormalize()
    }

    mutating func encodeBypass(_ bin: Int) {
        low <<= 1
        if bin == 1 {
            low += range
        }
        if low >= 1024 {
            putBit(1)
            low -= 1024
        } else if low < 512 {
            putBit(0)
        } else {
            outstandingBits += 1
            low -= 512
        }
    }

    mutating func encodeTerminate(_ bin: Int) {
        range -= 2
        if bin == 1 {
            low += range
            flush()
        } else {
            renormalize()
        }
    }

    mutating func packedBytes() -> [UInt8] {
        var bytes: [UInt8] = []
        var current = 0
        var count = 0
        for bit in bits {
            current = current << 1 | bit
            count += 1
            if count == 8 {
                bytes.append(UInt8(current))
                current = 0
                count = 0
            }
        }
        if count > 0 {
            bytes.append(UInt8(current << (8 - count)))
        }
        return bytes
    }

    private mutating func flush() {
        range = 2
        renormalize()
        putBit((low >> 9) & 1)
        bits.append((low >> 8) & 1)
        bits.append(1)
    }

    private mutating func renormalize() {
        while range < 256 {
            if low >= 512 {
                putBit(1)
                low -= 512
            } else if low < 256 {
                putBit(0)
            } else {
                outstandingBits += 1
                low -= 256
            }
            low <<= 1
            range <<= 1
        }
    }

    private mutating func putBit(_ bit: Int) {
        if isFirstBit {
            isFirstBit = false
        } else {
            bits.append(bit)
        }
        while outstandingBits > 0 {
            bits.append(1 - bit)
            outstandingBits -= 1
        }
    }
}
