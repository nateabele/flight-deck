// scripts/adapterprobe/probe.swift
//
// The real adapters, as a CLI.
//
// Linked against the built `FlightDeck` module rather than compiled from a hand-listed set of
// sources: `CodexAdapter` needs FleetKit, `CodexRPC`, `CodexProcessTransport`, `SessionStore`'s
// types and `@MainActor async` context, and a second source list would be a second build
// description that drifts. This one cannot drift, because it *is* the app's module.
//
// Every subcommand prints one JSON object on stdout. Exit 0 = the probe ran; 1 = it ran and
// the operation failed (the object carries "error"); 2 = usage. A non-zero exit is never by
// itself a statement about the adapter — the runner decides that.
import Foundation
@testable import FlightDeck

@main
struct Probe {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let op = args.first else { usage() }
        switch op {
        case "declare":
            guard args.count == 2, let agent = agentID(args[1]) else { usage() }
            await emit(declare(agent))
        default:
            usage()
        }
    }

    @MainActor
    static func declare(_ agent: AgentID) -> [String: Any] {
        [
            "agent": agent.rawValue,
            "textChannel": agent.textChannel != nil,
            "dialogDriver": agent.dialogDriver != nil,
            "openPromptReader": agent.openPromptReader != nil,
            "negotiatesIdentity": agent.negotiatesIdentity,
            "needsRuntimeStart": agent.needsRuntimeStart,
            "hasStatusRegistry": agent.hasStatusRegistry,
            "homeMarkerFile": agent.homeMarkerFile,
            "allowRow": agent.dialogDriver?.allowRow as Any,
        ]
    }

    static func agentID(_ raw: String) -> AgentID? {
        switch raw {
        case "claude": .claude
        case "codex": .codex
        default: nil
        }
    }

    static func emit(_ object: [String: Any], exit code: Int32 = 0) -> Never {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"error":"unserializable"}"#.utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(code)
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data("usage: probe declare <claude|codex>\n".utf8))
        exit(2)
    }
}
