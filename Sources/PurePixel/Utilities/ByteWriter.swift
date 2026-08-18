import Foundation

/// Sequential writer that builds up a byte buffer.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    var data: Data {
        Data(bytes)
    }

    mutating func writeByte(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func writeBytes(_ newBytes: [UInt8]) {
        bytes += newBytes
    }

    mutating func writeUInt16LittleEndian(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func writeUInt32LittleEndian(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func writeUInt32BigEndian(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func writeInt32LittleEndian(_ value: Int32) {
        writeUInt32LittleEndian(UInt32(bitPattern: value))
    }
}
