// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PurePixel",
    platforms: [
        // The library itself only needs Foundation; the viewer's SwiftUI
        // interface sets the macOS floor. Linux is unaffected.
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PurePixel",
            targets: ["PurePixel"]
        ),
        .executable(
            name: "PurePixelViewer",
            targets: ["PurePixelViewer"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PurePixel",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .executableTarget(
            name: "PurePixelViewer",
            dependencies: ["PurePixel"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "PurePixelTests",
            dependencies: ["PurePixel"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
