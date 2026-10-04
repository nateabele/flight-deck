import Foundation

// `HostDaemonLinux echo --port N --slot UUID --secret-hex HEX` — the §3.2 interop gate's server:
// one paired slot, every text frame answered with "echo:" + text. Later subcommands (pair,
// serve) grow from the same listener.

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: HostDaemonLinux echo --port N --slot UUID --secret-hex HEX\n".utf8))
    exit(64)
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
guard args.first == "echo",
      let port = option("--port", in: args).flatMap(Int.init),
      let slot = option("--slot", in: args).flatMap(UUID.init(uuidString:)),
      let secret = option("--secret-hex", in: args).flatMap(bytes(hex:))
else { usage() }

// Upper-cased because that is what `UUID.uuidString` produces on Darwin, and the identity is
// compared as a string.
let keys = [slot.uuidString.uppercased(): secret]
let server = PSKWebSocketServer(host: "0.0.0.0", port: port, keys: { keys }) { connection, text in
    connection.send(text: "echo:" + text)
}
let channel = try server.start()
// Straight to the fd, not `print`: stdout is block-buffered under `docker run -d`, and the
// interop script waits on this exact line in `docker logs`.
FileHandle.standardOutput.write(Data("listening on \(port)\n".utf8))
try channel.closeFuture.wait()
