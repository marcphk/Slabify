// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Slabify",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Slabify", targets: ["Slabify"])
    ],
    targets: [
        .target(
            name: "Slabify",
            swiftSettings: [
                // The frame only exists in Debug builds. In Release, the public API is a no-op.
                .define("DEBUG", .when(configuration: .debug))
            ]
        )
    ]
)
