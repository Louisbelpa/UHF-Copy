// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UHFSync",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UHFSync", targets: ["UHFSync"])
    ],
    dependencies: [
        .package(path: "../UHFCore"),
        .package(path: "../UHFSources"),
        .package(path: "../UHFStore"),
    ],
    targets: [
        .target(name: "UHFSync", dependencies: [
            .product(name: "UHFCore", package: "UHFCore"),
            .product(name: "UHFSources", package: "UHFSources"),
            .product(name: "UHFStore", package: "UHFStore"),
        ]),
        .testTarget(name: "UHFSyncTests", dependencies: ["UHFSync"]),
    ]
)
