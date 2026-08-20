/// AV1 open bitstream units and the sequence header (AV1 specification
/// sections 5.2–5.5). AV1 has no emulation prevention, so payloads are
/// used as stored.
struct AV1OBU {
    static let sequenceHeader = 1
    static let temporalDelimiter = 2
    static let frameHeader = 3
    static let tileGroup = 4
    static let metadata = 5
    static let frame = 6
    static let redundantFrameHeader = 7
    static let tileList = 8
    static let padding = 15

    var type: Int
    var payload: [UInt8]

    /// Splits a buffer into OBUs: a 1-byte header, an optional extension
    /// byte, a LEB128 size (or the rest of the buffer when absent).
    static func split(_ data: [UInt8]) throws -> [AV1OBU] {
        var units: [AV1OBU] = []
        var offset = 0
        while offset < data.count {
            let header = data[offset]
            guard header & 0x80 == 0 else {
                throw ImageError.invalidData(reason: "Invalid AV1 OBU header")
            }
            let type = Int(header >> 3) & 0x0F
            let hasExtension = header & 0x04 != 0
            let hasSize = header & 0x02 != 0
            offset += 1
            if hasExtension {
                guard offset < data.count else {
                    throw ImageError.invalidData(reason: "Truncated AV1 OBU")
                }
                offset += 1
            }
            let size: Int
            if hasSize {
                (size, offset) = try readLEB128(data, at: offset)
            } else {
                size = data.count - offset
            }
            guard size >= 0, offset + size <= data.count else {
                throw ImageError.invalidData(reason: "AV1 OBU exceeds its data")
            }
            units.append(AV1OBU(type: type, payload: Array(data[offset..<offset + size])))
            offset += size
        }
        return units
    }

    private static func readLEB128(_ data: [UInt8], at start: Int) throws -> (value: Int, next: Int) {
        var value = 0
        var offset = start
        for shift in stride(from: 0, to: 64, by: 7) {
            guard offset < data.count, shift <= 56 else {
                throw ImageError.invalidData(reason: "Invalid AV1 LEB128 value")
            }
            let byte = data[offset]
            offset += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return (value, offset)
            }
        }
        throw ImageError.invalidData(reason: "Invalid AV1 LEB128 value")
    }
}

/// The AV1 sequence header (specification section 5.5) — the fields a
/// still-picture decoder needs.
struct AV1SequenceHeader {
    var profile = 0
    var stillPicture = false
    var reducedStillPictureHeader = false
    var width = 0
    var height = 0
    var use128x128Superblock = false
    var enableFilterIntra = false
    var enableIntraEdgeFilter = false
    var enableSuperres = false
    var enableCDEF = false
    var enableRestoration = false
    var bitDepth = 8
    var monochrome = false
    var subsamplingX = 1
    var subsamplingY = 1
    var chromaSamplePosition = 0
    var colorPrimaries = 2      // unspecified
    var transferCharacteristics = 2
    var matrixCoefficients = 2
    var fullRange = false
    var separateUVDeltaQ = false
    var filmGrainPresent = false
    var frameIDNumbersPresent = false
    var deltaFrameIDLength = 0
    var additionalFrameIDLength = 0
    /// 0/1 fixed, 2 = chosen per frame (SELECT).
    var forceScreenContentTools = 2
    var forceIntegerMV = 2
    var enableOrderHint = false
    var orderHintBits = 0

    static func parse(_ payload: [UInt8]) throws -> AV1SequenceHeader {
        var reader = HEVCBitReader(payload)
        var header = AV1SequenceHeader()

        header.profile = try reader.readBits(3)
        guard header.profile <= 2 else {
            throw ImageError.invalidData(reason: "Invalid AV1 sequence profile")
        }
        header.stillPicture = try reader.readFlag()
        header.reducedStillPictureHeader = try reader.readFlag()

        if header.reducedStillPictureHeader {
            _ = try reader.readBits(5)  // seq_level_idx[0]
        } else {
            guard try reader.readFlag() == false else {
                // timing_info drags in the decoder model; still images
                // never carry it.
                throw ImageError.unsupportedFeature(reason: "AV1 streams with timing information are not supported (still images only)")
            }
            let initialDisplayDelayPresent = try reader.readFlag()
            let operatingPoints = 1 + (try reader.readBits(5))
            for _ in 0..<operatingPoints {
                _ = try reader.readBits(12)  // operating_point_idc
                let levelIndex = try reader.readBits(5)
                if levelIndex > 7 {
                    _ = try reader.readBit()  // seq_tier
                }
                if initialDisplayDelayPresent, try reader.readFlag() {
                    _ = try reader.readBits(4)  // initial_display_delay_minus_1
                }
            }
        }

        let widthBits = 1 + (try reader.readBits(4))
        let heightBits = 1 + (try reader.readBits(4))
        header.width = 1 + (try reader.readBits(widthBits))
        header.height = 1 + (try reader.readBits(heightBits))
        let (pixelCount, overflow) = header.width.multipliedReportingOverflow(by: header.height)
        guard !overflow, pixelCount <= Image.maxPixelCount else {
            throw ImageError.invalidData(reason: "Invalid AV1 picture dimensions")
        }

        if !header.reducedStillPictureHeader {
            header.frameIDNumbersPresent = try reader.readFlag()
            if header.frameIDNumbersPresent {
                header.deltaFrameIDLength = 2 + (try reader.readBits(4))
                header.additionalFrameIDLength = 1 + (try reader.readBits(3))
            }
        }

        header.use128x128Superblock = try reader.readFlag()
        header.enableFilterIntra = try reader.readFlag()
        header.enableIntraEdgeFilter = try reader.readFlag()

        if !header.reducedStillPictureHeader {
            _ = try reader.readBits(4)  // inter-only compound/motion tool flags
            header.enableOrderHint = try reader.readFlag()
            if header.enableOrderHint {
                _ = try reader.readBits(2)  // jnt_comp, ref_frame_mvs
            }
            // seq_force_screen_content_tools / seq_force_integer_mv
            if try reader.readFlag() == false {
                header.forceScreenContentTools = try reader.readBit()
            }
            if header.forceScreenContentTools > 0 {
                if try reader.readFlag() == false {
                    header.forceIntegerMV = try reader.readBit()
                }
            } else {
                header.forceIntegerMV = 2
            }
            if header.enableOrderHint {
                header.orderHintBits = 1 + (try reader.readBits(3))
            }
        }

        header.enableSuperres = try reader.readFlag()
        header.enableCDEF = try reader.readFlag()
        header.enableRestoration = try reader.readFlag()

        // color_config (5.5.2)
        let highBitdepth = try reader.readFlag()
        if header.profile == 2 && highBitdepth {
            header.bitDepth = (try reader.readFlag()) ? 12 : 10
        } else {
            header.bitDepth = highBitdepth ? 10 : 8
        }
        header.monochrome = header.profile == 1 ? false : try reader.readFlag()
        if try reader.readFlag() {  // color_description_present
            header.colorPrimaries = try reader.readBits(8)
            header.transferCharacteristics = try reader.readBits(8)
            header.matrixCoefficients = try reader.readBits(8)
        }
        if header.monochrome {
            header.fullRange = try reader.readFlag()
            header.subsamplingX = 1
            header.subsamplingY = 1
        } else if header.colorPrimaries == 1, header.transferCharacteristics == 13, header.matrixCoefficients == 0 {
            // sRGB: implicitly 4:4:4 full range.
            header.fullRange = true
            header.subsamplingX = 0
            header.subsamplingY = 0
        } else {
            header.fullRange = try reader.readFlag()
            switch header.profile {
            case 0:
                header.subsamplingX = 1
                header.subsamplingY = 1
            case 1:
                header.subsamplingX = 0
                header.subsamplingY = 0
            default:
                if header.bitDepth == 12 {
                    header.subsamplingX = try reader.readBit()
                    header.subsamplingY = header.subsamplingX == 1 ? try reader.readBit() : 0
                } else {
                    header.subsamplingX = 1
                    header.subsamplingY = 0
                }
            }
            if header.subsamplingX == 1, header.subsamplingY == 1 {
                header.chromaSamplePosition = try reader.readBits(2)
            }
        }
        if !header.monochrome {
            header.separateUVDeltaQ = try reader.readFlag()
        }
        header.filmGrainPresent = try reader.readFlag()
        return header
    }
}

/// The AV1CodecConfigurationRecord from an av1C property (AV1-ISOBMFF).
struct AV1DecoderConfiguration {
    var profile = 0
    var configurationOBUs: [UInt8] = []

    init(payload: [UInt8]) throws {
        guard payload.count >= 4, payload[0] == 0x81 else {  // marker + version 1
            throw ImageError.invalidData(reason: "Unsupported AV1 decoder configuration")
        }
        profile = Int(payload[1] >> 5)
        // seq_level_idx, tier, bit depth and subsampling repeat the
        // sequence header; the header itself is authoritative. Any trailing
        // bytes are configuration OBUs to prepend to the item data.
        configurationOBUs = Array(payload.dropFirst(4))
    }
}
