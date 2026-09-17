// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UHFCore",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UHFCore", targets: ["UHFCore"])
    ],
    targets: [
        .target(name: "UHFCore"),
        .testTarget(name: "UHFCoreTests", dependencies: ["UHFCore"]),
    ]
)
