#if canImport(SwiftUI) && os(macOS)
import SwiftUI

/// A small image viewer demonstrating PurePixel: every image is decoded,
/// edited and re-encoded by the library's pure-Swift codecs — the platform
/// frameworks only put the finished pixels on screen.
@main
struct ViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("PurePixel Viewer") {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
#else
/// The viewer's interface is SwiftUI on macOS; on other platforms the
/// executable just explains itself so the package still builds everywhere.
@main
struct ViewerApp {
    static func main() {
        print("The PurePixel viewer is a SwiftUI application and runs on macOS.")
        print("The PurePixel library itself works on any platform with Foundation.")
    }
}
#endif
