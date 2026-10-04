import Foundation
import PairingCore

// The §3.2 interop gates' server, one subcommand per gate:
//   echo --port N --slot UUID --secret-hex HEX
//       gate 1: one paired slot, every text frame answered with "echo:" + text.
//   pair-test --port N --slot UUID --secret-hex HEX --code XXXX-XXXX-XXXX
//       gate 2: one host-profile pairing window that seals that slot and secret under the
//       name "interop-host", then exits 0 — or exits 1 when the window burns or expires.
// Later subcommands (serve) grow from the same listeners.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: HostDaemonLinux echo --port N --slot UUID --secret-hex HEX
               HostDaemonLinux pair-test --port N --slot UUID --secret-hex HEX --code CODE

        """.utf8))
    exit(64)
}

/// Straight to the fd, not `print`: stdout is block-buffered under `docker run -d`, and the
/// interop script waits on this exact line in `docker logs`.
func announceListening(_ port: Int) {
    FileHandle.standardOutput.write(Data("listening on \(port)\n".utf8))
}

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

let args = Array(CommandLine.arguments.dropFirst())
guard let port = option("--port", in: args).flatMap(Int.init),
      let slot = option("--slot", in: args).flatMap(UUID.init(uuidString:)),
      let secret = option("--secret-hex", in: args).flatMap(bytes(hex:))
else { usage() }

switch args.first {
case "echo":
    try await echo(port: port, slot: slot, secret: secret)
case "pair-test":
    guard let code = option("--code", in: args).flatMap(PairingCode.init(normalizing:)) else { usage() }
    do {
        try await NIOPairingResponder.run(
            code: code, key: FleetDeviceKey(slot: slot, secret: Data(secret)),
            hostName: "interop-host", port: port, onListening: { announceListening(port) }
        )
        FileHandle.standardOutput.write(Data("paired\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("pairing window ended: \(error)\n".utf8))
        exit(1)
    }
default:
    usage()
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
