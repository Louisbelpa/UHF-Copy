// swift-tools-version: 6.0
import PackageDescription

// ⚠️ Ce paquet dépend d'AVFoundation : il ne compile que sur les plateformes Apple.
// Il est volontairement exclu du job Linux de la CI.
let package = Package(
    name: "UHFPlayback",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UHFPlayback", targets: ["UHFPlayback"])
    ],
    dependencies: [
        .package(path: "../UHFCore"),
        .package(path: "../UHFSources"),
    ],
    targets: [
        .target(name: "UHFPlayback", dependencies: [
            .product(name: "UHFCore", package: "UHFCore"),
            .product(name: "UHFSources", package: "UHFSources"),
        ])
    ]
)
