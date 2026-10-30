// swift-tools-version: 6.4

import PackageDescription

#if canImport(CoreLocation)
    let locationTargets: [Target] = [
        .target(
            name: "LocationMigration",
            dependencies: [.product(name: "DioramaLocation", package: "Diorama")],
            swiftSettings: [
                .defaultIsolation(nil),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]),
    ]
#else
    let locationTargets: [Target] = []
#endif

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
            name: "DioramaDateUsage",
            dependencies: [
                .product(name: "Diorama", package: "Diorama"),
                .product(name: "DioramaDate", package: "Diorama"),
            ],
            swiftSettings: [
                .defaultIsolation(nil),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]),
        .executableTarget(
            name: "DioramaRandomUsage",
            dependencies: [
                .product(name: "Diorama", package: "Diorama"),
                .product(name: "DioramaCore", package: "Diorama"),
                .product(name: "DioramaRandom", package: "Diorama"),
            ],
            swiftSettings: [
                .defaultIsolation(nil),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]),
    ] + locationTargets,
    swiftLanguageModes: [.v6])
