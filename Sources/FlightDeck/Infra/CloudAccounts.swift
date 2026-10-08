import Foundation
import IntakeKit

/// Where one cloud account stands, as `infra doctor` and the setup sheet show it.
enum AccountStatus: Equatable, Sendable {
    /// Signed in; `identity` is what the user recognises the account by (AWS account ID, GCP project).
    case ready(identity: String)
    /// No usable credentials; `fix` is the exact command that signs in.
    case signedOut(fix: String)
    /// The check itself failed for some other reason (network, a broken profile); the CLI's own words.
    case unavailable(String)
}

/// One instance type's quota in one region. `have` is what the quota allows, `need` what this
/// machine takes, in the quota's own unit (vCPUs, or GPUs when the GPU quota is the binding one).
struct QuotaCheck: Equatable, Sendable {
    let ok: Bool
    let have: Double
    let need: Double
    /// The console page that raises exactly this quota, so a too-low quota is one click from fixed.
    let increaseURL: URL?
}

enum CloudAccountError: Error, Equatable {
    /// The CLI ran and failed; the message is its stderr tail, or the exit code when it said nothing.
    case failed(String)
    /// No quota is known for this family, so the check cannot say yes or no.
    case unsupportedInstanceType(String)
}

/// One cloud account, driven entirely through that cloud's own CLI: its sign-in flow, its
/// credential chain and its quota API. Nothing here holds a credential itself.
protocol CloudAccount: Sendable {
    var cloud: String { get }
    func status() async -> AccountStatus
    /// Runs the CLI's own browser sign-in and returns when it exits.
    func signIn() async throws
    func quota(region: String, instanceType: String) async throws -> QuotaCheck
    /// What OpenTofu's provider needs to find the same account (`AWS_PROFILE`, `GOOGLE_CLOUD_PROJECT`…).
    func providerEnvironment() -> [String: String]
    /// Module variables the account decides rather than the repo: the GCP preset's `project`.
    func moduleVars() -> [String: String]
    /// The machine's boot console, for a machine that never enrolled: cloud-init's own errors
    /// are there. Nil when the CLI fails or the cloud has nothing yet; this only ever adds
    /// detail to a failure already being reported.
    func consoleOutput(instanceID: String, region: String) async -> String?
}

/// The environment every cloud tool runs with: the app's own, its PATH repaired from the login
/// shell (an app launched from the Dock has launchd's bare PATH, which finds neither a Homebrew
/// Python for gcloud nor a credential helper), then the resolved tool's own variables
/// (`CLOUDSDK_PYTHON`), then the account's provider variables (`AWS_PROFILE`). One place, so
/// OpenTofu and the CLIs can never disagree about which account they are in.
enum InfraToolEnvironment {
    static func make(base: [String: String], tool: [String: String] = [:], provider: [String: String] = [:]) -> [String: String] {
        base.merging(tool) { _, new in new }.merging(provider) { _, new in new }
    }

    static func defaultBase() -> [String: String] { LoginShellPath.repairing(ProcessInfo.processInfo.environment) }
}

/// Runs one cloud CLI with `base` (`InfraToolEnvironment.defaultBase()` unless a test injects
/// one) plus `extra`. The CLI's own directory leads `PATH`: gcloud's entry point execs siblings
/// beside it, and a managed copy (Task 6) is not on the user's `PATH` at all.
struct CloudCLI: Sendable {
    let executable: URL
    let runner: CommandRunner
    let extra: [String: String]
    var base: [String: String]?

    func run(_ arguments: [String]) async throws -> CommandResult {
        var env = base ?? InfraToolEnvironment.defaultBase()
        let dir = executable.deletingLastPathComponent().path
        env["PATH"] = [dir, env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env.merge(extra) { _, new in new }
        return try await runner.run(executable: executable.path, arguments: arguments,
                                    cwd: FileManager.default.homeDirectoryForCurrentUser, environment: env)
    }

    /// Runs and throws `failed` on a non-zero exit, so a caller only ever sees a good result.
    func checked(_ arguments: [String]) async throws -> CommandResult {
        let result = try await run(arguments)
        guard result.exitCode == 0 else { throw CloudAccountError.failed(Self.message(result)) }
        return result
    }

    /// The stderr tail, else the exit code, so a failure never reads as an empty message.
    static func message(_ result: CommandResult) -> String {
        let tail = result.stderr.split(separator: "\n").suffix(5).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? "exit \(result.exitCode)" : tail
    }
}
