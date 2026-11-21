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
        // web terminal, no C library). Resolved to 0.15.1, the latest
        // release; its bundled transport protection is AES-GCM only, so
        // OpenWrtSSH adds AES-CTR schemes through the public
        // NIOSSHTransportProtection extension point (a chacha20-poly1305
        // scheme is implemented too but not proposed — upstream key
        // derivation cannot expand to its 64-byte key; see
        // TransportProtection.swift).
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.0"),
        // swift-crypto 4/5 need a newer compiler than the local 6.2
        // toolchain; 3.x is within swift-nio-ssh's allowed range and
        // provides everything the SSH stack uses.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0")
    ],
    targets: [
        .target(name: "OpenWrtKit"),
        .target(name: "OpenWrtSSH", dependencies: [
            "OpenWrtKit",
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto")
        ]),
        .testTarget(
            name: "OpenWrtKitTests",
            dependencies: ["OpenWrtKit", "OpenWrtSSH"],
            resources: [
                .copy("Fixtures/snapshot-192.168.31.167-2026-11-20.json"),
                .copy("Fixtures/snapshot-192.168.31.1-2026-11-20.json"),
                .copy("Fixtures/menu-192.168.31.167-anonymous.json"),
                .copy("Fixtures/menu-192.168.31.167-full.json"),
                .copy("Fixtures/translations-192.168.31.167.txt"),
                .copy("Fixtures/translations-192.168.31.1.txt"),
                .copy("Fixtures/uci-luci-192.168.31.167.json"),
                .copy("Fixtures/uci-luci-192.168.31.1.json"),
                .copy("Fixtures/nftables-192.168.31.167.json")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
