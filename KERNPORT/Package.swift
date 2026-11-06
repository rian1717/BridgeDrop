// swift-tools-version: 6.0
import PackageDescription

// No third-party dependencies. The Quick Share protocol — wire format, UKEY2
// handshake, secure messages, mDNS discovery and payload transfer — is
// implemented in KERNPORTCore on top of Foundation, Network and CryptoKit
// alone. See docs/ARCHITECTURE.md.
let package = Package(
    name: "KERNPORT",
    platforms: [.macOS("26.0")],   // real Liquid Glass (glassEffect) needs macOS 26
    products: [
        .library(name: "KERNPORTCore", targets: ["KERNPORTCore"]),
        .executable(name: "KERNPORT", targets: ["KERNPORT"]),
        .executable(name: "KERNPORTProbe", targets: ["KERNPORTProbe"]),
    ],
    targets: [
        // Our Quick Share protocol implementation.
        .target(
            name: "KERNPORTCore",
            path: "Sources/KERNPORTCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Our native SwiftUI app.
        .executableTarget(
            name: "KERNPORT",
            dependencies: ["KERNPORTCore"],
            path: "Sources/KERNPORT",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Headless real-device interoperability harness.
        .executableTarget(
            name: "KERNPORTProbe",
            dependencies: ["KERNPORTCore"],
            path: "Sources/KERNPORTProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KERNPORTCoreTests",
            dependencies: ["KERNPORTCore"],
            path: "Tests/KERNPORTCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KERNPORTTests",
            dependencies: ["KERNPORT", "KERNPORTCore"],
            path: "Tests/KERNPORTTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
