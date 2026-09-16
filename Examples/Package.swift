// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "DioramaExamples",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(name: "Diorama", path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "DioramaRandomUsage",
            dependencies: [
                .product(name: "DioramaCore", package: "Diorama"),
                .product(name: "DioramaRandom", package: "Diorama"),
            ],
            swiftSettings: [
                .defaultIsolation(nil),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]),
    ],
    swiftLanguageModes: [.v6])
