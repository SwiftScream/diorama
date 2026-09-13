// swift-tools-version: 6.4

import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .defaultIsolation(nil),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "Diorama",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "DioramaCore",
            targets: ["DioramaCore"]),
        .library(
            name: "DioramaRandom",
            targets: ["DioramaRandom"]),
    ],
    targets: [
        .target(
            name: "DioramaCore",
            swiftSettings: strictConcurrencySettings),
        .target(
            name: "DioramaRandom",
            dependencies: ["DioramaCore"],
            swiftSettings: strictConcurrencySettings),
        .target(
            name: "DioramaConsumerTestSupport",
            dependencies: ["DioramaCore"],
            path: "Tests/DioramaConsumerTestSupport",
            swiftSettings: strictConcurrencySettings),
        .testTarget(
            name: "DioramaCoreTests",
            dependencies: ["DioramaCore"],
            swiftSettings: strictConcurrencySettings),
        .testTarget(
            name: "DioramaRandomTests",
            dependencies: ["DioramaCore", "DioramaRandom"],
            swiftSettings: strictConcurrencySettings),
        .testTarget(
            name: "DioramaConsumerTests",
            dependencies: ["DioramaCore", "DioramaConsumerTestSupport"],
            swiftSettings: strictConcurrencySettings),
    ],
    swiftLanguageModes: [.v6])
