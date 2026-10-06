import Foundation
import IntakeKit

/// Spec §9 "Turn off Flight Control": FD stops acting on the repo and gives back what it took.
/// Hooks, AGENTS.md and `.beads` stay exactly as they are.
@MainActor
struct FlightControlOff {
    struct Report: Equatable {
        var reopened: [String]
        var released: [String]
    }

    let swarm: SwarmService?
    let backend: SwarmBackend
    /// Every FD-booted agent in the project (sessions with an Agent Mail identity).
    let agents: (String) -> [(session: UUID, agentName: String)]
    let stopObserving: (String) -> Void
    let setEnabled: (String, Bool) -> Void

    func run(project: String) async -> Report {
        let key = FlywheelObserveService.key(project)
        let reopened = await swarm?.turnOff(project: key) ?? []
        var released: [String] = []
        for (_, name) in agents(key) {
            if await backend.releaseReservations(agent: name, project: URL(fileURLWithPath: key, isDirectory: true)) {
                released.append(name)
            }
        }
        stopObserving(key)
        setEnabled(key, false)
        return Report(reopened: reopened, released: released)
    }
}

/// Spec §9 "Remove from repo…": undoes what Flight Control setup wrote, after a confirmation that
/// lists it. Never touches `.beads`.
struct FlightControlRepoRemoval {
    /// `br agents --add`'s fence (`FlywheelSetup.agentsSectionMarker`) — referenced, never copied.
    static let agentsSectionStart = FlywheelSetup.agentsSectionMarker
    /// Probed with br 0.6.0: the section closes with this line (note: no `-v1`, unlike the opener).
    static let agentsSectionEnd: String? = "<!-- end-br-agent-instructions -->"
    /// Probed: `br agents --remove` exists (it backs up to AGENTS.md.bak, which `remove` deletes
    /// when it was not there before). The string surgery below is the fallback when it exits non-zero.
    static let brAgentsRemoveArgs: [String]? = ["agents", "--remove", "--force"]
    /// Probed: `am guard uninstall <REPO>` exists.
    static let guardUninstallArgs: [String]? = ["guard", "uninstall"]

    let runner: FlywheelProcessRunner
    var amPath = "am"
    var brPath = "br"

    func plannedChanges(repo: URL) -> [String] {
        var lines: [String] = []
        if FlywheelProjectProbe.status(of: repo).guardInstalled {
            lines.append(Self.guardUninstallArgs == nil
                         ? "The Agent Mail commit guard stays: remove it by hand"
                         : "Uninstall the Agent Mail commit guard")
        }
        if hookIsOurs(repo) { lines.append("Delete the task-sync commit hook") }
        if agentsSectionRange(repo) != nil { lines.append("Remove the task-tracker section from AGENTS.md") }
        lines.append("Keep the task data in the repo")
        return lines
    }

    @discardableResult
    func remove(repo: URL) async -> [String] {
        var done: [String] = []
        if let args = Self.guardUninstallArgs, FlywheelProjectProbe.status(of: repo).guardInstalled,
           (try? await runner.run(amPath, args + [repo.path], cwd: repo.path))?.exitCode == 0 {
            done.append("guard")
        }
        if hookIsOurs(repo), (try? FileManager.default.removeItem(at: FlywheelSetup.beadsSyncHookPath(in: repo))) != nil {
            done.append("hook")
        }
        if agentsSectionRange(repo) != nil {
            // `br agents --remove` backs AGENTS.md up to AGENTS.md.bak and leaves it in the
            // user's repo. A backup this removal created is ours to delete; one that was
            // already there is the user's and stays.
            let backup = repo.appendingPathComponent("AGENTS.md.bak")
            let hadBackup = FileManager.default.fileExists(atPath: backup.path)
            if let args = Self.brAgentsRemoveArgs,
               (try? await runner.run(brPath, args, cwd: repo.path))?.exitCode == 0,
               agentsSectionRange(repo) == nil {
                if !hadBackup { try? FileManager.default.removeItem(at: backup) }
                done.append("agents")
            } else if removeAgentsSectionByHand(repo) {
                done.append("agents")
            }
        }
        return done
    }

    private func removeAgentsSectionByHand(_ repo: URL) -> Bool {
        let agentsURL = repo.appendingPathComponent("AGENTS.md")
        guard let range = agentsSectionRange(repo), var text = try? String(contentsOf: agentsURL, encoding: .utf8) else { return false }
        text.removeSubrange(range)
        while text.hasSuffix("\n\n") { text.removeLast() }
        return (try? text.write(to: agentsURL, atomically: true, encoding: .utf8)) != nil
    }

    /// Only a hook still holding exactly what `enable` wrote is ours to delete.
    private func hookIsOurs(_ repo: URL) -> Bool {
        (try? String(contentsOf: FlywheelSetup.beadsSyncHookPath(in: repo), encoding: .utf8)) == FlywheelSetup.beadsSyncHookContents
    }

    private func agentsSectionRange(_ repo: URL) -> Range<String.Index>? {
        guard let text = try? String(contentsOf: repo.appendingPathComponent("AGENTS.md"), encoding: .utf8),
              let start = text.range(of: Self.agentsSectionStart) else { return nil }
        guard let endMarker = Self.agentsSectionEnd else { return start.lowerBound..<text.endIndex }
        guard let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex) else { return nil }
        let afterNewline = text[end.upperBound...].first == "\n" ? text.index(after: end.upperBound) : end.upperBound
        return start.lowerBound..<afterNewline
    }
}
