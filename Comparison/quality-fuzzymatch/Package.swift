// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "quality-fuzzymatch",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "quality-fuzzymatch",
            dependencies: [
                .product(name: "FuzzyMatch", package: "FuzzyMatch"),
            ],
            path: "Sources"
        ),
    ]
)
