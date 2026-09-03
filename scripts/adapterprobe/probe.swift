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
            // `--activity <idle|busy|waiting>` is optional; absent, `activity` stays nil exactly
            // as before. Codex has no reader at all, so it must short-circuit to "unsupported"
            // ahead of validating the flag's value — an invalid `--activity` must not turn a
            // codex probe into a usage error, and must not turn a claude probe into a silent nil.
            guard args.count == 2 || args.count == 4, let agent = agentID(args[1]) else { usage() }
            if args.count == 4 { guard args[2] == "--activity" else { usage() } }
            let tail = stdinText()
            let answer: [String: Any] = await MainActor.run {
                guard let reader = agent.openPromptReader else { return ["unsupported": true] }
                var activity: SessionActivity?
                if args.count == 4 {
                    guard let parsed = SessionActivity(rawValue: args[3]) else { usage() }
                    activity = parsed
                }
                let lines = tail.split(separator: "\n").enumerated().map {
                    SourceLine(offset: $0.offset, text: String($0.element))
                }
                return ["kind": reader.openPrompt(inTranscriptTail: lines, activity: activity)
                            .map { String(describing: $0) } as Any]
            }
            await emit(answer)

        case "prepare":
            guard let agent = args.count > 1 ? agentID(args[1]) : nil,
                  let cwd = flag(args, "--cwd") else { usage() }
            let session = Session(title: "adapterprobe", workingDirectory: cwd)
            do {
                let binding: AgentBinding
                switch agent {
                case .claude:
                    binding = try await MainActor.run { claudeAdapter() }
                        .prepare(for: session, options: .claude(FlagSet()))
                case .codex:
                    binding = try await withCodex {
                        try await $0.prepare(for: session, options: .codex(CodexThreadOptions()))
                    }
                }
                await emit([
                    // Lowercased: both `*-command` cases below print the agents' own
                    // command text, which already spells the id lowercase (`.uuidString`
                    // is Swift's uppercase form) — the probe matches that here so every
                    // caller compares one case rather than each having to normalise.
                    "conversationID": binding.conversationID.uuidString.lowercased(),
                    "transcriptURL": binding.transcriptURL?.path as Any,
                ])
            } catch {
                await emit(["error": String(describing: error)], exit: 1)
            }

        case "rebind":
            guard let agent = args.count > 1 ? agentID(args[1]) : nil,
                  let pinRaw = flag(args, "--pin"), let pin = UUID(uuidString: pinRaw),
                  let cwd = flag(args, "--cwd") else { usage() }
            let session = Session(
                title: "adapterprobe", workingDirectory: cwd, pinnedConversationID: pin
            )
            do {
                let binding: AgentBinding
                switch agent {
                case .claude:
                    binding = try await MainActor.run { claudeAdapter() }
                        .rebind(for: session, options: .claude(FlagSet()))
                case .codex:
                    binding = try await withCodex {
                        try await $0.rebind(for: session, options: .codex(CodexThreadOptions()))
                    }
                }
                await emit([
                    // Lowercased for the same reason `prepare` is — see that emission site.
                    "conversationID": binding.conversationID.uuidString.lowercased(),
                    "transcriptURL": binding.transcriptURL?.path as Any,
                    "repointed": binding.conversationID != pin,
                ])
            } catch {
                await emit(["error": String(describing: error)], exit: 1)
            }

        case "rename":
            guard let agent = args.count > 1 ? agentID(args[1]) : nil,
                  let idRaw = flag(args, "--id"), let id = UUID(uuidString: idRaw),
                  let title = flag(args, "--to") else { usage() }
            let binding = AgentBinding(conversationID: id, transcriptURL: nil)
            // `.claude` is a deliberate refusal, not a dispatch — never call `ClaudeAdapter
            // .rename`. Its own doc comment records why: claude renames go inline through
            // `SessionStore.rename`, never through the adapter, so this method traps
            // (`assertionFailure`) in Debug on purpose, as a tripwire for a future
            // refactor that starts routing claude through it. Calling it from here would
            // make this probe a way to trip that tripwire and SIGTRAP the harness — an
            // ambiguous signal a `rename` capability row cannot tell apart from a real
            // crash. Answering the refusal directly, as structured JSON, is what lets that
            // row see "claude doesn't rename through the adapter" as the expected answer
            // it is.
            if agent == .claude {
                await emit([
                    "error": "unreachable: claude renames dispatch inline through "
                        + "SessionStore, never through the adapter",
                ], exit: 1)
            }
            do {
                try await withCodex { try await $0.rename(binding, to: title) }
                await emit(["renamed": true])
            } catch {
                await emit(["error": String(describing: error)], exit: 1)
            }

        case "read":
            guard let agent = args.count > 1 ? agentID(args[1]) : nil,
                  let idRaw = flag(args, "--id"), let id = UUID(uuidString: idRaw) else { usage() }
            let binding = AgentBinding(conversationID: id, transcriptURL: nil)
            do {
                let result: (title: String?, activity: SessionActivity?)
                switch agent {
                case .claude:
                    // `AgentAdapter` carries no live `read` — claude's title/activity come
                    // from `ConversationTitle`/`SessionStatusWatcher`, both outside the
                    // adapter surface this probe exercises. A probe answers what the
                    // protocol actually offers rather than reaching around it.
                    result = (title: nil, activity: nil)
                case .codex:
                    result = try await withCodex { try await $0.read(binding) }
                }
                await emit([
                    "title": result.title as Any,
                    "activity": result.activity.map { String(describing: $0) } as Any,
                ])
            } catch {
                await emit(["error": String(describing: error)], exit: 1)
            }

        case "environment":
            // Every conformer's `environment(for:)` is the protocol's shared default (see
            // `AgentAdapter.swift`) -- neither `ClaudeAdapter` nor `CodexAdapter` overrides
            // it, so calling it through the claude witness below runs the exact same code a
            // codex-typed `self` would. Spinning up the real app-server just to reach a pure
            // `[String: String]` computation would pay a live turn for nothing this probe
            // can observe. The point of this subcommand is not which instance answers — it
            // is that a row calls `environment(for:)` at all, instead of asserting on the
            // probe's own hand-rolled `CLAUDE_CONFIG_DIR`/`CODEX_HOME` plumbing.
            guard args.count == 2, let agent = agentID(args[1]) else { usage() }
            guard let home = ProcessInfo.processInfo.environment[agent.homeEnvironmentKey] else {
                await emit([
                    "error": "\(agent.homeEnvironmentKey) is unset in the probe's own environment",
                ], exit: 1)
            }
            let account = AgentAccount(agent: agent, displayName: "adapterprobe",
                                        home: URL(fileURLWithPath: home))
            let env = await MainActor.run { claudeAdapter().environment(for: account) }
            await emit(env.mapValues { $0 as Any })

        case "launch-command", "resume-command":
            guard let agent = args.count > 1 ? agentID(args[1]) : nil,
                  let idRaw = flag(args, "--id"), let id = UUID(uuidString: idRaw),
                  let cwd = flag(args, "--cwd") else { usage() }
            let session = Session(
                title: "adapterprobe", workingDirectory: cwd, pinnedConversationID: id
            )
            let binding = AgentBinding(conversationID: id, transcriptURL: nil)
            do {
                let text: String
                switch agent {
                case .claude:
                    let claude = await MainActor.run { claudeAdapter() }
                    text = await MainActor.run {
                        op == "launch-command"
                            ? claude.launchCommand(binding, session, .claude(FlagSet()))
                            : claude.resumeCommand(binding, session, .claude(FlagSet()))
                    }
                case .codex:
                    text = try await withCodex { adapter in
                        await MainActor.run {
                            op == "launch-command"
                                ? adapter.launchCommand(binding, session, .codex(CodexThreadOptions()))
                                : adapter.resumeCommand(binding, session, .codex(CodexThreadOptions()))
                        }
                    }
                }
                await emit(["text": text])
            } catch {
                await emit(["error": String(describing: error)], exit: 1)
            }

        default:
            usage()
        }
    }

    static func stdinText() -> String {
        String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// `--name value` out of an argument list, or nil when the flag or its value is absent.
    static func flag(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), args.index(after: i) < args.endIndex else { return nil }
        return args[args.index(after: i)]
    }

    /// A `ClaudeAdapter` pointed at the sandbox, when one is in play. `projectsRoot` defaults
    /// to `ClaudeSession.defaultProjectsRoot`, which resolves against the REAL home — a probe
    /// run under `AgentSandbox` sets `CLAUDE_CONFIG_DIR`, and this is what keeps every claude
    /// subcommand's reads and derivations inside it instead.
    @MainActor
    static func claudeAdapter() -> ClaudeAdapter {
        var claude = ClaudeAdapter()
        if let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            claude.projectsRoot = { URL(fileURLWithPath: home).appendingPathComponent("projects") }
        }
        return claude
    }

    /// A real codex stack for one probe invocation, torn down on every exit path.
    @MainActor
    static func withCodex<T>(_ body: (CodexAdapter) async throws -> T) async throws -> T {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        let transport = CodexProcessTransport(executable: "codex", home: home)
        try transport.start()
        defer { transport.stop() }
        let rpc = CodexRPC(transport: transport)
        try await CodexProcessTransport.verifyHandshake(rpc)
        var adapter = CodexAdapter(rpc: rpc)
        adapter.historyMode = "legacy"   // the commit rule; see CodexIntegrationTests
        return try await body(adapter)
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
