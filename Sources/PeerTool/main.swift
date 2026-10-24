import Darwin
import Dispatch
import Foundation

signal(SIGPIPE, SIG_IGN)
var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "serve" else {
    FileHandle.standardError.write(Data("flightdeck-peer is managed by Flight Deck; use flightdeck peer --help\n".utf8)); exit(2)
}
arguments.removeFirst()
var values: [String: String] = [:], configs: [String] = []
while !arguments.isEmpty {
    let key = arguments.removeFirst()
    guard key.hasPrefix("--"), !arguments.isEmpty else { exit(2) }
    let value = arguments.removeFirst()
    if key == "--config" { configs.append(value) } else { values[key] = value }
}
func output(_ value: [String: Any]) {
    do { try FileHandle.standardOutput.write(contentsOf: PeerJSON.line(value)) }
    catch { exit(1) }
}
do {
    guard let session = values["--session"], let state = values["--state-dir"] else { exit(2) }
    let endpoint = try PeerEndpoint(sessionID: session, name: values["--name"] ?? "Flight Deck",
        agent: values["--agent"] ?? "codex", mode: values["--mode"] ?? "prompting", configs: configs,
        socketDirectory: values["--socket-dir"] ?? "/tmp/cc-socks", stateDirectory: state,
        advertised: values["--advertise"] != "false")
    endpoint.emit = output
    output(["type": "ready", "pid": getpid(), "socket": endpoint.socket.path, "sessionId": endpoint.sessionID])
    var decoder = PeerFrameDecoder()
    let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
    input.setEventHandler {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        if count <= 0 { endpoint.stop(); exit(0) }
        do {
            for request in try decoder.push(Data(buffer.prefix(count))) {
                guard let id = request["id"], let method = request["method"] as? String else { continue }
                do { output(["id": id, "result": try endpoint.request(method, request["params"] as? [String: Any] ?? [:])]) }
                catch { output(["id": id, "error": String(describing: error)]) }
            }
        } catch { endpoint.stop(); exit(1) }
    }
    input.resume()
    var signals: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { endpoint.stop(); exit(0) }
        source.resume(); signals.append(source)
    }
    withExtendedLifetime((endpoint, input, signals)) { dispatchMain() }
} catch {
    FileHandle.standardError.write(Data("flightdeck-peer: \(error)\n".utf8)); exit(1)
}
