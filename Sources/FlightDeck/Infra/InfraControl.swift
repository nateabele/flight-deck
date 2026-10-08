import FleetKit
import Foundation
import HostKit

/// `infra.*` on the control socket (`InfraControlWire.swift`): one request in, its frames out.
extension InfraService {
    /// Answers one request. `reply` is called on the main actor, any number of
    /// `infraProgress` frames first for `up` and `down`, and exactly one terminal frame last.
    ///
    /// `up` reads `[infra.<name>]` from `cwd`'s repo through the same loader `delegate.*` uses,
    /// so a recipe `run --on gpu` would see and the one `infra up gpu` creates are one and the
    /// same.
    func handle(_ request: InfraRequest, cid: Int,
                config: DelegateConfigLoading = LiveConfigLoader(),
                worktrees: WorktreeLocating = LiveWorktreeLocator(),
                reply: @escaping (ServerFrame) -> Void) {
        Task { @MainActor in
            // The text `up`/`down` recorded on the machine when it failed, which says more
            // than the bare error (`destroy: …`, or OpenTofu's diagnostics with their fix).
            var recorded: String?
            let events: (InfraEvent) -> Void = { event in
                switch event {
                case .progress(let line): reply(.infraProgress(cid: cid, line: line))
                case .cost(let line): reply(.infraProgress(cid: cid, line: "cost: \(line)"))
                // The terminal `infraMachine` carries it.
                case .ready: break
                case .failed(let message): recorded = message
                }
            }
            do {
                switch request {
                case .up(let name, let cwd):
                    let (root, recipe) = try await Self.recipe(name, cwd: cwd, config: config, worktrees: worktrees)
                    let machine = try await self.up(name: name, config: recipe, repoRoot: root, events: events)
                    reply(.infraMachine(cid: cid, self.wire(machine, now: self.now)))
                case .down(_, let orphanID?):
                    try await self.downOrphan(id: orphanID)
                    reply(.infraDone(cid: cid))
                case .down(let name, nil):
                    try await self.down(name: name, events: events)
                    reply(.infraDone(cid: cid))
                case .list(let withOrphans):
                    let now = self.now
                    let machines = self.list(now: now).map { self.wire($0, now: now) }
                    guard withOrphans else { return reply(.infraList(cid: cid, machines, orphans: [])) }
                    let scan = await self.orphans()
                    reply(.infraList(cid: cid, machines, orphans: scan.found.map(\.ref), unreadable: scan.unreadable))
                case .doctor:
                    reply(.infraDoctor(cid: cid, await self.doctor().map {
                        WireInfraCheck(name: $0.name, ok: $0.ok, detail: $0.detail, fix: $0.fix)
                    }))
                case .extend(let name, let seconds):
                    let machine = try await self.extend(name: name, by: HostKit.Duration(seconds: seconds))
                    reply(.infraMachine(cid: cid, self.wire(machine, now: self.now)))
                }
            } catch {
                let refusal = Self.refusal(for: error, recorded: recorded)
                reply(.err(cid: cid, code: refusal.code, message: refusal.message))
            }
        }
    }

    /// `[infra.<name>]` from the `delegate.toml` of the repo `cwd` is in, and that repo's root.
    private static func recipe(_ name: String, cwd: String, config: DelegateConfigLoading,
                               worktrees: WorktreeLocating) async throws -> (URL, InfraConfig) {
        let root: URL
        do { root = try await worktrees.locate(cwd: URL(fileURLWithPath: cwd)).worktree } catch {
            throw Refusal(code: "infra_not_found",
                          message: "\(cwd) is not in a git repo; cd into the repo whose .flightdeck/delegate.toml has [infra.\(name)]")
        }
        let file: DelegateConfig?
        do { file = try config.load(worktree: root) } catch {
            throw InfraError.preflight([PreflightCheck(
                name: "config", ok: false, detail: ".flightdeck/delegate.toml: \(DelegationService.describe(error))",
                fix: "flightdeck recipe check")])
        }
        guard let recipe = file?.infra[name] else {
            throw Refusal(code: "infra_not_found", message: "no [infra.\(name)] in \(root.path)/.flightdeck/delegate.toml")
        }
        return (root, recipe)
    }

    /// The `err` a failure is answered with: each `InfraError` keeps its own code, so the CLI
    /// can tell "fix this setting" from "it broke".
    static func refusal(for error: Error, recorded: String?) -> (code: String, message: String) {
        switch error {
        case let refusal as Refusal:
            return (refusal.code, refusal.message)
        case InfraError.preflight(let checks):
            return ("infra_preflight", checks.filter { !$0.ok }.map { check in
                "\(check.name): \(check.detail)" + (check.fix.map { " — \($0)" } ?? "")
            }.joined(separator: "\n"))
        case InfraError.nameInUse(let why):
            return ("infra_name_in_use", why)
        case InfraError.enrollTimeout(let console):
            let first = recorded ?? failureText(error)
            return ("infra_enroll_timeout", console.map { "\(first)\n\(Self.tail($0))" } ?? first)
        case InfraError.notFound(let what):
            return ("infra_not_found", "no cloud machine or orphan named \(what); flightdeck infra ls --orphans lists them")
        case InfraError.refused(let why):
            return ("infra_refused", why)
        default:
            return ("infra_failed", recorded ?? failureText(error))
        }
    }

    /// A refusal decided here rather than by the service, already in its wire form.
    private struct Refusal: Error {
        let code: String
        let message: String
    }

    /// A boot console's last 40 lines: where cloud-init says why it stopped, without putting a
    /// whole boot log on one control-socket line.
    private static func tail(_ console: String) -> String {
        console.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
    }
}
