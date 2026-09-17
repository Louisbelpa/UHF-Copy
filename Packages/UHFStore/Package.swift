// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UHFStore",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UHFStore", targets: ["UHFStore"])
    ],
    dependencies: [
        .package(path: "../UHFCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(name: "UHFStore", dependencies: [
            .product(name: "UHFCore", package: "UHFCore"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "UHFStoreTests", dependencies: ["UHFStore"]),
    ]
)
