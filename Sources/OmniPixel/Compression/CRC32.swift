/// CRC-32 (the polynomial used by PNG, zip and gzip).
///
/// The table is sliced eight ways, so the main loop folds eight input bytes per
/// iteration instead of one.
enum CRC32 {
    /// Eight consecutive 256-entry tables: `table[slice * 256 + byte]` folds
    /// `byte` through `slice` further byte positions.
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 8 * 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = value & 1 == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1
            }
            table[index] = value
        }
        for slice in 1..<8 {
            for index in 0..<256 {
                let previous = table[(slice - 1) * 256 + index]
                table[slice * 256 + index] = table[Int(previous & 0xFF)] ^ (previous >> 8)
            }
        }
        return table
    }()

    /// The starting value for an incremental checksum.
    static let initialValue: UInt32 = 0xFFFFFFFF

    static func checksum(of bytes: [UInt8]) -> UInt32 {
        finalize(update(initialValue, with: bytes))
    }

    /// Folds `bytes` into a running checksum, so a checksum over several pieces
    /// doesn't need them concatenated into one buffer first.
    static func update(_ crc: UInt32, with bytes: [UInt8]) -> UInt32 {
        var crc = crc
        bytes.withUnsafeBufferPointer { input in
            table.withUnsafeBufferPointer { table in
                let count = input.count
                var index = 0
                while index + 8 <= count {
                    let low = crc
                        ^ UInt32(input[index])
                        ^ UInt32(input[index + 1]) << 8
                        ^ UInt32(input[index + 2]) << 16
                        ^ UInt32(input[index + 3]) << 24
                    crc = table[7 * 256 + Int(low & 0xFF)]
                        ^ table[6 * 256 + Int((low >> 8) & 0xFF)]
                        ^ table[5 * 256 + Int((low >> 16) & 0xFF)]
                        ^ table[4 * 256 + Int(low >> 24)]
                        ^ table[3 * 256 + Int(input[index + 4])]
                        ^ table[2 * 256 + Int(input[index + 5])]
                        ^ table[1 * 256 + Int(input[index + 6])]
                        ^ table[Int(input[index + 7])]
                    index += 8
                }
                while index < count {
                    crc = table[Int((crc ^ UInt32(input[index])) & 0xFF)] ^ (crc >> 8)
                    index += 1
                }
            }
        }
        return crc
    }

    /// Turns a running checksum into the value stored in a file.
    static func finalize(_ crc: UInt32) -> UInt32 {
        crc ^ 0xFFFFFFFF
    }
}
