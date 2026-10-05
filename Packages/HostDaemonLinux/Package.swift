// swift-tools-version:6.0
import Foundation
import PackageDescription

// The pinned vendor/boringssl's libcrypto, built by scripts/build-boringssl-linux.sh into a
// per-arch directory so an x86_64 and an aarch64 build cannot pick up each other's archive.
#if arch(x86_64)
let arch = "x86_64"
#else
let arch = "aarch64"
#endif
// Absolute, from this manifest's own location, because the two flags below are read by
// different tools from different working directories, and a relative one that resolves for
// clang compiling shim.c does not for swiftc importing the module or for the linker.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let boringSSLInclude = "\(root)/Vendor/boringssl-include"

// Linux-only by intent: the macOS hostd is the xcodegen `HostDaemon` target, which serves the
// same frames over FleetKit's Network.framework listener. Nothing here is referenced by
// project.yml, so Xcode never resolves SwiftNIO for the app.
let package = Package(
    name: "HostDaemonLinux",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
        // The host protocol core, controller store and admin socket — the same sources the
        // macOS hostd and the app build, so the two hostds cannot disagree on a frame.
        .package(path: "../HostKit"),
    ],
    targets: [
        // SPAKE2 from the *pinned* BoringSSL — the same source the Mac and the phone link —
        // rather than swift-nio-ssl's or swift-crypto's vendored copies, which are other
        // BoringSSL revisions behind CNIOBoringSSL_/CCryptoBoringSSL_ symbol prefixes. Their
        // symbols are prefixed and these are not, so all three link into one binary.
        .target(
            name: "BoringSSLShim",
            path: "Sources/BoringSSLShim",
            cSettings: [.headerSearchPath("../../Vendor/boringssl-include")],
            linkerSettings: [.unsafeFlags([
                "-L\(root)/../../vendor/boringssl-artifacts/linux-\(arch)", "-lcrypto",
            ])]
        ),
        // FleetKit's pairing files, compiled here through symlinks (Sources/PairingCore), so
        // the Linux responder runs the phone's exact SPAKE2, confirmation and seal code rather
        // than a port of it that could disagree by a byte and present as "wrong code".
        .target(
            name: "PairingCore",
            dependencies: ["BoringSSLShim", .product(name: "Crypto", package: "swift-crypto")],
            // Again here, not only on the shim: `headerSearchPath` reaches clang compiling the
            // shim's own sources and nothing downstream, so Swift importing `BoringSSLShim`
            // failed with "'openssl/curve25519.h' file not found" without this.
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(boringSSLInclude)"])]
        ),
        .executableTarget(
            name: "HostDaemonLinux",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "HostKit", package: "HostKit"),
                "PairingCore",
            ]
        ),
        // Linux-only like the rest of the package: run by scripts/test-hostd-linux.sh in the
        // same container image the interop script builds in.
        .testTarget(
            name: "HostDaemonLinuxTests",
            dependencies: [
                "HostDaemonLinux",
                "PairingCore",
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(boringSSLInclude)"])]
        ),
    ]
)
