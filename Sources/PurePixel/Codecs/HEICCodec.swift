import Foundation

/// HEIC/HEIF (ISO Base Media File Format container with an HEVC payload).
///
/// PurePixel recognizes HEIC files and parses the container far enough to
/// report the image's dimensions, but decoding the pixels requires an HEVC
/// (H.265) decoder — CABAC entropy coding, quad-tree coding units, 35 intra
/// prediction modes and in-loop filters — which is not implemented. Both
/// decoding and encoding therefore throw `ImageError.unsupportedFeature`
/// with a precise message, so callers can tell a valid-but-undecodable HEIC
/// apart from corrupt data. On Apple platforms, ImageIO can decode HEIC and
/// the resulting pixels can be handed to PurePixel.
enum HEICCodec: ImageCodec {
    /// HEIF brands carrying HEVC-coded still images.
    private static let heifBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"]

    static func canDecode(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        let bytes = [UInt8](data.prefix(min(data.count, 64)))
        guard Array(bytes[4..<8]) == Array("ftyp".utf8) else { return false }

        let boxSize = min(
            Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3]),
            bytes.count
        )
        guard boxSize >= 16 else { return false }

        // The major brand plus any compatible brand may mark the file as HEIF.
        var brands = [String(decoding: bytes[8..<12], as: UTF8.self)]
        var offset = 16
        while offset + 4 <= boxSize {
            brands.append(String(decoding: bytes[offset..<offset + 4], as: UTF8.self))
            offset += 4
        }
        return brands.contains { heifBrands.contains($0) }
    }

    static func decode(_ data: Data) throws -> Image {
        guard canDecode(data) else {
            throw ImageError.invalidData(reason: "Missing HEIF file type box")
        }
        let bytes = [UInt8](data)
        var scan = BoxScan()
        scanBoxes(bytes, from: 0, to: bytes.count, scan: &scan, depth: 0)

        var detail = ""
        if let width = scan.width, let height = scan.height {
            detail = " (image is \(width)×\(height))"
        }
        throw ImageError.unsupportedFeature(
            reason: "HEIC decoding requires an HEVC (H.265) decoder, which is not implemented" + detail
        )
    }

    static func encode(_ image: Image) throws -> Data {
        throw ImageError.unsupportedFeature(
            reason: "HEIC encoding requires an HEVC (H.265) encoder, which is not implemented"
        )
    }

    // MARK: Container parsing

    private struct BoxScan {
        var width: Int?
        var height: Int?
        var hasHEVCItem = false
    }

    /// Best-effort recursive box walk gathering what we can report about the
    /// image; malformed structures simply end the walk.
    private static func scanBoxes(_ bytes: [UInt8], from start: Int, to end: Int, scan: inout BoxScan, depth: Int) {
        func u32(_ offset: Int) -> Int {
            Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }

        var offset = start
        while offset + 8 <= end {
            var size = u32(offset)
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            var headerSize = 8
            if size == 1 {  // 64-bit size
                guard offset + 16 <= end, u32(offset + 8) == 0 else { return }
                size = u32(offset + 12)
                headerSize = 16
            } else if size == 0 {  // extends to the end of the enclosing box
                size = end - offset
            }
            guard size >= headerSize, offset + size <= end else { return }
            let payloadStart = offset + headerSize
            let payloadEnd = offset + size

            switch type {
            case "meta":  // full box wrapping the metadata tree
                if depth < 8, payloadStart + 4 <= payloadEnd {
                    scanBoxes(bytes, from: payloadStart + 4, to: payloadEnd, scan: &scan, depth: depth + 1)
                }
            case "iprp", "ipco":  // plain containers
                if depth < 8 {
                    scanBoxes(bytes, from: payloadStart, to: payloadEnd, scan: &scan, depth: depth + 1)
                }
            case "iinf":  // full box: version, then an entry count before the children
                if depth < 8, payloadStart + 4 <= payloadEnd {
                    let version = bytes[payloadStart]
                    let childStart = payloadStart + 4 + (version == 0 ? 2 : 4)
                    if childStart <= payloadEnd {
                        scanBoxes(bytes, from: childStart, to: payloadEnd, scan: &scan, depth: depth + 1)
                    }
                }
            case "infe":  // full box: item ID, protection index, then the item type
                if payloadStart + 4 <= payloadEnd {
                    let version = bytes[payloadStart]
                    let typeOffset = payloadStart + 4 + (version >= 3 ? 4 : 2) + 2
                    if typeOffset + 4 <= payloadEnd,
                       String(decoding: bytes[typeOffset..<typeOffset + 4], as: UTF8.self) == "hvc1" {
                        scan.hasHEVCItem = true
                    }
                }
            case "ispe":  // full box: image spatial extents
                if payloadStart + 12 <= payloadEnd, scan.width == nil {
                    scan.width = u32(payloadStart + 4)
                    scan.height = u32(payloadStart + 8)
                }
            default:
                break
            }
            offset += size
        }
    }
}
