import FleetKit
import Foundation

/// Everything `flightdeck` prints, as strings — no I/O here, so the runner's output is what a
/// test reads back.
enum CLIOutput {
    /// One frame as one line of JSON: the wire's own encoding, so `tail`/`raw` output is what a
    /// packet dump would show and a consumer can decode it with FleetKit's own `ServerFrame`.
    static func line(_ frame: ServerFrame) -> String { json(frame) }

    /// Compact and key-sorted: compact so every value is one line a `while read` loop or `jq`
    /// can take, sorted so two runs over the same state print byte-identical output that
    /// `diff` can compare.
    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Every value printed here is a wire type the Mac itself encodes on every frame, so a
        // failure is a FleetKit bug, not an input problem. `null` keeps the line parseable
        // rather than printing nothing a consumer would wait on.
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `ls` for a human at a terminal. The id column is the 8-character prefix, which is
    /// already past `CLISessionResolver`'s 4-character floor, so any cell can be pasted
    /// straight back into another command.
    static func table(_ fleet: FleetSnapshot) -> String {
        var rows = [["PROJECT", "ID", "TITLE", "AGENT", "ACTIVITY", "WAITING"]]
        for project in fleet.projects {
            for session in project.sessions {
                rows.append([
                    project.name, String(session.id.uuidString.prefix(8)), session.title,
                    session.agent,
                    // `-`, never `idle`: nil means no agent process at all, and printing it as
                    // idle is the "every dead tab looks alive" mistake `WireSession.activity`
                    // warns about.
                    session.activity ?? "-", session.waitingFor ?? "",
                ])
            }
        }
        return columns(rows)
    }

    /// `host ls` for a human. A refused host's reason rides in its STATUS cell, because it is
    /// the one thing the user has to act on ("Update Flight Deck on mini") and a separate
    /// column would sit empty for every other host.
    static func table(_ hosts: [WireHost], now: Date) -> String {
        var rows = [["NAME", "PLATFORM", "STATUS", "LAST SEEN"]]
        for host in hosts {
            rows.append([
                host.name, host.platform ?? "-",
                host.detail.map { "\(host.status): \($0)" } ?? host.status,
                // "now" for an online host: the registry stamps `lastSeenAt` when the link
                // comes up, not on every pong, so its age would claim an idle-but-live host
                // went quiet hours ago.
                host.status == "online" ? "now" : host.lastSeenAt.map { relative($0, now: now) } ?? "never",
            ])
        }
        return columns(rows)
    }

    /// `host info` for a human: one `key: value` line per field, the disk figure in the units
    /// Finder would show rather than a twelve-digit byte count.
    static func hostInfo(_ info: WireHostInfo) -> String {
        let disk = ByteCountFormatter()
        disk.countStyle = .file
        return [
            ("name", info.name), ("host", info.hostName), ("platform", info.platform),
            ("os", info.osVersion), ("arch", info.arch), ("hostd", info.hostdVersion),
            ("xcode", info.xcode.isEmpty ? "-" : info.xcode.joined(separator: ", ")),
            ("docker", info.docker ?? "-"),
            ("disk free", disk.string(fromByteCount: info.diskFreeBytes)),
        ]
        .map { "\($0):".padding(toLength: 11, withPad: " ", startingAt: 0) + $1 }
        .joined(separator: "\n")
    }

    /// "4m ago". POSIX locale so the output a script or test reads does not change with the
    /// user's language settings.
    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Left-aligned columns two spaces apart, each as wide as its widest cell.
    private static func columns(_ rows: [[String]]) -> String {
        let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { cells in
            cells.enumerated().map { column, cell in
                cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: "\n")
    }

    /// The session an event is about, for `tail --session`. An explicit switch with **no
    /// `default`**, so a new `FleetEvent` case fails to compile here until someone decides
    /// whether a session filter shows it — a default would silently drop it from every
    /// filtered tail.
    static func eventSession(_ event: FleetEvent) -> UUID? {
        switch event {
        case .sessionAdded(let session, _, _):
            return session.id
        case .sessionRemoved(let id), .sessionMoved(let id, _, _), .renamed(let id, _, _),
             .activityChanged(let id, _, _, _, _, _, _, _, _), .unreadChanged(let id, _),
             .apiErrorChanged(let id, _), .planGateChanged(let id, _),
             .promptExpired(let id, _), .promptTyped(let id, _):
            return id
        case .projectAdded, .projectRemoved, .projectCollapsed, .projectsReordered,
             .sessionsReordered, .projectIntakes:
            return nil
        }
    }

    /// `prompt` for a human. Options are numbered **from 0**, because those are the numbers
    /// `answer`'s `[[Int]]` takes — numbering from 1 here would make every answer typed off
    /// this screen pick the option below the one meant.
    static func prompt(_ prompt: OpenPrompt) -> String {
        switch prompt {
        case .question(let callID, let questions):
            var lines: [String] = []
            for (q, question) in questions.enumerated() {
                let header = question.header.map { "[\($0)] " } ?? ""
                let multi = question.multiSelect ? " (several)" : ""
                lines.append("\(q). \(header)\(question.question)\(multi)")
                for (i, option) in question.options.enumerated() {
                    let detail = option.detail.map { " — \($0)" } ?? ""
                    lines.append("   \(i). \(option.label)\(detail)")
                }
            }
            lines.append("call: \(callID)")
            return lines.joined(separator: "\n")
        case .permission(let callID, let tool, let summary):
            var lines = ["permission: \(tool ?? "unknown tool")"]
            if let summary { lines.append(summary) }
            lines.append("call: \(callID)")
            return lines.joined(separator: "\n")
        }
    }

    /// `prompt --json`. Its own shape because `OpenPrompt` is deliberately not `Codable` — it
    /// is derived on each end and never travels — so this is the CLI's format, not the wire's.
    static func promptJSON(_ prompt: OpenPrompt) -> String {
        switch prompt {
        case .question(let callID, let questions):
            return json(PromptJSON(
                kind: "question", call: callID, tool: nil, summary: nil,
                questions: questions.map { question in
                    .init(header: question.header, question: question.question,
                          multiSelect: question.multiSelect,
                          options: question.options.map { .init(label: $0.label, detail: $0.detail) })
                }))
        case .permission(let callID, let tool, let summary):
            return json(PromptJSON(kind: "permission", call: callID, tool: tool, summary: summary,
                                   questions: nil))
        }
    }

    private struct PromptJSON: Encodable {
        struct Question: Encodable {
            struct Option: Encodable { let label: String; let detail: String? }
            let header: String?
            let question: String
            let multiSelect: Bool
            let options: [Option]
        }
        let kind: String
        let call: String
        let tool: String?
        let summary: String?
        let questions: [Question]?
    }
}
