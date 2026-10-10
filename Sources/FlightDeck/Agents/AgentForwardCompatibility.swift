import Foundation
import IntakeKit

/// **Keeping `sessions.json` and `preferences.v1` readable by a build that predates an agent.**
///
/// Both files are decoded with synthesized `Codable` and `try?`, and `AgentID` is a raw-value
/// enum: a build that has never heard of `"opencode"` (or `"grok"`) throws on the first value it
/// cannot map, the WHOLE decode fails, and the store starts from empty and saves that — every
/// tab, account and setting gone. That is not a hypothetical in this workflow. A Debug build
/// shares the Release build's defaults domain (so it writes the `preferences.v1` the installed
/// app reads), and sessions routinely swap in Release builds made from worktrees that predate
/// the newest agent (AGENT-OPERATIONS, "concurrent swaps").
///
/// **The one mechanism, in two halves.** On the way to disk, anything naming an agent outside
/// `readableByEveryBuild` moves out of the fields an older build decodes into a side field it
/// does not know about — synthesized `Codable` skips unknown keys — and on the way back in it is
/// merged to where it was. An older build then loads every claude and codex tab and setting
/// intact and simply does not see the others; the worst it can do is drop them on its next save.
/// The fields that only builds from the unify work onward read (`storedAccountList`,
/// `capacity.pools`) are the other half: those builds decode them element by element
/// (`AccountList`, `CapacityPreferences`), and the flat mirrors an older build reads instead
/// (`storedAccounts`, `capacity.pools`) are filtered by this same set
/// (`AccountList.legacyAccounts`). One set answers "can every build read this agent" for both.
///
/// The side fields are themselves decoded element by element, so a side entry naming an agent
/// THIS build does not know (a later build's) costs that entry, never the file.
///
/// **Add an agent here only when every build that might still read these files knows it.**
extension AgentID {
    /// The agents every build since agent adapters can decode: the two that existed before the
    /// unify work added grok and gemini. grok and gemini are NOT in it, although the installed
    /// unify Release reads them: a pre-unify build swapped in from an older worktree would reset
    /// every preference over a single grok row, while a unify build only loses its grok/gemini
    /// rows (its agent migration re-adds them, with empty options).
    static let readableByEveryBuild: Set<AgentID> = [.claude, .codex]

    var isReadableByEveryBuild: Bool { Self.readableByEveryBuild.contains(self) }
}

/// A list element moved aside, with where it was, so the merge restores the original order —
/// the order of `sessions` is the sidebar's, and the order of `agents` is the New Session
/// shortcut binding.
struct PlacedValue<Value: Codable & Equatable>: Codable, Equatable {
    let index: Int
    let value: Value
}

/// `[PlacedValue<Value>]` decoded element by element: an element this build cannot decode is
/// dropped, never the array (and through it the file).
struct LaterAgentList<Value: Codable & Equatable>: Codable, Equatable {
    var values: [PlacedValue<Value>]

    init(_ values: [PlacedValue<Value>] = []) { self.values = values }

    private struct Lossy: Decodable {
        let value: PlacedValue<Value>?
        init(from decoder: Decoder) throws { value = try? PlacedValue<Value>(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        values = try decoder.singleValueContainer().decode([Lossy].self).compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }
}

private func split<Value>(
    _ values: [Value], keep: (Value) -> Bool
) -> (kept: [Value], moved: [PlacedValue<Value>]) {
    var kept: [Value] = []
    var moved: [PlacedValue<Value>] = []
    for (index, value) in values.enumerated() {
        if keep(value) { kept.append(value) } else { moved.append(PlacedValue(index: index, value: value)) }
    }
    return (kept, moved)
}

private func merge<Value>(_ kept: [Value], _ moved: [PlacedValue<Value>]) -> [Value] {
    var out = kept
    for placed in moved.sorted(by: { $0.index < $1.index }) {
        out.insert(placed.value, at: min(max(placed.index, 0), out.count))
    }
    return out
}

// MARK: - Sessions

extension SessionSnapshot {
    /// The snapshot as it is written: `sessions` holds only entries every build can read.
    func storedForOlderBuilds() -> SessionSnapshot {
        var copy = self
        let parts = split(sessions) { $0.agent?.isReadableByEveryBuild ?? true }
        copy.sessions = parts.kept
        copy.laterAgentSessions = parts.moved.isEmpty ? nil : LaterAgentList(parts.moved)
        return copy
    }

    /// The snapshot as it was before `storedForOlderBuilds`.
    func restoringLaterAgents() -> SessionSnapshot {
        guard let moved = laterAgentSessions else { return self }
        var copy = self
        copy.sessions = merge(sessions, moved.values)
        copy.laterAgentSessions = nil
        return copy
    }
}

// MARK: - Preferences

/// The parts of `Preferences` that name an agent an older build cannot decode.
struct LaterAgentPreferences: Codable, Equatable {
    var agents = LaterAgentList<AgentSettings>()
    /// Per project, a `ProjectSettings` holding only the moved agents' default, assignments and
    /// options — the type's own `Codable`, so pool assignments keep their two-key spelling.
    var projects: [String: ProjectSettings] = [:]

    var isEmpty: Bool { agents.values.isEmpty && projects.isEmpty }

    init() {}

    private enum CodingKeys: String, CodingKey { case agents, projects }

    private struct LossyProject: Decodable {
        let value: ProjectSettings?
        init(from decoder: Decoder) throws { value = try? ProjectSettings(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agents = (try? c.decodeIfPresent(LaterAgentList<AgentSettings>.self, forKey: .agents)) ?? LaterAgentList()
        let projects = (try? c.decodeIfPresent([String: LossyProject].self, forKey: .projects)) ?? [:]
        self.projects = projects.compactMapValues(\.value)
    }
}

extension Preferences {
    func storedForOlderBuilds() -> Preferences {
        var copy = self
        var later = LaterAgentPreferences()
        if let agents = storedAgents {
            let parts = split(agents) { $0.id.isReadableByEveryBuild }
            copy.storedAgents = parts.kept
            later.agents = LaterAgentList(parts.moved)
        }
        if var projects = storedProjectSettings {
            for (path, settings) in projects {
                var stripped = settings
                var moved = ProjectSettings()
                if let agent = settings.defaultAgent, !agent.isReadableByEveryBuild {
                    moved.defaultAgent = agent
                    stripped.defaultAgent = nil
                }
                for (agent, assignment) in settings.accounts where !agent.isReadableByEveryBuild {
                    moved.accounts[agent] = assignment
                    stripped.accounts[agent] = nil
                }
                for (agent, options) in settings.options where !agent.isReadableByEveryBuild {
                    moved.options[agent] = options
                    stripped.options[agent] = nil
                }
                guard moved != ProjectSettings() else { continue }
                projects[path] = stripped
                later.projects[path] = moved
            }
            copy.storedProjectSettings = projects
        }
        copy.laterAgents = later.isEmpty ? nil : later
        return copy
    }

    func restoringLaterAgents() -> Preferences {
        guard let later = laterAgents else { return self }
        var copy = self
        if let agents = storedAgents { copy.storedAgents = merge(agents, later.agents.values) }
        if !later.projects.isEmpty {
            var projects = storedProjectSettings ?? [:]
            for (path, moved) in later.projects {
                var settings = projects[path] ?? ProjectSettings()
                if let agent = moved.defaultAgent { settings.defaultAgent = agent }
                settings.accounts.merge(moved.accounts) { _, later in later }
                settings.options.merge(moved.options) { _, later in later }
                projects[path] = settings
            }
            copy.storedProjectSettings = projects
        }
        copy.laterAgents = nil
        return copy
    }
}
