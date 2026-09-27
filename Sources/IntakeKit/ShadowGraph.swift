import Foundation

/// A build step failed, or the change set couldn't even be validated against the graph it
/// was about to shadow — either way, `detail` is short enough to fold straight into a
/// polish round's record when the caller decides to run without `bv` guidance rather than
/// treat this as fatal (spec: "the shadow is an aid, not a gate").
public struct ShadowGraphBuildFailed: Error, Equatable, Sendable {
    public let detail: String
}

/// A throwaway copy of a project's `.beads` with a proposed `ChangeSet` applied on top, so a
/// polish round can run `bv`'s graph analytics (bottlenecks, critical path, ready-set width,
/// cycles) against what the graph would look like AFTER the change set landed — without ever
/// writing to the real bead database. `RoundExecutor` builds one per polish round under
/// `work/shadow/` and points the `bv --db <shadowPath>` it allows agents to run at the URL
/// this returns.
public struct ShadowGraph: Sendable {
    private let runner: CommandRunner
    private let brPath: String
    private let environment: [String: String]

    /// Every shadow write is attributed to this actor, not to whichever polish round
    /// triggered it: the shadow has no `Intake`/round identity of its own to attribute to,
    /// and it is deleted with `dir` anyway — a stable name is enough for `br`'s audit trail
    /// to show it never came from a real release.
    private static let actor = "flightdeck-intake:shadow"

    public init(runner: CommandRunner, brPath: String = "br", environment: [String: String]) {
        self.runner = runner
        self.brPath = brPath
        self.environment = environment
    }

    /// Copies `<project>/.beads` to `<dir>/.beads` (replacing any earlier copy under `dir`),
    /// then applies `changeSet`'s creates, edges (held ones included) and existing-bead edits
    /// to THAT copy with `br --db <dir>/.beads/beads.db …`. Returns `<dir>/.beads`.
    ///
    /// Every `br` call below runs with `cwd` = `dir`, never `project`: `br` auto-discovers
    /// `.beads` from `cwd` when `--db` is absent, and a call that ever fell back to that
    /// discovery here would silently write into the copy sitting in `project` — or, once
    /// `dir` no longer has a `.beads` of its own (before the first copy completes), into
    /// nothing traceable at all. Passing `--db` explicitly on every call, on top of never
    /// pointing `cwd` at `project`, means neither one of those slip-ups is enough by itself
    /// to reach the real graph.
    public func build(project: URL, changeSet: ChangeSet, in dir: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let shadowBeads = dir.appendingPathComponent(".beads", isDirectory: true)
        if fm.fileExists(atPath: shadowBeads.path) {
            try fm.removeItem(at: shadowBeads)
        }
        try fm.copyItem(at: project.appendingPathComponent(".beads", isDirectory: true), to: shadowBeads)
        let dbPath = shadowBeads.appendingPathComponent("beads.db").path

        // The "before" snapshot for validation is read from the COPY, not `project` — same
        // point of the URL, but it keeps every read in this method honoring the same
        // never-cwd=project rule as the writes below, rather than carving out an exception
        // for reads because they happen to be safe on their own.
        let snapshot = try await readGraph(dbPath: dbPath, cwd: dir)
        let validated: ValidatedChangeSet
        switch ChangeSetValidator.validate(changeSet, against: snapshot) {
        case .success(let v): validated = v
        case .failure(let errors):
            throw ShadowGraphBuildFailed(detail: errors.errors.map(\.message).joined(separator: "; "))
        }

        var idMap: [String: String] = [:]
        for step in ApplyPlanner.plan(validated, skipping: []) {
            switch step {
            case .create(let bead):
                idMap[bead.tempId] = try await create(bead, dbPath: dbPath, cwd: dir)
            case .depend(let dependent, let dependency, let kind):
                try await depend(resolve(dependent, idMap: idMap), resolve(dependency, idMap: idMap),
                                 kind: kind, dbPath: dbPath, cwd: dir)
            case .update(let id, let set):
                try await update(id, set: set, dbPath: dbPath, cwd: dir)
            case .recheck, .reopen:
                // The shadow is a one-shot snapshot with no concurrent writer to race, so
                // `recheck`'s precondition guard has nothing to protect against here; `reopen`
                // changes status, which `bv`'s ready-set/critical-path metrics do care about,
                // but the brief scopes this build to create/depend/update only — leaving it
                // out is a deliberate limitation, not an oversight.
                continue
            }
        }
        return shadowBeads
    }

    private func resolve(_ ref: BeadRef, idMap: [String: String]) throws -> String {
        switch ref {
        case .existing(let id): return id
        case .new(let tempId):
            guard let id = idMap[tempId] else {
                throw ShadowGraphBuildFailed(detail: "unresolved temp id new:\(tempId)")
            }
            return id
        }
    }

    private func readGraph(dbPath: String, cwd: URL) async throws -> GraphSnapshot {
        let list = try await run(["list", "--all", "--json"], dbPath: dbPath, cwd: cwd, label: "br list")
        let graph = try await run(["graph", "--all", "--json"], dbPath: dbPath, cwd: cwd, label: "br graph")
        return try GraphSnapshot.decode(list: list, graph: graph)
    }

    private func create(_ bead: NewBead, dbPath: String, cwd: URL) async throws -> String {
        var args = ["create", "--title", bead.title, "-t", bead.type, "-p", String(bead.priority),
                    "--description", bead.description]
        // `--acceptance`, not `--acceptance-criteria` (the flag `update` below uses) — the
        // same alias split `BeadWriter.run(_:)` documents for the real writer, verified live
        // against `br 0.6.0 --help create`/`--help update`.
        if let acceptance = bead.acceptance { args += ["--acceptance", acceptance] }
        if !bead.labels.isEmpty { args += ["-l", bead.labels.joined(separator: ",")] }
        args += ["--actor", Self.actor, "--json"]
        let stdout = try await run(args, dbPath: dbPath, cwd: cwd, label: "create \(bead.tempId)")
        struct Reply: Decodable { let id: String }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: stdout) else {
            throw ShadowGraphBuildFailed(detail: "create \(bead.tempId): unexpected output: \(Self.firstLine(of: stdout))")
        }
        return reply.id
    }

    private func depend(_ dependent: String, _ dependency: String, kind: EdgeKind, dbPath: String, cwd: URL) async throws {
        let args = ["dep", "add", dependent, dependency, "--type", kind.rawValue, "--actor", Self.actor]
        _ = try await run(args, dbPath: dbPath, cwd: cwd, label: "dep add \(dependent) \(dependency)")
    }

    private func update(_ id: String, set: FieldSet, dbPath: String, cwd: URL) async throws {
        var args = ["update", id]
        if let title = set.title { args += ["--title", title] }
        if let value = set.description { args += ["--description", value] }
        if let acceptance = set.acceptance { args += ["--acceptance-criteria", acceptance] }
        if let priority = set.priority { args += ["-p", String(priority)] }
        args += ["--actor", Self.actor]
        _ = try await run(args, dbPath: dbPath, cwd: cwd, label: "update \(id)")
    }

    /// `--db` goes FIRST, ahead of the subcommand — verified live against `br 0.6.0`: it is
    /// a global option (`br [OPTIONS] <COMMAND>`), and `br --db <path> create …` is the form
    /// that actually lands in the pointed-at database rather than whatever `cwd` discovers.
    private func run(_ arguments: [String], dbPath: String, cwd: URL, label: String) async throws -> Data {
        let result = try await runner.run(executable: brPath, arguments: ["--db", dbPath] + arguments,
                                          cwd: cwd, environment: environment)
        guard result.exitCode == 0 else {
            throw ShadowGraphBuildFailed(detail: "\(label): exit \(result.exitCode): \(Self.firstLine(of: result.stdout))")
        }
        return result.stdout
    }

    private static func firstLine(of data: Data) -> String {
        let s = String(decoding: data, as: UTF8.self)
        return s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }
}
