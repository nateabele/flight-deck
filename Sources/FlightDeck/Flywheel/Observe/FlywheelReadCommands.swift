import Foundation
import IntakeKit

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

    /// `am reservations --project <project> --all --json`. The row shape was captured live in
    /// L3-S Task 11a (`Fixtures/FlightControlL3/Swarm/am-reservations-held.json`). `waiters` is
    /// always empty here: am knows who holds, not who is waiting — the swarm's guard-block capture
    /// fills that in (Task 11e).
    func reservations(project: String) async -> [RawReservation]? {
        await read(amPath, ["reservations", "--project", project, "--all", "--json"], project: project) {
            ReservationRows.decode($0)
        }
    }

    /// `br graph --all --json --db <db>` — the same command release reads live
    /// (`IntakeKit/GraphReader`), decoded by the same `GraphSnapshot.decodeEdges`. `from` is the
    /// dependent, `to` its dependency. Sorted so a repoll with the same graph is equal.
    func depEdges(project: String) async -> [RawDepEdge]? {
        await read(brPath, ["graph", "--all", "--json", "--db", beadsDBPath(project: project)], project: project) { data in
            (try? GraphSnapshot.decodeEdges(graph: data)).map { edges in
                edges.map { RawDepEdge(from: $0.dependent, to: $0.dependency) }
                    .sorted { ($0.from, $0.to) < ($1.from, $1.to) }
            }
        }
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

/// Decodes `am reservations --all --json`'s `all_active` rows. Field names are read from short
/// candidate lists because the robot output has renamed fields between am releases; a row with
/// no recognizable path or holder is dropped rather than guessed. The captured row (am 0.3.35)
/// is `{agent, path, exclusive, remaining_seconds, remaining, granted_at: "5s ago"}`: its only
/// grant time is relative, so it is anchored on the envelope's `_meta.timestamp`.
enum ReservationRows {
    static let pathKeys = ["path_pattern", "path", "pattern", "file"]
    static let holderKeys = ["agent_name", "agent", "holder", "holder_name"]
    static let timeKeys = ["created_ts", "created_at", "acquired_ts", "since"]
    static let relativeTimeKeys = ["granted_at"]

    static func decode(_ data: Data) -> [FlywheelReadCommands.RawReservation]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["all_active"] as? [[String: Any]] else { return nil }
        let anchor = ((object["_meta"] as? [String: Any])?["timestamp"] as? String)
            .flatMap(AgentMailTime.parse) ?? Date()
        return rows.compactMap { row in
            guard let path = pathKeys.lazy.compactMap({ row[$0] as? String }).first,
                  let holder = holderKeys.lazy.compactMap({ holderName(row[$0]) }).first else { return nil }
            let absolute = timeKeys.lazy.compactMap { (row[$0] as? String).flatMap(AgentMailTime.parse) }.first
            let relative = relativeTimeKeys.lazy.compactMap {
                (row[$0] as? String).flatMap { AgentMailTime.parseRelative($0, from: anchor) }
            }.first
            return FlywheelReadCommands.RawReservation(
                file: path, holder: holder, since: absolute ?? relative ?? .distantPast, waiters: [])
        }
    }

    private static func holderName(_ value: Any?) -> String? {
        if let name = value as? String, !name.isEmpty { return name }
        if let object = value as? [String: Any], let name = object["name"] as? String { return name }
        return nil
    }
}

/// am writes microsecond timestamps (`2026-09-22T16:57:34.483761Z`, `…+00:00`), which
/// `JSONDecoder.iso8601` refuses. Fractions are cut to milliseconds before parsing.
enum AgentMailTime {
    static func parse(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    /// `"5s ago"`, `"12m ago"`, `"2h ago"`, `"1d ago"` — the form am's reservation rows use for
    /// `granted_at` — resolved against `anchor`. Anything else is nil.
    static func parseRelative(_ text: String, from anchor: Date) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, parts[1] == "ago", let unit = parts[0].last,
              let amount = Double(parts[0].dropLast()),
              let seconds = ["s": 1.0, "m": 60, "h": 3600, "d": 86400][String(unit)] else { return nil }
        return anchor.addingTimeInterval(-amount * seconds)
    }
}
