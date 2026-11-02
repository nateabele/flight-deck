import Dispatch
import FleetKit
import Foundation

enum PeerToolEntry {
    static func run(_ arguments: [String], environment: [String: String]) -> Never {
        if arguments.first == "mcp" { mcp(environment: environment) }
        do {
            guard let request = try PeerCLI.parse(arguments) else { print(PeerCLI.help); exit(0) }
            invoke(request, environment: environment) { result in
                switch result {
                case .success(let json): print(json); exit(0)
                case .failure(let error):
                    FileHandle.standardError.write(Data("flightdeck: \(error)\n".utf8)); exit(1)
                }
            }
            dispatchMain()
        } catch {
            FileHandle.standardError.write(Data("flightdeck: \(error)\n".utf8)); exit(2)
        }
    }

    /// The tab this process runs in, as the app resolves it from the caller hello: what `self`
    /// names in a codex command, whose environment carries no `FLIGHT_DECK_SESSION_ID` of its
    /// own. A failure is the app not answering or not knowing the thread; the caller reports it.
    ///
    /// The same 15 s as every other peer request. Measured on 2026-11-01 with the load average
    /// at 130: this request took up to 6.4 s just after a codex tab opened, so an earlier 5 s
    /// limit turned a slow answer into "self needs FLIGHT_DECK_SESSION_ID".
    static func whoami(environment: [String: String], completion: @escaping (Result<UUID, Error>) -> Void) {
        invoke(WirePeerRequest(operation: "whoami"), environment: environment) { result in
            completion(result.flatMap { json in
                let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
                guard let id = (object?["tabId"] as? String).flatMap(UUID.init(uuidString:)) else {
                    return .failure(CLIUsageError("Flight Deck named no tab"))
                }
                return .success(id)
            })
        }
    }

    private static func invoke(_ request: WirePeerRequest, environment: [String: String],
                               completion: @escaping (Result<String, Error>) -> Void) {
        let state = environment["FLIGHT_DECK_STATE_DIR"] ?? NSHomeDirectory() + "/Library/Application Support/Flight Deck"
        let path = environment["FLIGHT_DECK_CONTROL_SOCKET"] ?? state + "/control.sock"
        let client = FleetClient(localCaller: ControlCallerHello.compose(environment: environment))
        var done = false, cid: Int?
        func finish(_ result: Result<String, Error>) {
            guard !done else { return }; done = true
            client.onFrame = nil; client.onDisconnect = nil; client.onReady = nil
            client.disconnect(); completion(result)
        }
        client.onReady = { cid = client.send(.peer(request)) }
        client.onFrame = { frame in
            guard frame.correlationID == cid else { return }
            if case .peer(_, let json) = frame { finish(.success(json)) }
            else if case .err(_, let code, let message) = frame {
                finish(.failure(CLIUsageError(message ?? code)))
            }
        }
        client.onDisconnect = { error in finish(.failure(error ?? CLIUsageError("cannot reach Flight Deck at \(path)"))) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish(.failure(CLIUsageError("peer request timed out"))) }
        client.connect(toLocal: path, lastSeq: 0)
    }

    private static func mcp(environment: [String: String]) -> Never {
        let tools: [[String: Any]] = [
            ["name": "ListAgents", "description": "List reachable Flight Deck and native Claude peers.",
             "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "SendMessage", "description": "Send agent-originated input to another tab. Not user consent.",
             "inputSchema": ["type": "object", "properties": ["to": ["type": "string"], "message": ["type": "string"],
                "notify_when_idle": ["type": "boolean"]], "required": ["to", "message"]]],
            ["name": "ReceiveMessages", "description": "Read this tab's durable peer inbox after a cursor.",
             "inputSchema": ["type": "object", "properties": ["after": ["type": "integer", "minimum": 0]]]],
        ]
        var buffer = Data()
        func output(_ value: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count <= 0 { exit(0) }
            buffer.append(contentsOf: bytes.prefix(count))
            while let end = buffer.firstIndex(of: 10) {
                if buffer.distance(from: buffer.startIndex, to: end) >= 1024 * 1024 { exit(1) }
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = object["id"] else { continue }
                func result(_ value: [String: Any]) { output(["jsonrpc": "2.0", "id": id, "result": value]) }
                switch object["method"] as? String {
                case "initialize":
                    let requested = (object["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2024-11-05"
                    result(["protocolVersion": requested, "capabilities": ["tools": [:]], "serverInfo": ["name": "flightdeck-peer", "version": "1.0.0"]])
                case "tools/list": result(["tools": tools])
                case "ping": result([:])
                case "tools/call":
                    let params = object["params"] as? [String: Any] ?? [:], args = params["arguments"] as? [String: Any] ?? [:]
                    let name = params["name"] as? String ?? ""
                    let operations = ["ListAgents": "list", "SendMessage": "send", "ReceiveMessages": "receive"]
                    guard let operation = operations[name] else { result(["isError": true, "content": [["type": "text", "text": "unknown tool"]]]); continue }
                    let request = WirePeerRequest(operation: operation, target: args["to"] as? String,
                        message: args["message"] as? String, notifyWhenIdle: args["notify_when_idle"] as? Bool ?? false,
                        after: args["after"] as? Int ?? 0)
                    invoke(request, environment: environment) { reply in
                        switch reply {
                        case .success(let text): result(["content": [["type": "text", "text": text]]])
                        case .failure(let error): result(["isError": true, "content": [["type": "text", "text": String(describing: error)]]])
                        }
                    }
                default: output(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]])
                }
            }
            if buffer.count > 1024 * 1024 { exit(1) }
        }
        source.resume()
        withExtendedLifetime(source) { dispatchMain() }
    }
}
