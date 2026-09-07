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
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "DioramaCore",
            targets: ["DioramaCore"]
        ),
    ],
    targets: [
        .target(
            name: "DioramaCore",
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "DioramaCoreTests",
            dependencies: ["DioramaCore"],
            swiftSettings: strictConcurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
