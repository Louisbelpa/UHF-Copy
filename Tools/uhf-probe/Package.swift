// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "uhf-probe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/UHFCore"),
        .package(path: "../../Packages/UHFSources"),
    ],
    targets: [
        .executableTarget(
            name: "uhf-probe",
            dependencies: [
                .product(name: "UHFCore", package: "UHFCore"),
                .product(name: "UHFSources", package: "UHFSources"),
            ]),
    ]
)
