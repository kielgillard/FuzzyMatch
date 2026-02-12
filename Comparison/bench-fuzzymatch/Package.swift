// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bench-fuzzymatch",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "bench-fuzzymatch",
            dependencies: [
                .product(name: "FuzzyMatch", package: "FuzzyMatch"),
                .product(name: "HeapModule", package: "swift-collections"),
            ],
            path: "Sources"
        ),
    ]
)
