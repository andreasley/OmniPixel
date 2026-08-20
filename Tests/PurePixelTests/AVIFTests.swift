import Foundation
import Testing
@testable import PurePixel

@Suite("AVIF")
struct AVIFTests {
    /// A 33×21 lossless AVIF (avifenc --lossless, identity matrix) of the
    /// gradient r = 7x, g = 11y, b = 3(x+y) — decoding must reproduce it
    /// exactly.
    private static let losslessAVIF: [UInt8] = [
        0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66, 0x00, 0x00, 0x00, 0x00,
        0x61, 0x76, 0x69, 0x66, 0x6D, 0x69, 0x66, 0x31, 0x6D, 0x69, 0x61, 0x66, 0x4D, 0x41, 0x31, 0x41,
        0x00, 0x00, 0x01, 0x2C, 0x6D, 0x65, 0x74, 0x61, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21,
        0x68, 0x64, 0x6C, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x70, 0x69, 0x63, 0x74,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x0E, 0x70, 0x69, 0x74, 0x6D, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x2C, 0x69,
        0x6C, 0x6F, 0x63, 0x00, 0x00, 0x00, 0x00, 0x44, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x01, 0x9C, 0x00, 0x00, 0x01, 0x62, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x00, 0x01, 0x54, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x41, 0x69, 0x69, 0x6E, 0x66, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x1A, 0x69, 0x6E, 0x66, 0x65, 0x02, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x00, 0x61, 0x76, 0x30, 0x31, 0x43, 0x6F, 0x6C, 0x6F, 0x72, 0x00, 0x00,
        0x00, 0x00, 0x19, 0x69, 0x6E, 0x66, 0x65, 0x02, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x45,
        0x78, 0x69, 0x66, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00, 0x00, 0x00, 0x1A, 0x69, 0x72, 0x65, 0x66,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0E, 0x63, 0x64, 0x73, 0x63, 0x00, 0x02, 0x00, 0x01,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x6A, 0x69, 0x70, 0x72, 0x70, 0x00, 0x00, 0x00, 0x4B, 0x69, 0x70,
        0x63, 0x6F, 0x00, 0x00, 0x00, 0x14, 0x69, 0x73, 0x70, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x21, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00, 0x10, 0x70, 0x69, 0x78, 0x69, 0x00, 0x00,
        0x00, 0x00, 0x03, 0x08, 0x08, 0x08, 0x00, 0x00, 0x00, 0x0C, 0x61, 0x76, 0x31, 0x43, 0x81, 0x20,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x13, 0x63, 0x6F, 0x6C, 0x72, 0x6E, 0x63, 0x6C, 0x78, 0x00, 0x01,
        0x00, 0x0D, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x17, 0x69, 0x70, 0x6D, 0x61, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x04, 0x01, 0x02, 0x83, 0x04, 0x00, 0x00, 0x01, 0xB2,
        0x6D, 0x64, 0x61, 0x74, 0x00, 0x00, 0x00, 0x00, 0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,
        0x00, 0x01, 0x87, 0x69, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1A, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x03, 0xA0, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0xA0, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x21, 0xA0, 0x03, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00, 0x00, 0x12, 0x00, 0x0A, 0x08,
        0x38, 0x15, 0x20, 0xA3, 0x08, 0x08, 0x68, 0x01, 0x32, 0xD3, 0x02, 0x10, 0x00, 0x00, 0xED, 0xFB,
        0x4F, 0x21, 0x7C, 0x8B, 0xEE, 0x1D, 0xD6, 0x9E, 0xCE, 0x23, 0x58, 0x56, 0x9B, 0xC0, 0x06, 0xE2,
        0x9A, 0xCE, 0x25, 0x23, 0xB4, 0x79, 0xEF, 0xAC, 0xDE, 0x96, 0xEB, 0x21, 0xA4, 0xA9, 0x6E, 0x21,
        0xA0, 0x31, 0xE1, 0x44, 0x43, 0xEB, 0xE7, 0xD4, 0x8C, 0x64, 0x0F, 0x2F, 0x23, 0xC3, 0xC9, 0x61,
        0x26, 0xE6, 0x71, 0x35, 0x80, 0xC1, 0xA6, 0xAE, 0x2F, 0x18, 0xE9, 0x34, 0xAA, 0xFE, 0x28, 0xC6,
        0x89, 0x8F, 0x8D, 0xF4, 0xEA, 0x2F, 0x9C, 0x3E, 0x9E, 0xCE, 0x0F, 0xBB, 0x55, 0x7A, 0x94, 0x49,
        0xB5, 0xE2, 0x28, 0x80, 0x1A, 0x33, 0xA7, 0x9B, 0x74, 0xDB, 0xFA, 0x31, 0x7C, 0x82, 0xDD, 0x14,
        0x1C, 0x15, 0x46, 0x5A, 0x2C, 0x5E, 0x4B, 0x7A, 0x03, 0x31, 0x41, 0x7E, 0x40, 0x13, 0xC7, 0xAE,
        0xF5, 0x6C, 0xC6, 0x69, 0xFD, 0xBE, 0x84, 0xE2, 0xA4, 0x51, 0xB6, 0x8C, 0x97, 0x5C, 0x7F, 0xF8,
        0xA8, 0x6D, 0xEB, 0x7A, 0x96, 0x08, 0xBD, 0x1F, 0x36, 0x16, 0x56, 0xE7, 0x0A, 0x8C, 0x73, 0x72,
        0x84, 0x84, 0x1C, 0xE3, 0x29, 0x18, 0xE2, 0xEE, 0xFC, 0x41, 0x6B, 0xB9, 0xB0, 0x3C, 0x92, 0x67,
        0x90, 0xB2, 0x34, 0x39, 0x70, 0x4C, 0x7A, 0x27, 0x63, 0x43, 0xCA, 0x29, 0x7C, 0x84, 0x5E, 0xDE,
        0x7E, 0x36, 0xD0, 0x7D, 0xEE, 0x12, 0xB9, 0x8F, 0x58, 0xE2, 0xFF, 0xDD, 0x72, 0x34, 0x93, 0x32,
        0x50, 0x8C, 0x77, 0x7C, 0x6B, 0xC6, 0x72, 0x6D, 0x0F, 0x05, 0x66, 0x2D, 0xE1, 0xD1, 0x3C, 0x48,
        0x02, 0xA0, 0xA3, 0xB9, 0xEC, 0x95, 0x7D, 0x72, 0x92, 0xF6, 0xDA, 0x7F, 0xDD, 0x9E, 0x3F, 0xD0,
        0x5C, 0x3F, 0x4C, 0xBD, 0xCD, 0x79, 0x61, 0x14, 0x9D, 0x17, 0x5D, 0xD6, 0x08, 0x6D, 0x10, 0x20,
        0x8D, 0x4E, 0xC1, 0xB5, 0xAD, 0xD7, 0x0C, 0x45, 0xE9, 0x5E, 0xE6, 0x7F, 0x53, 0x48, 0xF1, 0x42,
        0x0E, 0xCD, 0x67, 0xFC, 0xCE, 0x7A, 0xAF, 0xAE, 0x9D, 0xF5, 0x49, 0x27, 0xAD, 0xC1, 0x53, 0x9F,
        0x5B, 0xBE, 0xA5, 0x51, 0x7B, 0x03, 0x5F, 0x61, 0xA9, 0x50, 0xDA, 0x69, 0xB0, 0x6A, 0x54, 0x1B,
        0x5E, 0xE3, 0x52, 0xC7, 0x4D, 0x67, 0xF0, 0x72, 0xDA, 0x59, 0xA5, 0xE5, 0x1F, 0x56, 0x1F, 0x9E,
        0x1B, 0x18, 0x07, 0xAE, 0x28, 0x77, 0xDF, 0xB7, 0xC6, 0x8B, 0xF2, 0x85, 0x76, 0xD5, 0x2D, 0x7A,
        0x15, 0x43, 0x74, 0xA9, 0x1C, 0xEF, 0xBA, 0x70, 0x73, 0x53, 0x39, 0xC9, 0xC2, 0x8F,
    ]

    /// A real 64×48 4:2:0 AVIF produced by avifenc 1.4.2 (libaom).
    private static let sampleAVIF: [UInt8] = [
        0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66, 0x00, 0x00, 0x00, 0x00, 0x61, 0x76, 0x69, 0x66, 0x6d, 0x69, 0x66, 0x31, 0x6d, 0x69, 0x61, 0x66, 0x4d, 0x41, 0x31, 0x42,
        0x00, 0x00, 0x00, 0xeb, 0x6d, 0x65, 0x74, 0x61, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x68, 0x64, 0x6c, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x70, 0x69, 0x63, 0x74,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0e, 0x70, 0x69, 0x74, 0x6d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1e, 0x69,
        0x6c, 0x6f, 0x63, 0x00, 0x00, 0x00, 0x00, 0x44, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x13, 0x00, 0x00, 0x00, 0xd5, 0x00, 0x00, 0x00, 0x28, 0x69, 0x69, 0x6e,
        0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1a, 0x69, 0x6e, 0x66, 0x65, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x61, 0x76, 0x30, 0x31, 0x43, 0x6f, 0x6c, 0x6f, 0x72,
        0x00, 0x00, 0x00, 0x00, 0x6a, 0x69, 0x70, 0x72, 0x70, 0x00, 0x00, 0x00, 0x4b, 0x69, 0x70, 0x63, 0x6f, 0x00, 0x00, 0x00, 0x14, 0x69, 0x73, 0x70, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x40, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00, 0x10, 0x70, 0x69, 0x78, 0x69, 0x00, 0x00, 0x00, 0x00, 0x03, 0x08, 0x08, 0x08, 0x00, 0x00, 0x00, 0x0c, 0x61, 0x76, 0x31, 0x43, 0x81, 0x00, 0x0c,
        0x00, 0x00, 0x00, 0x00, 0x13, 0x63, 0x6f, 0x6c, 0x72, 0x6e, 0x63, 0x6c, 0x78, 0x00, 0x01, 0x00, 0x0d, 0x00, 0x06, 0x80, 0x00, 0x00, 0x00, 0x17, 0x69, 0x70, 0x6d, 0x61, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x04, 0x01, 0x02, 0x83, 0x04, 0x00, 0x00, 0x00, 0xdd, 0x6d, 0x64, 0x61, 0x74, 0x12, 0x00, 0x0a, 0x09, 0x18, 0x15, 0x7f, 0xbd, 0xa2, 0x02, 0x1a, 0x0d, 0x08,
        0x32, 0xc5, 0x01, 0x17, 0x87, 0x87, 0x86, 0x21, 0x84, 0x92, 0x49, 0x26, 0x55, 0x00, 0x00, 0x00, 0xc2, 0x0f, 0x99, 0x41, 0x1a, 0xb6, 0x1d, 0x72, 0x79, 0x25, 0x51, 0xb6, 0x41, 0x28, 0xa7, 0xc4,
        0x66, 0x42, 0xb6, 0x60, 0x78, 0x1b, 0x24, 0x27, 0x57, 0xc7, 0xae, 0xac, 0xca, 0x75, 0x4a, 0xaa, 0x6b, 0xff, 0xac, 0xe8, 0x83, 0xfd, 0x70, 0xfc, 0x2f, 0xac, 0xc9, 0x5e, 0xc3, 0x23, 0xa1, 0x07,
        0x52, 0xa9, 0x51, 0x8e, 0x27, 0x40, 0x76, 0x36, 0x84, 0x20, 0xb2, 0xa6, 0x38, 0x5b, 0x61, 0x1b, 0x26, 0x7c, 0xd6, 0x50, 0x50, 0x0c, 0x1b, 0x3d, 0x5c, 0x94, 0x28, 0x05, 0xa4, 0xd0, 0xa0, 0x8b,
        0x9c, 0x92, 0x94, 0xd7, 0xbf, 0x28, 0x88, 0xb6, 0x3f, 0x6d, 0xa4, 0xe9, 0x35, 0x98, 0x49, 0x9c, 0x2c, 0xcc, 0x4e, 0x37, 0xcf, 0xe2, 0x81, 0x00, 0x27, 0xe3, 0xac, 0xc0, 0x6f, 0x47, 0x2f, 0x00,
        0x74, 0x7a, 0xe4, 0xa5, 0x39, 0x94, 0x25, 0xac, 0x3b, 0x55, 0xa1, 0x94, 0xce, 0x6c, 0x7c, 0x87, 0xec, 0x70, 0xd9, 0x3d, 0xab, 0xa3, 0xfb, 0x62, 0xde, 0xef, 0x30, 0x41, 0x1c, 0x40, 0x54, 0xef,
        0xce, 0xb5, 0xd2, 0x05, 0x4a, 0x47, 0xe7, 0x80, 0x98, 0x35, 0x60, 0x83, 0x9f, 0xa0, 0xc7, 0x66, 0x4a, 0xe6, 0x6b, 0xa3, 0x09, 0x1f, 0x7f, 0xaf, 0x1b, 0x31, 0x6c, 0x82, 0x18, 0xf7, 0x18, 0x38,
        0x7b, 0x3d, 0x71, 0x0a, 0x05, 0x3e, 0x6c, 0xe0,    ]

    @Test func detectsAndParsesRealAVIF() throws {
        let data = Data(Self.sampleAVIF)
        #expect(ImageFormat(detecting: data) == .avif)
        #expect(AVIFCodec.canDecode(data))
        #expect(!HEICCodec.canDecode(data))  // shares mif1, must not be claimed

        let stream = try AVIFCodec.parseStream(from: data)
        #expect(stream.displayWidth == 64)
        #expect(stream.displayHeight == 48)
        let header = stream.sequenceHeader
        #expect(header.profile == 0)
        #expect(header.bitDepth == 8)
        #expect(header.stillPicture)
        #expect(header.reducedStillPictureHeader)
        #expect(!header.monochrome)
        #expect(header.subsamplingX == 1)
        #expect(header.subsamplingY == 1)
        #expect(header.colorPrimaries == 1)
        #expect(header.transferCharacteristics == 13)
        #expect(header.matrixCoefficients == 6)
        #expect(header.fullRange)
        #expect(!header.filmGrainPresent)
        // Temporal delimiter, sequence header, frame.
        #expect(stream.obus.map(\.type) == [2, 1, 6])
    }

    @Test func parsesFrameHeaderOfRealAVIF() throws {
        let stream = try AVIFCodec.parseStream(from: Data(Self.sampleAVIF))
        let header = stream.frameHeader
        #expect(header.frameWidth == 64)
        #expect(header.frameHeight == 48)
        #expect(header.baseQIndex == 120)
        #expect(!header.codedLossless)
        #expect(!header.segmentationEnabled)
        #expect(header.deltaQPresent)
        #expect(header.deltaQRes == 2)
        #expect(header.loopFilterLevel == [9, 9, 9, 9])
        #expect(header.cdefBits == 1)
        #expect(header.cdefDamping == 4)
        #expect(header.cdefYPrimary[0] == 5)
        #expect(header.restorationType == [0, 0, 0])
        #expect(!header.txModeSelect)
        #expect(!header.reducedTxSet)
        #expect(!header.allowIntrabc)
        #expect(header.tiles.columnCount == 1)
        #expect(header.tiles.rowCount == 1)
        #expect(stream.tileGroup.tiles.map(\.count) == [184])
    }

    @Test func decodesTileSyntaxOfRealAVIF() throws {
        // The full symbol layer of the embedded fixture: superblock
        // partitioning, intra modes, transform sizes and coefficients,
        // through the exit_symbol trailing-bit check. The pinned values
        // are internally consistent (each block's transform size matches
        // its block size) and stable against any entropy-decoding change.
        let stream = try AVIFCodec.parseStream(from: Data(Self.sampleAVIF))
        let decoders = try AVIFCodec.decodeTiles(stream: stream)
        let tile = try #require(decoders.first)

        #expect(tile.blocks.count == 8)
        #expect(tile.blocks.map(\.size) == [9, 9, 8, 6, 3, 3, 3, 3])
        #expect(tile.blocks.map(\.yMode) == [0, 12, 2, 2, 2, 2, 1, 2])
        #expect(tile.blocks.map(\.uvMode) == [13, 13, 13, 2, 2, 2, 1, 2])
        #expect(tile.blocks.map(\.txSize) == [3, 3, 10, 2, 1, 1, 1, 1])
        #expect(tile.blocks.allSatisfy { !$0.skip })

        #expect(tile.transformBlocks.count == 22)
        #expect(tile.transformBlocks.map(\.eob).reduce(0, +) == 969)
        let first = try #require(tile.transformBlocks.first)
        #expect(first.plane == 0)
        #expect(first.txSize == 3)
        #expect(first.eob == 78)
        #expect(Array(first.quant.prefix(4)) == [-120, -41, 0, -5])
        #expect(tile.restorationUnits.isEmpty)
    }

    @Test func decodesLosslessAVIFExactly() throws {
        // Lossless AV1 codes with the Walsh-Hadamard transform, no loop
        // filters and the identity color matrix, so the full decode
        // pipeline must reproduce the source pixels bit-exactly.
        let image = try Image(data: Data(Self.losslessAVIF))
        #expect(image.width == 33)
        #expect(image.height == 21)
        var mismatches = 0
        for y in 0..<21 {
            for x in 0..<33 {
                let expected = RGBA(
                    red: UInt8((x * 7) & 255),
                    green: UInt8((y * 11) & 255),
                    blue: UInt8(((x + y) * 3) & 255)
                )
                if image[x, y] != expected {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0)
    }

    @Test func decodesRealAVIFEndToEnd() throws {
        // The embedded fixture uses the avifenc defaults: quantizer
        // matrices, deblocking and CDEF are all active. The pinned YUV
        // samples are sample-exact against avifdec (dav1d), pinned during
        // oracle validation.
        let stream = try AVIFCodec.parseStream(from: Data(Self.sampleAVIF))
        let frame = try AVIFCodec.decodeFrame(stream: stream)
        let lumaSamples = [(0, 0), (63, 0), (0, 47), (63, 47), (32, 24), (17, 5)]
            .map { frame.sample(0, $0.1, $0.0) }
        #expect(lumaSamples == [2, 26, 50, 72, 153, 49])
        #expect([(0, 0), (31, 23), (16, 11)].map { frame.sample(1, $0.1, $0.0) } == [126, 150, 75])
        #expect([(0, 0), (31, 23), (16, 11)].map { frame.sample(2, $0.1, $0.0) } == [128, 119, 138])

        let image = try Image(data: Data(Self.sampleAVIF))
        #expect(image.width == 64)
        #expect(image.height == 48)
        #expect(image[0, 0] == RGBA(red: 2, green: 3, blue: 0))
        #expect(image[32, 24] == RGBA(red: 160, green: 169, blue: 52))
        #expect(image[63, 47] == RGBA(red: 59, green: 71, blue: 111))
    }

    @Test func avifEncodingIsUnsupported() {
        let image = Image(width: 2, height: 2, fill: .white)
        #expect(throws: ImageError.self) {
            _ = try image.encoded(as: .avif)
        }
    }

    @Test func symbolDecoderRoundTrip() throws {
        // Randomized multi-symbol round-trip: the test encoder mirrors the
        // decoder's interval arithmetic, both sides adapt their own CDF
        // copies, and every decoded symbol and the final CDF states must
        // match. Exercises adaptation across all rate stages (the counter
        // saturates at 32), bools, and literals.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func random() -> UInt64 {
            seed &+= 0x9E3779B97F4A7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        // Random monotone CDFs of assorted sizes.
        func makeCDF(_ symbolCount: Int) -> [UInt16] {
            var weights = (0..<symbolCount).map { _ in Int(random() % 1000) + 1 }
            let total = weights.reduce(0, +)
            var cdf = [UInt16]()
            var running = 0
            for i in 0..<symbolCount {
                running += weights[i]
                let value = i == symbolCount - 1 ? 32768 : max(1, min(32767, running * 32768 / total))
                cdf.append(UInt16(max(value, cdf.last.map(Int.init) ?? 0)))
            }
            cdf.append(0)  // adaptation counter
            weights.removeAll()
            return cdf
        }
        let sizes = [2, 3, 4, 6, 8, 13, 16]
        var encoderCDFs = sizes.map(makeCDF)
        var decoderCDFs = encoderCDFs

        enum Operation {
            case symbol(table: Int, value: Int)
            case literal(bits: Int, value: Int)
        }
        var operations: [Operation] = []
        var encoder = TestAV1SymbolEncoder()
        for _ in 0..<20000 {
            if random() % 4 == 0 {
                let bits = Int(random() % 8) + 1
                let value = Int(random() % (1 << UInt64(bits)))
                encoder.encodeLiteral(value, bits: bits)
                operations.append(.literal(bits: bits, value: value))
            } else {
                let table = Int(random() % UInt64(sizes.count))
                let value = Int(random() % UInt64(sizes[table]))
                encoder.encodeSymbol(value, cdf: &encoderCDFs[table])
                operations.append(.symbol(table: table, value: value))
            }
        }
        let bytes = encoder.finish()

        var decoder = try AV1SymbolDecoder(bytes: bytes, count: bytes.count)
        for (index, operation) in operations.enumerated() {
            switch operation {
            case .symbol(let table, let value):
                let decoded = decoder.readSymbol(&decoderCDFs[table])
                if decoded != value {
                    Issue.record("Symbol mismatch at operation \(index): \(decoded) != \(value)")
                    return
                }
            case .literal(let bits, let value):
                let decoded = decoder.readLiteral(bits)
                if decoded != value {
                    Issue.record("Literal mismatch at operation \(index): \(decoded) != \(value)")
                    return
                }
            }
        }
        #expect(encoderCDFs == decoderCDFs)
    }

    #if os(macOS)
    @Test func parsesFreshAVIFVariantsFromBundledEncoder() throws {
        // The repository bundles avifenc (libavif); when present, exercise
        // the parser against fresh encoder output in several color
        // configurations. Skipped silently where the binary can't run.
        guard let encoder = Self.bundledEncoderPath() else { return }

        var source = Image(width: 33, height: 21)
        for y in 0..<21 {
            for x in 0..<33 {
                source[x, y] = RGBA(red: UInt8(x * 7), green: UInt8(y * 11), blue: UInt8((x + y) * 3))
            }
        }
        let directory = FileManager.default.temporaryDirectory
        let pngURL = directory.appendingPathComponent("purepixel-avif-source.png")
        try source.encoded(as: .png).write(to: pngURL)

        for (arguments, expectedDepth, expectedMono) in [
            (["-s", "8", "-y", "420"], 8, false),
            (["-s", "8", "-y", "444", "-d", "10"], 10, false),
            (["-s", "8", "-y", "400"], 8, true),
            // Speed 0 turns on loop restoration, covering the Wiener and
            // self-guided parameter syntax.
            (["-s", "0", "-y", "420"], 8, false),
        ] {
            let outputURL = directory.appendingPathComponent("purepixel-avif-out.avif")
            try? FileManager.default.removeItem(at: outputURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: encoder)
            process.arguments = ["-q", "60"] + arguments + [pngURL.path, outputURL.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)

            let data = try Data(contentsOf: outputURL)
            #expect(ImageFormat(detecting: data) == .avif)
            let stream = try AVIFCodec.parseStream(from: data)
            #expect(stream.displayWidth == 33)
            #expect(stream.displayHeight == 21)
            #expect(stream.sequenceHeader.bitDepth == expectedDepth)
            #expect(stream.sequenceHeader.monochrome == expectedMono)

            // The whole tile syntax layer must decode to clean
            // exit_symbol termination.
            let decoders = try AVIFCodec.decodeTiles(stream: stream)
            #expect(!decoders.isEmpty)
            #expect(decoders.allSatisfy { !$0.blocks.isEmpty })

            // And the full pipeline (reconstruction + loop filters) must
            // produce an image at the right size.
            let image = try Image(data: data)
            #expect(image.width == 33)
            #expect(image.height == 21)
        }

        // Alpha: an RGBA source must round-trip its alpha channel through
        // the auxiliary alpha item.
        var alphaSource = Image(width: 33, height: 21)
        for y in 0..<21 {
            for x in 0..<33 {
                alphaSource[x, y] = RGBA(
                    red: UInt8(x * 7), green: UInt8(y * 11), blue: UInt8((x + y) * 3),
                    alpha: UInt8(x * 255 / 32)
                )
            }
        }
        let alphaPNG = directory.appendingPathComponent("purepixel-avif-alpha.png")
        try alphaSource.encoded(as: .png).write(to: alphaPNG)
        let alphaURL = directory.appendingPathComponent("purepixel-avif-alpha.avif")
        try? FileManager.default.removeItem(at: alphaURL)
        let alphaProcess = Process()
        alphaProcess.executableURL = URL(fileURLWithPath: encoder)
        alphaProcess.arguments = ["-q", "80", "-y", "444", alphaPNG.path, alphaURL.path]
        alphaProcess.standardOutput = Pipe()
        alphaProcess.standardError = Pipe()
        try alphaProcess.run()
        alphaProcess.waitUntilExit()
        try #require(alphaProcess.terminationStatus == 0)
        let alphaImage = try Image(data: Data(contentsOf: alphaURL))
        #expect(alphaImage.width == 33)
        var maxAlphaDiff = 0
        for y in 0..<21 {
            for x in 0..<33 {
                maxAlphaDiff = max(maxAlphaDiff, abs(Int(alphaImage[x, y].alpha) - Int(alphaSource[x, y].alpha)))
            }
        }
        #expect(maxAlphaDiff <= 8, "alpha diverges by \(maxAlphaDiff)")

        // Grid: a multi-item tiled AVIF composites to the declared size.
        var gridSource = Image(width: 128, height: 96)
        for y in 0..<96 {
            for x in 0..<128 {
                gridSource[x, y] = RGBA(red: UInt8(x * 2), green: UInt8(255 - x * 2), blue: UInt8(y * 2))
            }
        }
        let gridPNG = directory.appendingPathComponent("purepixel-avif-grid.png")
        try gridSource.encoded(as: .png).write(to: gridPNG)
        let gridURL = directory.appendingPathComponent("purepixel-avif-grid.avif")
        try? FileManager.default.removeItem(at: gridURL)
        let gridProcess = Process()
        gridProcess.executableURL = URL(fileURLWithPath: encoder)
        gridProcess.arguments = ["-q", "70", "--grid", "2x2", gridPNG.path, gridURL.path]
        gridProcess.standardOutput = Pipe()
        gridProcess.standardError = Pipe()
        try gridProcess.run()
        gridProcess.waitUntilExit()
        try #require(gridProcess.terminationStatus == 0)
        let gridData = try Data(contentsOf: gridURL)
        #expect(gridData.range(of: Data("grid".utf8)) != nil)
        let gridImage = try Image(data: gridData)
        #expect(gridImage.width == 128)
        #expect(gridImage.height == 96)
        var gridSumSquared = 0.0
        for y in 0..<96 {
            for x in 0..<128 {
                let a = gridImage[x, y]
                let b = gridSource[x, y]
                for (u, v) in [(a.red, b.red), (a.green, b.green), (a.blue, b.blue)] {
                    let diff = Double(Int(u) - Int(v))
                    gridSumSquared += diff * diff
                }
            }
        }
        let gridMSE = gridSumSquared / Double(128 * 96 * 3)
        let gridPSNR = gridMSE == 0 ? 99 : 10 * (log10(255.0 * 255.0) - log10(gridMSE))
        #expect(gridPSNR > 32, "grid PSNR \(gridPSNR) too low")

        // A fresh lossless encode must decode back to the source exactly.
        let losslessURL = directory.appendingPathComponent("purepixel-avif-lossless.avif")
        try? FileManager.default.removeItem(at: losslessURL)
        let losslessProcess = Process()
        losslessProcess.executableURL = URL(fileURLWithPath: encoder)
        losslessProcess.arguments = ["--lossless", pngURL.path, losslessURL.path]
        losslessProcess.standardOutput = Pipe()
        losslessProcess.standardError = Pipe()
        try losslessProcess.run()
        losslessProcess.waitUntilExit()
        try #require(losslessProcess.terminationStatus == 0)
        let losslessImage = try Image(data: Data(contentsOf: losslessURL))
        #expect(losslessImage.width == source.width)
        #expect(losslessImage.height == source.height)
        var mismatches = 0
        for y in 0..<source.height {
            for x in 0..<source.width where losslessImage[x, y] != source[x, y] {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)

        // A lossy encode without in-loop filters must decode to an image
        // close to the source (reconstruction is oracle-validated
        // sample-exactly against avifdec during bring-up).
        let lossyURL = directory.appendingPathComponent("purepixel-avif-nofilter.avif")
        try? FileManager.default.removeItem(at: lossyURL)
        let lossyProcess = Process()
        lossyProcess.executableURL = URL(fileURLWithPath: encoder)
        lossyProcess.arguments = [
            "-q", "95", "-y", "444",
            "-a", "enable-cdef=0", "-a", "enable-restoration=0", "-a", "enable-qm=0",
            pngURL.path, lossyURL.path,
        ]
        lossyProcess.standardOutput = Pipe()
        lossyProcess.standardError = Pipe()
        try lossyProcess.run()
        lossyProcess.waitUntilExit()
        try #require(lossyProcess.terminationStatus == 0)
        let lossyImage = try Image(data: Data(contentsOf: lossyURL))
        #expect(lossyImage.width == source.width)
        var sumSquared = 0.0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let a = lossyImage[x, y]
                let b = source[x, y]
                for (u, v) in [(a.red, b.red), (a.green, b.green), (a.blue, b.blue)] {
                    let diff = Double(Int(u) - Int(v))
                    sumSquared += diff * diff
                }
            }
        }
        let mse = sumSquared / Double(source.width * source.height * 3)
        let psnr = mse == 0 ? 99 : 10 * (log10(255.0 * 255.0) - log10(mse))
        #expect(psnr > 38, "PSNR \(psnr) too low for the no-filter lossy decode")
    }

    private static func bundledEncoderPath() -> String? {
        // Tests/PurePixelTests/AVIFTests.swift → repository root → libavif.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent("libavif/avifenc").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    #endif
}

/// An AV1 multi-symbol range encoder derived from the decoder's interval
/// arithmetic, for round-trip validation only. The decoder's value register
/// is the complement of the bit window, which makes intervals run from the
/// top of the range: encoding a symbol adds `range − cur(symbol − 1)` to
/// the interval's lower bound. The bound is kept exactly, as the bit array
/// itself — additions ripple-carry as far as needed and renormalization
/// simply appends a fractional zero bit — so there is no low-window
/// alignment to get wrong.
private struct TestAV1SymbolEncoder {
    /// The interval's lower bound: bits[i] has weight 2^(count - 1 − i).
    private var bits = [Int](repeating: 0, count: 15)
    private var range = 1 << 15

    mutating func encodeSymbol(_ symbol: Int, cdf: inout [UInt16], adapt: Bool = true) {
        let n = cdf.count - 1
        func cur(_ index: Int) -> Int {
            if index < 0 { return range }
            let f = (1 << 15) - Int(cdf[index])
            let scaled = ((range >> 8) * (f >> AV1SymbolDecoder.probabilityShift))
                >> (7 - AV1SymbolDecoder.probabilityShift)
            return scaled + AV1SymbolDecoder.minimumProbability * (n - index - 1)
        }
        let top = cur(symbol - 1)
        let bottom = cur(symbol)
        add(range - top)
        range = top - bottom
        if adapt {
            AV1SymbolDecoder.updateCDF(&cdf, symbol: symbol)
        }
        while range < (1 << 15) {
            range <<= 1
            bits.append(0)
        }
    }

    mutating func encodeBool(_ bit: Int) {
        var cdf: [UInt16] = [1 << 14, 1 << 15, 0]
        encodeSymbol(bit, cdf: &cdf, adapt: false)
    }

    mutating func encodeLiteral(_ value: Int, bits: Int) {
        for shift in stride(from: bits - 1, through: 0, by: -1) {
            encodeBool((value >> shift) & 1)
        }
    }

    /// Packs the lower bound into bytes; the decoder's zero padding keeps
    /// the read value inside the final interval.
    func finish() -> [UInt8] {
        var bytes = [UInt8]()
        for start in stride(from: 0, to: bits.count, by: 8) {
            var byte = 0
            for i in 0..<8 {
                byte = byte << 1 | (start + i < bits.count ? bits[start + i] : 0)
            }
            bytes.append(UInt8(byte))
        }
        return bytes
    }

    /// Adds an integer aligned at the current least significant bit.
    private mutating func add(_ amount: Int) {
        var carry = amount
        var index = bits.count - 1
        while carry > 0 && index >= 0 {
            let total = bits[index] + (carry & 1)
            bits[index] = total & 1
            carry = (carry >> 1) + (total >> 1)
            index -= 1
        }
    }
}
