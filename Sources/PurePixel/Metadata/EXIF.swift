import Foundation

/// A rational number as stored in EXIF metadata.
public struct EXIFRational: Hashable, Sendable {
    public var numerator: Int
    public var denominator: Int

    public init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public var doubleValue: Double? {
        denominator == 0 ? nil : Double(numerator) / Double(denominator)
    }
}

/// A single EXIF field value, preserving its TIFF storage type so metadata
/// can be written back exactly as it was read.
public enum EXIFValue: Hashable, Sendable {
    case byte([UInt8])
    case ascii(String)
    case short([Int])
    case long([Int])
    case rational([EXIFRational])
    case undefined([UInt8])
    case signedLong([Int])
    case signedRational([EXIFRational])
    case double([Double])

    public var intValue: Int? {
        switch self {
        case .short(let values), .long(let values), .signedLong(let values):
            values.first
        case .byte(let values):
            values.first.map(Int.init)
        default:
            nil
        }
    }

    public var stringValue: String? {
        if case .ascii(let string) = self { string } else { nil }
    }

    public var rationalValue: EXIFRational? {
        switch self {
        case .rational(let values), .signedRational(let values):
            values.first
        default:
            nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let values):
            values.first
        case .rational(let values), .signedRational(let values):
            values.first?.doubleValue
        case .short(let values), .long(let values), .signedLong(let values):
            values.first.map(Double.init)
        case .byte(let values):
            values.first.map(Double.init)
        default:
            nil
        }
    }
}

/// Well-known EXIF tag numbers for use with EXIFData's tag dictionaries.
public enum EXIFTag {
    // Main image (IFD0) tags.
    public static let imageDescription = 270
    public static let cameraMake = 271
    public static let cameraModel = 272
    public static let orientation = 274
    public static let software = 305
    public static let dateTime = 306
    public static let artist = 315
    public static let copyright = 33432
    static let exifIFDPointer = 34665
    static let gpsIFDPointer = 34853

    // Photography (Exif sub-IFD) tags.
    public static let exposureTime = 33434
    public static let fNumber = 33437
    public static let isoSpeed = 34855
    public static let dateTimeOriginal = 36867
    public static let dateTimeDigitized = 36868
    public static let focalLength = 37386
    public static let userComment = 37510
    public static let lensModel = 42036

    // GPS sub-IFD tags.
    public static let gpsLatitudeReference = 1
    public static let gpsLatitude = 2
    public static let gpsLongitudeReference = 3
    public static let gpsLongitude = 4
    public static let gpsAltitudeReference = 5
    public static let gpsAltitude = 6
}

/// How stored pixels must be transformed for upright display (EXIF tag 274).
/// Cases are named after where the stored image's row 0 and column 0 sit in
/// the captured scene.
public enum EXIFOrientation: Int, Hashable, Sendable {
    case topLeft = 1      // upright
    case topRight = 2     // mirrored horizontally
    case bottomRight = 3  // rotated 180°
    case bottomLeft = 4   // mirrored vertically
    case leftTop = 5      // transposed
    case rightTop = 6     // needs a 90° clockwise turn
    case rightBottom = 7  // transversed
    case leftBottom = 8   // needs a 270° clockwise turn
}

extension Image {
    /// Returns the image transformed for upright display, given the EXIF
    /// orientation describing how its pixels are stored.
    public func oriented(by orientation: EXIFOrientation) -> Image {
        switch orientation {
        case .topLeft: self
        case .topRight: mirrored(across: .horizontal)
        case .bottomRight: rotated(by: .clockwise180)
        case .bottomLeft: mirrored(across: .vertical)
        case .leftTop: rotated(by: .clockwise90).mirrored(across: .horizontal)
        case .rightTop: rotated(by: .clockwise90)
        case .rightBottom: rotated(by: .clockwise90).mirrored(across: .vertical)
        case .leftBottom: rotated(by: .clockwise270)
        }
    }
}

/// EXIF metadata: the tags of the main image, the photography sub-IFD and
/// the GPS sub-IFD, keyed by tag number (see `EXIFTag`).
public struct EXIFData: Hashable, Sendable {
    public var tags: [Int: EXIFValue]
    public var photoTags: [Int: EXIFValue]
    public var gpsTags: [Int: EXIFValue]

    public init(
        tags: [Int: EXIFValue] = [:],
        photoTags: [Int: EXIFValue] = [:],
        gpsTags: [Int: EXIFValue] = [:]
    ) {
        self.tags = tags
        self.photoTags = photoTags
        self.gpsTags = gpsTags
    }

    public var isEmpty: Bool {
        tags.isEmpty && photoTags.isEmpty && gpsTags.isEmpty
    }

    // MARK: Typed conveniences

    public var orientation: EXIFOrientation? {
        tags[EXIFTag.orientation]?.intValue.flatMap(EXIFOrientation.init(rawValue:))
    }
    public var cameraMake: String? { tags[EXIFTag.cameraMake]?.stringValue }
    public var cameraModel: String? { tags[EXIFTag.cameraModel]?.stringValue }
    public var software: String? { tags[EXIFTag.software]?.stringValue }
    /// "YYYY:MM:DD HH:MM:SS" as stored in the file.
    public var dateTime: String? { tags[EXIFTag.dateTime]?.stringValue }
    public var dateTimeOriginal: String? { photoTags[EXIFTag.dateTimeOriginal]?.stringValue }
    public var exposureTime: EXIFRational? { photoTags[EXIFTag.exposureTime]?.rationalValue }
    public var fNumber: Double? { photoTags[EXIFTag.fNumber]?.doubleValue }
    public var isoSpeed: Int? { photoTags[EXIFTag.isoSpeed]?.intValue }
    public var focalLength: Double? { photoTags[EXIFTag.focalLength]?.doubleValue }
    public var lensModel: String? { photoTags[EXIFTag.lensModel]?.stringValue }

    /// Latitude in degrees; negative is south of the equator.
    public var gpsLatitude: Double? {
        coordinate(valueTag: EXIFTag.gpsLatitude, referenceTag: EXIFTag.gpsLatitudeReference, negativeReference: "S")
    }

    /// Longitude in degrees; negative is west of the prime meridian.
    public var gpsLongitude: Double? {
        coordinate(valueTag: EXIFTag.gpsLongitude, referenceTag: EXIFTag.gpsLongitudeReference, negativeReference: "W")
    }

    /// Altitude in meters; negative is below sea level.
    public var gpsAltitude: Double? {
        guard let altitude = gpsTags[EXIFTag.gpsAltitude]?.doubleValue else { return nil }
        return gpsTags[EXIFTag.gpsAltitudeReference]?.intValue == 1 ? -altitude : altitude
    }

    private func coordinate(valueTag: Int, referenceTag: Int, negativeReference: String) -> Double? {
        guard case .rational(let parts)? = gpsTags[valueTag], !parts.isEmpty else { return nil }
        var value = 0.0
        let divisors = [1.0, 60.0, 3600.0]
        for (index, part) in parts.prefix(3).enumerated() {
            guard let component = part.doubleValue else { return nil }
            value += component / divisors[index]
        }
        return gpsTags[referenceTag]?.stringValue == negativeReference ? -value : value
    }

    // MARK: Extraction

    /// Extracts EXIF metadata from encoded JPEG, TIFF, PNG or WebP data.
    /// Returns nil when the data carries none, or when it is unreadable.
    public init?(data: Data) {
        guard let format = ImageFormat(detecting: data) else { return nil }
        let bytes = [UInt8](data)
        let payload: [UInt8]?
        switch format {
        case .jpeg: payload = Self.exifPayloadFromJPEG(bytes)
        case .tiff: payload = bytes
        case .png: payload = Self.exifPayloadFromPNG(bytes)
        case .webp: payload = Self.exifPayloadFromWebP(bytes)
        default: payload = nil
        }
        guard let payload, var parsed = EXIFData(tiffPayload: payload) else { return nil }
        if format == .tiff {
            // The file's own IFD doubles as EXIF storage; drop the tags that
            // merely describe the pixel layout.
            parsed.tags = parsed.tags.filter { !Self.structuralTIFFTags.contains($0.key) }
        }
        guard !parsed.isEmpty else { return nil }
        self = parsed
    }

    private static let structuralTIFFTags: Set<Int> = [
        254, 255, 256, 257, 258, 259, 262, 266, 269, 273, 277, 278, 279, 280, 281,
        282, 283, 284, 296, 297, 317, 318, 319, 320, 322, 323, 324, 325, 332, 338, 339, 347,
    ]

    private static func exifPayloadFromJPEG(_ bytes: [UInt8]) -> [UInt8]? {
        var offset = 2  // past SOI
        while offset + 4 <= bytes.count {
            guard bytes[offset] == 0xFF else { return nil }
            let marker = bytes[offset + 1]
            if marker == 0x01 || (0xD0...0xD8).contains(marker) {
                offset += 2
                continue
            }
            if marker == 0xDA || marker == 0xD9 {
                return nil  // entropy data or end reached without EXIF
            }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 2, offset + 2 + length <= bytes.count else { return nil }
            if marker == 0xE1, length >= 8,
               Array(bytes[offset + 4..<offset + 10]) == Array("Exif".utf8) + [0, 0] {
                return Array(bytes[offset + 10..<offset + 2 + length])
            }
            offset += 2 + length
        }
        return nil
    }

    private static func exifPayloadFromPNG(_ bytes: [UInt8]) -> [UInt8]? {
        var offset = 8  // past the signature
        while offset + 8 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = Array(bytes[offset + 4..<offset + 8])
            guard length >= 0, offset + 12 + length <= bytes.count else { return nil }
            if type == Array("eXIf".utf8) {
                return Array(bytes[offset + 8..<offset + 8 + length])
            }
            if type == Array("IEND".utf8) {
                return nil
            }
            offset += 12 + length
        }
        return nil
    }

    private static func exifPayloadFromWebP(_ bytes: [UInt8]) -> [UInt8]? {
        var offset = 12  // past RIFF size and WEBP
        while offset + 8 <= bytes.count {
            let fourCC = Array(bytes[offset..<offset + 4])
            let size = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
                | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
            guard size >= 0, offset + 8 + size <= bytes.count else { return nil }
            if fourCC == Array("EXIF".utf8) {
                var payload = Array(bytes[offset + 8..<offset + 8 + size])
                if payload.count >= 6, Array(payload[0..<6]) == Array("Exif".utf8) + [0, 0] {
                    payload.removeFirst(6)  // some writers keep the JPEG-style prefix
                }
                return payload
            }
            offset += 8 + size + (size & 1)
        }
        return nil
    }

    /// Parses a TIFF-structured EXIF block (the payload of a JPEG APP1
    /// segment, PNG eXIf chunk or WebP EXIF chunk — or a whole TIFF file).
    init?(tiffPayload bytes: [UInt8]) {
        guard bytes.count >= 8 else { return nil }
        let isLittleEndian: Bool
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): isLittleEndian = true
        case (0x4D, 0x4D): isLittleEndian = false
        default: return nil
        }
        let parser = TIFFStructureParser(bytes: bytes, isLittleEndian: isLittleEndian)
        guard parser.u16(2) == 42,
              let ifdOffset = parser.u32(4),
              var mainTags = parser.parseIFD(at: ifdOffset) else {
            return nil
        }

        var photo: [Int: EXIFValue] = [:]
        if let pointer = mainTags[EXIFTag.exifIFDPointer]?.intValue {
            photo = parser.parseIFD(at: pointer) ?? [:]
            mainTags[EXIFTag.exifIFDPointer] = nil
        }
        var gps: [Int: EXIFValue] = [:]
        if let pointer = mainTags[EXIFTag.gpsIFDPointer]?.intValue {
            gps = parser.parseIFD(at: pointer) ?? [:]
            mainTags[EXIFTag.gpsIFDPointer] = nil
        }
        self.init(tags: mainTags, photoTags: photo, gpsTags: gps)
    }

    // MARK: Serialization

    /// Serializes the metadata as a little-endian TIFF block — the payload
    /// format shared by JPEG APP1, PNG eXIf and WebP EXIF. The orientation
    /// tag is reset to upright because PurePixel always encodes pixels in
    /// display order; keeping the original value would rotate them twice.
    func serializedPayload() -> [UInt8] {
        var mainTags = tags
        mainTags[EXIFTag.exifIFDPointer] = nil
        mainTags[EXIFTag.gpsIFDPointer] = nil
        if mainTags[EXIFTag.orientation] != nil {
            mainTags[EXIFTag.orientation] = .short([1])
        }

        typealias PreparedEntry = (tag: Int, type: Int, count: Int, valueBytes: [UInt8])
        func prepare(_ tagValues: [Int: EXIFValue]) -> [PreparedEntry] {
            tagValues.sorted { $0.key < $1.key }.map { tag, value in
                let encoded = Self.encodeValue(value)
                return (tag, encoded.type, encoded.count, encoded.bytes)
            }
        }
        func blockSize(entryCount: Int) -> Int {
            2 + entryCount * 12 + 4
        }
        func externalSize(_ entries: [PreparedEntry]) -> Int {
            entries.reduce(0) {
                $0 + ($1.valueBytes.count > 4 ? $1.valueBytes.count + ($1.valueBytes.count & 1) : 0)
            }
        }

        var mainEntries = prepare(mainTags)
        let photoEntries = prepare(photoTags)
        let gpsEntries = prepare(gpsTags)

        let mainCount = mainEntries.count + (photoEntries.isEmpty ? 0 : 1) + (gpsEntries.isEmpty ? 0 : 1)
        var nextStart = 8 + blockSize(entryCount: mainCount) + externalSize(mainEntries)
        if !photoEntries.isEmpty {
            mainEntries.append((EXIFTag.exifIFDPointer, 4, 1, Self.uint32(nextStart)))
            nextStart += blockSize(entryCount: photoEntries.count) + externalSize(photoEntries)
        }
        if !gpsEntries.isEmpty {
            mainEntries.append((EXIFTag.gpsIFDPointer, 4, 1, Self.uint32(nextStart)))
        }
        mainEntries.sort { $0.tag < $1.tag }

        var output: [UInt8] = [0x49, 0x49, 42, 0]  // little-endian TIFF header
        output += Self.uint32(8)

        func appendIFD(_ entries: [PreparedEntry], startingAt start: Int) {
            output += Self.uint16(entries.count)
            var externalOffset = start + blockSize(entryCount: entries.count)
            var externalData: [UInt8] = []
            for entry in entries {
                output += Self.uint16(entry.tag)
                output += Self.uint16(entry.type)
                output += Self.uint32(entry.count)
                if entry.valueBytes.count <= 4 {
                    output += entry.valueBytes + [UInt8](repeating: 0, count: 4 - entry.valueBytes.count)
                } else {
                    output += Self.uint32(externalOffset)
                    externalData += entry.valueBytes
                    if entry.valueBytes.count & 1 == 1 {
                        externalData.append(0)
                    }
                    externalOffset += entry.valueBytes.count + (entry.valueBytes.count & 1)
                }
            }
            output += Self.uint32(0)  // no next IFD
            output += externalData
        }

        appendIFD(mainEntries, startingAt: 8)
        var subIFDStart = 8 + blockSize(entryCount: mainEntries.count) + externalSize(mainEntries)
        if !photoEntries.isEmpty {
            appendIFD(photoEntries, startingAt: subIFDStart)
            subIFDStart += blockSize(entryCount: photoEntries.count) + externalSize(photoEntries)
        }
        if !gpsEntries.isEmpty {
            appendIFD(gpsEntries, startingAt: subIFDStart)
        }
        return output
    }

    private static func encodeValue(_ value: EXIFValue) -> (type: Int, count: Int, bytes: [UInt8]) {
        switch value {
        case .byte(let values):
            return (1, values.count, values)
        case .ascii(let string):
            let bytes = Array(string.utf8) + [0]
            return (2, bytes.count, bytes)
        case .short(let values):
            return (3, values.count, values.flatMap(uint16))
        case .long(let values):
            return (4, values.count, values.flatMap(uint32))
        case .rational(let values):
            return (5, values.count, values.flatMap { uint32($0.numerator) + uint32($0.denominator) })
        case .undefined(let values):
            return (7, values.count, values)
        case .signedLong(let values):
            return (9, values.count, values.flatMap(uint32))
        case .signedRational(let values):
            return (10, values.count, values.flatMap { uint32($0.numerator) + uint32($0.denominator) })
        case .double(let values):
            return (12, values.count, values.flatMap { value in
                (0..<8).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
            })
        }
    }

    private static func uint16(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }

    private static func uint32(_ value: Int) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ]
    }
}

/// Bounds-checked reader for the TIFF structure inside EXIF payloads.
private struct TIFFStructureParser {
    let bytes: [UInt8]
    let isLittleEndian: Bool

    func u16(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        let a = Int(bytes[offset])
        let b = Int(bytes[offset + 1])
        return isLittleEndian ? a | b << 8 : a << 8 | b
    }

    func u32(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let a = Int(bytes[offset])
        let b = Int(bytes[offset + 1])
        let c = Int(bytes[offset + 2])
        let d = Int(bytes[offset + 3])
        return isLittleEndian
            ? a | b << 8 | c << 16 | d << 24
            : a << 24 | b << 16 | c << 8 | d
    }

    private static let valueSizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8]

    /// Parses one IFD leniently: malformed entries are skipped, not fatal.
    func parseIFD(at start: Int) -> [Int: EXIFValue]? {
        guard let entryCount = u16(start), entryCount <= 512 else { return nil }
        var result: [Int: EXIFValue] = [:]
        for index in 0..<entryCount {
            let base = start + 2 + index * 12
            guard let tag = u16(base),
                  let type = u16(base + 2),
                  let count = u32(base + 4),
                  count >= 0, count <= 1 << 16,
                  let size = Self.valueSizes[type] else {
                continue
            }
            let total = size * count
            var valueOffset = base + 8
            if total > 4 {
                guard let pointer = u32(base + 8) else { continue }
                valueOffset = pointer
            }
            guard valueOffset >= 0, valueOffset + total <= bytes.count else { continue }
            if let value = parseValue(type: type, count: count, at: valueOffset) {
                result[tag] = value
            }
        }
        return result
    }

    private func parseValue(type: Int, count: Int, at offset: Int) -> EXIFValue? {
        switch type {
        case 1, 6:
            return .byte(Array(bytes[offset..<offset + count]))
        case 2:
            var characters = Array(bytes[offset..<offset + count])
            while characters.last == 0 {
                characters.removeLast()
            }
            return .ascii(String(decoding: characters, as: UTF8.self))
        case 3:
            return .short((0..<count).compactMap { u16(offset + $0 * 2) })
        case 8:  // SSHORT, folded into .short with its sign preserved
            return .short((0..<count).compactMap { index in
                u16(offset + index * 2).map { Int(Int16(truncatingIfNeeded: $0)) }
            })
        case 4:
            return .long((0..<count).compactMap { u32(offset + $0 * 4) })
        case 9:
            return .signedLong((0..<count).compactMap { index in
                u32(offset + index * 4).map { Int(Int32(truncatingIfNeeded: $0)) }
            })
        case 5:
            return .rational((0..<count).compactMap { index in
                guard let numerator = u32(offset + index * 8),
                      let denominator = u32(offset + index * 8 + 4) else { return nil }
                return EXIFRational(numerator: numerator, denominator: denominator)
            })
        case 10:
            return .signedRational((0..<count).compactMap { index in
                guard let numerator = u32(offset + index * 8),
                      let denominator = u32(offset + index * 8 + 4) else { return nil }
                return EXIFRational(
                    numerator: Int(Int32(truncatingIfNeeded: numerator)),
                    denominator: Int(Int32(truncatingIfNeeded: denominator))
                )
            })
        case 11:  // FLOAT, widened to .double
            return .double((0..<count).compactMap { index in
                u32(offset + index * 4).map { Double(Float(bitPattern: UInt32(truncatingIfNeeded: $0))) }
            })
        case 12:
            return .double((0..<count).compactMap { index in
                var pattern: UInt64 = 0
                for byteIndex in 0..<8 {
                    let sourceIndex = offset + index * 8 + (isLittleEndian ? byteIndex : 7 - byteIndex)
                    pattern |= UInt64(bytes[sourceIndex]) << (byteIndex * 8)
                }
                return Double(bitPattern: pattern)
            })
        default:
            return nil
        }
    }
}
