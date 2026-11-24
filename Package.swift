// swift-tools-version: 6.4

import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .defaultIsolation(nil),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

#if canImport(CoreLocation)
    let locationProducts: [Product] = [.library(name: "DioramaLocation", targets: ["DioramaLocation"])]
    let locationTargets: [Target] = [
        .target(
            name: "DioramaLocation",
            dependencies: ["DioramaCore", "DioramaPersistence"],
            swiftSettings: strictConcurrencySettings),
        .testTarget(
            name: "DioramaLocationTests",
            dependencies: ["Diorama", "DioramaLocation", "DioramaCore", "DioramaPersistence"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictConcurrencySettings),
    ]
#else
    let locationProducts: [Product] = []
    let locationTargets: [Target] = []
#endif

#if canImport(Darwin)
    let urlSessionProducts: [Product] = [.library(name: "DioramaURLSession", targets: ["DioramaURLSession"])]
    let urlSessionTargets: [Target] = [
        .target(
            name: "DioramaURLSession",
            dependencies: [
                "DioramaCore", "DioramaPersistence", "DioramaHTTP",
                .product(name: "HTTPTypesFoundation", package: "swift-http-types"),
            ],
            swiftSettings: strictConcurrencySettings),
        .testTarget(
            name: "DioramaURLSessionTests",
            dependencies: [
                "Diorama", "DioramaURLSession", "DioramaHTTP", "DioramaCore", "DioramaPersistence", "DioramaRandom",
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: strictConcurrencySettings),
    ]
#else
    let urlSessionProducts: [Product] = []
    let urlSessionTargets: [Target] = []
#endif

let package = Package(
    name: "Diorama",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .macCatalyst(.v18),
    ],
    products: [
        .library(name: "Diorama", targets: ["Diorama"]),
        .library(
            name: "DioramaCore",
            targets: ["DioramaCore"]),
        .library(
            name: "DioramaDate",
            targets: ["DioramaDate"]),
        .library(
            name: "DioramaRandom",
            targets: ["DioramaRandom"]),
        .library(
            name: "DioramaPersistence",
            targets: ["DioramaPersistence"]),
        .library(name: "DioramaHTTP", targets: ["DioramaHTTP"]),
    ] + locationProducts + urlSessionProducts,
    dependencies: [
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "DioramaHTTP",
            dependencies: [
                "DioramaCore",
                "DioramaPersistence",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: strictConcurrencySettings),
        .testTarget(
            name: "DioramaHTTPTests",
            dependencies: ["DioramaHTTP", "DioramaCore", "DioramaPersistence"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictConcurrencySettings),
        .target(
            name: "Diorama",
            dependencies: ["DioramaCore", "DioramaPersistence"],
            swiftSettings: strictConcurrencySettings),
        .target(
            name: "DioramaCore",
            swiftSettings: strictConcurrencySettings),
        .target(
            name: "DioramaDate",
            dependencies: ["DioramaCore", "DioramaPersistence"],
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
            resources: [.copy("Fixtures")],
            swiftSettings: strictConcurrencySettings),
        .testTarget(
            name: "DioramaDateTests",
            dependencies: [
                "Diorama", "DioramaDate", "DioramaConsumerTestSupport", "DioramaCore", "DioramaPersistence",
            ],
            resources: [.copy("Fixtures")],
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
    ] + locationTargets + urlSessionTargets,
    swiftLanguageModes: [.v6])
