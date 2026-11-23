// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSize",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacSizeCore", targets: ["MacSizeCore"]),
        .executable(name: "macsize", targets: ["macsize"]),
        .executable(name: "MacSizeApp", targets: ["MacSizeApp"]),
    ],
    dependencies: [
        // Auto-updates for the app only. The CLI and core stay dependency-free.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(name: "MacSizeCore"),
        .executableTarget(name: "macsize", dependencies: ["MacSizeCore"]),
        .executableTarget(
            name: "MacSizeApp",
            dependencies: [
                "MacSizeCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(name: "MacSizeCoreTests", dependencies: ["MacSizeCore"]),
    ]
)
