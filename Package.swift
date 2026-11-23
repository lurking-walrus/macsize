// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TreeSize",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TreeSizeCore", targets: ["TreeSizeCore"]),
        .executable(name: "treesize", targets: ["treesize"]),
        .executable(name: "TreeSizeApp", targets: ["TreeSizeApp"]),
    ],
    targets: [
        .target(name: "TreeSizeCore"),
        .executableTarget(name: "treesize", dependencies: ["TreeSizeCore"]),
        .executableTarget(name: "TreeSizeApp", dependencies: ["TreeSizeCore"]),
        .testTarget(name: "TreeSizeCoreTests", dependencies: ["TreeSizeCore"]),
    ]
)
