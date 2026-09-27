import Foundation

/// A build step failed, or the change set couldn't even be validated against the graph it
/// was about to shadow — either way, `detail` is short enough to fold straight into a
/// polish round's record when the caller decides to run without `bv` guidance rather than
/// treat this as fatal (spec: "the shadow is an aid, not a gate").
public struct ShadowGraphBuildFailed: Error, Equatable, Sendable {
    public let detail: String
}

/// A throwaway copy of a project's `.beads` with a proposed `ChangeSet` applied on top, so `bv`
/// can be run against what the graph would look like AFTER the change set landed — without ever
/// writing to the real bead database. `RoundExecutor` builds one per polish round under
/// `work/shadow/`, then runs `bv`'s robot reports against the URL this returns ITSELF — never
/// the agent: a claude `Bash` allow is a prefix match on the whole command line, so even one
/// scoped to this URL would also match `bv`'s write flags on the same invocation. The reports
/// land as plain files (`ShadowAnalytics` in RoundPrompts.swift) that the polish prompt points
/// the agent at to read.
public struct ShadowGraph: Sendable {
    private let runner: CommandRunner
    private let brPath: String
    private let environment: [String: String]

    /// Runs the `sqlite3 … VACUUM INTO` snapshot step. Injectable like `runner` so that step's
    /// failure path is testable without a broken system `sqlite3`; the convenience init
    /// below keeps the real one for every production caller.
    private let sqliteRunner: CommandRunner
    private static let sqlite3Path = "/usr/bin/sqlite3"

    /// Every shadow write is attributed to this actor, not to whichever polish round
    /// triggered it: the shadow has no `Intake`/round identity of its own to attribute to,
    /// and it is deleted with `dir` anyway — a stable name is enough for `br`'s audit trail
    /// to show it never came from a real release.
    private static let actor = "flightdeck-intake:shadow"

    public init(runner: CommandRunner, sqliteRunner: CommandRunner, brPath: String = "br",
                environment: [String: String]) {
        self.runner = runner
        self.sqliteRunner = sqliteRunner
        self.brPath = brPath
        self.environment = environment
    }

    public init(runner: CommandRunner, brPath: String = "br", environment: [String: String]) {
        self.init(runner: runner, sqliteRunner: SystemCommandRunner(), brPath: brPath, environment: environment)
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
    ///
    /// Whatever fails underneath — `FileManager`, a `br`/`sqlite3` exit code, JSON decoding —
    /// surfaces as `ShadowGraphBuildFailed`, never a raw `CocoaError`/`DecodingError`/etc.: the
    /// brief's "the shadow is an aid, not a gate" only works if a caller can catch ONE type and
    /// fold `.detail` into the round record, rather than enumerating every failure domain a
    /// `FileManager` copy or a JSON decode could throw.
    public func build(project: URL, changeSet: ChangeSet, in dir: URL) async throws -> URL {
        do {
            return try await buildUnchecked(project: project, changeSet: changeSet, in: dir)
        } catch let failure as ShadowGraphBuildFailed {
            throw failure
        } catch {
            throw ShadowGraphBuildFailed(detail: error.localizedDescription)
        }
    }

    private func buildUnchecked(project: URL, changeSet: ChangeSet, in dir: URL) async throws -> URL {
        let shadowBeads = try await copyBeads(from: project, to: dir)
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

    /// Copies `<project>/.beads` to `<dir>/.beads`, replacing any earlier copy. Everything
    /// except the live SQLite files is a plain `FileManager` copy; `beads.db` goes through
    /// `sqlite3 -readonly … "VACUUM INTO …"` instead of copying `beads.db`/`-wal`/`-shm` as
    /// three independent files. Those three files only add up to one consistent database
    /// when nothing is mid-write; a real `br` process holding an open WAL transaction while
    /// this runs would otherwise leave the shadow with a `beads.db` that doesn't match the
    /// `-wal` bytes sitting next to it — a torn copy. `VACUUM INTO` instead opens the SOURCE
    /// read-only and materializes one self-contained snapshot file, so the shadow is either
    /// the graph as of the last commit before this ran, or (if `sqlite3` itself fails) no
    /// copy at all — never a half-applied one. Falls back to the old three-file copy when
    /// `/usr/bin/sqlite3` isn't present, since a stale-by-milliseconds shadow beats none.
    private func copyBeads(from project: URL, to dir: URL) async throws -> URL {
        let fm = FileManager.default
        let sourceBeads = project.appendingPathComponent(".beads", isDirectory: true)
        let shadowBeads = dir.appendingPathComponent(".beads", isDirectory: true)
        if fm.fileExists(atPath: shadowBeads.path) {
            try fm.removeItem(at: shadowBeads)
        }
        try fm.createDirectory(at: shadowBeads, withIntermediateDirectories: true)

        // A prefix match, not an exact set: a real `br` checkout grows more than just `-wal`/
        // `-shm` next to `beads.db` — WAL cert files, an fsqlite-ns gate/use pair, a
        // migration-state marker, observed live against `br 0.6.0` — and every one of them is
        // part of the live SQLite file's own state, handled below, never by this generic
        // loop. `config.yaml`, `.gitignore`, `issues.jsonl`, `metadata.json` and the like all
        // pass through here untouched.
        let sourceItems = try fm.contentsOfDirectory(at: sourceBeads, includingPropertiesForKeys: nil)
        for item in sourceItems where !item.lastPathComponent.hasPrefix("beads.db") {
            try fm.copyItem(at: item, to: shadowBeads.appendingPathComponent(item.lastPathComponent))
        }

        let sourceDB = sourceBeads.appendingPathComponent("beads.db")
        guard fm.fileExists(atPath: sourceDB.path) else { return shadowBeads }   // nothing to snapshot
        let shadowDB = shadowBeads.appendingPathComponent("beads.db")

        guard fm.isExecutableFile(atPath: Self.sqlite3Path) else {
            // No `sqlite3` to snapshot with — copy every `beads.db*` sidecar verbatim instead.
            // Same tearing risk as the whole-directory copy this replaces (a concurrent
            // writer mid-transaction could still leave these inconsistent), but a
            // stale-by-milliseconds shadow beats no shadow at all.
            for item in sourceItems where item.lastPathComponent.hasPrefix("beads.db") {
                try fm.copyItem(at: item, to: shadowBeads.appendingPathComponent(item.lastPathComponent))
            }
            return shadowBeads
        }

        // `cwd: dir` (the shadow side), never `project`, matching the never-cwd=project rule
        // everywhere else in this type — belt-and-suspenders alongside `-readonly`, which is
        // what actually stops this from ever taking a write lock on the real database. The
        // destination path is SQL text, not a shell argument (`Process` execs `sqlite3`
        // directly, no shell in between), so it only needs SQL's `''` quoting, never shell
        // quoting.
        let escapedDest = shadowDB.path.replacingOccurrences(of: "'", with: "''")
        let result = try await sqliteRunner.run(
            executable: Self.sqlite3Path,
            arguments: ["-readonly", sourceDB.path, "VACUUM INTO '\(escapedDest)';"],
            cwd: dir, environment: environment)
        guard result.exitCode == 0 else {
            throw ShadowGraphBuildFailed(detail: "vacuum shadow db: exit \(result.exitCode): \(result.stderr)")
        }
        return shadowBeads
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
            throw ShadowGraphBuildFailed(detail: "create \(bead.tempId): unexpected output: \(firstLine(of: stdout))")
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
            throw ShadowGraphBuildFailed(detail: "\(label): exit \(result.exitCode): \(firstLine(of: result.stdout))")
        }
        return result.stdout
    }
}
