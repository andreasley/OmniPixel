/// A single H.265 NAL unit: the two-byte header parsed, the payload
/// unescaped (emulation-prevention bytes removed) into RBSP form.
struct HEVCNALUnit {
    let type: Int
    let temporalID: Int
    /// Raw byte sequence payload, without the 2-byte NAL header.
    let payload: [UInt8]

    // NAL unit types used by still images.
    static let idrWithRADL = 19
    static let idrNoLeadingPictures = 20
    static let cra = 21
    static let vps = 32
    static let sps = 33
    static let pps = 34

    /// Whether this is a coded slice of an intra picture (types 16–21).
    var isIntraSlice: Bool {
        (16...21).contains(type)
    }

    /// Whether this is an intra random access point (needs the
    /// no_output_of_prior_pics_flag in its slice header).
    var isIRAP: Bool {
        (16...23).contains(type)
    }

    /// Whether the slice type carries picture order count fields
    /// (everything except plain IDR).
    var isIDR: Bool {
        type == Self.idrWithRADL || type == Self.idrNoLeadingPictures
    }

    /// Positions (in the raw payload) of removed emulation-prevention bytes.
    let escapeOffsets: [Int]

    init?(bytes: [UInt8]) {
        guard bytes.count >= 2, bytes[0] & 0x80 == 0 else {
            return nil  // forbidden_zero_bit set
        }
        type = Int(bytes[0] >> 1) & 0x3F
        temporalID = Int(bytes[1] & 0x07) - 1
        (payload, escapeOffsets) = Self.removingEmulationPrevention(Array(bytes.dropFirst(2)))
    }

    /// Maps an offset in the unescaped payload to the raw (escaped) domain.
    /// Wavefront entry points are specified in raw bytes, so substream
    /// boundaries must be converted through this mapping.
    func rawOffset(forUnescaped offset: Int) -> Int {
        var escapes = 0
        for escape in escapeOffsets {
            if escape <= offset + escapes {
                escapes += 1
            } else {
                break
            }
        }
        return offset + escapes
    }

    /// Maps a raw (escaped) payload offset back to the unescaped domain.
    func unescapedOffset(forRaw raw: Int) -> Int {
        raw - escapeOffsets.count(where: { $0 < raw })
    }

    /// Drops the 0x03 byte inserted after every 0x00 0x00 in the raw stream,
    /// remembering where the removed bytes were.
    private static func removingEmulationPrevention(_ input: [UInt8]) -> ([UInt8], [Int]) {
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var escapes: [Int] = []
        var zeroRun = 0
        for (index, byte) in input.enumerated() {
            if zeroRun >= 2, byte == 3 {
                escapes.append(index)
                zeroRun = 0
                continue
            }
            output.append(byte)
            zeroRun = byte == 0 ? zeroRun + 1 : 0
        }
        return (output, escapes)
    }
}

/// Reads an RBSP most-significant-bit first, including the Exp-Golomb codes
/// (ue(v)/se(v)) that H.265 headers are built from.
struct HEVCBitReader {
    private let bytes: [UInt8]
    private(set) var bitPosition = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var bitsRemaining: Int {
        bytes.count * 8 - bitPosition
    }

    mutating func readBit() throws -> Int {
        let byteIndex = bitPosition >> 3
        guard byteIndex < bytes.count else {
            throw ImageError.invalidData(reason: "HEVC bitstream ended early")
        }
        let bit = Int(bytes[byteIndex] >> (7 - (bitPosition & 7))) & 1
        bitPosition += 1
        return bit
    }

    mutating func readFlag() throws -> Bool {
        try readBit() == 1
    }

    mutating func readBits(_ count: Int) throws -> Int {
        var value = 0
        for _ in 0..<count {
            value = value << 1 | (try readBit())
        }
        return value
    }

    /// ue(v): unsigned Exp-Golomb.
    mutating func readUnsignedExpGolomb() throws -> Int {
        var leadingZeros = 0
        while try readBit() == 0 {
            leadingZeros += 1
            guard leadingZeros <= 31 else {
                throw ImageError.invalidData(reason: "Invalid HEVC Exp-Golomb code")
            }
        }
        guard leadingZeros > 0 else {
            return 0
        }
        return (1 << leadingZeros) - 1 + (try readBits(leadingZeros))
    }

    /// se(v): signed Exp-Golomb (1 → 1, 2 → −1, 3 → 2, 4 → −2, …).
    mutating func readSignedExpGolomb() throws -> Int {
        let code = try readUnsignedExpGolomb()
        let magnitude = (code + 1) / 2
        return code % 2 == 1 ? magnitude : -magnitude
    }

    mutating func alignToByte() {
        bitPosition = (bitPosition + 7) & ~7
    }
}
