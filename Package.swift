// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SemanticsTesting",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "SemanticsTesting", targets: ["SemanticsTesting"]),
    ],
    targets: [
        .target(
            name: "SemanticsTesting",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ],
        ),
        .testTarget(
            name: "SemanticsTestingTests",
            dependencies: ["SemanticsTesting"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ],
        ),
    ],
    swiftLanguageModes: [.v6],
)
