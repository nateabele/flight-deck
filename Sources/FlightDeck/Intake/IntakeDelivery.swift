import Foundation
import CryptoKit
import IntakeKit

/// Carries out the `DeliveryAction`s `DeliveryPlanner` produces: it shells out to Agent-Mail
/// (`am`) and beads (`br`), and calls back into the app to inject a prompt into a live
/// session. Every side effect this type performs is a *warning* on failure, never a thrown
/// error — a release that already happened must not roll back because a notification to one
/// holder didn't land, so `deliver` collects one human-readable line per failed action and
/// keeps going.
struct IntakeDelivery {
    let runner: FlywheelProcessRunner
    let amPath: String
    let brPath: String
    let store: IntakeStore
    /// `(agentName, text, token) -> Bool`. Wired to `SessionStore.submitPrompt(_:token:to:)`
    /// by `IntakeService` (Task 16) — this type only needs the shape, not the session lookup.
    let inject: (String, String, UUID) -> Bool

    init(
        runner: FlywheelProcessRunner = SystemFlywheelProcessRunner(),
        amPath: String = "am",
        brPath: String = "br",
        store: IntakeStore,
        inject: @escaping (String, String, UUID) -> Bool
    ) {
        self.runner = runner
        self.amPath = amPath
        self.brPath = brPath
        self.store = store
        self.inject = inject
    }

    /// Deterministic per (intake, bead) so a retried release re-injects the identical token —
    /// `submitPrompt` treats a repeat as `.duplicate` rather than typing the prompt twice.
    static func injectToken(intake: UUID, bead: String) -> UUID {
        let d = Array(SHA256.hash(data: Data("\(intake.uuidString)|\(bead)".utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                           d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    func deliver(_ actions: [DeliveryAction], project: String, intakeID: UUID) async -> [String] {
        guard !actions.isEmpty else { return [] }

        let fdName: String
        do {
            fdName = try await agentMailIdentity(project: project)
        } catch {
            // No FD identity means every `am` call below is a dead end — report each
            // planned action as failed rather than only the one that happened to boot.
            return actions.map { _ in "could not resolve Flight Deck's Agent-Mail identity for \(project): \(error)" }
        }

        var warnings: [String] = []
        for action in actions {
            switch action {
            case .mail(let to, let bead, let subject, let body, let urgent):
                var argv = ["mail", "send", "--project", project, "--from", fdName, "--to", to,
                            "--subject", subject, "--body", body,
                            "--thread-id", "bead:\(bead)", "--topic", "fd-intake"]
                if urgent { argv += ["--importance", "high", "--ack-required"] }
                if let warning = await run(argv, cwd: project, describing: "am mail send to \(to) for \(bead)") {
                    warnings.append(warning)
                }
            case .inject(let agent, let bead, let text):
                let token = Self.injectToken(intake: intakeID, bead: bead)
                if !inject(agent, text, token) {
                    warnings.append("could not inject \(agent) for \(bead)")
                }
            case .reclaim(let bead, let agent):
                let actor = "flightdeck-intake:\(intakeID.uuidString)"
                let updateArgv = ["update", bead, "--status", "open", "--assignee", "", "--actor", actor]
                if let warning = await run(updateArgv, cwd: project, brExecutable: true, describing: "br update \(bead)") {
                    warnings.append(warning)
                }
                // `am` may refuse to release reservations it didn't grant to this identity —
                // that's a warning, not a reason to abandon the reclaim itself.
                let releaseArgv = ["file_reservations", "release", project, agent]
                if let warning = await run(releaseArgv, cwd: project, describing: "am file_reservations release for \(agent)") {
                    warnings.append(warning)
                }
            }
        }
        return warnings
    }

    /// Runs one `am`/`br` invocation and turns a non-zero exit or a thrown error into a
    /// warning string quoting the first line of its output — `describing` names the action
    /// so the warning reads like "am mail send to X for Y failed: ...", not a bare exit code.
    private func run(_ argv: [String], cwd: String, brExecutable: Bool = false, describing: String) async -> String? {
        do {
            let (stdout, exitCode) = try await runner.run(brExecutable ? brPath : amPath, argv, cwd: cwd)
            guard exitCode != 0 else { return nil }
            return "\(describing) failed (exit \(exitCode)): \(Self.firstLine(of: stdout))"
        } catch {
            return "\(describing) failed: \(error)"
        }
    }

    /// FD's own Agent-Mail identity for `project`, cached under `<intakes root>/agent-mail-identities.json`
    /// so a release doesn't re-run `am macros start-session` (and mint a fresh name) every time.
    private func agentMailIdentity(project: String) async throws -> String {
        let cacheURL = store.root.appendingPathComponent("agent-mail-identities.json")
        var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        if let cached = cache[project] { return cached }

        // No `name:` — letting `am` assign one avoids colliding with whatever identity a
        // spawned agent in this same project already registered under a chosen name.
        let identity = try await FlywheelCoordinator(runner: runner, amPath: amPath)
            .boot(project: project, program: "flightdeck", model: "n/a", name: nil)
        cache[project] = identity.agentName
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        return identity.agentName
    }

    /// A process's stdout is often several lines of `am`/`br`'s own logging — the warning
    /// this feeds wants one sentence, not a dump. Mirrors `FlywheelError.firstLine`.
    private static func firstLine(of output: String) -> String {
        output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? "(no output)"
    }
}
