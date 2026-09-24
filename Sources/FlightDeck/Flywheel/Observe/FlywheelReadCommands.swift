import Foundation

/// Read-only `am`/`br` wrappers for Observe. Mirrors `FlywheelCoordinator`'s runner+path
/// injection and minimal-decode approach, with one rule reversed: a read that fails or
/// returns an unexpected shape yields `nil` (the lane degrades to "unavailable") rather
/// than throwing — a substrate hiccup must never take down the drawer.
///
/// Every argv here is taken verbatim from Task 1's live probe,
/// `docs/superpowers/notes/2026-09-24-observe-command-shapes.md` — the source of truth
/// for the exact flags/flag order each lane needs.
struct FlywheelReadCommands {
    let runner: FlywheelProcessRunner
    let amPath: String
    let brPath: String

    init(runner: FlywheelProcessRunner = SystemFlywheelProcessRunner(),
         amPath: String = "am", brPath: String = "br") {
        self.runner = runner
        self.amPath = amPath
        self.brPath = brPath
    }

    struct RawAgent: Decodable, Equatable { let name: String }
    struct RawBead: Decodable, Equatable {
        let id: String; let title: String; let status: String; let assignee: String?
    }
    struct RawReservation: Decodable, Equatable {
        let file: String; let holder: String; let since: Date; let waiters: [String]
    }
    struct RawDepEdge: Decodable, Equatable { let from: String; let to: String }
    struct RawEvent: Decodable, Equatable { let agent: String; let kind: String; let at: Date }

    /// `br` needs `--db <path>` scoping every read to this project's beads database —
    /// positioned *after* the subcommand and its flags (not as a leading global flag),
    /// which keeps `argv.prefix(2)` (and so the fake-runner response key in tests) stable
    /// and independent of the project path. Confirmed live: findings doc, "Beads lanes".
    private func beadsDBPath(project: String) -> String {
        URL(fileURLWithPath: project).appendingPathComponent(".beads/beads.db").path
    }

    /// One decode helper so every lane degrades identically. Returns nil on non-zero exit
    /// or unparseable stdout; logs once at that point (caller decides log cadence).
    private func read<T>(_ exe: String, _ argv: [String], project: String,
                          decode: (Data) -> T?) async -> T? {
        guard let (stdout, code) = try? await runner.run(exe, argv, cwd: project), code == 0,
              let data = stdout.data(using: .utf8) else { return nil }
        return decode(data)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    /// `am agents list <project> --json` — PROVEN. Bare array, not wrapped.
    func agents(project: String) async -> [RawAgent]? {
        await read(amPath, ["agents", "list", project, "--json"], project: project) {
            try? Self.decoder.decode([RawAgent].self, from: $0)
        }
    }

    /// `br list --status in_progress --json --db <project>/.beads/beads.db` — CONFIRMED.
    /// Envelope is `{issues:[...], total, limit, offset, has_more}`; only `issues` matters
    /// here. Item shape is `IssueWithCounts`, which does carry `assignee` (optional).
    func inProgressBeads(project: String) async -> [RawBead]? {
        struct Envelope: Decodable { let issues: [RawBead] }
        let argv = ["list", "--status", "in_progress", "--json", "--db", beadsDBPath(project: project)]
        return await read(brPath, argv, project: project) {
            (try? Self.decoder.decode(Envelope.self, from: $0))?.issues
        }
    }

    /// `am reservations --project <project> --all --json` — the envelope
    /// (`{_meta, _alerts, all_active, reservation_read_attestation}`) is confirmed, but
    /// Task 1's live probe returned an empty `all_active`, so the per-row shape backing
    /// `RawReservation{file,holder,since,waiters}` was never observed and isn't in the
    /// findings doc's schema dump either. Guessing a row shape here would risk silently
    /// decoding nothing (or worse, decoding garbage) forever, so this stays a nil-stub
    /// until a real held reservation can be captured.
    // TODO(observe): unconfirmed shape — see notes
    func reservations(project: String) async -> [RawReservation]? {
        nil
    }

    /// `br dep list <issue> --json` needs a real issue id (exit 3 without one) and has no
    /// bare/whole-project form — Task 1 confirmed the argv and error envelope but never
    /// obtained a positive-path row, and `br schema commands` itself has no `item_schema`
    /// for this command. CC-1 in Task 1's report: ship as nil-stub, not a guessed edge shape.
    // TODO(observe): unconfirmed shape — see notes
    func depEdges(project: String) async -> [RawDepEdge]? {
        nil
    }

    /// `am inbox-events --agent <name> --project <project> --after <cursor> --direct --json`
    /// — MUST pass `--direct`, or Agent-Mail tries the HTTP daemon first and exits 1 with no
    /// local fallback (confirmed live). The envelope (`{events, next_cursor, has_more, ...}`)
    /// is confirmed, but the live probe's `events` array was empty, so the per-event shape
    /// backing `RawEvent{agent,kind,at}` is unconfirmed — nil-stub until a real event can be
    /// captured, same reasoning as `reservations`/`depEdges`.
    // TODO(observe): unconfirmed shape — see notes
    func events(project: String, after: String) async -> (events: [RawEvent], cursor: String)? {
        nil
    }
}
