// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SiliconWin",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SiliconWin",
            path: "Sources/SiliconWin",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("WebKit"),
            ]
        ),
    ]
)
