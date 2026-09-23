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
        .library(name: "Diorama", targets: ["Diorama"]),
        .library(
            name: "DioramaCore",
            targets: ["DioramaCore"]),
        .library(
            name: "DioramaRandom",
            targets: ["DioramaRandom"]),
        .library(
            name: "DioramaPersistence",
            targets: ["DioramaPersistence"]),
    ],
    targets: [
        .target(
            name: "Diorama",
            dependencies: ["DioramaCore", "DioramaPersistence"],
            swiftSettings: strictConcurrencySettings),
        .target(
            name: "DioramaCore",
            swiftSettings: strictConcurrencySettings),
        .target(
            name: "DioramaRandom",
            dependencies: ["DioramaCore", "DioramaPersistence"],
            swiftSettings: strictConcurrencySettings),
        .target(
            name: "DioramaPersistence",
            dependencies: ["DioramaCore"],
            swiftSettings: strictConcurrencySettings),
        .target(
            name: "DioramaConsumerTestSupport",
            dependencies: ["DioramaCore", "DioramaPersistence"],
            path: "Tests/DioramaConsumerTestSupport",
            swiftSettings: strictConcurrencySettings),
        .testTarget(
            name: "DioramaTests",
            dependencies: ["Diorama", "DioramaCore"],
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
            name: "DioramaPersistenceTests",
            dependencies: ["Diorama", "DioramaCore", "DioramaPersistence", "DioramaRandom"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictConcurrencySettings),
        .testTarget(
            name: "DioramaConsumerTests",
            dependencies: [
                "Diorama", "DioramaConsumerTestSupport", "DioramaCore",
                "DioramaPersistence", "DioramaRandom",
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: strictConcurrencySettings),
    ],
    swiftLanguageModes: [.v6])
