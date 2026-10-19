// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWrtKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "OpenWrtKit", targets: ["OpenWrtKit"])
    ],
    targets: [
        .target(name: "OpenWrtKit"),
        .testTarget(name: "OpenWrtKitTests", dependencies: ["OpenWrtKit"])
    ]
)
