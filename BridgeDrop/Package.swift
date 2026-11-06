// swift-tools-version: 6.0
import PackageDescription

// No third-party dependencies. The Quick Share protocol — wire format, UKEY2
// handshake, secure messages, mDNS discovery and payload transfer — is
// implemented in BridgeDropCore on top of Foundation, Network and CryptoKit
// alone. See docs/ARCHITECTURE.md.
let package = Package(
    name: "KERNPORT",
    platforms: [.macOS("26.0")],   // real Liquid Glass (glassEffect) needs macOS 26
    products: [
        .library(name: "BridgeDropCore", targets: ["BridgeDropCore"]),
        .executable(name: "BridgeDrop", targets: ["BridgeDrop"]),
        .executable(name: "BridgeDropProbe", targets: ["BridgeDropProbe"]),
    ],
    targets: [
        // Our Quick Share protocol implementation.
        .target(
            name: "BridgeDropCore",
            path: "Sources/BridgeDropCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Our native SwiftUI app.
        .executableTarget(
            name: "BridgeDrop",
            dependencies: ["BridgeDropCore"],
            path: "Sources/BridgeDrop",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Headless real-device interoperability harness.
        .executableTarget(
            name: "BridgeDropProbe",
            dependencies: ["BridgeDropCore"],
            path: "Sources/BridgeDropProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BridgeDropCoreTests",
            dependencies: ["BridgeDropCore"],
            path: "Tests/BridgeDropCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BridgeDropTests",
            dependencies: ["BridgeDrop", "BridgeDropCore"],
            path: "Tests/BridgeDropTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
