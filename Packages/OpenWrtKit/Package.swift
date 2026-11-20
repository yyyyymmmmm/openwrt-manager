// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenWrtKit",
    platforms: [.iOS(.v26), .macOS(.v13)],
    products: [
        .library(name: "OpenWrtKit", targets: ["OpenWrtKit"]),
        .library(name: "OpenWrtSSH", targets: ["OpenWrtSSH"])
    ],
    dependencies: [
        // Native SSH transport for the phase-3 terminal: Apple's
        // maintained pure-Swift SSH stack on SwiftNIO (auditable, no
        // web terminal, no C library). Pinned to the 0.12 line.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.12.0"),
        // swift-crypto 4/5 need a newer compiler than the local 6.2
        // toolchain; 3.x is within swift-nio-ssh's allowed range and
        // provides everything the SSH stack uses.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0")
    ],
    targets: [
        .target(name: "OpenWrtKit"),
        .target(name: "OpenWrtSSH", dependencies: [
            "OpenWrtKit",
            .product(name: "NIOSSH", package: "swift-nio-ssh")
        ]),
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
