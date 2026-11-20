// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenWrtKit",
    platforms: [.iOS(.v26), .macOS(.v13)],
    products: [
        .library(name: "OpenWrtKit", targets: ["OpenWrtKit"])
    ],
    targets: [
        .target(name: "OpenWrtKit"),
        .testTarget(
            name: "OpenWrtKitTests",
            dependencies: ["OpenWrtKit"],
            resources: [
                .copy("Fixtures/snapshot-192.168.31.167-2026-11-20.json"),
                .copy("Fixtures/snapshot-192.168.31.1-2026-11-20.json")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
