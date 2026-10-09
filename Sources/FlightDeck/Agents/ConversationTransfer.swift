import Foundation
import IntakeKit

/// Carries one tab's conversation from one account's home into another's, so the agent's own
/// resume finds it there. What a smart-sleep thaw needs to roll a conversation off a spent
/// account (`SessionStore.rollOver`): every agent keeps its transcripts inside the home its
/// account variable names, so resuming the same id under the next account's home finds nothing
/// — and claude's and grok's resume commands then fall through to a FRESH session under the
/// same id, losing the conversation without an error anywhere.
///
/// Each conformer copies, never moves: the copy is made while the old agent still exists, and a
/// launch that fails afterwards must still find the conversation where it was. The old home's
/// copy goes stale the moment the new agent writes its next turn.
///
/// Probed 2026-10-09 (`.superpowers/round2-sleep-lease-rollover-REPORT.md`): claude 2.1.295
/// resumed a copied transcript under a second signed-in home with full context; codex-cli
/// 0.160.0's app-server and `exec resume` found a copied rollout in a home whose state database
/// had never seen the thread; grok 1.0.30 found a copied session directory by id; OpenCode
/// 1.18.34 imported an exported session into a second data root, and that root's running server
/// served it at once.
protocol AgentConversationTransfer {
    /// Copies `session`'s conversation from the home `from` into the home `to`, and returns the
    /// session as the resumed tab must carry it (a transcript path that names a file under
    /// `to`, for the agents that store one). A conversation that never wrote anything has
    /// nothing to carry and comes back unchanged: its resume starts fresh under the same id in
    /// either home. Throws when there IS a conversation and it could not be copied — the caller
    /// then leaves the agent where it is rather than resume it somewhere it cannot be found.
    func transfer(_ session: Session, from: URL, to: URL) async throws -> Session
}

enum ConversationTransferError: Error, Equatable {
    /// OpenCode names its session in the tab's transcript path; a tab with none cannot say
    /// which session to export.
    case unknownSession
    /// A step of the copy failed; the message says which.
    case failed(String)
}

/// Copy helpers every file-based conformer shares.
enum TransferFiles {
    /// Replaces `destination` with a copy of `source` (a file or a directory), creating the
    /// parent. Replacing rather than merging: a conversation that rolled A → B → A finds B's
    /// older copy in A, and the newer one is the one that must win.
    static func replace(_ destination: URL, with source: URL, skipping skip: (URL) -> Bool = { _ in false }) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else { return try fm.copyItem(at: source, to: destination) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let child = source.appendingPathComponent(name)
            if skip(child) { continue }
            try replace(destination.appendingPathComponent(name), with: child, skipping: skip)
        }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// claude: `<home>/projects/<encoded cwd>/<id>.jsonl`, plus the `<id>/` directory beside it
/// (subagent transcripts, spilled tool results). `claude --resume <id>` looks only under the
/// cwd's own project directory, so the copy keeps the directory name the source used.
struct ClaudeConversationTransfer: AgentConversationTransfer {
    func transfer(_ session: Session, from: URL, to: URL) async throws -> Session {
        let id = session.pinnedConversationID.uuidString.lowercased()
        let sourceRoot = from.appendingPathComponent("projects", isDirectory: true)
        let expected = ClaudeSession.transcriptURL(sessionID: session.pinnedConversationID,
                                                   workingDirectory: session.transcriptDirectory,
                                                   projectsRoot: sourceRoot)
        let source: URL
        if TransferFiles.exists(expected) {
            source = expected
        } else if let found = Self.find("\(id).jsonl", under: sourceRoot) {
            source = found
        } else {
            return session   // never written: nothing to carry
        }
        let directory = source.deletingLastPathComponent().lastPathComponent
        let targetDirectory = to.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(directory, isDirectory: true)
        do {
            try TransferFiles.replace(targetDirectory.appendingPathComponent("\(id).jsonl"), with: source)
            let sidecar = source.deletingLastPathComponent().appendingPathComponent(id, isDirectory: true)
            if TransferFiles.exists(sidecar) {
                try TransferFiles.replace(targetDirectory.appendingPathComponent(id, isDirectory: true), with: sidecar)
            }
        } catch {
            throw ConversationTransferError.failed("copying the claude transcript: \(error.localizedDescription)")
        }
        return session
    }

    /// `projects/*/<name>`: a conversation resumed from another directory keeps the project
    /// directory it was born in.
    static func find(_ name: String, under root: URL) -> URL? {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return dirs.lazy.map { root.appendingPathComponent($0).appendingPathComponent(name) }
            .first(where: TransferFiles.exists)
    }
}

/// codex: the rollout under `<home>/sessions/YYYY/MM/DD/`, which `codex resume <id>` and the
/// app-server's `thread/read` both find by scanning when the home's state database has never
/// seen the thread (probed), plus the thread's line in `session_index.jsonl` so its name
/// travels too. The tab's `transcriptPath` is repointed at the copy: it is what the rollout
/// watcher tails.
struct CodexConversationTransfer: AgentConversationTransfer {
    func transfer(_ session: Session, from: URL, to: URL) async throws -> Session {
        let id = session.pinnedConversationID.uuidString.lowercased()
        let sourceSessions = from.appendingPathComponent("sessions", isDirectory: true)
        let source: URL
        if let path = session.transcriptPath, TransferFiles.exists(URL(fileURLWithPath: path)) {
            source = URL(fileURLWithPath: path)
        } else if let found = Self.findRollout(id, under: sourceSessions) {
            source = found
        } else {
            return session   // never got past the trust prompt: codex wrote no rollout
        }
        // The rollout keeps its dated directory: `YYYY/MM/DD/rollout-…-<id>.jsonl`.
        let dated = source.pathComponents.suffix(4)
        let destination = dated.reduce(to.appendingPathComponent("sessions", isDirectory: true)) {
            $0.appendingPathComponent($1)
        }
        do {
            try TransferFiles.replace(destination, with: source)
            try Self.carryIndexLines(for: id, from: from, to: to)
        } catch {
            throw ConversationTransferError.failed("copying the codex rollout: \(error.localizedDescription)")
        }
        var moved = session
        moved.transcriptPath = destination.path
        return moved
    }

    static func findRollout(_ id: String, under root: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent.hasSuffix("-\(id).jsonl") { return url }
        return nil
    }

    /// Appends the thread's `session_index.jsonl` lines (its names) to the destination's,
    /// unless they are already there.
    static func carryIndexLines(for id: String, from: URL, to: URL) throws {
        let source = from.appendingPathComponent("session_index.jsonl")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init).filter { $0.contains("\"\(id)\"") }
        guard !lines.isEmpty else { return }
        let destination = to.appendingPathComponent("session_index.jsonl")
        let existing = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
        let missing = lines.filter { !existing.contains($0) }
        guard !missing.isEmpty else { return }
        var joined = existing
        if !joined.isEmpty, !joined.hasSuffix("\n") { joined += "\n" }
        joined += missing.joined(separator: "\n") + "\n"
        try joined.write(to: destination, atomically: true, encoding: .utf8)
    }
}

/// grok: the whole `<home>/sessions/<encoded cwd>/<id>/` directory — `chat_history.jsonl` is
/// the model's context, `updates.jsonl` the transcript the tab reads. `grok -r <id>` finds a
/// session by id under any directory (facts §0.6). Lock files are left behind: they belong to a
/// process that is about to be gone.
struct GrokConversationTransfer: AgentConversationTransfer {
    func transfer(_ session: Session, from: URL, to: URL) async throws -> Session {
        guard let source = GrokSessionFiles.existingSessionDirectory(
            root: GrokSessionFiles.sessionsRoot(home: from), conversationID: session.pinnedConversationID)
        else { return session }
        let destination = GrokSessionFiles.sessionsRoot(home: to)
            .appendingPathComponent(source.deletingLastPathComponent().lastPathComponent, isDirectory: true)
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)
        do {
            try TransferFiles.replace(destination, with: source, skipping: { $0.pathExtension == "lock" })
        } catch {
            throw ConversationTransferError.failed("copying the grok session: \(error.localizedDescription)")
        }
        return session
    }
}

/// OpenCode: its sessions are rows in one SQLite database per data root, so the copy is
/// OpenCode's own `export` from the old root and `import` into the new one. `import` stamps the
/// session with the directory it runs in (probed), so it runs in the tab's. The tab's
/// transcript path is the mirror Flight Deck keeps per database, so it is recomputed for the
/// new one.
struct OpenCodeConversationTransfer: AgentConversationTransfer {
    /// Runs `opencode <arguments>` with `XDG_DATA_HOME` = the data root, in `directory`, and
    /// returns its standard output. Throws on a non-zero exit.
    typealias Run = (_ arguments: [String], _ dataHome: URL, _ directory: URL) async throws -> Data

    var run: Run = OpenCodeConversationTransfer.live
    var mirrorRoot: URL = OpenCodeMirror.defaultRoot

    func transfer(_ session: Session, from: URL, to: URL) async throws -> Session {
        guard let sessionID = OpenCodeIdentity.sessionID(
            fromTranscript: session.transcriptPath.map { URL(fileURLWithPath: $0) })
        else { throw ConversationTransferError.unknownSession }
        let directory = URL(fileURLWithPath: session.transcriptDirectory, isDirectory: true)
        let exported = try await run(["export", sessionID], from, directory)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("fd-opencode-\(sessionID)-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try exported.write(to: file)
        _ = try await run(["import", file.path], to, directory)
        guard let database = OpenCodeMirror.databaseURL(home: to) else {
            throw ConversationTransferError.failed("OpenCode imported the session, but no database was found under \(to.path)")
        }
        var moved = session
        moved.transcriptPath = OpenCodeMirror.url(forSession: sessionID, database: database, root: mirrorRoot).path
        return moved
    }

    static let live: Run = { arguments, dataHome, directory in
        let executable = try await OpenCodeServer.locate()
        return try await Task.detached {
            var environment = LoginShellPath.repairing()
            environment[OpenCodeProfile.homeEnvironmentKey] = dataHome.path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = directory
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ConversationTransferError.failed("opencode \(arguments.first ?? "") exited \(process.terminationStatus)")
            }
            return data
        }.value
    }
}
