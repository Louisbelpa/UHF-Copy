// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UHFSources",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UHFSources", targets: ["UHFSources"])
    ],
    dependencies: [
        .package(path: "../UHFCore")
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "UHFSources", dependencies: ["CZlib", .product(name: "UHFCore", package: "UHFCore")]),
        .testTarget(name: "UHFSourcesTests", dependencies: ["UHFSources"]),
    ]
)
