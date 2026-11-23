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
    targets: [
        .target(name: "MacSizeCore"),
        .executableTarget(name: "macsize", dependencies: ["MacSizeCore"]),
        .executableTarget(name: "MacSizeApp", dependencies: ["MacSizeCore"]),
        .testTarget(name: "MacSizeCoreTests", dependencies: ["MacSizeCore"]),
    ]
)
