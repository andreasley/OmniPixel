/// Parsed HEIF/ISOBMFF structure: the pieces needed to locate and extract
/// a primary item's coded bitstream and display properties (shared by the
/// HEIC and AVIF codecs).
struct HEIFContainer {
    struct ItemLocation {
        var constructionMethod = 0
        var baseOffset = 0
        var extents: [(offset: Int, length: Int)] = []
    }

    private(set) var primaryItemID: Int?
    private(set) var itemTypes: [Int: String] = [:]
    private(set) var itemLocations: [Int: ItemLocation] = [:]
    private(set) var properties: [(type: String, payload: [UInt8])] = []
    private(set) var associations: [Int: [Int]] = [:]
    private(set) var references: [(type: String, from: Int, to: [Int])] = []
    private(set) var idat: [UInt8] = []
    private let bytes: [UInt8]

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        try walkBoxes(from: 0, to: bytes.count, container: "", depth: 0)
    }

    // MARK: Lookups

    /// Returns the payload of the first property of `type` associated with
    /// the item. Only items without any association entry fall back to a
    /// global search (lenient parsing for single-image files) — in tiled
    /// images, one item's properties must not leak onto another's.
    func property(ofType type: String, forItem itemID: Int) -> [UInt8]? {
        if let indices = associations[itemID] {
            for index in indices where index >= 1 && index <= properties.count {
                if properties[index - 1].type == type {
                    return properties[index - 1].payload
                }
            }
            return nil
        }
        return properties.first { $0.type == type }?.payload
    }

    /// Item IDs referenced from `itemID` with the given reference type
    /// (for example the `dimg` tiles of a grid), in declaration order.
    func linkedItems(ofType type: String, from itemID: Int) -> [Int] {
        references.filter { $0.type == type && $0.from == itemID }.flatMap(\.to)
    }

    /// Assembles an item's data from its iloc extents.
    func itemData(for itemID: Int) throws -> [UInt8]? {
        guard let location = itemLocations[itemID] else { return nil }
        var data: [UInt8] = []
        for extent in location.extents {
            let start = location.baseOffset + extent.offset
            let source: [UInt8]
            switch location.constructionMethod {
            case 0:
                source = bytes
            case 1:
                source = idat
            default:
                throw ImageError.unsupportedFeature(reason: "HEIC item construction method \(location.constructionMethod) is not supported")
            }
            // A zero-length single extent means "to the end of the resource".
            let length = extent.length == 0 && location.extents.count == 1
                ? source.count - start
                : extent.length
            guard start >= 0, length >= 0, start + length <= source.count else {
                throw ImageError.invalidData(reason: "HEIC item data lies outside the file")
            }
            data += source[start..<start + length]
        }
        return data
    }

    // MARK: Box parsing

    private func readU16(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else {
            throw ImageError.invalidData(reason: "HEIF box offset out of range")
        }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    private func readU32(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw ImageError.invalidData(reason: "HEIF box offset out of range")
        }
        return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    private func readSized(_ offset: Int, byteCount: Int) throws -> Int {
        guard byteCount >= 0, byteCount <= 8, offset >= 0, offset + byteCount <= bytes.count else {
            throw ImageError.invalidData(reason: "HEIF box offset out of range")
        }
        var value = 0
        for i in 0..<byteCount {
            let byte = Int(bytes[offset + i])
            guard value <= (Int.max - byte) >> 8 else {
                throw ImageError.invalidData(reason: "HEIF offset too large")
            }
            value = value << 8 | byte
        }
        return value
    }

    private mutating func walkBoxes(from start: Int, to end: Int, container: String, depth: Int) throws {
        guard depth < 10 else { return }
        var offset = start
        while offset + 8 <= end {
            var size = try readU32(offset)
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            var headerSize = 8
            if size == 1 {  // 64-bit size
                guard offset + 16 <= end, try readU32(offset + 8) == 0 else {
                    throw ImageError.invalidData(reason: "HEIF box too large")
                }
                size = try readU32(offset + 12)
                headerSize = 16
            } else if size == 0 {  // extends to the end of the enclosing box
                size = end - offset
            }
            guard size >= headerSize, offset + size <= end else {
                throw ImageError.invalidData(reason: "HEIF box exceeds its container")
            }
            let payloadStart = offset + headerSize
            let payloadEnd = offset + size

            switch (container, type) {
            case ("", "meta"):  // full box
                try walkBoxes(from: payloadStart + 4, to: payloadEnd, container: "meta", depth: depth + 1)
            case ("meta", "pitm"):
                try parsePrimaryItem(payloadStart)
            case ("meta", "iinf"):
                guard payloadStart < payloadEnd else { break }
                let version = Int(bytes[payloadStart])
                let childStart = payloadStart + 4 + (version == 0 ? 2 : 4)
                if childStart <= payloadEnd {
                    try walkBoxes(from: childStart, to: payloadEnd, container: "iinf", depth: depth + 1)
                }
            case ("meta", "iloc"):
                try parseItemLocations(payloadStart, payloadEnd)
            case ("meta", "iref"):
                try parseItemReferences(payloadStart, payloadEnd)
            case ("meta", "iprp"):
                try walkBoxes(from: payloadStart, to: payloadEnd, container: "iprp", depth: depth + 1)
            case ("meta", "idat"):
                idat = Array(bytes[payloadStart..<payloadEnd])
            case ("iprp", "ipco"):
                try collectProperties(payloadStart, payloadEnd)
            case ("iprp", "ipma"):
                try parseAssociations(payloadStart, payloadEnd)
            case ("iinf", "infe"):
                try parseItemInfo(payloadStart, payloadEnd)
            default:
                break
            }
            offset += size
        }
    }

    private mutating func parsePrimaryItem(_ start: Int) throws {
        guard start < bytes.count else {
            throw ImageError.invalidData(reason: "Corrupt HEIF primary item box")
        }
        let version = Int(bytes[start])
        primaryItemID = version == 0 ? try readU16(start + 4) : try readU32(start + 4)
    }

    private mutating func parseItemInfo(_ start: Int, _ end: Int) throws {
        guard start < end else { return }
        let version = Int(bytes[start])
        guard version >= 2 else { return }  // pre-HEIF layouts carry no item type
        let itemID: Int
        var offset: Int
        if version == 2 {
            itemID = try readU16(start + 4)
            offset = start + 6
        } else {
            itemID = try readU32(start + 4)
            offset = start + 8
        }
        offset += 2  // item_protection_index
        guard offset + 4 <= end else { return }
        itemTypes[itemID] = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
    }

    private mutating func parseItemLocations(_ start: Int, _ end: Int) throws {
        guard start + 8 <= end else {
            throw ImageError.invalidData(reason: "Corrupt HEIF item location box")
        }
        let version = Int(bytes[start])
        let offsetSize = Int(bytes[start + 4]) >> 4
        let lengthSize = Int(bytes[start + 4]) & 0x0F
        let baseOffsetSize = Int(bytes[start + 5]) >> 4
        let indexSize = version >= 1 ? Int(bytes[start + 5]) & 0x0F : 0

        var offset: Int
        let itemCount: Int
        if version < 2 {
            itemCount = try readU16(start + 6)
            offset = start + 8
        } else {
            itemCount = try readU32(start + 6)
            offset = start + 10
        }
        guard itemCount <= 4096 else {
            throw ImageError.invalidData(reason: "Unreasonable HEIF item count")
        }

        for _ in 0..<itemCount {
            let itemID: Int
            if version < 2 {
                itemID = try readU16(offset)
                offset += 2
            } else {
                itemID = try readU32(offset)
                offset += 4
            }
            var location = ItemLocation()
            if version == 1 || version == 2 {
                location.constructionMethod = try readU16(offset) & 0x0F
                offset += 2
            }
            let dataReferenceIndex = try readU16(offset)
            offset += 2
            guard dataReferenceIndex == 0 else {
                throw ImageError.unsupportedFeature(reason: "HEIC with external data references is not supported")
            }
            location.baseOffset = try readSized(offset, byteCount: baseOffsetSize)
            offset += baseOffsetSize
            let extentCount = try readU16(offset)
            offset += 2
            guard extentCount <= 4096 else {
                throw ImageError.invalidData(reason: "Unreasonable HEIF extent count")
            }
            for _ in 0..<extentCount {
                if version >= 1, indexSize > 0 {
                    offset += indexSize  // extent_index, unused
                }
                let extentOffset = try readSized(offset, byteCount: offsetSize)
                offset += offsetSize
                let extentLength = try readSized(offset, byteCount: lengthSize)
                offset += lengthSize
                location.extents.append((extentOffset, extentLength))
            }
            itemLocations[itemID] = location
        }
    }

    /// iref: a full box containing one reference box per link type, each
    /// listing a source item and the items it references. Item IDs are
    /// 16-bit in version 0 and 32-bit in version 1.
    private mutating func parseItemReferences(_ start: Int, _ end: Int) throws {
        guard start + 4 <= end else {
            throw ImageError.invalidData(reason: "Corrupt HEIF item reference box")
        }
        let wideIDs = bytes[start] >= 1
        var offset = start + 4
        while offset + 8 <= end {
            let size = try readU32(offset)
            guard size >= 8, offset + size <= end else {
                throw ImageError.invalidData(reason: "Corrupt HEIF item reference box")
            }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            var cursor = offset + 8
            let fromID: Int
            if wideIDs {
                fromID = try readU32(cursor)
                cursor += 4
            } else {
                fromID = try readU16(cursor)
                cursor += 2
            }
            let referenceCount = try readU16(cursor)
            cursor += 2
            guard referenceCount <= 4096 else {
                throw ImageError.invalidData(reason: "Unreasonable HEIF reference count")
            }
            var targets: [Int] = []
            for _ in 0..<referenceCount {
                if wideIDs {
                    targets.append(try readU32(cursor))
                    cursor += 4
                } else {
                    targets.append(try readU16(cursor))
                    cursor += 2
                }
            }
            guard cursor <= offset + size else {
                throw ImageError.invalidData(reason: "Corrupt HEIF item reference box")
            }
            references.append((type, fromID, targets))
            offset += size
        }
    }

    private mutating func collectProperties(_ start: Int, _ end: Int) throws {
        var offset = start
        while offset + 8 <= end {
            let size = try readU32(offset)
            guard size >= 8, offset + size <= end else {
                throw ImageError.invalidData(reason: "Corrupt HEIF property container")
            }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            properties.append((type, Array(bytes[offset + 8..<offset + size])))
            offset += size
        }
    }

    private mutating func parseAssociations(_ start: Int, _ end: Int) throws {
        guard start + 8 <= end else {
            throw ImageError.invalidData(reason: "Corrupt HEIF property associations")
        }
        let version = Int(bytes[start])
        let wideIndices = bytes[start + 3] & 0x01 == 1
        let entryCount = try readU32(start + 4)
        guard entryCount <= 4096 else {
            throw ImageError.invalidData(reason: "Unreasonable HEIF association count")
        }
        var offset = start + 8
        for _ in 0..<entryCount {
            let itemID: Int
            if version < 1 {
                itemID = try readU16(offset)
                offset += 2
            } else {
                itemID = try readU32(offset)
                offset += 4
            }
            guard offset < end else {
                throw ImageError.invalidData(reason: "Corrupt HEIF property associations")
            }
            let associationCount = Int(bytes[offset])
            offset += 1
            var indices: [Int] = []
            for _ in 0..<associationCount {
                if wideIndices {
                    indices.append(try readU16(offset) & 0x7FFF)
                    offset += 2
                } else {
                    guard offset < end else {
                        throw ImageError.invalidData(reason: "Corrupt HEIF property associations")
                    }
                    indices.append(Int(bytes[offset]) & 0x7F)
                    offset += 1
                }
            }
            associations[itemID] = indices
        }
    }
}
