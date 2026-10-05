// swift-tools-version:6.0
import PackageDescription

// Foundation-only (spec §2.1): no Network, Security or CryptoKit, so the same sources build
// for the macOS hostd, the app, and the Linux hostd. `scripts/test-hostkit.sh` runs this
// package's tests on both platforms; a Darwin-only API that slips in fails there, not in
// production.
//
// `HostKitDarwin` is the one exception, and it is a separate target so the exception cannot
// leak: the macOS host's power assertions (IOKit) and console/lock state (CoreGraphics), for
// screen runs (§6.3). Its sources are wrapped in `#if os(macOS)`, so on Linux it builds to an
// empty module and HostKit itself still never sees a Darwin framework. Declared here once, in
// the contract task, so the track that fills it never edits this manifest.
let package = Package(
    name: "HostKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HostKit", targets: ["HostKit"]),
        .library(name: "HostKitDarwin", targets: ["HostKitDarwin"]),
    ],
    targets: [
        .target(name: "HostKit"),
        .target(
            name: "HostKitDarwin",
            dependencies: ["HostKit"],
            linkerSettings: [
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("CoreGraphics", .when(platforms: [.macOS])),
            ]
        ),
        // Depends on HostKitDarwin too, so its tests can live here under `#if os(macOS)`
        // without a second test target.
        .testTarget(name: "HostKitTests", dependencies: ["HostKit", "HostKitDarwin"]),
    ]
)
