// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "URLSessionInterception",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    targets: [
        .testTarget(
            name: "URLSessionInterceptionTests",
            swiftSettings: [
                .defaultIsolation(nil),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]),
    ],
    swiftLanguageModes: [.v6])
