// swift-tools-version:6.0
import PackageDescription

// Foundation-only (spec §2.1): no Network, Security or CryptoKit, so the same sources build
// for the macOS hostd, the app, and the Linux hostd. `scripts/test-hostkit.sh` runs this
// package's tests on both platforms; a Darwin-only API that slips in fails there, not in
// production.
let package = Package(
    name: "HostKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HostKit", targets: ["HostKit"])],
    targets: [
        .target(name: "HostKit"),
        .testTarget(name: "HostKitTests", dependencies: ["HostKit"]),
    ]
)
