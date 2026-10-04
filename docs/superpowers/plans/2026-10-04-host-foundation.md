# Host Foundation (Sub-project A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pair a Mac host and a Linux host with a controller Flight Deck from the GUI, keep a live authenticated connection to each one, and answer `flightdeck host ls` and `flightdeck host info <host>` from a session shell.

**Architecture:** A Foundation-only SwiftPM package, `HostKit`, holds the wire protocol, the host's controller store, the host-info probe, the admin socket and the transport-agnostic `HostServerCore`. Two thin executables wrap it.
- **macOS hostd:** an xcodegen tool target that serves `HostServerCore` over FleetKit's existing TLS-PSK and WebSocket listener. It is registered as a GUI-session LaunchAgent with `SMAppService`.
- **Linux hostd:** a separate SwiftPM package that serves the same frames over SwiftNIO and swift-nio-ssl.

Pairing reuses FleetKit's SPAKE2 exchange, parameterized by a `PairingProfile` so host pairing is domain-separated from phone pairing. On the controller, `HostRegistry`, `HostLink` and `HostService` hold the paired hosts and their connections, and two new `FleetRequest`s expose them to the CLI.

**Tech Stack:**
- Swift 6.3.3 (Xcode toolchain and the `swift:6.3-noble` Docker image).
- Network.framework (Darwin).
- SwiftNIO, swift-nio-ssl and NIOWebSocket (Linux).
- Pinned `vendor/boringssl` libcrypto for SPAKE2 on Linux.
- swift-crypto on Linux, in place of CryptoKit.
- XcodeGen, ServiceManagement (`SMAppService`), and systemd user units.

**Spec:** `docs/superpowers/specs/2026-10-03-remote-hosts-delegation-design.md`. This plan implements §1–3 and §2.1's units for sub-project **A**, plus the `host ls` / `host info` rows of §5. Sub-project C (§4–§9) gets its own plan. See "Not in this plan" at the end.

## Global Constraints

- Hosts are macOS or Linux, x86_64 or arm64. No Windows.
- `HostKit` is "Foundation-only, Swift 6, with no Network.framework, Security or CryptoKit". It must build and test on Linux.
- FleetKit stays Foundation, Network, Security and CryptoKit only, because it also compiles for iOS (`FleetKitiOS`). Touching FleetKit means running `./scripts/build-ios.sh`.
- The app target keeps `SWIFT_VERSION: "5.0"`. New SwiftPM packages use tools version 6.0.
- TLS: `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8) over TLS 1.2. **Never pin a TLS 1.3 minimum.** FleetTLS records that this silently breaks PSK.
- Bonjour service types must be at most 15 characters. Host fleet: `_fd-host._tcp`. Host pairing: `_fd-host-pair._tcp`.
- Pairing codes are valid for **2 minutes**, with at most 3 attempts, as for the phone.
- Liveness: a WebSocket ping every 15 s. Three missed pings mean offline. Reconnect backoff runs from 1 s to 30 s, and an `NWPathMonitor` change resets it.
- `hello {protocol: major.minor, capabilities: [...]}`. A major-version mismatch is refused.
- hostd runs as the user who enabled it, never as root.
- The controller's paired hosts live in `Application Support/Flight Deck/hosts.json`, never in `sessions.json`.
- Target and module names must not differ from an existing name only by case (APFS is case-insensitive here; see `project.yml:275-296`).
- **Commits:** lowercase, behavioral, imperative, with the trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- **Tests:**
  - TDD: confirm each test fails against the broken code first. Never weaken an assertion.
  - `./scripts/test-unit.sh` runs the **whole** macOS suite every time (about 8 minutes) and exits 0 even when tests fail. Always `rg -n "error:|failed" <log>`.
  - Use `FD_TEST_FILTER=Class` to scope a run.
  - Subagents run tests in the foreground.
- **Never launch a bundle from `DerivedData/`.** Never swap `/Applications`. GUI end-to-end checks are the maintainer's (AGENTS.md rule 2).
- The checkout is shared. Never `git stash` and never revert files you didn't write.

**Deviations from the spec, decided while planning (record them in the spec in Task 12):**
1. §2.1 says the controller's host secrets go "in the Keychain, as for phone slots". Phone slots actually live in the `preferences.v1` UserDefaults blob (`PairedDevice.swift:10`). This plan **does** use the Keychain for host secrets (service `dev.flightdeck.host`), which is stronger. Only the "as for phone slots" clause is wrong.
2. §3.1 says the target shows "a code and QR". A Mac controller has no camera to scan a QR, so host pairing shows the **code only**.
3. The host keeps its controllers in a `0600` file (`controllers.json`) on both platforms. The spec is silent here, and Linux has no keychain.

## Review Focus

1. **A host's address changes** (DHCP, a Wi-Fi switch, the laptop moving to Tailscale). Expect: `HostLink` reaches the host again with no re-pairing, through Bonjour or the next stored address. Test: Task 8, `testReconnectsWhenStoredEndpointIsStale`.
2. **A controller is unpaired on the host while it is connected.** Expect: the live connection closes within one second, and the next connect is refused. Test: Task 7, `testRevokedControllerIsDisconnected`; Task 6, the same scenario for Linux.
3. **Pairing is armed while a code is already showing.** Expect: the old code dies, only the newest code works, and two controllers can't both pair from one code. Test: Task 5, `testArmReplacesPreviousCode`.
4. **Two paired hosts have the same display name** (two Macs called "mini"). Expect: pairing stores the second one as `mini-2`. `host info mini` resolves to exactly one host or fails with the list. It never picks one silently. Test: Task 8, `testDuplicateNamesAreDisambiguated`; Task 9, `testHostInfoUnknownNameListsHosts`.
5. **hostd crashes and leaves its admin socket file behind.** Expect: the next hostd start rebinds, and the app reports "Host service is not running" instead of hanging. Test: Task 5, `testStaleSocketFileIsReplaced` and `testClientReportsNotRunning`.

---

## File structure

```
Packages/HostKit/                       Foundation-only library + tests (macOS + Linux)
  Package.swift
  Sources/HostKit/
    HostWire.swift                      client/server/admin frames, ProtocolVersion, capabilities
    HostInfo.swift                      HostInfo value type
    HostInfoProbe.swift                 gathers HostInfo with bounded subprocesses
    HostStateRoot.swift                 per-platform state directory
    ControllerStore.swift               paired controllers, 0600 JSON file
    HostServerCore.swift                transport-agnostic frame handling
    AdminSocket.swift                   POSIX AF_UNIX line socket (server + client)
    PortableRandom.swift                CSPRNG bytes (getentropy)
  Tests/HostKitTests/…
Packages/HostDaemonLinux/               Linux-only executable package
  Package.swift
  Sources/BoringSSLShim/                C target: SPAKE2 header shim over vendor libcrypto
  Sources/PairingCore/                  symlinks to FleetKit's portable pairing files
  Sources/HostDaemonLinux/
    main.swift                          `serve` / `pair` / `status` subcommands
    PSKWebSocketServer.swift            NIO TLS-PSK + WebSocket listener
    NIOPairingResponder.swift           bootstrap-PSK pairing exchange
    AvahiPublisher.swift                optional avahi-publish child
  Vendor/boringssl-include -> ../../../vendor/boringssl/include
Sources/HostDaemon/                     macOS hostd (xcodegen tool target)
  main.swift
  DarwinHostServer.swift
  dev.flightdeck.hostd.plist            LaunchAgent, copied to Contents/Library/LaunchAgents
Sources/FleetKit/
  FleetDeviceKey.swift                  extracted from FleetTLS.swift, portable
  Pairing/PairingProfile.swift          phone vs host names + bonjour types, portable
  HostTransport.swift                   public TLS-PSK+WebSocket params for hosts
  Wire.swift / TimelineFrames.swift / Frames.swift   WireHost, hostList/hostInfo request+reply
Sources/FlightDeck/Hosts/
  HostRecord.swift  HostRegistry.swift  HostSecretStore.swift  HostLink.swift  HostService.swift
  HostAdminClient.swift                 talks to this Mac's hostd admin socket
Sources/FlightDeck/Preferences/UI/
  HostsSettingsTab.swift  AddHostSheet.swift  HostingSettingsTab.swift
scripts/
  build-boringssl-linux.sh  build-hostd-linux.sh  test-hostkit.sh  test-hostd-linux-interop.sh
  hostd-install.sh                      the one-paste Linux installer
Tests/FlightDeckTests/
  LinuxHostdInteropTests.swift  HostTransportLoopbackTests.swift  HostRegistryTests.swift
  HostLinkTests.swift  HostCLITests.swift  PairingProfileTests.swift
```

---

### Task 1: Gate 1 — Linux TLS-PSK and WebSocket interop

This is the §3.2 gate. **If it fails, stop the plan and report back. Do not work around it.** The spec returns to brainstorming for the Linux transport.

**Files:**
- Create: `Sources/FleetKit/HostTransport.swift`
- Create: `Packages/HostDaemonLinux/Package.swift`
- Create: `Packages/HostDaemonLinux/Sources/HostDaemonLinux/PSKWebSocketServer.swift`
- Create: `Packages/HostDaemonLinux/Sources/HostDaemonLinux/main.swift` (an `echo` subcommand, for now)
- Create: `scripts/test-hostd-linux-interop.sh`
- Test: `Tests/FlightDeckTests/LinuxHostdInteropTests.swift`

**Interfaces:**
- Produces:
  - `public enum HostTransport { static func listenerParameters(keys: [FleetDeviceKey]) -> NWParameters; static func clientParameters(key: FleetDeviceKey) -> NWParameters; static func endpoint(for: NWEndpoint) -> NWEndpoint }`
  - `PSKWebSocketServer(host: String, port: Int, keys: () -> [String: [UInt8]], onText: (Connection, String) -> Void)`, keyed by PSK identity (a UUID string).

- [ ] **Step 1: Add the public FleetKit seam.** `FleetSocket` is internal, so hosts need a public composition of TLS-PSK and WebSocket:

```swift
// Sources/FleetKit/HostTransport.swift
import Foundation
import Network

/// The parameters a Flight Deck *host* connection uses: the fleet's TLS-PSK (one slot per paired
/// controller) under the fleet's WebSocket framing. Public because the macOS hostd and the
/// controller's `HostLink` both live outside FleetKit, and `FleetSocket` is internal on purpose —
/// exposing the composition rather than its parts keeps a host from being dialled over bare
/// TLS, which the Linux server would answer with handshake silence.
public enum HostTransport {
    public static func listenerParameters(keys: [FleetDeviceKey]) -> NWParameters {
        FleetSocket.webSocketParameters(FleetTLS.listenerParameters(keys: keys))
    }

    public static func clientParameters(key: FleetDeviceKey) -> NWParameters {
        FleetSocket.webSocketParameters(FleetTLS.clientParameters(key: key))
    }

    /// A `.hostPort` endpoint wrapped as a `ws://` URL; anything else is passed through.
    public static func endpoint(for endpoint: NWEndpoint) -> NWEndpoint {
        FleetSocket.webSocketEndpoint(for: endpoint)
    }
}
```

- [ ] **Step 2: Write the failing interop test.** It skips unless the script below has started the container:

```swift
// Tests/FlightDeckTests/LinuxHostdInteropTests.swift
import Foundation
import Network
import XCTest
@testable import FleetKit

/// The §3.2 gate: Darwin's Network.framework TLS-PSK client against swift-nio-ssl (BoringSSL).
/// Skipped unless `scripts/test-hostd-linux-interop.sh` started the Linux server and exported
/// `FD_LINUX_HOSTD_ENDPOINT` (host:port) — `test-unit.sh` runs xctest directly, so a plain
/// variable reaches the runner (no TEST_RUNNER_ prefix needed there).
final class LinuxHostdInteropTests: XCTestCase {
    static let slot = UUID(uuidString: "6F0B2C1E-8E37-4D7A-9D0A-3C5E2B1A9F00")!
    static let secret = Data(repeating: 0x5A, count: 32)

    func testEchoOverPSKWebSocket() async throws {
        guard let spec = ProcessInfo.processInfo.environment["FD_LINUX_HOSTD_ENDPOINT"] else {
            throw XCTSkip("FD_LINUX_HOSTD_ENDPOINT not set")
        }
        let parts = spec.split(separator: ":")
        let endpoint = NWEndpoint.hostPort(host: .init(String(parts[0])),
                                           port: .init(String(parts[1]))!)
        let key = FleetDeviceKey(slot: Self.slot, secret: Self.secret)
        let connection = NWConnection(to: HostTransport.endpoint(for: endpoint),
                                      using: HostTransport.clientParameters(key: key))
        let reply = try await Self.roundTrip(connection, text: "ping-gate")
        XCTAssertEqual(reply, "echo:ping-gate")
        let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        let suite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(tls!.securityProtocolMetadata)
        XCTAssertEqual(suite.rawValue, 0x00A8)
        connection.cancel()
    }

    func testWrongKeyIsRefused() async throws {
        guard let spec = ProcessInfo.processInfo.environment["FD_LINUX_HOSTD_ENDPOINT"] else {
            throw XCTSkip("FD_LINUX_HOSTD_ENDPOINT not set")
        }
        let parts = spec.split(separator: ":")
        let endpoint = NWEndpoint.hostPort(host: .init(String(parts[0])),
                                           port: .init(String(parts[1]))!)
        let key = FleetDeviceKey(slot: Self.slot, secret: Data(repeating: 0x00, count: 32))
        let connection = NWConnection(to: HostTransport.endpoint(for: endpoint),
                                      using: HostTransport.clientParameters(key: key))
        do {
            _ = try await Self.roundTrip(connection, text: "x", timeout: 5)
            XCTFail("a wrong PSK must not complete a WebSocket round trip")
        } catch {}
        connection.cancel()
    }

    /// Connects, sends one text frame, returns the first text frame received.
    static func roundTrip(_ c: NWConnection, text: String, timeout: TimeInterval = 10) async throws -> String {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<String, Error>) in
            let queue = DispatchQueue(label: "interop")
            var done = false
            func finish(_ r: Result<String, Error>) { guard !done else { return }; done = true; k.resume(with: r) }
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(URLError(.timedOut))) }
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                    let ctx = NWConnection.ContentContext(identifier: "t", metadata: [meta])
                    c.send(content: Data(text.utf8), contentContext: ctx, isComplete: true,
                           completion: .contentProcessed { if let e = $0 { finish(.failure(e)) } })
                    c.receiveMessage { data, _, _, error in
                        if let error { return finish(.failure(error)) }
                        finish(.success(String(decoding: data ?? Data(), as: UTF8.self)))
                    }
                case .failed(let e), .waiting(let e): finish(.failure(e))
                default: break
                }
            }
            c.start(queue: queue)
        }
    }
}
```

- [ ] **Step 3: Create the Linux package.**

```swift
// Packages/HostDaemonLinux/Package.swift
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
```

- [ ] **Step 4: Write `PSKWebSocketServer`.**
  - TLS: build the configuration with `var tls = TLSConfiguration.makePreSharedKeyConfiguration()`, then:
    - set `tls.minimumTLSVersion = .tlsv12` and `tls.maximumTLSVersion = .tlsv12`;
    - set `tls.cipherSuites = "PSK-AES128-GCM-SHA256"`;
    - set `tls.pskServerProvider` to a closure that looks the client's identity string up in `keys()` and returns `PSKServerIdentityResponse(key: NIOSSLSecureBytes(bytes))`, or throws for an unknown identity.
  - Pipeline: `NIOSSLServerHandler`, then `HTTPServerUpgradeHandler` with `NIOWebSocketServerUpgrader` (accepts any URI, `maxFrameSize: 16 << 20`), then a `WebSocketFrameHandler`.
    - The frame handler answers `.ping` with `.pong` (mirroring `autoReplyPing` on the Darwin side) and closes on `.connectionClose`.
    - It passes `.text` frames to `onText(connection, text)`.
  - `Connection` exposes `identity: String` (captured in the PSK callback and stored on the channel's `ChannelHandlerContext` via a `SlotAttribute` handler) and `send(text:)`.
  - **Verify the API names against the resolved swift-nio-ssl version** (`swift package resolve`, then read `Sources/NIOSSL/TLSConfiguration.swift`). The plan's names come from the 2.2x PSK API. If `pskServerProvider` is spelled differently, use the real spelling and note it in the commit body.
  - `main.swift echo --port N --slot UUID --secret-hex HEX` serves keys `[slot: secret]` and replies `"echo:" + text`.

- [ ] **Step 5: Write the interop script.**

```bash
#!/usr/bin/env bash
# scripts/test-hostd-linux-interop.sh — §3.2 gate and Linux hostd integration.
# Builds Packages/HostDaemonLinux in swift:6.3-noble, runs it on a published port, then runs
# the Darwin side through test-unit.sh scoped to the interop classes.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=swift:6.3-noble
NAME=fd-hostd-interop-$$
PORT=${FD_INTEROP_PORT:-47411}
MODE=${1:-echo}            # echo (gate 1) | pair (gate 2) | serve (task 6)
docker run -d --rm --name "$NAME" -p "127.0.0.1:$PORT:$PORT" \
  -v "$PWD:/src" -w /src/Packages/HostDaemonLinux "$IMAGE" \
  bash -c "swift build -c debug && .build/debug/HostDaemonLinux $MODE --port $PORT \
           --slot 6F0B2C1E-8E37-4D7A-9D0A-3C5E2B1A9F00 --secret-hex $(printf '5a%.0s' {1..32})" >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
until docker logs "$NAME" 2>&1 | rg -q "listening on"; do
  docker inspect "$NAME" >/dev/null 2>&1 || { echo "container died"; exit 1; }; sleep 1
done
FD_LINUX_HOSTD_ENDPOINT="127.0.0.1:$PORT" FD_TEST_FILTER="${FD_INTEROP_FILTER:-LinuxHostdInteropTests}" \
  ./scripts/test-unit.sh 2>&1 | tee /tmp/fd-interop.log
! rg -n "error:|failed \(" /tmp/fd-interop.log
```

The `main.swift` prints `listening on <port>` once it is bound.

- [ ] **Step 6: Run it and confirm it fails while the server is a stub** (point `onText` at nothing).
  Run: `./scripts/test-hostd-linux-interop.sh echo`
  Expected: `testEchoOverPSKWebSocket` FAILs with a timeout. `testWrongKeyIsRefused` passes.

- [ ] **Step 7: Implement the echo.** Run the script again.
  Expected: both tests pass, and the suite assertion confirms 0x00A8.
  **If the handshake never completes:** capture the swift-nio-ssl error log and the Darwin `NWConnection` state, commit nothing, and report the failure back as the gate result.

- [ ] **Step 8: Run `./scripts/build-ios.sh`.** `HostTransport.swift` is in FleetKit and must compile for iOS.

- [ ] **Step 9: Commit**

```bash
git add Sources/FleetKit/HostTransport.swift Packages/HostDaemonLinux scripts/test-hostd-linux-interop.sh Tests/FlightDeckTests/LinuxHostdInteropTests.swift
git commit -m "test: prove a Darwin TLS-PSK client talks to a swift-nio-ssl host

<body: negotiated suite, NIO PSK API names as resolved, timing>

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Gate 2 — portable pairing core and Linux SPAKE2 interop

This proves that a Darwin `PairingInitiator` pairs with a Linux responder. **If the pinned BoringSSL will not build or link on Linux, stop and report.**

**Files:**
- Create: `Sources/FleetKit/FleetDeviceKey.swift`. Move `FleetDeviceKey` here from `FleetTLS.swift:5-34`, unchanged except for `mint()`.
- Create: `Sources/FleetKit/Pairing/PairingProfile.swift`
- Modify:
  - `Sources/FleetKit/PairingCode.swift`: `mint()` randomness and the CryptoKit import.
  - `Sources/FleetKit/SPAKE2/PairingSecrets.swift`: the import only.
  - `PairingListener.swift`, `PairingInitiator.swift`, `PairingBrowser.swift` and `PairingRunner.swift`: take a profile.
- Create: `scripts/build-boringssl-linux.sh`
- Create:
  - `Packages/HostDaemonLinux/Sources/BoringSSLShim/{include/BoringSSLShim.h,shim.c}`
  - `Packages/HostDaemonLinux/Sources/PairingCore/` (symlinks)
  - `Packages/HostDaemonLinux/Sources/HostDaemonLinux/NIOPairingResponder.swift`
- Test:
  - `Tests/FlightDeckTests/PairingProfileTests.swift`
  - `Tests/FlightDeckTests/LinuxHostdInteropTests.swift`, adding `testDarwinInitiatorPairsWithLinuxResponder`

**Interfaces:**
- Produces:
  - `public struct PairingProfile: Sendable, Equatable { bonjourType: String; initiatorName: Data; responderName: Data; static let phone; static let host }`
  - `PairingListener.init(profile: PairingProfile = .phone, queue:)`, `PairingInitiator.init(profile:queue:)`, `PairingBrowser.init(profile:queue:)` and `PairingRunner.init(profile:queue:)`. Every existing call site keeps the `.phone` default.
  - `NIOPairingResponder.run(code: PairingCode, key: FleetDeviceKey, hostName: String, port: Int, deadline: TimeInterval = 120) async throws`. It returns once the sealed key is delivered. The responder never learns the controller's name; the controller sends it in its first `hello` (Task 4's `onControllerName`).

- [ ] **Step 1: Write the failing profile tests.**

```swift
// Tests/FlightDeckTests/PairingProfileTests.swift
import XCTest
@testable import FleetKit

final class PairingProfileTests: XCTestCase {
    func testPhoneProfileIsTheShippedConstants() {
        XCTAssertEqual(PairingProfile.phone.bonjourType, "_flightdeck-pair._tcp")
        XCTAssertEqual(PairingProfile.phone.initiatorName, Data("flightdeck-phone".utf8))
        XCTAssertEqual(PairingProfile.phone.responderName, Data("flightdeck-mac".utf8))
    }

    /// Domain separation: a code typed into a host pairing must never complete against a phone
    /// pairing window, and vice versa — SPAKE2 names are bound into the key, so differing names
    /// make the confirmations mismatch.
    func testHostProfileIsDomainSeparated() {
        XCTAssertEqual(PairingProfile.host.bonjourType, "_fd-host-pair._tcp")
        XCTAssertLessThanOrEqual(PairingProfile.host.bonjourType.split(separator: ".")[0].count - 1, 15)
        XCTAssertNotEqual(PairingProfile.host.initiatorName, PairingProfile.phone.initiatorName)
        XCTAssertNotEqual(PairingProfile.host.responderName, PairingProfile.phone.responderName)
    }

    func testHostInitiatorFailsAgainstPhoneListener() async throws {
        // Arm a phone-profile PairingListener on loopback and dial it with a host-profile
        // PairingInitiator using the right code: expect `.wrongCode`, never `onPaired`.
        let listener = PairingListener(profile: .phone)
        let code = PairingCode.mint()
        let port = try await listener.start(code: code, key: .mint(), macName: "m",
                                            serviceName: "t-\(UUID())", port: nil)
        let initiator = PairingInitiator(profile: .host)
        let failed = expectation(description: "fails")
        initiator.onPaired = { _, _ in XCTFail("cross-profile pairing must not succeed") }
        initiator.onFailure = { failure in XCTAssertEqual(failure, .wrongCode); failed.fulfill() }
        initiator.start(code: code, endpoint: .hostPort(host: "127.0.0.1", port: port))
        await fulfillment(of: [failed], timeout: 15)
        listener.stop()
    }
}
```

  Check `PairingInitiator.onFailure`'s exact closure shape in `PairingInitiator.swift` and match it.

- [ ] **Step 2: Run them and confirm they fail.**
  Run: `FD_TEST_FILTER=PairingProfileTests ./scripts/test-unit.sh 2>&1 | tee /tmp/t.log; rg -n "error:" /tmp/t.log`
  Expected: the compile fails with `cannot find 'PairingProfile' in scope`.

- [ ] **Step 3: Add the profile and thread it through.**

```swift
// Sources/FleetKit/Pairing/PairingProfile.swift
import Foundation

/// Which pairing this is. SPAKE2 binds both names into the derived key, so two profiles with
/// different names cannot complete against each other even with the right code — that is what
/// stops a code shown for a host from pairing a phone, and the reverse.
///
/// Foundation-only and free of Network on purpose: the Linux hostd compiles this file directly
/// (Packages/HostDaemonLinux/Sources/PairingCore is a symlink farm), so it must not grow imports.
public struct PairingProfile: Sendable, Equatable {
    public let bonjourType: String
    public let initiatorName: Data
    public let responderName: Data

    public static let phone = PairingProfile(
        bonjourType: "_flightdeck-pair._tcp",
        initiatorName: Data("flightdeck-phone".utf8),
        responderName: Data("flightdeck-mac".utf8)
    )

    public static let host = PairingProfile(
        bonjourType: "_fd-host-pair._tcp",
        initiatorName: Data("flightdeck-controller".utf8),
        responderName: Data("flightdeck-host".utf8)
    )
}
```

  Then thread the profile through:
  - Make `PairingChannel.bonjourType`, `initiatorName` and `responderName` forward to `PairingProfile.phone` (the iOS app still reads them).
  - Replace the three uses at `PairingListener.swift:220,403`, `PairingInitiator.swift:107` and `PairingBrowser.swift:52` with `profile.…`.
  - Add `profile` as the first init parameter, defaulting to `.phone`, on all four types. `PairingRunner` passes its profile into the browser and initiator it creates.

- [ ] **Step 4: Make the shared files portable.** Do this in `FleetDeviceKey.swift`, `PairingCode.swift`, `PairingSecrets.swift`, `SPAKE2Session.swift` and `PairingFrames.swift`.
  - Imports:
    ```swift
    #if canImport(CryptoKit)
    import CryptoKit
    #else
    import Crypto   // swift-crypto: same API surface for SHA256/HKDF/HMAC/AES.GCM
    #endif
    ```
  - Randomness: replace each `SecRandomCopyBytes` with:
    ```swift
    #if canImport(Security)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
    #else
    // getentropy is the Linux CSPRNG with no fd and no partial reads below 256 bytes.
    precondition(getentropy(&bytes, bytes.count) == 0, "getentropy failed: \(errno)")
    #endif
    ```
    with `#if canImport(Security) import Security #else import Glibc #endif`.
  - Leave the comments that explain trapping, and add one line naming the Linux branch.

- [ ] **Step 5: Run the profile tests and the existing pairing suites.**
  Run: `FD_TEST_FILTER=PairingProfileTests,PairingListenerTests,PairingInitiatorTests,PairingRunnerTests,PairingSecretsTests ./scripts/test-unit.sh 2>&1 | tee /tmp/t.log; rg -n "error:|failed \(" /tmp/t.log`
  Expected: no matches. Then run `./scripts/build-ios.sh` and expect success.

- [ ] **Step 6: Build the pinned BoringSSL for Linux.**

```bash
#!/usr/bin/env bash
# scripts/build-boringssl-linux.sh — libcrypto.a from the pinned vendor/boringssl for the
# Linux hostd's SPAKE2. Separate from swift-nio-ssl's own vendored copy (whose symbols are
# CNIOBoringSSL_-prefixed), so the two link side by side without clashing.
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH=${1:-$(uname -m | sed 's/arm64/aarch64/')}
OUT=vendor/boringssl-artifacts/linux-$ARCH
PLATFORM=$([ "$ARCH" = x86_64 ] && echo linux/amd64 || echo linux/arm64)
mkdir -p "$OUT"
docker run --rm --platform "$PLATFORM" -v "$PWD:/src" -w /src swift:6.3-noble bash -c "
  apt-get update -qq && apt-get install -y -qq cmake ninja-build golang >/dev/null &&
  cmake -S vendor/boringssl -B /tmp/b -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON &&
  ninja -C /tmp/b crypto && cp /tmp/b/libcrypto.a $OUT/"
ls -l "$OUT/libcrypto.a"
```

- [ ] **Step 7: Wire the shim and the symlinked pairing core into `Packages/HostDaemonLinux/Package.swift`.**

```swift
// add to dependencies:
.package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
// add targets:
.target(
    name: "BoringSSLShim",
    path: "Sources/BoringSSLShim",
    cSettings: [.headerSearchPath("../../Vendor/boringssl-include")],
    linkerSettings: [.unsafeFlags(["-L../../vendor/boringssl-artifacts/linux-\(arch)", "-lcrypto"])]
),
.target(
    name: "PairingCore",
    dependencies: ["BoringSSLShim", .product(name: "Crypto", package: "swift-crypto")]
),
// and HostDaemonLinux gains: "PairingCore"
```

  - Compute `arch` at the top of the manifest:
    ```swift
    #if arch(x86_64)
    let arch = "x86_64"
    #else
    let arch = "aarch64"
    #endif
    ```
  - Copy `include/BoringSSLShim.h` from `Sources/FleetKit/SPAKE2/BoringSSLShim.h`. Its `#error` guard stays. `shim.c` is an empty translation unit, which SwiftPM requires for a C target.
  - Create the symlinks. Each target is relative to `Packages/HostDaemonLinux/Sources/PairingCore/`:
    ```bash
    cd Packages/HostDaemonLinux/Sources/PairingCore
    for f in FleetDeviceKey.swift PairingCode.swift Pairing/PairingProfile.swift Pairing/PairingFrames.swift \
             SPAKE2/PairingSecrets.swift SPAKE2/SPAKE2Session.swift; do
      ln -s "../../../../Sources/FleetKit/$f" "$(basename "$f")"; done
    ln -s ../../../vendor/boringssl/include ../../Vendor/boringssl-include
    ```
    The `../../Vendor` link is created in `Packages/HostDaemonLinux/Vendor`; make that directory first.
  - **Access levels:** `PairingFrames` cases are `internal`. They are now compiled into `PairingCore` and used by `HostDaemonLinux`, so add `@_spi(HostPairing) public` to the two frame enums and `PairingRejection`, and use `@_spi(HostPairing) import PairingCore` on Linux. This keeps them out of FleetKit's public API.

- [ ] **Step 8: Write the failing cross-platform pairing test.** Add it to `LinuxHostdInteropTests`:

```swift
func testDarwinInitiatorPairsWithLinuxResponder() async throws {
    guard let spec = ProcessInfo.processInfo.environment["FD_LINUX_HOSTD_ENDPOINT"],
          let codeText = ProcessInfo.processInfo.environment["FD_LINUX_HOSTD_CODE"],
          let code = PairingCode(normalizing: codeText) else {
        throw XCTSkip("pairing interop env not set")
    }
    let parts = spec.split(separator: ":")
    let initiator = PairingInitiator(profile: .host)
    let paired = expectation(description: "paired")
    initiator.onPaired = { key, hostName in
        XCTAssertEqual(key.slot, Self.slot)          // the responder seals the slot it was given
        XCTAssertEqual(key.secret, Self.secret)
        XCTAssertEqual(hostName, "interop-host")
        paired.fulfill()
    }
    initiator.onFailure = { XCTFail("pairing failed: \($0)") }
    initiator.start(code: code, endpoint: .hostPort(host: .init(String(parts[0])), port: .init(String(parts[1]))!))
    await fulfillment(of: [paired], timeout: 30)
}
```

  - The script's `pair` mode runs `HostDaemonLinux pair-test --port N --slot … --secret-hex … --code <fixed>`, using a fixed code minted once and pasted into the script as `FD_LINUX_HOSTD_CODE`.
  - Run with `FD_INTEROP_FILTER=LinuxHostdInteropTests/testDarwinInitiatorPairsWithLinuxResponder`.
  - Expected: FAIL (connection refused) while `pair-test` is unimplemented.

- [ ] **Step 9: Implement `NIOPairingResponder`.** Mirror `PairingListener`'s protocol exactly: `PairingListener.swift` is the reference, and its comments are the requirements.
  - **TLS:** a bootstrap-PSK listener with the identity `PairingChannel.bootstrapIdentity` bytes (`"flightdeck-pairing-bootstrap-v1"`). The secret is `SHA256("…")`; copy the derivation from `PairingChannel.swift:54`. Same TLS 1.2 PSK suite, with WebSocket on top.
  - **Exchange:**
    1. Receive `.pake(msg)`.
    2. Create `SPAKE2Session(role: .responder, myName: profile.responderName, theirName: profile.initiatorName)`.
    3. Reply `.pake(msg: session.message(for: code))`, then derive `PairingSecrets(keyMaterial: session.keyMaterial(from: msg), transcript: session.transcript)`.
    4. Receive `.confirm(mac)`. If `!PairingSecrets.matches(mac, secrets.initiatorConfirmation)`, spend an attempt and reply `.reject(.badCode)`, or `.attemptsExhausted` at 3.
    5. Otherwise reply `.sealed(mac: secrets.responderConfirmation, box: secrets.seal(key, macName: hostName))` and finish.
  - **Limits:** `maxAttempts = 3`, a 10 s handshake deadline, a 5 s first-frame deadline, a 30 s exchange deadline, 16 KiB frames and a 120 s window.
  - Frames use `JSONEncoder`/`JSONDecoder` with the same `t`-tagged coding, which is the symlinked `PairingFrames.swift` itself.

- [ ] **Step 10: Run the gate.**
  Run: `FD_INTEROP_FILTER=LinuxHostdInteropTests ./scripts/test-hostd-linux-interop.sh pair`
  Expected: PASS. If it fails, report back the logs from both sides.

- [ ] **Step 11: Commit.** Add `vendor/boringssl-artifacts/linux-*` to `.gitignore` if the existing ignore rule doesn't already cover it.

```bash
git add Sources/FleetKit Packages/HostDaemonLinux scripts/build-boringssl-linux.sh Tests/FlightDeckTests/PairingProfileTests.swift Tests/FlightDeckTests/LinuxHostdInteropTests.swift scripts/test-hostd-linux-interop.sh
git commit -m "feat: pair a Linux host with the phone's SPAKE2 exchange under a host profile

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: HostKit package and HostWire

**Files:**
- Create: `Packages/HostKit/Package.swift`, `Packages/HostKit/Sources/HostKit/HostWire.swift`, `Packages/HostKit/Sources/HostKit/HostInfo.swift`
- Create: `scripts/test-hostkit.sh`
- Test: `Packages/HostKit/Tests/HostKitTests/HostWireTests.swift`

**Interfaces:**
- Produces:

```swift
public struct ProtocolVersion: Codable, Sendable, Equatable, Comparable { public let major: Int; public let minor: Int
    public static let current = ProtocolVersion(major: 1, minor: 0) }
public enum HostCapability: String, Codable, Sendable { case hostInfo = "host.info" }
public struct HostInfo: Codable, Sendable, Equatable {
    public var hostName: String; public var platform: String   // "macOS" | "Linux"
    public var osVersion: String; public var arch: String; public var hostdVersion: String
    public var xcode: [String]; public var docker: String?; public var diskFreeBytes: Int64 }
public enum HostClientFrame: Codable, Sendable, Equatable {
    case hello(protocolVersion: ProtocolVersion, capabilities: [HostCapability], controllerName: String)
    case request(id: Int, HostRequest) }
public enum HostRequest: Codable, Sendable, Equatable { case hostInfo }
public enum HostServerFrame: Codable, Sendable, Equatable {
    case helloAck(protocolVersion: ProtocolVersion, capabilities: [HostCapability], hostName: String)
    case refused(reason: HostRefusal)
    case reply(id: Int, HostReply)
    case error(id: Int, code: String, message: String) }
public enum HostReply: Codable, Sendable, Equatable { case hostInfo(HostInfo) }
public enum HostRefusal: Codable, Sendable, Equatable { case majorVersionMismatch(host: ProtocolVersion) }
public enum HostWire { public static func encode<T: Encodable>(_ v: T) throws -> String
                       public static func decode<T: Decodable>(_ t: T.Type, from text: String) throws -> T }
```

- [ ] **Step 1: Create the package.**

```swift
// Packages/HostKit/Package.swift
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
```

```bash
#!/usr/bin/env bash
# scripts/test-hostkit.sh — HostKit's tests on macOS, then in swift:6.3-noble.
set -euo pipefail
cd "$(dirname "$0")/../Packages/HostKit"
swift test
docker run --rm -v "$PWD:/src" -w /src swift:6.3-noble swift test --scratch-path /tmp/hk
```

- [ ] **Step 2: Write the failing tests.**

```swift
// Packages/HostKit/Tests/HostKitTests/HostWireTests.swift
import XCTest
@testable import HostKit

final class HostWireTests: XCTestCase {
    func testClientFramesRoundTrip() throws {
        let frames: [HostClientFrame] = [
            .hello(protocolVersion: .current, capabilities: [.hostInfo], controllerName: "laptop"),
            .request(id: 7, .hostInfo),
        ]
        for f in frames {
            XCTAssertEqual(try HostWire.decode(HostClientFrame.self, from: HostWire.encode(f)), f)
        }
    }

    func testServerFramesRoundTrip() throws {
        let info = HostInfo(hostName: "mini", platform: "macOS", osVersion: "26.5", arch: "arm64",
                            hostdVersion: "1.0", xcode: ["26.4"], docker: nil, diskFreeBytes: 42)
        let frames: [HostServerFrame] = [
            .helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini"),
            .refused(reason: .majorVersionMismatch(host: .init(major: 2, minor: 0))),
            .reply(id: 7, .hostInfo(info)),
            .error(id: 7, code: "unsupported", message: "nope"),
        ]
        for f in frames {
            XCTAssertEqual(try HostWire.decode(HostServerFrame.self, from: HostWire.encode(f)), f)
        }
    }

    /// The tag is a stable string on the wire: a Linux hostd and a Mac controller built months
    /// apart must agree, so pin it rather than trusting synthesized Codable.
    func testWireShapeIsPinned() throws {
        XCTAssertEqual(try HostWire.encode(HostClientFrame.request(id: 1, .hostInfo)),
                       #"{"id":1,"req":{"op":"host.info"},"t":"req"}"#)
    }

    /// An unknown frame tag from a newer peer decodes to an error, not a crash, so minor-version
    /// skew degrades instead of killing the connection.
    func testUnknownTagThrows() {
        XCTAssertThrowsError(try HostWire.decode(HostClientFrame.self, from: #"{"t":"future"}"#))
    }

    func testVersionOrdering() {
        XCTAssertLessThan(ProtocolVersion(major: 1, minor: 0), ProtocolVersion(major: 1, minor: 1))
        XCTAssertLessThan(ProtocolVersion(major: 1, minor: 9), ProtocolVersion(major: 2, minor: 0))
    }
}
```

- [ ] **Step 3: Run them and confirm they fail.**
  Run: `cd Packages/HostKit && swift test`
  Expected: the compile fails because the types are missing.

- [ ] **Step 4: Implement the types.**
  - Write hand-rolled `Codable` in the `t`-tag style of `PairingFrames.swift`:
    - client tags are `hello` and `req`;
    - server tags are `helloAck`, `refused`, `reply` and `err`;
    - requests are `{"op":"host.info"}`;
    - replies are `{"op":"host.info","info":{…}}`.
  - `HostWire.encode` uses a `JSONEncoder` with `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`.
  - `ProtocolVersion` is `Comparable` by `(major, minor)`.

- [ ] **Step 5: Run `./scripts/test-hostkit.sh`.** Expected: it passes on macOS and on Linux.

- [ ] **Step 6: Commit** — `git add Packages/HostKit scripts/test-hostkit.sh`, then `git commit -m "feat: add the host wire protocol in a cross-platform HostKit package"` with the trailer.

---

### Task 4: HostKit — controller store, info probe and server core

**Files:**
- Create: `Packages/HostKit/Sources/HostKit/{HostStateRoot,ControllerStore,HostInfoProbe,HostServerCore,PortableRandom}.swift`
- Test: `Packages/HostKit/Tests/HostKitTests/{ControllerStoreTests,HostInfoProbeTests,HostServerCoreTests}.swift`

**Interfaces:**
- Consumes: the Task 3 types.
- Produces:

```swift
public enum HostStateRoot { public static func `default`() -> URL }   // mac: ~/Library/Application Support/Flight Deck Host; linux: $XDG_DATA_HOME or ~/.local/share/flightdeck-hostd
public struct PairedController: Codable, Sendable, Equatable { public let slot: UUID; public var name: String; public let secret: Data; public let pairedAt: Date }
public final class ControllerStore: @unchecked Sendable {
    public init(root: URL); public func all() -> [PairedController]
    public func add(_ c: PairedController) throws; public func revoke(slot: UUID) throws -> Bool
    public var onChange: (@Sendable () -> Void)? }
public struct HostInfoProbe: Sendable { public init(stateRoot: URL, hostdVersion: String, run: @Sendable (String, [String]) -> String? = HostInfoProbe.runCommand)
    public func gather() -> HostInfo; public static func runCommand(_ path: String, _ args: [String]) -> String? }
public protocol HostPeer: AnyObject, Sendable { var slot: UUID { get }; func send(text: String); func close() }
public final class HostServerCore: @unchecked Sendable {
    public init(hostName: @escaping @Sendable () -> String, probe: HostInfoProbe)
    public var onControllerName: (@Sendable (UUID, String) -> Void)?   // fired on each accepted hello
    public func receive(text: String, from peer: HostPeer)      // hello gate, requests, errors
    public func disconnect(slot: UUID)                           // closes every peer of that slot
    public func peerClosed(_ peer: HostPeer) }
public enum PortableRandom { public static func bytes(_ n: Int) -> Data }
```

- [ ] **Step 1: Write the failing tests.**

```swift
// ControllerStoreTests.swift
final class ControllerStoreTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testAddPersistsAndReloads() throws {
        let c = PairedController(slot: UUID(), name: "laptop", secret: PortableRandom.bytes(32), pairedAt: Date())
        try ControllerStore(root: root).add(c)
        XCTAssertEqual(ControllerStore(root: root).all(), [c])
    }

    /// Secrets on disk must not be readable by other users of the host.
    func testFileIsOwnerOnly() throws {
        try ControllerStore(root: root).add(.init(slot: UUID(), name: "x", secret: PortableRandom.bytes(32), pairedAt: Date()))
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("controllers.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as! NSNumber).intValue & 0o777, 0o600)
    }

    func testRevokeRemovesAndNotifies() throws {
        let store = ControllerStore(root: root); let slot = UUID()
        try store.add(.init(slot: slot, name: "x", secret: PortableRandom.bytes(32), pairedAt: Date()))
        let fired = expectation(description: "onChange"); store.onChange = { fired.fulfill() }
        XCTAssertTrue(try store.revoke(slot: slot))
        wait(for: [fired], timeout: 1)
        XCTAssertEqual(store.all(), [])
        XCTAssertFalse(try store.revoke(slot: slot))
    }
}

// HostInfoProbeTests.swift
final class HostInfoProbeTests: XCTestCase {
    func testGatherUsesInjectedCommandsAndDegradesWhenAbsent() {
        let probe = HostInfoProbe(stateRoot: FileManager.default.temporaryDirectory, hostdVersion: "1.0") { path, args in
            if path.hasSuffix("docker") { return "27.3.1\n" }
            return nil   // no xcodebuild, no sw_vers
        }
        let info = probe.gather()
        XCTAssertEqual(info.docker, "27.3.1")
        XCTAssertEqual(info.xcode, [])
        XCTAssertGreaterThan(info.diskFreeBytes, 0)
        XCTAssertFalse(info.hostName.isEmpty)
        #if os(Linux)
        XCTAssertEqual(info.platform, "Linux")
        #else
        XCTAssertEqual(info.platform, "macOS")
        #endif
    }

    /// A hung `docker version` (daemon wedged) must not hang host.info.
    func testRunCommandTimesOut() {
        let start = Date()
        XCTAssertNil(HostInfoProbe.runCommand("/bin/sleep", ["30"]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }
}

// HostServerCoreTests.swift
final class FakePeer: HostPeer, @unchecked Sendable {
    let slot: UUID; var sent: [String] = []; var closed = false
    init(slot: UUID = UUID()) { self.slot = slot }
    func send(text: String) { sent.append(text) }
    func close() { closed = true }
    func frames() throws -> [HostServerFrame] { try sent.map { try HostWire.decode(HostServerFrame.self, from: $0) } }
}

final class HostServerCoreTests: XCTestCase {
    let probe = HostInfoProbe(stateRoot: FileManager.default.temporaryDirectory, hostdVersion: "1.0") { _, _ in nil }
    func core() -> HostServerCore { HostServerCore(hostName: { "mini" }, probe: probe) }
    func hello(_ v: ProtocolVersion = .current) throws -> String {
        try HostWire.encode(HostClientFrame.hello(protocolVersion: v, capabilities: [.hostInfo], controllerName: "laptop"))
    }

    func testHelloThenHostInfo() throws {
        let c = core(); let p = FakePeer()
        c.receive(text: try hello(), from: p)
        c.receive(text: try HostWire.encode(HostClientFrame.request(id: 3, .hostInfo)), from: p)
        let f = try p.frames()
        XCTAssertEqual(f[0], .helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini"))
        guard case .reply(3, .hostInfo(let info)) = f[1] else { return XCTFail("\(f)") }
        XCTAssertEqual(info.hostName, "mini")
    }

    func testRequestBeforeHelloIsRefusedAndClosed() throws {
        let c = core(); let p = FakePeer()
        c.receive(text: try HostWire.encode(HostClientFrame.request(id: 1, .hostInfo)), from: p)
        XCTAssertEqual(try p.frames(), [.error(id: 1, code: "no_hello", message: "send hello first")])
        XCTAssertTrue(p.closed)
    }

    func testMajorMismatchRefuses() throws {
        let c = core(); let p = FakePeer()
        c.receive(text: try hello(.init(major: 2, minor: 0)), from: p)
        XCTAssertEqual(try p.frames(), [.refused(reason: .majorVersionMismatch(host: .current))])
        XCTAssertTrue(p.closed)
    }

    func testMinorSkewIsAccepted() throws {
        let c = core(); let p = FakePeer()
        c.receive(text: try hello(.init(major: 1, minor: 7)), from: p)
        guard case .helloAck = try p.frames().first else { return XCTFail() }
    }

    func testGarbageIsAnErrorNotACrash() throws {
        let c = core(); let p = FakePeer()
        c.receive(text: try hello(), from: p)
        c.receive(text: "{not json", from: p)
        XCTAssertEqual(try p.frames().last, .error(id: 0, code: "malformed", message: "unreadable frame"))
        XCTAssertFalse(p.closed)
    }

    func testHelloNamesTheController() throws {
        let c = core(); let p = FakePeer(); var named: (UUID, String)?
        c.onControllerName = { named = ($0, $1) }
        c.receive(text: try hello(), from: p)
        XCTAssertEqual(named?.0, p.slot); XCTAssertEqual(named?.1, "laptop")
    }

    func testDisconnectSlotClosesOnlyThatSlot() throws {
        let c = core(); let a = FakePeer(); let b = FakePeer()
        c.receive(text: try hello(), from: a); c.receive(text: try hello(), from: b)
        c.disconnect(slot: a.slot)
        XCTAssertTrue(a.closed); XCTAssertFalse(b.closed)
    }
}
```

- [ ] **Step 2: Run `cd Packages/HostKit && swift test`.** Expected: the compile fails.

- [ ] **Step 3: Implement.**
  - **`ControllerStore`:**
    - Guard with an `NSLock`.
    - Write atomically: write to `controllers.json.tmp` with `FileManager.createFile(atPath:contents:attributes: [.posixPermissions: 0o600])`, then `rename(2)`.
    - Create the root with `0o700`.
    - Call `onChange` after every successful mutation.
  - **`HostInfoProbe.runCommand`:** use Foundation `Process` with a pipe, and terminate it after 5 s via `DispatchQueue.asyncAfter` and `process.terminate()`. Return trimmed stdout only on exit 0. Probes:
    - **macOS:** `/usr/bin/sw_vers -productVersion`. Xcode versions come from enumerating `/Applications/Xcode*.app/Contents/version.plist`, reading `CFBundleShortVersionString` with `PropertyListSerialization`. No subprocess is needed.
    - **Linux:** the OS version is `PRETTY_NAME` from `/etc/os-release`.
    - **Docker:** `docker version --format {{.Server.Version}}`, searched in `/usr/local/bin`, `/opt/homebrew/bin` and `/usr/bin`.
    - **Disk free:** `URL.resourceValues(forKeys: [.volumeAvailableCapacityKey])` on macOS; on Linux, `statvfs` `f_bavail * f_frsize` on `stateRoot`.
    - **Architecture:** `uname().machine`.
    - **Host name:** `ProcessInfo.processInfo.hostName`, with a trailing `.local` stripped.
  - **`HostServerCore`:**
    - Keep a dictionary `ObjectIdentifier(peer) -> (peer, helloed: Bool)` under a lock.
    - On a hello from a different major version, send `refused` and close.
    - A request before hello gets `error(no_hello)` and a close.
    - A decode failure gets `error(id: 0, "malformed", "unreadable frame")`.
    - Gather `hostInfo` on a global queue, then send the reply.
    - `disconnect(slot:)` closes and removes every peer with that slot.
  - **`PortableRandom`:** `getentropy` in 256-byte chunks, importing `Glibc` or `Darwin` conditionally.

- [ ] **Step 4: Run `./scripts/test-hostkit.sh`.** Expected: it passes on both platforms.

- [ ] **Step 5: Commit** — `feat: serve host.info from a transport-agnostic host core`, with the trailer.

---

### Task 5: HostKit — admin socket and the arm/revoke protocol

This is how the Hosting tab (macOS) and `flightdeck-hostd pair` (Linux) drive a running hostd. Both run as the same user, so a local `AF_UNIX` socket created with `0600` permissions is the trust boundary.

**Files:**
- Create: `Packages/HostKit/Sources/HostKit/AdminSocket.swift`, `Packages/HostKit/Sources/HostKit/AdminWire.swift`, `Packages/HostKit/Sources/HostKit/PairingWindow.swift`
- Test: `Packages/HostKit/Tests/HostKitTests/AdminSocketTests.swift`, `PairingWindowTests.swift`

**Interfaces:**
- Produces:

```swift
public enum AdminRequest: Codable, Sendable, Equatable { case status; case arm; case cancelArm; case listControllers; case revoke(slot: UUID) }
public enum AdminReply: Codable, Sendable, Equatable {
    case status(paired: Int, armedUntil: Date?, listeningPort: Int?, hostName: String)
    case armed(code: String, expiresAt: Date)          // code is PairingCode.formatted
    case controllers([AdminController]); case ok; case failed(String) }
public struct AdminController: Codable, Sendable, Equatable { public let slot: UUID; public let name: String; public let pairedAt: Date }
public final class AdminSocketServer: @unchecked Sendable {
    public init(path: String, handle: @escaping @Sendable (AdminRequest) -> AdminReply) throws  // unlinks a stale file, chmod 0600
    public func stop() }
public enum AdminSocketClient { public static func send(_ r: AdminRequest, path: String, timeout: TimeInterval = 5) throws -> AdminReply }
public enum AdminSocketError: Error, Equatable { case notRunning; case timedOut; case protocolError }
/// One pairing window at a time; arming again replaces it (Review Focus 3).
public final class PairingWindow: @unchecked Sendable {
    public init(now: @escaping @Sendable () -> Date = Date.init, lifetime: TimeInterval = 120)
    public func arm(codeText: String) -> Date; public func cancel()
    public var current: (code: String, expiresAt: Date)? { get }   // nil once expired
    public func consume(codeText: String) -> Bool }                 // true once, for the live code
```

  `PairingWindow` holds the code as **text** because `PairingCode` lives in FleetKit and PairingCore, not in HostKit. Each hostd mints its `PairingCode` and passes `formatted` in.

- [ ] **Step 1: Write the failing tests.**

```swift
final class AdminSocketTests: XCTestCase {
    var path: String!
    override func setUp() { path = "/tmp/fdhk-\(UUID().uuidString.prefix(8)).sock" }
    override func tearDown() { unlink(path) }

    func testRequestReply() throws {
        let server = try AdminSocketServer(path: path) { req in req == .status ? .status(paired: 2, armedUntil: nil, listeningPort: 4711, hostName: "mini") : .failed("x") }
        defer { server.stop() }
        XCTAssertEqual(try AdminSocketClient.send(.status, path: path), .status(paired: 2, armedUntil: nil, listeningPort: 4711, hostName: "mini"))
    }

    func testSocketIsOwnerOnly() throws {
        let server = try AdminSocketServer(path: path) { _ in .ok }; defer { server.stop() }
        var st = stat(); stat(path, &st)
        XCTAssertEqual(Int(st.st_mode) & 0o777, 0o600)
    }

    /// Review Focus 5: a crashed hostd leaves the file; the next start must rebind.
    func testStaleSocketFileIsReplaced() throws {
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let server = try AdminSocketServer(path: path) { _ in .ok }; defer { server.stop() }
        XCTAssertEqual(try AdminSocketClient.send(.status, path: path), .ok)
    }

    func testClientReportsNotRunning() {
        XCTAssertThrowsError(try AdminSocketClient.send(.status, path: path)) {
            XCTAssertEqual($0 as? AdminSocketError, .notRunning)
        }
    }
}

final class PairingWindowTests: XCTestCase {
    func testArmReplacesPreviousCode() {
        let w = PairingWindow()
        _ = w.arm(codeText: "AAAA-BBBB-CCCC")
        _ = w.arm(codeText: "DDDD-EEEE-FFFF")
        XCTAssertFalse(w.consume(codeText: "AAAA-BBBB-CCCC"))
        XCTAssertTrue(w.consume(codeText: "DDDD-EEEE-FFFF"))
        XCTAssertFalse(w.consume(codeText: "DDDD-EEEE-FFFF"), "a code pairs exactly one controller")
    }

    func testExpiresAfterLifetime() {
        var now = Date(timeIntervalSince1970: 0)
        let w = PairingWindow(now: { now }, lifetime: 120)
        _ = w.arm(codeText: "AAAA-BBBB-CCCC")
        now += 121
        XCTAssertNil(w.current)
        XCTAssertFalse(w.consume(codeText: "AAAA-BBBB-CCCC"))
    }
}
```

- [ ] **Step 2: Run `swift test`.** Expected: the compile fails.

- [ ] **Step 3: Implement.**
  - **`AdminSocketServer`:**
    - Create `socket(AF_UNIX, SOCK_STREAM)`, `unlink(path)` first, then `bind`, `chmod(path, 0o600)` and `listen(4)`.
    - Accept in a loop on a dedicated `Thread`, one connection at a time. Read up to `\n` (cap 64 KiB), decode `AdminRequest` with `HostWire.decode`, write `encode(reply) + "\n"`, and close.
    - `stop()` does `shutdown`, `close` and `unlink`.
    - `sun_path` overflow (more than 103 bytes) throws. Name the limit in a comment, as `DaemonControl.swift:82` does.
  - **`AdminSocketClient`:** set `SO_RCVTIMEO`/`SO_SNDTIMEO` to `timeout`. `ENOENT` or `ECONNREFUSED` maps to `.notRunning`.
  - `AdminWire` uses `t` tags: `status`, `arm`, `cancelArm`, `ls`, `revoke`; replies `status`, `armed`, `controllers`, `ok`, `failed`.

- [ ] **Step 4: Run `./scripts/test-hostkit.sh`.** Expected: it passes on both platforms.

- [ ] **Step 5: Commit** — `feat: drive a running hostd over a user-only admin socket`, with the trailer.

---

### Task 6: Linux hostd — serve, pair and status

**Files:**
- Modify: `Packages/HostDaemonLinux/Package.swift`. Add `.package(path: "../HostKit")` and give `HostDaemonLinux` the `HostKit` dependency.
- Modify: `Packages/HostDaemonLinux/Sources/HostDaemonLinux/main.swift`
- Create: `Packages/HostDaemonLinux/Sources/HostDaemonLinux/AvahiPublisher.swift`
- Test: `Tests/FlightDeckTests/LinuxHostdInteropTests.swift`. Add `testHelloAndHostInfoAgainstLinuxHostd` and `testRevokedControllerIsDisconnected`.

**Interfaces:**
- Consumes:
  - From HostKit: `HostServerCore`, `ControllerStore`, `AdminSocketServer`, `PairingWindow`, `HostInfoProbe` and `HostStateRoot`.
  - `NIOPairingResponder` (Task 2) and `PSKWebSocketServer` (Task 1).
- Produces the CLI contract that `hostd-install.sh` (Task 11) relies on:
  - `flightdeck-hostd serve [--port 47410] [--root DIR]` prints `listening on <port>`.
  - `flightdeck-hostd pair [--root DIR]` arms through the admin socket, prints `Pairing code: XXXX-XXXX-XXXX (valid 2 minutes)`, then polls `status` until `paired` grows or the code expires. Exit code: 0 when paired, 1 when the code expired, 2 when hostd is not running.
  - `flightdeck-hostd status` prints the status as JSON.
- The admin socket lives at `<root>/admin.sock`. The default port is **47410**, and the pairing port is **47411**.

- [ ] **Step 1: Write the failing Darwin-side tests.** Add them to `LinuxHostdInteropTests`. They use a `serve` mode that the script starts with `--test-controller <slot>:<hex>`, which seeds `ControllerStore` at start. That flag is accepted only when `FD_HOSTD_TEST=1`.

```swift
func testHelloAndHostInfoAgainstLinuxHostd() async throws {
    guard let ep = Self.endpoint() else { throw XCTSkip("FD_LINUX_HOSTD_ENDPOINT not set") }
    let c = NWConnection(to: HostTransport.endpoint(for: ep), using: HostTransport.clientParameters(key: .init(slot: Self.slot, secret: Self.secret)))
    let hello = try HostWire.encode(HostClientFrame.hello(protocolVersion: .current, capabilities: [.hostInfo], controllerName: "interop"))
    let ack = try HostWire.decode(HostServerFrame.self, from: try await Self.roundTrip(c, text: hello))
    guard case .helloAck(_, _, let name) = ack else { return XCTFail("\(ack)") }
    XCTAssertFalse(name.isEmpty)
    let info = try HostWire.decode(HostServerFrame.self, from: try await Self.next(c, sending: HostWire.encode(HostClientFrame.request(id: 1, .hostInfo))))
    guard case .reply(1, .hostInfo(let i)) = info else { return XCTFail("\(info)") }
    XCTAssertEqual(i.platform, "Linux")
    c.cancel()
}

/// Review Focus 2: revoking through the admin socket closes the live connection promptly.
func testRevokedControllerIsDisconnected() async throws {
    guard let ep = Self.endpoint(), let container = ProcessInfo.processInfo.environment["FD_LINUX_HOSTD_CONTAINER"] else { throw XCTSkip("env") }
    let c = NWConnection(to: HostTransport.endpoint(for: ep), using: HostTransport.clientParameters(key: .init(slot: Self.slot, secret: Self.secret)))
    _ = try await Self.roundTrip(c, text: HostWire.encode(HostClientFrame.hello(protocolVersion: .current, capabilities: [], controllerName: "interop")))
    let closed = expectation(description: "closed")
    c.stateUpdateHandler = { if case .cancelled = $0 { closed.fulfill() }; if case .failed = $0 { closed.fulfill() } }
    c.receiveMessage { _, _, complete, error in if complete || error != nil { closed.fulfill() } }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
    p.arguments = ["exec", container, "/src/Packages/HostDaemonLinux/.build/debug/HostDaemonLinux", "revoke", Self.slot.uuidString, "--root", "/tmp/fdroot"]
    try p.run(); p.waitUntilExit()
    await fulfillment(of: [closed], timeout: 2)
}
```

  - Add the `static func endpoint() -> NWEndpoint?` and `static func next(_:sending:)` helpers, which send on an already-ready connection and await one message.
  - Extend the script so it exports `FD_LINUX_HOSTD_CONTAINER="$NAME"` and runs `serve` with `--root /tmp/fdroot --test-controller …`.
  - Add a `revoke <slot>` subcommand that sends `AdminRequest.revoke`.
  - The `closed` expectation may fire more than once, so set `assertForOverFulfill = false`.

- [ ] **Step 2: Run** `FD_INTEROP_FILTER=LinuxHostdInteropTests ./scripts/test-hostd-linux-interop.sh serve`. Expected: FAIL, because `serve` doesn't exist yet.

- [ ] **Step 3: Implement `serve`.**
  - The keys closure reads `store.all()` and maps `slot.uuidString` to the secret. It is read on every handshake, so a newly paired controller works with no restart.
  - `store.onChange` calls `core.disconnect(slot:)` for every slot that is no longer present.
  - Each NIO connection is wrapped as a `HostPeer` whose `slot` is the handshake identity. Text goes to `core.receive`, and a channel close calls `core.peerClosed`.
  - **Admin handler:**
    - `status`, `listControllers`, `revoke` and `cancelArm` map onto the store and window.
    - `arm` mints a `PairingCode`, calls `window.arm(codeText: code.formatted)`, and starts `NIOPairingResponder.run(code:key: .mint(), hostName:, port: 47411)` in a `Task`.
      - On success it checks `window.consume(codeText:)` and adds `PairedController(slot: key.slot, name: "controller", secret:, pairedAt:)`; `core.onControllerName` renames it on first hello.
      - A new `arm` cancels the previous responder task.
  - `AvahiPublisher`: if `/usr/bin/avahi-publish` exists, spawn `avahi-publish -s <hostName> _fd-host._tcp <port>` for the life of `serve`. While a code is armed, also publish `_fd-host-pair._tcp 47411` with TXT `name=<hostName>`. Terminate both on exit.
  - `pair` and `status` follow the contract above.

- [ ] **Step 4: Run** `FD_INTEROP_FILTER=LinuxHostdInteropTests ./scripts/test-hostd-linux-interop.sh serve`. Expected: PASS.

- [ ] **Step 5: Commit** — `feat: run a Linux hostd that pairs controllers and answers host.info`, with the trailer.

---

### Task 7: macOS hostd as a GUI-session LaunchAgent

**Files:**
- Create: `Sources/HostDaemon/main.swift`, `Sources/HostDaemon/DarwinHostServer.swift`, `Sources/HostDaemon/dev.flightdeck.hostd.plist`
- Modify: `project.yml`. Add a `packages: HostKit: path: Packages/HostKit` entry, a new `HostDaemon` target, the FlightDeck target's embed of hostd and the plist copy, and `FlightDeckTests` dependencies on the `HostKit` package product and the `HostDaemon` sources.
- Test: `Tests/FlightDeckTests/HostTransportLoopbackTests.swift`

**Interfaces:**
- Consumes: `HostTransport.listenerParameters(keys:)`, `PairingListener(profile: .host)`, and HostKit's `HostServerCore`, `ControllerStore`, `AdminSocketServer` and `PairingWindow`.
- Produces: `final class DarwinHostServer { init(root: URL, port: NWEndpoint.Port?, hostName: @escaping () -> String); func start() async throws -> NWEndpoint.Port; func stop() }`. It advertises `_fd-host._tcp` under the host name, and serves the admin socket at `<root>/admin.sock`.

- [ ] **Step 1: Write the failing loopback tests.**

```swift
// Tests/FlightDeckTests/HostTransportLoopbackTests.swift
import Foundation
import Network
import XCTest
@testable import FleetKit
import HostKit

final class HostTransportLoopbackTests: XCTestCase {
    var root: URL!
    override func setUp() { root = URL(fileURLWithPath: "/tmp/fdh-\(UUID().uuidString.prefix(6))") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testPairedControllerGetsHostInfo() async throws {
        let key = FleetDeviceKey.mint()
        try ControllerStore(root: root).add(.init(slot: key.slot, name: "t", secret: key.secret, pairedAt: Date()))
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        let port = try await server.start(); defer { server.stop() }
        let c = NWConnection(to: HostTransport.endpoint(for: .hostPort(host: "127.0.0.1", port: port)),
                             using: HostTransport.clientParameters(key: key))
        let ack = try await LinuxHostdInteropTests.roundTrip(c, text: HostWire.encode(HostClientFrame.hello(protocolVersion: .current, capabilities: [.hostInfo], controllerName: "t")))
        XCTAssertEqual(try HostWire.decode(HostServerFrame.self, from: ack),
                       .helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "loop"))
        c.cancel()
    }

    func testUnpairedKeyIsRefused() async throws {
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        let port = try await server.start(); defer { server.stop() }
        let c = NWConnection(to: HostTransport.endpoint(for: .hostPort(host: "127.0.0.1", port: port)),
                             using: HostTransport.clientParameters(key: .mint()))
        do { _ = try await LinuxHostdInteropTests.roundTrip(c, text: "x", timeout: 5); XCTFail("stranger got through") } catch {}
        c.cancel()
    }

    /// Review Focus 2 (macOS): revoking via the admin socket closes the live connection.
    func testRevokedControllerIsDisconnected() async throws {
        let key = FleetDeviceKey.mint()
        try ControllerStore(root: root).add(.init(slot: key.slot, name: "t", secret: key.secret, pairedAt: Date()))
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        let port = try await server.start(); defer { server.stop() }
        let c = NWConnection(to: HostTransport.endpoint(for: .hostPort(host: "127.0.0.1", port: port)),
                             using: HostTransport.clientParameters(key: key))
        _ = try await LinuxHostdInteropTests.roundTrip(c, text: HostWire.encode(HostClientFrame.hello(protocolVersion: .current, capabilities: [], controllerName: "t")))
        let closed = expectation(description: "closed"); closed.assertForOverFulfill = false
        c.receiveMessage { _, _, complete, error in if complete || error != nil { closed.fulfill() } }
        XCTAssertEqual(try AdminSocketClient.send(.revoke(slot: key.slot), path: root.appendingPathComponent("admin.sock").path), .ok)
        await fulfillment(of: [closed], timeout: 2)
    }

    func testArmThenPairWithHostProfile() async throws {
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        _ = try await server.start(); defer { server.stop() }
        guard case .armed(let codeText, _) = try AdminSocketClient.send(.arm, path: root.appendingPathComponent("admin.sock").path),
              let code = PairingCode(normalizing: codeText) else { return XCTFail() }
        let initiator = PairingInitiator(profile: .host)
        let paired = expectation(description: "paired")
        initiator.onPaired = { _, name in XCTAssertEqual(name, "loop"); paired.fulfill() }
        initiator.start(code: code, endpoint: .hostPort(host: "127.0.0.1", port: server.pairingPort!))
        await fulfillment(of: [paired], timeout: 15)
        XCTAssertEqual(ControllerStore(root: root).all().count, 1)
    }
}
```

- [ ] **Step 2: Add `project.yml` entries.**

```yaml
packages:
  HostKit:
    path: Packages/HostKit
# targets:
  HostDaemon:
    type: tool
    platform: macOS
    sources: [{ path: Sources/HostDaemon, excludes: ["*.plist"] }]
    dependencies:
      - target: FleetKit
        embed: false
      - package: HostKit
        product: HostKit
    settings:
      base:
        SWIFT_VERSION: "6.0"
        PRODUCT_NAME: flightdeck-hostd   # distinct from `flightdeck` and `FlightDeck` under case folding
        PRODUCT_MODULE_NAME: HostDaemon
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks"
        HEADER_SEARCH_PATHS: $(SRCROOT)/vendor/boringssl-artifacts/include
        DEVELOPMENT_TEAM: ZM74LQ6QWG
```

  Then wire it into the existing targets:
  - In the FlightDeck target's `dependencies`, add `- target: HostDaemon` with `embed: true, codeSign: true, copy: { destination: executables }`. Also add the `HostKit` package product.
  - In the FlightDeck target's `sources`, add `- path: Sources/HostDaemon/dev.flightdeck.hostd.plist` with `buildPhase: { copyFiles: { destination: wrapper, subpath: Contents/Library/LaunchAgents } }`.
  - In `FlightDeckTests`, add `- path: Sources/HostDaemon` to sources (excluding `main.swift` and the plist) and the `HostKit` package product to dependencies.
  - Run `xcodegen generate` and confirm the project builds.

- [ ] **Step 3: Run** `FD_TEST_FILTER=HostTransportLoopbackTests ./scripts/test-unit.sh 2>&1 | tee /tmp/t.log; rg -n "error:" /tmp/t.log`. Expected: the compile fails, because `DarwinHostServer` is missing.

- [ ] **Step 4: Implement `DarwinHostServer` and `main.swift`.**
  - **Listener:** an `NWListener(using: HostTransport.listenerParameters(keys: store keys))` with `service = .init(name: hostName(), type: "_fd-host._tcp")`.
  - **Key changes:** restart the listener on the same port, following `FleetSocketServer.start`'s wait-for-cancel then rebind. A key change after a revoke also calls `core.disconnect(slot:)` for the removed slots, so live connections close and are not merely refused next time.
  - **Peer identity:** read the slot through FleetKit's PSK selection, which is internal. Expose a minimal `public` hook in `HostTransport`: `listenerParameters(keys:onIdentity: @escaping (sec_protocol_metadata_t, UUID) -> Void)`, built on `FleetPSKIdentities`. Do not use `sec_protocol_metadata_access_pre_shared_keys`; `FleetSocketServer.swift:743` records why it gives the wrong answer.
  - **Pairing:** a `PairingListener(profile: .host)` on an ephemeral port, exposed as `pairingPort` for tests, armed by `AdminRequest.arm` with `serviceName: hostName()`. Its `onPaired` adds the controller as `"controller"`, because the responder never learns the initiator's name. The controller sends its name in its first `hello`, and `core.onControllerName` (tested in Task 4) renames the slot in `ControllerStore`.
  - **Power:** `main.swift` starts the server with `root = HostStateRoot.default()`, port 47410, and `Host.current().localizedName`. It holds `ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled…)` only while a connection is open (it holds no assertion when idle), then runs `dispatchMain()`.
  - **LaunchAgent plist** (an `SMAppService.agent` plist):
    ```xml
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>dev.flightdeck.hostd</string>
      <key>BundleProgram</key><string>Contents/MacOS/flightdeck-hostd</string>
      <key>ProgramArguments</key><array><string>flightdeck-hostd</string><string>serve</string></array>
      <!-- Aqua: run inside the GUI login session, which XCTest UI runs (sub-project C) need. -->
      <key>LimitLoadToSessionType</key><string>Aqua</string>
      <key>KeepAlive</key><true/>
      <key>ProcessType</key><string>Interactive</string>
    </dict></plist>
    ```

- [ ] **Step 5: Run the loopback tests and the Task 4 tests.**
  Run: `FD_TEST_FILTER=HostTransportLoopbackTests ./scripts/test-unit.sh …` and `./scripts/test-hostkit.sh`.
  Expected: all pass. Then run `./scripts/build.sh` and check the bundle layout **without executing the bundle**: `ls "DerivedData/Build/Products/Debug/Flight Deck.app/Contents/MacOS/flightdeck-hostd" "DerivedData/Build/Products/Debug/Flight Deck.app/Contents/Library/LaunchAgents/dev.flightdeck.hostd.plist"`.

- [ ] **Step 6: Commit** — `feat: host this Mac for other Flight Decks from a GUI-session agent`, with the trailer.

---

### Task 8: Controller — HostRegistry, HostLink and HostService

**Files:**
- Create: `Sources/FlightDeck/Hosts/{HostRecord,HostSecretStore,HostRegistry,HostLink,HostService}.swift`
- Test: `Tests/FlightDeckTests/HostRegistryTests.swift`, `Tests/FlightDeckTests/HostLinkTests.swift`

**Interfaces:**
- Consumes: `HostTransport`, `PairingRunner(profile: .host)`, `DarwinHostServer` (in tests), and the HostKit frames.
- Produces:

```swift
struct HostRecord: Codable, Equatable, Identifiable { let slot: UUID; var name: String; var serviceName: String
    var endpoints: [String]; var platform: String?; let pairedAt: Date; var lastSeenAt: Date?; var id: UUID { slot } }
protocol HostSecretStoring { func secret(for slot: UUID) -> Data?; func set(_ secret: Data, for slot: UUID) throws; func remove(slot: UUID) }
final class KeychainHostSecretStore: HostSecretStoring   // service "dev.flightdeck.host", account slot.uuidString, AfterFirstUnlockThisDeviceOnly
final class InMemoryHostSecretStore: HostSecretStoring
@MainActor final class HostRegistry { init(fileURL: URL, secrets: HostSecretStoring)
    private(set) var hosts: [HostRecord]
    func add(key: FleetDeviceKey, name: String, serviceName: String, endpoints: [String]) throws -> HostRecord  // dedupes name → "mini-2"
    func remove(slot: UUID); func update(_ r: HostRecord); func key(for slot: UUID) -> FleetDeviceKey?
    func resolve(name: String) -> Result<HostRecord, HostLookupError> }
enum HostLookupError: Error, Equatable { case unknown(available: [String]) }
enum HostLinkState: Equatable { case connecting; case online(hostName: String); case offline(lastSeen: Date?); case refused(String) }
@MainActor final class HostLink { init(record: HostRecord, key: FleetDeviceKey, controllerName: String,
        dial: HostLinkDialing = NetworkHostDialer(), clock: HostLinkClock = SystemHostLinkClock())
    private(set) var state: HostLinkState; var onStateChange: ((HostLinkState) -> Void)?
    var onEndpointLearned: ((String) -> Void)?
    func start(); func stop(); func request(_ r: HostRequest) async throws -> HostReply }
enum HostLinkError: Error, Equatable { case offline; case remote(code: String, message: String); case timedOut }
@MainActor final class HostService: ObservableObject { @Published private(set) var statuses: [UUID: HostLinkState]
    init(registry: HostRegistry, controllerName: String); func start(); func info(name: String) async throws -> (HostRecord, HostInfo)
    func pair(code: PairingCode, candidate: PairingBrowser.DiscoveredMac?) async throws -> HostRecord
    func pair(code: PairingCode, address: String) async throws -> HostRecord
    func forget(slot: UUID) }
```

- [ ] **Step 1: Write the failing tests.**

```swift
// HostRegistryTests.swift
@MainActor final class HostRegistryTests: XCTestCase {
    var url: URL!
    override func setUp() { url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID()).json") }

    func testAddPersistsWithoutSecretInFile() throws {
        let secrets = InMemoryHostSecretStore()
        let key = FleetDeviceKey.mint()
        _ = try HostRegistry(fileURL: url, secrets: secrets).add(key: key, name: "mini", serviceName: "mini", endpoints: ["10.0.0.5:47410"])
        let reloaded = HostRegistry(fileURL: url, secrets: secrets)
        XCTAssertEqual(reloaded.hosts.map(\.name), ["mini"])
        XCTAssertEqual(reloaded.key(for: key.slot), key)
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(key.secret.base64EncodedString()))
    }

    /// Review Focus 4.
    func testDuplicateNamesAreDisambiguated() throws {
        let r = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        _ = try r.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: [])
        let second = try r.add(key: .mint(), name: "mini", serviceName: "mini (2)", endpoints: [])
        XCTAssertEqual(second.name, "mini-2")
        XCTAssertEqual(try r.resolve(name: "mini").get().slot, r.hosts[0].slot)
        XCTAssertEqual(r.resolve(name: "maxi"), .failure(.unknown(available: ["mini", "mini-2"])))
    }

    func testRemoveDeletesSecret() throws {
        let secrets = InMemoryHostSecretStore(); let r = HostRegistry(fileURL: url, secrets: secrets)
        let rec = try r.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: [])
        r.remove(slot: rec.slot)
        XCTAssertNil(secrets.secret(for: rec.slot)); XCTAssertEqual(r.hosts, [])
    }
}

// HostLinkTests.swift — against an in-process DarwinHostServer (Task 7).
@MainActor final class HostLinkTests: XCTestCase {
    func makeServer(_ key: FleetDeviceKey) async throws -> (DarwinHostServer, NWEndpoint.Port, URL) {
        let root = URL(fileURLWithPath: "/tmp/fdl-\(UUID().uuidString.prefix(6))")
        try ControllerStore(root: root).add(.init(slot: key.slot, name: "t", secret: key.secret, pairedAt: Date()))
        let s = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        return (s, try await s.start(), root)
    }

    func testGoesOnlineAndAnswersInfo() async throws {
        let key = FleetDeviceKey.mint(); let (s, port, _) = try await makeServer(key); defer { s.stop() }
        let link = HostLink(record: .init(slot: key.slot, name: "loop", serviceName: "loop-none", endpoints: ["127.0.0.1:\(port)"], platform: nil, pairedAt: Date()), key: key, controllerName: "test")
        let online = expectation(description: "online")
        link.onStateChange = { if case .online = $0 { online.fulfill() } }
        link.start(); await fulfillment(of: [online], timeout: 10)
        guard case .hostInfo(let info) = try await link.request(.hostInfo) else { return XCTFail() }
        XCTAssertEqual(info.hostName.isEmpty, false); link.stop()
    }

    /// Review Focus 1: the first stored endpoint is dead; the link must reach the live one.
    func testReconnectsWhenStoredEndpointIsStale() async throws {
        let key = FleetDeviceKey.mint(); let (s, port, _) = try await makeServer(key); defer { s.stop() }
        let link = HostLink(record: .init(slot: key.slot, name: "loop", serviceName: "loop-none",
                                          endpoints: ["127.0.0.1:1", "127.0.0.1:\(port)"], platform: nil, pairedAt: Date()), key: key, controllerName: "test")
        let online = expectation(description: "online"); online.assertForOverFulfill = false
        link.onStateChange = { if case .online = $0 { online.fulfill() } }
        link.start(); await fulfillment(of: [online], timeout: 10); link.stop()
    }

    func testServerStopMarksOfflineAndRestartRecovers() async throws {
        let key = FleetDeviceKey.mint(); var (s, port, root) = try await makeServer(key)
        let clock = ManualHostLinkClock()
        let link = HostLink(record: .init(slot: key.slot, name: "loop", serviceName: "loop-none", endpoints: ["127.0.0.1:\(port)"], platform: nil, pairedAt: Date()), key: key, controllerName: "test", clock: clock)
        var states: [HostLinkState] = []; link.onStateChange = { states.append($0) }
        link.start(); try await waitUntil { states.contains { if case .online = $0 { true } else { false } } }
        s.stop(); try await waitUntil { states.last.map { if case .offline = $0 { true } else { false } } ?? false }
        s = DarwinHostServer(root: root, port: port, hostName: { "loop" }); _ = try await s.start()
        clock.advance(by: 1)   // first backoff step is 1 s
        try await waitUntil { if case .online = states.last { true } else { false } }
        s.stop(); link.stop()
    }

    func testRequestWhileOfflineFailsFast() async throws {
        let key = FleetDeviceKey.mint()
        let link = HostLink(record: .init(slot: key.slot, name: "x", serviceName: "none", endpoints: ["127.0.0.1:1"], platform: nil, pairedAt: Date()), key: key, controllerName: "t")
        do { _ = try await link.request(.hostInfo); XCTFail() } catch { XCTAssertEqual(error as? HostLinkError, .offline) }
    }
}
```

  `waitUntil` is a small polling helper, 50 ms ticks for up to 10 s, that uses `try await Task.sleep`. Put it in `HostLinkTests.swift`. Use `await fulfillment(of:)`, never `wait(for:)`, in `@MainActor` tests.

- [ ] **Step 2: Run** `FD_TEST_FILTER=HostRegistryTests,HostLinkTests ./scripts/test-unit.sh …`. Expected: the compile fails.

- [ ] **Step 3: Implement.**
  - **`HostRegistry`:** a JSON file written atomically, with secrets in `HostSecretStoring`. Name dedupe appends `-2`, `-3` and so on. `resolve` matches the name exactly, case-insensitively.
  - **`HostLink`:**
    - **Dialing:** race every candidate in parallel, the way `FleetConnector.race()` (`FleetConnector.swift:499`) does: each stored endpoint, plus Bonjour `_fd-host._tcp` resolved by `serviceName` through `NWBrowser`. The first one that completes `helloAck` wins, and the rest are cancelled.
    - **Learning addresses:** a winning `.hostPort` that isn't already stored is passed to `onEndpointLearned`, and the service persists it at the front, keeping at most 2, as `PairingPayload.maxEndpoints` does.
    - **Liveness:** while online, send a WebSocket ping (`NWProtocolWebSocket.Metadata(opcode: .ping)` with `setPongHandler`) every 15 s. Three missed pongs mean offline.
    - **Reconnects:** a backoff of 1, 2, 4, 8, 16 and then 30 s on `clock`. An `NWPathMonitor` update resets it to 1 s.
    - **Refusal:** a `refused(majorVersionMismatch)` reply sets `.refused("Update Flight Deck on <name>")` and stops retrying.
    - **Requests:** each gets an increasing id, a continuation table, and a 10 s timeout that throws `.timedOut`. When the link goes offline, every pending request fails with `.offline`.
  - **`HostService`:**
    - It creates one `HostLink` per record, mirrors their states into `statuses`, and updates `lastSeenAt` and `platform` from `helloAck` and `hostInfo`.
    - `pair(code:candidate:)` uses `PairingRunner(profile: .host).start(code:candidates: [candidate])`. `pair(code:address:)` uses `PairingInitiator(profile: .host).start(code:endpoint:)` with port 47411.
    - After pairing it calls `registry.add` and opens the link.
    - `forget` stops the link and calls `registry.remove`.
    - `controllerName` is `Host.current().localizedName`.
    - It is created in `FlightDeckApp`, next to `FleetService`, with `fileURL` = `<Application Support>/Flight Deck/hosts.json`, using the same directory-resolution helper `sessions.json` uses, so Debug builds get "Flight Deck (Debug)".

- [ ] **Step 4: Run the tests.** Expected: they pass. Run `rg -n "error:|failed \(" /tmp/t.log` and expect no matches.

- [ ] **Step 5: Commit** — `feat: keep a live authenticated link to each paired host`, with the trailer.

---

### Task 9: `flightdeck host ls` and `flightdeck host info`

All wire, scope, server and CLI changes **land in one commit**. Wire enum cases are atomic, and every switch is exhaustive.

**Files:**
- Modify:
  - `Sources/FleetKit/Wire.swift`: add `WireHost` and `WireHostInfo`.
  - `Sources/FleetKit/TimelineFrames.swift`: add `FleetRequest` cases.
  - `Sources/FleetKit/Frames.swift`: add `ServerFrame` cases, plus encode, decode and cid.
  - `Sources/FlightDeck/Fleet/ControlScope.swift:117`
  - `Sources/FlightDeck/Fleet/FleetService.swift`: the `handleRequest` arms.
  - `Sources/FleetKit/FleetConnector.swift`: the ServerFrame switch, about line 674.
  - `Sources/FlightDeckCLI/CLIArguments.swift`, `Sources/FlightDeckCLI/CLIRunner.swift` and `Sources/FlightDeckTool/main.swift`: usage lines.
- Test: `Tests/FlightDeckTests/HostCLITests.swift`, and extend `CLIArgumentsTests.swift`.

**Interfaces:**
- Produces:

```swift
public struct WireHost: Codable, Equatable, Sendable { public let name: String; public let platform: String?
    public let status: String /* "online" | "offline" | "connecting" | "refused" */; public let detail: String?; public let lastSeenAt: Date? }
public struct WireHostInfo: Codable, Equatable, Sendable { public let name: String; public let hostName: String; public let platform: String
    public let osVersion: String; public let arch: String; public let hostdVersion: String; public let xcode: [String]; public let docker: String?; public let diskFreeBytes: Int64 }
// FleetRequest: case hostList  (op "host.list");  case hostInfo(name: String)  (op "host.info")
// ServerFrame:  case hostList(cid: Int, [WireHost]);  case hostInfo(cid: Int, WireHostInfo)
// CLICommand:   case hostList;  case hostInfo(name: String)
```

- [ ] **Step 1: Write the failing tests.**

```swift
// CLIArgumentsTests.swift additions
func testHostLs() { XCTAssertEqual(CLIArguments.parse(["host", "ls"]).command, .hostList) }
func testHostInfo() { XCTAssertEqual(CLIArguments.parse(["host", "info", "mini"]).command, .hostInfo(name: "mini")) }
func testHostInfoRequiresName() { XCTAssertNotNil(CLIArguments.parse(["host", "info"]).error) }

// HostCLITests.swift — FleetService over its local control socket with a stub HostService.
@MainActor final class HostCLITests: XCTestCase {
    func testHostListReplyRoundTrips() throws {
        let frame = ServerFrame.hostList(cid: 4, [WireHost(name: "mini", platform: "macOS", status: "online", detail: nil, lastSeenAt: nil)])
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(frame)), frame)
    }

    func testHostRequestsAreReadOnlyScope() {
        XCTAssertTrue(ControlScope.permits(.hostList, level: .readOnly, caller: .session(UUID())))
        XCTAssertTrue(ControlScope.permits(.hostInfo(name: "x"), level: .readOnly, caller: .session(UUID())))
    }

    /// Review Focus 4: an unknown name errors with the available names, never a silent pick.
    func testHostInfoUnknownNameListsHosts() async throws {
        let reply = try await FleetServiceHarness.request(.hostInfo(name: "maxi"), hosts: ["mini", "mini-2"])
        XCTAssertEqual(reply, .err(cid: reply.cid, code: "unknown_host", message: "no host named maxi; paired: mini, mini-2"))
    }
}
```

  - **The harness:** `CLIEndToEndTests.swift` and `FleetLocalControlTests.swift` already stand up a `FleetService` against a local socket. Reuse that setup as `FleetServiceHarness`, injecting a `HostService` built on an in-memory `HostRegistry` with no live links.
  - **Level names:** use the real `ControlScopeLevel` case names from `ControlScope.swift`. `readOnly` above is a stand-in; check before writing. The `.err` frame's real shape must also be checked in `Frames.swift`.

- [ ] **Step 2: Run** `FD_TEST_FILTER=CLIArgumentsTests,HostCLITests ./scripts/test-unit.sh …`. Expected: the compile fails.

- [ ] **Step 3: Implement.**
  - **CLI parsing:** in `parseVerb`, add `"host"`, following the `"plan"` sub-switch pattern (`CLIArguments.swift:253`).
  - **`CLIRunner`:**
    - `.hostList` sends `request(.hostList)`, and its reply prints `CLIOutput.table` with the columns NAME, PLATFORM, STATUS and LAST SEEN, or JSON with `--json`.
    - `.hostInfo` prints key/value lines, with `diskFreeBytes` shown through `ByteCountFormatter`.
  - **`FleetService.handleRequest`:**
    - `.hostList` maps `hostService.registry.hosts` and `statuses`.
    - `.hostInfo(name)` resolves the name and calls `try await hostService.info(name:)`, then replies.
    - `HostLookupError.unknown` maps to `err(code: "unknown_host", "no host named X; paired: …")`.
    - `HostLinkError.offline` maps to `err(code: "host_offline", "<name> is offline (last seen 4m ago)")`. Use `RelativeDateTimeFormatter`, or "never" when there is no last-seen time.
  - **`ControlScope.permits`:** add both cases to the read-only, always-allowed list.
  - **`FleetConnector`:** add both cases to its switch and ignore them (the phone never asks).
  - **`main.swift` usage:** `flightdeck host ls` and `flightdeck host info <host>`.

- [ ] **Step 4: Run** `./scripts/test-unit.sh 2>&1 | tee /tmp/full.log; rg -n "error:|failed \(" /tmp/full.log`. The full suite is needed because the wire switches change. Expected: no matches. Then run `./scripts/build-ios.sh` (FleetKit changed) and `./scripts/test-ios.sh` (the phone app decodes `ServerFrame`). Expected: both pass.

- [ ] **Step 5: Commit** — `feat: list paired hosts and read their toolchains from a session shell`, with the trailer.

---

### Task 10: Settings — Hosts and Hosting tabs

**Files:**
- Modify: `Sources/FlightDeck/Preferences/PreferencesTab.swift` (add `.hosts` and `.hosting`), `Sources/FlightDeck/Preferences/UI/PreferencesView.swift`, `Sources/FlightDeck/FlightDeckApp.swift:312` (pass `hostService`)
- Create: `Sources/FlightDeck/Preferences/UI/{HostsSettingsTab,AddHostSheet,HostingSettingsTab}.swift`, `Sources/FlightDeck/Hosts/HostAdminClient.swift`
- Test: `Tests/FlightDeckTests/HostingControllerTests.swift` (logic only; the SwiftUI layout is checked by hand)

**Interfaces:**
- Consumes: `HostService` (Task 8) and `AdminSocketClient` (Task 5).
- Produces:

```swift
@MainActor final class HostingController: ObservableObject {
    enum State: Equatable { case off; case starting; case on(paired: Int, port: Int?); case needsApproval; case notRunning; case failed(String) }
    @Published private(set) var state: State; @Published private(set) var armed: (code: String, expiresAt: Date)?
    init(service: AgentServiceRegistering = SMAppServiceAgent(plistName: "dev.flightdeck.hostd.plist"), adminPath: String)
    func setEnabled(_ on: Bool); func refresh(); func arm(); func cancelArm(); func revoke(slot: UUID); var controllers: [AdminController] }
protocol AgentServiceRegistering { var status: SMAppService.Status { get }; func register() throws; func unregister() throws }
```

- [ ] **Step 1: Write the failing tests.**

```swift
@MainActor final class HostingControllerTests: XCTestCase {
    final class FakeAgent: AgentServiceRegistering { var status: SMAppService.Status = .notRegistered
        func register() throws { status = .enabled }; func unregister() throws { status = .notRegistered } }

    func testEnableRegistersAndReportsNotRunningUntilAdminAnswers() {
        let c = HostingController(service: FakeAgent(), adminPath: "/tmp/none-\(UUID().uuidString.prefix(6)).sock")
        c.setEnabled(true); c.refresh()
        XCTAssertEqual(c.state, .notRunning)   // Review Focus 5: says so, does not hang
    }

    func testRequiresApprovalIsSurfaced() {
        let a = FakeAgent(); a.status = .requiresApproval
        let c = HostingController(service: a, adminPath: "/tmp/x.sock"); c.refresh()
        XCTAssertEqual(c.state, .needsApproval)
    }

    func testArmShowsCodeFromAdmin() throws {
        let path = "/tmp/fdhc-\(UUID().uuidString.prefix(6)).sock"
        let server = try AdminSocketServer(path: path) { r in
            switch r { case .arm: .armed(code: "AAAA-BBBB-CCCC", expiresAt: .distantFuture)
                       case .status: .status(paired: 0, armedUntil: nil, listeningPort: 47410, hostName: "m")
                       default: .ok } }
        defer { server.stop() }
        let a = FakeAgent(); a.status = .enabled
        let c = HostingController(service: a, adminPath: path); c.refresh(); c.arm()
        XCTAssertEqual(c.armed?.code, "AAAA-BBBB-CCCC")
        XCTAssertEqual(c.state, .on(paired: 0, port: 47410))
    }
}
```

- [ ] **Step 2: Run** `FD_TEST_FILTER=HostingControllerTests ./scripts/test-unit.sh …`. Expected: the compile fails.

- [ ] **Step 3: Implement.**
  - **`HostingController`:** admin calls run off the main actor via `Task.detached` and publish back to the main actor. `refresh()` is driven by a 2 s timer while the tab is visible. `SMAppServiceAgent` wraps `SMAppService.agent(plistName:)`.
  - **`HostingSettingsTab`:**
    - A "Let other Macs use this Mac" toggle.
    - A status line, one of: "Running on port 47410 · 2 controllers", "Waiting for approval in System Settings → General → Login Items" (with a button that runs `SMAppService.openSystemSettingsLoginItems()`), or "Host service is not running".
    - A "Pair a Controller…" button that shows a sheet with the code in large monospaced text and a countdown. The sheet closes itself once `status.paired` grows.
    - A Controllers list with Revoke.
    - Footer text: "The host runs while you're logged in. It stops when you log out."
  - **`HostsSettingsTab`:** list `hostService.registry.hosts` with a status dot (online green, connecting yellow, offline grey, refused red, plus the detail), the platform and last seen. A "Forget" context-menu item asks for confirmation. There is an "Add Host…" button.
  - **`AddHostSheet`:**
    - **Mac:** a `PairingBrowser(profile: .host)` lists hosts that advertise a pairing window. Choose one, enter the code (`PairingCode.grouped(partial:)` as you type, as `PairingCodeView` does), and pair.
    - **Linux:** show the install command from Task 11, `curl -fsSL <base>/hostd-install.sh | sh -s -- --sha256 <digest>`, with a Copy button. Read the base URL and digest from Info.plist keys `FDHostdReleaseBaseURL` and `FDHostdInstallerSHA256`, set by build settings. Then show an address field (host or IP) and a code field, and call `pair(code:address:)`.
    - Errors use the `PairingInitiator.Failure` cases' existing user-facing strings. Find where `DevicesSettingsTab` renders them and reuse that function.
  - Add the tabs to `PreferencesView`, with SF Symbols `desktopcomputer.and.arrow.down` for Hosts and `server.rack` for Hosting, and accessibility identifiers `prefs-hosts` and `prefs-hosting`.

- [ ] **Step 4: Run the tests.** Expected: they pass. Then run `./scripts/build.sh`, and render each new tab off-screen with the `layer.render(in:)` technique (memory: offscreen render) to check the layout. Do not launch the bundle.

- [ ] **Step 5: Commit** — `feat: add and host Flight Deck machines from Settings`, with the trailer.

---

### Task 11: Linux packaging and the one-paste installer

**Files:**
- Create: `scripts/build-hostd-linux.sh`, `scripts/hostd-install.sh`
- Modify: `project.yml` (the `FDHostdReleaseBaseURL` and `FDHostdInstallerSHA256` Info.plist build settings)
- Test: `scripts/test-hostd-install.sh`, run in Docker

**Interfaces:**
- Consumes: the CLI contract from Task 6.
- Produces:
  - Release assets `flightdeck-hostd-linux-{aarch64,x86_64}.tar.gz`, `SHA256SUMS` and `hostd-install.sh`, in `build/hostd-release/`.
  - The installer flags `--sha256 <digest-of-SHA256SUMS>`, `--no-systemd` (for tests and containers) and `--asset-base <url>`.

- [ ] **Step 1: Write the failing installer test.**

```bash
#!/usr/bin/env bash
# scripts/test-hostd-install.sh — the pasted command, end to end, in a plain Ubuntu container,
# served from a local HTTP server so nothing is published.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-hostd-linux.sh aarch64
SUMS=$(shasum -a 256 build/hostd-release/SHA256SUMS | cut -d' ' -f1)
docker run --rm -v "$PWD/build/hostd-release:/rel:ro" ubuntu:24.04 bash -c "
  apt-get update -qq && apt-get install -y -qq curl python3 >/dev/null
  (cd /rel && python3 -m http.server 8000 >/dev/null 2>&1 &) ; sleep 1
  useradd -m dev && su dev -c '
    curl -fsSL http://127.0.0.1:8000/hostd-install.sh | sh -s -- --sha256 $SUMS --asset-base http://127.0.0.1:8000 --no-systemd
    ~/.local/bin/flightdeck-hostd serve --port 47410 & sleep 2
    timeout 5 ~/.local/bin/flightdeck-hostd pair | grep -q \"Pairing code:\"
    test \$(stat -c %a ~/.local/share/flightdeck-hostd) = 700
    curl -fsSL http://127.0.0.1:8000/hostd-install.sh | sh -s -- --sha256 0000 --asset-base http://127.0.0.1:8000 --no-systemd && exit 9 || true
  '"
echo "INSTALL PASS"
```

  The last line checks that a wrong digest refuses to install.

- [ ] **Step 2: Run** `./scripts/test-hostd-install.sh`. Expected: FAIL, because the scripts are missing.

- [ ] **Step 3: Write `build-hostd-linux.sh`.**
  - For each architecture (`--platform linux/arm64` or `linux/amd64`; OrbStack emulates amd64), run `./scripts/build-boringssl-linux.sh <arch>`.
  - Then, in `swift:6.3-noble`, run `swift build -c release --static-swift-stdlib --product HostDaemonLinux` and copy the binary as `flightdeck-hostd`.
  - Tar each binary, write `SHA256SUMS`, and copy `hostd-install.sh` alongside.

- [ ] **Step 4: Write `hostd-install.sh`.** It is POSIX `sh`, uses no bashisms, and runs `set -eu`. It:
  1. Detects the architecture with `uname -m`.
  2. Downloads `SHA256SUMS` and checks `sha256sum` of it against `--sha256`. A mismatch prints `flightdeck: checksum mismatch — refusing to install` and exits 1.
  3. Downloads the tarball and checks it against `SHA256SUMS`.
  4. Installs to `~/.local/bin/flightdeck-hostd` with mode 755.
  5. Unless `--no-systemd` is given:
     - writes `~/.config/systemd/user/flightdeck-hostd.service` with `ExecStart=%h/.local/bin/flightdeck-hostd serve`, `Restart=on-failure` and `WantedBy=default.target`;
     - runs `systemctl --user daemon-reload` and `enable --now flightdeck-hostd`;
     - runs `loginctl enable-linger "$USER"`, and if that fails, prints a one-line note that the host stops at logout.
  6. Runs `flightdeck-hostd pair` in the foreground. Its output is the code to type into the Mac.

- [ ] **Step 5: Run** `./scripts/test-hostd-install.sh`. Expected: `INSTALL PASS`.

- [ ] **Step 6: Wire the Info.plist keys.**
  - `FDHostdReleaseBaseURL` defaults to `https://github.com/nateabele/flight-deck/releases/download/hostd-v$(MARKETING_VERSION)`.
  - `FDHostdInstallerSHA256` is filled by `build-hostd-linux.sh`, which writes `build/hostd-release/installer.xcconfig`, included by the Release config.
  - **Publishing the GitHub release is the maintainer's step and outward-facing. Do not publish it.** Note it in HANDOFF.

- [ ] **Step 7: Commit** — `feat: install a Linux host with one pasted command`, with the trailer.

---

### Task 12: Docs

**Files:**
- Modify: `docs/ARCHITECTURE.md` (a new "Hosts" section after "Detached sessions"), `docs/BUILD.md` (HostKit, the Linux package, and the four new scripts), `docs/AGENT-OPERATIONS.md` (the hostd process and how to stop it: `launchctl bootout gui/$UID/dev.flightdeck.hostd`, or the Hosting toggle; never `kill -9` mid-pairing), `docs/FOLLOWUPS.md`, `docs/HANDOFF.md`, `AGENTS.md` (the Commands block and the Layout table), and the spec (the three planning deviations from Global Constraints).

- [ ] **Step 1: Write the sections.** Keep the house style: comments explain *why* and name the failure they prevent. Cover:
  - the `HostKit` / `HostDaemon` / `HostDaemonLinux` split and why Xcode never sees NIO;
  - the two gates and their recorded results (the negotiated suite, timing);
  - the domain separation of `PairingProfile`;
  - the admin socket's trust model;
  - the ports 47410 and 47411;
  - the Bonjour types;
  - where secrets live on each side;
  - the GUI-session placement and P3, still unverified until sub-project C.

  **FOLLOWUPS** must record:
  - `flightdeck host update` (spec §3.4) is not built;
  - the GitHub release is unpublished;
  - Linux has no Bonjour without `avahi-publish`;
  - the GUI end-to-end checklist is the maintainer's.

- [ ] **Step 2: Check the links.** Run `rg -n "\]\((docs/)?[A-Z].*\.md" docs AGENTS.md | head` and make sure every new link resolves.

- [ ] **Step 3: Commit** — `docs: describe hosts, hostd and the pairing profiles`, with the trailer.

---

## Manual checks (the maintainer's; agents cannot run GUI end-to-end here)

1. **Pair a second Mac.** On the second Mac, open Settings → Hosting, turn the toggle on, and approve the login item. On the controller, open Hosts → Add Host, pick the Mac and enter the code. The host should show online, and `flightdeck host info <name>` from a session should list its Xcode versions.
2. **Revoke.** Revoke the controller from the host's Hosting tab. The controller should show the host offline within a few seconds, and reconnecting should be refused.
3. **Linux.** Paste the install command on the Linux box, type the code and address into Add Host → Linux, and run `host info` from a session.
4. **Address change.** Move the laptop from Wi-Fi to Tailscale. The host should return online with no re-pairing.

## Not in this plan

- **Sub-project C**, the next plan:
  - sync (§4);
  - the `run`, `exec`, `up`/`down`, `ps`, `wait`/`logs`/`stop`, `diff`/`apply` and `recipe` CLI (§5);
  - execution, services, port forwarding and screen leases (§6);
  - preflight (§7);
  - `delegate.toml` and routing shims (§8);
  - the agent skill and probes P1–P4 (§9–10);
  - deleting `workspaces/<slot>/` on revoke (§3.5), which has nothing to delete until C exists.
- **`flightdeck host update`** (§3.4) is recorded in FOLLOWUPS. The major-mismatch refusal and its message *are* in Task 8.
- **Sub-projects B and D** get their own specs.
