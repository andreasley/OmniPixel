import Foundation

/// Bounds-checked sequential reader over a byte buffer.
///
/// All methods throw `ImageError.invalidData` instead of trapping when the
/// data is shorter than expected, so decoders stay safe on truncated files.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remainingCount: Int {
        bytes.count - offset
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw ImageError.invalidData(reason: "Unexpected end of data")
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remainingCount else {
            throw ImageError.invalidData(reason: "Unexpected end of data")
        }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remainingCount else {
            throw ImageError.invalidData(reason: "Unexpected end of data")
        }
        offset += count
    }

    mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= bytes.count else {
            throw ImageError.invalidData(reason: "Seek target outside data")
        }
        offset = newOffset
    }

    /// Returns the next `count` bytes without advancing, or nil if fewer remain.
    func peek(_ count: Int) -> [UInt8]? {
        guard count >= 0, count <= remainingCount else { return nil }
        return Array(bytes[offset..<offset + count])
    }

    mutating func readUInt16LittleEndian() throws -> UInt16 {
        let b = try readBytes(2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func readUInt16BigEndian() throws -> UInt16 {
        let b = try readBytes(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    mutating func readUInt32LittleEndian() throws -> UInt32 {
        let b = try readBytes(4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    mutating func readUInt32BigEndian() throws -> UInt32 {
        let b = try readBytes(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    mutating func readInt32LittleEndian() throws -> Int32 {
        Int32(bitPattern: try readUInt32LittleEndian())
    }
}
