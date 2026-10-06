import Foundation
import HostKit
import PairingCore

// flightdeck-hostd for Linux. The CLI contract `hostd-install.sh` relies on:
//   serve [--port 47410] [--root DIR]
//       the host: prints "listening on <port>" once it accepts controllers and admin requests.
//   pair [--root DIR]
//       arms a pairing window through the admin socket, prints the code, and waits.
//       Exit 0 when a controller paired, 1 when the code expired (or burned), 2 when hostd is
//       not running.
//   status [--root DIR]      the admin status reply, as JSON. Exit 2 when hostd is not running.
//   controllers [--json] [--root DIR]
//                            the paired controllers, one "SLOT<TAB>NAME<TAB>PAIRED-AT" line each
//                            (ISO 8601), or a JSON array with --json. Exit 2 when hostd is not
//                            running. The SLOT is what `revoke` takes.
//   revoke SLOT [--root DIR] unpairs SLOT and cuts its live connections. Exit 1 when SLOT is not
//                            paired, 2 when hostd is not running.
//
// And the §3.2 interop gates' servers:
//   echo --port N --slot UUID --secret-hex HEX
//       gate 1: one paired slot, every text frame answered with "echo:" + text.
//   pair-test --port N --slot UUID --secret-hex HEX --code XXXX-XXXX-XXXX
//       gate 2: one host-profile pairing window that seals that slot and secret under the
//       name "interop-host", then exits 0 — or exits 1 when the window burns or expires.

/// Names the installed binary, not the SwiftPM product: `hostd-install.sh` puts this on PATH as
/// `flightdeck-hostd`, and the Add Host sheet tells the user to type that name, so a usage line
/// saying `HostDaemonLinux` would name a command that does not exist on their machine.
func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: flightdeck-hostd serve [--port N] [--root DIR]
               flightdeck-hostd pair [--root DIR]
               flightdeck-hostd status [--root DIR]
               flightdeck-hostd controllers [--json] [--root DIR]
               flightdeck-hostd revoke SLOT [--root DIR]
               flightdeck-hostd echo --port N --slot UUID --secret-hex HEX
               flightdeck-hostd pair-test --port N --slot UUID --secret-hex HEX --code CODE

        """.utf8))
    exit(64)
}

/// Straight to the fd, not `print`: stdout is block-buffered under `docker run -d` and under a
/// pipe, and both the interop script and `hostd-install.sh` wait on these exact lines.
func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("flightdeck-hostd: \(message)\n".utf8))
    exit(code)
}

func announceListening(_ port: Int) { say("listening on \(port)") }

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func bytes(hex: String) -> [UInt8]? {
    guard hex.count.isMultiple(of: 2) else { return nil }
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        out.append(byte)
        index = next
    }
    return out
}

func stateRoot(_ args: [String]) -> URL {
    option("--root", in: args).map { URL(fileURLWithPath: $0) } ?? HostStateRoot.default()
}

/// The gates' one paired slot, from `--slot` and `--secret-hex`.
func gateKey(_ args: [String]) -> (port: Int, slot: UUID, secret: [UInt8]) {
    guard let port = option("--port", in: args).flatMap(Int.init),
          let slot = option("--slot", in: args).flatMap(UUID.init(uuidString:)),
          let secret = option("--secret-hex", in: args).flatMap(bytes(hex:))
    else { usage() }
    return (port, slot, secret)
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "serve":
    try await serve(args)
case "pair":
    pair(root: stateRoot(args))
case "status":
    let reply = adminRequest(.status, root: stateRoot(args))
    say((try? HostWire.encode(reply)) ?? "{}")
case "controllers":
    guard case .controllers(let list) = adminRequest(.listControllers, root: stateRoot(args)) else {
        fail("unexpected reply to controllers", code: 1)
    }
    if args.contains("--json") {
        do { say(try ControllersCommand.json(list)) } catch { fail("could not encode: \(error)", code: 1) }
    } else if !list.isEmpty {
        say(ControllersCommand.text(list))
    }
case "revoke":
    guard args.count > 1, let slot = UUID(uuidString: args[1]) else { usage() }
    switch adminRequest(.revoke(slot: slot), root: stateRoot(args)) {
    case .ok: say("revoked \(slot.uuidString)")
    case .failed(let message): fail(message, code: 1)
    case let other: fail("unexpected reply \(other)", code: 1)
    }
case "echo":
    let gate = gateKey(args)
    try await echo(port: gate.port, slot: gate.slot, secret: gate.secret)
case "pair-test":
    let gate = gateKey(args)
    guard let code = option("--code", in: args).flatMap(PairingCode.init(normalizing:)) else { usage() }
    do {
        try await NIOPairingResponder.run(
            code: code, key: FleetDeviceKey(slot: gate.slot, secret: Data(gate.secret)),
            hostName: "interop-host", port: gate.port, onListening: { announceListening(gate.port) }
        )
        say("paired")
    } catch {
        FileHandle.standardError.write(Data("pairing window ended: \(error)\n".utf8))
        exit(1)
    }
default:
    usage()
}

func serve(_ args: [String]) async throws {
    let port = option("--port", in: args).map { Int($0) ?? -1 } ?? HostdPorts.serve
    guard (1...65535).contains(port) else { usage() }
    let root = stateRoot(args)
    // 0700 before anything else touches it: AdminSocketServer refuses a parent that group or
    // other can write, and controllers.json holds every controller's secret.
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    } catch {
        fail("cannot prepare state root \(root.path): \(error)", code: 1)
    }
    let hostd = LinuxHostd(root: root, port: port, hostName: localHostName())
    if let seed = option("--test-controller", in: args) {
        try seedTestController(seed, into: hostd.store)
    }
    try await hostd.run()
}

/// `--test-controller SLOT:HEX` pairs a known key without a SPAKE2 exchange, so the interop
/// tests can dial `serve` directly. Behind FD_HOSTD_TEST=1 because on a real host it is a way
/// to install a key nobody paired: a typo'd service file must fail loudly, not open a door.
func seedTestController(_ spec: String, into store: ControllerStore) throws {
    guard ProcessInfo.processInfo.environment["FD_HOSTD_TEST"] == "1" else {
        fail("--test-controller is only accepted when FD_HOSTD_TEST=1", code: 64)
    }
    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, let slot = UUID(uuidString: parts[0]), let secret = bytes(hex: parts[1]),
          !secret.isEmpty
    else { fail("--test-controller wants SLOT:HEX, got \(spec)", code: 64) }
    // A restarted test container keeps its root; adding the slot twice would list it twice.
    guard !store.all().contains(where: { $0.slot == slot }) else { return }
    try store.add(PairedController(slot: slot, name: "test-controller", secret: Data(secret),
                                   pairedAt: Date()))
}

/// One admin round trip, exiting 2 when hostd is not running — the code `pair`, `status`,
/// `controllers` and `revoke` share, so `hostd-install.sh` can tell "start it first" from every other failure.
func adminRequest(_ request: AdminRequest, root: URL) -> AdminReply {
    let path = root.appendingPathComponent("admin.sock").path
    do {
        return try AdminSocketClient.send(request, path: path)
    } catch AdminSocketError.notRunning {
        fail("hostd is not running (no admin socket at \(path))", code: 2)
    } catch {
        fail("admin request failed: \(error)", code: 1)
    }
}

func pair(root: URL) -> Never {
    // The baseline before arming: a controller that pairs between the arm and the first poll
    // still counts, because the count is compared against this.
    guard case .status(let baseline, _, _, _) = adminRequest(.status, root: root) else {
        fail("unexpected status reply", code: 1)
    }
    guard case .armed(let code, let expiresAt, _) = adminRequest(.arm, root: root) else {
        fail("hostd did not arm a pairing window", code: 1)
    }
    // An abandoned `pair` must not leave its code live for the rest of the two minutes.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler {
        _ = try? AdminSocketClient.send(.cancelArm, path: root.appendingPathComponent("admin.sock").path)
        exit(1)
    }
    interrupt.resume()
    say("Pairing code: \(code) (valid 2 minutes)")
    while true {
        Thread.sleep(forTimeInterval: 1)
        guard case .status(let paired, let armedUntil, _, _) = adminRequest(.status, root: root) else {
            fail("unexpected status reply", code: 1)
        }
        if paired > baseline {
            say("Paired.")
            exit(0)
        }
        // nil also covers a window that burned its three attempts or was cancelled:
        // either way this code can no longer pair.
        if armedUntil == nil || Date() > expiresAt {
            say("The code expired.")
            exit(1)
        }
        // Another `pair` armed a fresh code, which replaced this one (PairingWindow's rule), so
        // waiting out this code's two minutes would only hide that it can never pair. Compared
        // with a tolerance because the expiry crossed the wire as a double.
        if let armedUntil, abs(armedUntil.timeIntervalSince(expiresAt)) > 0.001 {
            say("The code was replaced by a newer one.")
            exit(1)
        }
    }
}

func echo(port: Int, slot: UUID, secret: [UInt8]) async throws {
    // Upper-cased because that is what `UUID.uuidString` produces on Darwin, and the identity
    // is compared as a string.
    let keys = [slot.uuidString.uppercased(): secret]
    let server = PSKWebSocketServer(host: "0.0.0.0", port: port, keys: { keys }) { connection, text in
        connection.send(text: "echo:" + text)
    }
    let channel = try server.start()
    announceListening(port)
    try await channel.closeFuture.get()
}
