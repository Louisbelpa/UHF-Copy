// swift-tools-version: 6.0
import PackageDescription

// Logique d'interface, sans SwiftUI : pagination, anti-rebond, états de chargement,
// gestion d'erreurs. Elle est ainsi testable hors simulateur, et les vues n'en sont
// plus que l'habillage.
let package = Package(
    name: "UHFViewModels",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UHFViewModels", targets: ["UHFViewModels"])
    ],
    dependencies: [
        .package(path: "../UHFCore"),
        .package(path: "../UHFSources"),
        .package(path: "../UHFStore"),
        .package(path: "../UHFSync"),
    ],
    targets: [
        .target(name: "UHFViewModels", dependencies: [
            .product(name: "UHFCore", package: "UHFCore"),
            .product(name: "UHFSources", package: "UHFSources"),
            .product(name: "UHFStore", package: "UHFStore"),
            .product(name: "UHFSync", package: "UHFSync"),
        ]),
        .testTarget(name: "UHFViewModelsTests", dependencies: ["UHFViewModels"]),
    ]
)
