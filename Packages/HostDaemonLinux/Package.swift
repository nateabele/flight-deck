// swift-tools-version:6.0
import PackageDescription

// Linux-only by intent: the macOS hostd is the xcodegen `HostDaemon` target, which serves the
// same frames over FleetKit's Network.framework listener. Nothing here is referenced by
// project.yml, so Xcode never resolves SwiftNIO for the app.
let package = Package(
    name: "HostDaemonLinux",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
    ],
    targets: [
        .executableTarget(
            name: "HostDaemonLinux",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
    ]
)
