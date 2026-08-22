/// A single pixel in 8-bit RGBA format.
///
/// Color values are stored with straight (non-premultiplied) alpha.
public struct RGBA: Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let transparent = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
    public static let black = RGBA(red: 0, green: 0, blue: 0)
    public static let white = RGBA(red: 255, green: 255, blue: 255)
}
