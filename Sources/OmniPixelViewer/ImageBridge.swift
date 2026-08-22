#if canImport(SwiftUI) && os(macOS)
import CoreGraphics
import Foundation
import OmniPixel

/// OmniPixel's image type; aliased because SwiftUI also has an `Image`.
typealias PixelImage = OmniPixel.Image

extension PixelImage {
    /// Bridges the decoded RGBA buffer to Core Graphics for display.
    /// OmniPixel does all decoding itself — this is presentation only.
    func makeCGImage() -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (index, pixel) in pixels.enumerated() {
            bytes[index * 4] = pixel.red
            bytes[index * 4 + 1] = pixel.green
            bytes[index * 4 + 2] = pixel.blue
            bytes[index * 4 + 3] = pixel.alpha
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
#endif
