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

        case "sanitize":
            guard args.count == 3, let agent = agentID(args[1]) else { usage() }
            await emit(["sanitized": agent.sanitizedTitle(args[2]) as Any])

        case "title-from-transcript":
            guard args.count == 3, let agent = agentID(args[1]) else { usage() }
            let url = URL(fileURLWithPath: args[2])
            await emit(["title": agent.title(fromTranscriptAt: url) as Any])

        case "timeline":
            guard args.count == 2, let agent = agentID(args[1]) else { usage() }
            let lines = stdinText().split(separator: "\n", omittingEmptySubsequences: true)
            var items = 0
            var barren: [Int] = []
            for (i, line) in lines.enumerated() {
                let produced = await MainActor.run { agent.timelineItems(inLine: String(line), at: i) }
                if produced.isEmpty { barren.append(i) } else { items += produced.count }
            }
            await emit(["lines": lines.count, "items": items, "barrenLines": barren])

        case "identity":
            guard args.count == 2, let agent = agentID(args[1]) else { usage() }
            let data = Data(stdinText().utf8)
            let id = await MainActor.run { agent.identity(fromHomeData: data) }
            await emit(["identity": id?.email as Any])

        case "composer-empty":
            guard args.count == 2, let agent = agentID(args[1]) else { usage() }
            let screen = stdinText()
            let answer: [String: Any] = await MainActor.run {
                guard let channel = agent.textChannel else { return ["error": "no text channel"] }
                return ["empty": channel.isComposerEmpty(ViewportInjector(screen))]
            }
            await emit(answer)

        case "focused-row":
            guard args.count == 2, let agent = agentID(args[1]) else { usage() }
            let screen = stdinText()
            let answer: [String: Any] = await MainActor.run {
                guard let driver = agent.dialogDriver else { return ["error": "no dialog driver"] }
                return ["row": driver.focusedRow(inViewport: screen) as Any]
            }
            await emit(answer)

        case "row-reads":
            guard args.count >= 4, let agent = agentID(args[1]), let n = Int(args[2]) else { usage() }
            let label = args[3...].joined(separator: " ")
            let screen = stdinText()
            let answer: [String: Any] = await MainActor.run {
                guard let driver = agent.dialogDriver else { return ["error": "no dialog driver"] }
                return ["reads": driver.row(n, reads: label, inViewport: screen)]
            }
            await emit(answer)

        case "open-prompt":
            guard args.count == 2, let agent = agentID(args[1]) else { usage() }
            let tail = stdinText()
            let answer: [String: Any] = await MainActor.run {
                guard let reader = agent.openPromptReader else { return ["unsupported": true] }
                let lines = tail.split(separator: "\n").enumerated().map {
                    SourceLine(offset: $0.offset, text: String($0.element))
                }
                return ["kind": reader.openPrompt(inTranscriptTail: lines, activity: nil)
                            .map { String(describing: $0) } as Any]
            }
            await emit(answer)

        default:
            usage()
        }
    }

    static func stdinText() -> String {
        String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

/// A `TextInjecting` over a captured screen. Reads answer `viewport`; writes are recorded so a
/// probe can report the keystrokes a driver produced without a real surface to send them at.
@MainActor
final class ViewportInjector: TextInjecting {
    let viewport: String
    private(set) var sent: [String] = []

    init(_ viewport: String) { self.viewport = viewport }

    func sendText(_ text: String) { sent.append("text:\(text)") }
    func sendReturn()             { sent.append("return") }
    func sendKillLine()           { sent.append("killline") }
    func sendYank()               { sent.append("yank") }
    func sendArrowDown()          { sent.append("down") }
    func sendArrowUp()            { sent.append("up") }
    func sendEscape()             { sent.append("escape") }
    func readViewport() -> String? { viewport }
}
