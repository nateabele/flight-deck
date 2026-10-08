import AppKit
import Combine
import FleetKit
import Foundation
import HostKit
import IntakeKit

/// The real seams `FlightDeckApp` builds `InfraService` from: the accounts Settings → Cloud
/// chose, the price lists, this Mac's public IP, and a controller id that outlives relaunches.
/// Everything here is for the app; tests build `InfraEnvironment` from fakes instead.
enum InfraLive {
    // MARK: Public IP (spec §6.2)

    static let checkIPURL = URL(string: "https://checkip.amazonaws.com")!

    /// This Mac's public IPv4, as public mode's one firewall rule needs it. Anything that is not
    /// a dotted quad — a captive portal's page, an IPv6 answer — throws: a firewall rule opened
    /// to garbage either fails the apply or, worse, admits the wrong network.
    static func publicIP(http: HTTPFetching = URLSessionHTTPFetcher(timeout: 5)) async throws -> String {
        let text = String(decoding: try await http.get(checkIPURL, headers: [:]).0, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isIPv4(text) else { throw InfraLiveError.notIPv4(String(text.prefix(40))) }
        return text
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            (1...3).contains(p.count) && p.allSatisfy { $0.isASCII && $0.isNumber } && Int(p)! <= 255
        }
    }

    /// The resolver's search path: the login shell's, asked off the main actor on first
    /// resolve; empty in a reset launch, so a UITest finds no real CLI.
    nonisolated static func searchPath(reset: Bool) -> @Sendable () -> [URL] {
        if reset { return { [] } }
        return { ToolResolver.defaultSearchPath() }
    }

    // MARK: Controller id (Task 14 carry 6)

    /// A UUID minted once and kept in `infra-controller.json` beside `infra.json`. Not the
    /// preferences' `installID`: Debug and Release share that defaults domain but keep their
    /// own state directories, so a shared id would have each build's orphan scan offer to
    /// delete the other build's machines.
    static func controllerID(directory: URL) throws -> String {
        let url = directory.appendingPathComponent("infra-controller.json")
        struct File: Codable { var version = 1; let controllerID: String }
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data),
           UUID(uuidString: file.controllerID) != nil {
            return file.controllerID
        }
        let id = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(File(controllerID: id)).write(to: url, options: .atomic)
        return id
    }

    // MARK: Delegated run, for the setup sheet's test step

    /// Runs `command` on `host` through the delegation service, as `flightdeck run --on <host>`
    /// would, and returns its output. `cwd` becomes a one-commit git repository first, because
    /// a delegated run syncs a worktree and the setup test has no project of its own.
    @MainActor
    static func delegatedRun(_ delegation: @escaping @MainActor () -> DelegationService?) -> CloudSetupModel.HostRun {
        { host, command, cwd in
            guard let delegation = delegation() else { throw InfraLiveError.noDelegation }
            try await Task.detached { try scratchRepository(cwd) }.value
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                var output = Data(), settled = false
                func settle(_ result: Result<String, Error>) {
                    guard !settled else { return }
                    settled = true
                    continuation.resume(with: result)
                }
                delegation.handle(.run(WireDelegateRun(cwd: cwd.path, host: host, command: command)), caller: .human, cid: 0) { frame in
                    switch frame {
                    case .delegateOutput(_, _, _, let data): output.append(data)
                    case .delegateExit(_, let status):
                        let text = String(decoding: output, as: UTF8.self)
                        settle(status == 0 ? .success(text) : .failure(InfraLiveError.runFailed(status, text)))
                    case .err(_, let code, let message): settle(.failure(InfraLiveError.refused(message ?? code)))
                    default: break
                    }
                }
            }
        }
    }

    private static func scratchRepository(_ dir: URL) throws {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q"],
                     ["-c", "user.name=Flight Deck", "-c", "user.email=setup@flightdeck.invalid",
                      "commit", "-q", "--allow-empty", "-m", "Flight Deck setup test"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = dir
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw InfraLiveError.refused("git \(args.first!) failed in \(dir.path)") }
        }
    }
}

enum InfraLiveError: Error, CustomStringConvertible {
    case notIPv4(String)
    case noDelegation
    case runFailed(Int32, String)
    case refused(String)

    var description: String {
        switch self {
        case .notIPv4(let got): "checkip.amazonaws.com did not answer with an IPv4 address (got “\(got)”)"
        case .noDelegation: "delegated runs are not available in this launch"
        case .runFailed(let status, let output): "uname -a exited \(status): \(output.suffix(200))"
        case .refused(let why): why
        }
    }
}

/// Settings → Cloud as the infra seams read it: a lock-guarded copy the app refreshes on every
/// preferences change, because accounts and price sources are asked off the main actor.
final class CloudChoices: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CloudPreferences

    init(_ value: CloudPreferences) { self.value = value }
    var current: CloudPreferences { lock.withLock { value } }
    func update(_ next: CloudPreferences) { lock.withLock { value = next } }
}

/// One cloud's account as Settings → Cloud currently chooses it (profile or project), over a
/// CLI resolved on first use — never at launch, where resolving waits on a login shell. A
/// missing CLI reads as `unavailable` with the resolver's own words; the setup sheet's Tools
/// step is what downloads one.
final class LiveCloudAccount: CloudAccount, @unchecked Sendable {
    let cloud: String
    private let resolver: ToolResolver
    private let runner: CommandRunner
    private let choices: CloudChoices
    private let lock = NSLock()
    private var resolved: ResolvedTool?

    init(cloud: String, resolver: ToolResolver, runner: CommandRunner, choices: CloudChoices) {
        self.cloud = cloud; self.resolver = resolver; self.runner = runner; self.choices = choices
    }

    func tool() async throws -> ResolvedTool {
        if let resolved = lock.withLock({ resolved }) { return resolved }
        let tool = try await resolver.resolve(cloud == "aws" ? .aws : .gcloud, provision: false)
        lock.withLock { resolved = tool }
        return tool
    }

    private func account(_ tool: ResolvedTool?) -> CloudAccount {
        // The synchronous calls (`providerEnvironment`, `moduleVars`) read only the profile or
        // project, so before the CLI is resolved a path that is never run stands in for it.
        let url = tool?.url ?? URL(fileURLWithPath: "/usr/bin/false")
        let env = tool?.environment ?? [:]
        let choice = choices.current
        return cloud == "aws"
            ? AWSAccount(aws: url, profile: choice.awsProfile, runner: runner, environment: env)
            : GCPAccount(gcloud: url, project: choice.gcpProject, runner: runner, environment: env)
    }

    private func live() async throws -> CloudAccount { account(try await tool()) }

    func status() async -> AccountStatus {
        do { return await (try await live()).status() } catch { return .unavailable(CloudSetupModel.describe(error)) }
    }
    func signIn() async throws { try await live().signIn() }
    func quota(region: String, instanceType: String) async throws -> QuotaCheck {
        try await live().quota(region: region, instanceType: instanceType)
    }
    func providerEnvironment() -> [String: String] { account(lock.withLock { resolved }).providerEnvironment() }
    func moduleVars() -> [String: String] { account(lock.withLock { resolved }).moduleVars() }
    func consoleOutput(instanceID: String, region: String) async -> String? {
        guard let account = try? await live() else { return nil }
        return await account.consoleOutput(instanceID: instanceID, region: region)
    }
    func listOwned(owner: String) async throws -> [OwnedResource] { try await live().listOwned(owner: owner) }
    func deleteOwned(_ resource: OwnedResource) async throws { try await live().deleteOwned(resource) }

    /// This cloud's price list over the same CLI and choice (spec §8.1).
    var prices: PriceSource { LivePriceSource(account: self, runner: runner, choices: choices) }
}

private struct LivePriceSource: PriceSource {
    let account: LiveCloudAccount
    let runner: CommandRunner
    let choices: CloudChoices

    func hourly(_ q: PriceQuery) async throws -> Double {
        let tool = try await account.tool()
        if account.cloud == "aws" {
            return try await AWSPriceSource(aws: tool.url, runner: runner, profile: choices.current.awsProfile).hourly(q)
        }
        let cli = CloudCLI(executable: tool.url, runner: runner,
                           extra: tool.environment.merging(["CLOUDSDK_CORE_DISABLE_PROMPTS": "1"]) { _, new in new })
        return try await GCPPriceSource(token: {
            String(decoding: try await cli.checked(["auth", "application-default", "print-access-token"]).stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }, http: URLSessionHTTPFetcher(), machineTypes: .builtIn).hourly(q)
    }
}

// MARK: - The app's wiring

/// Everything `FlightDeckApp` keeps alive for cloud machines.
@MainActor
struct InfraWiring {
    let service: InfraService
    let context: CloudSettingsContext
    /// Nil under a UITest reset, which must never destroy, warn about or re-point anything.
    let reaper: Reaper?
    /// Keeps `CloudChoices` in step with Settings → Cloud.
    let watch: AnyCancellable
}

/// The one place `FleetService` is reached from the setup sheet's test run: the fleet is built
/// later, in its own `@StateObject` thunk, and owns the delegation service the run goes through.
@MainActor
final class FleetRef {
    weak var fleet: FleetService?
}

/// The OAuth client in memory, for a UITest reset run, which must never touch the Keychain.
final class EphemeralTailnetSecrets: TailnetSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var client: TailscaleOAuthClient?
    func load() -> TailscaleOAuthClient? { lock.withLock { client } }
    func save(_ c: TailscaleOAuthClient) throws { lock.withLock { client = c } }
    func clear() { lock.withLock { client = nil } }
}

extension InfraLive {
    /// Builds `InfraService` and its Reaper beside `hosts`, the way `makeHostService` builds
    /// hosts: files beside `sessions.json` (`directory`), real accounts, prices and tailnet.
    /// `reset` is a UITest launch: scratch files, no Keychain, no CLI on the search path, no
    /// Reaper and no relaunch resume, so a GUI test can neither see nor destroy a real machine.
    @MainActor
    static func wire(directory: URL, reset: Bool, hosts: HostService, controllerName: String,
                     preferences: PreferencesStore, fleet: FleetRef) -> InfraWiring {
        let root = reset
            ? FileManager.default.temporaryDirectory.appendingPathComponent("flightdeck-infra-\(UUID().uuidString)")
            : directory
        let choices = CloudChoices(preferences.cloud)
        let watch = preferences.$preferences.sink { choices.update($0.cloud ?? CloudPreferences()) }
        let runner = SystemCommandRunner()
        let resolver = ToolResolver(
            searchPathProvider: searchPath(reset: reset),
            managedRoot: root.appendingPathComponent("tools", isDirectory: true), runner: runner,
            downloader: URLSessionToolDownloader())
        let aws = LiveCloudAccount(cloud: "aws", resolver: resolver, runner: runner, choices: choices)
        let gcp = LiveCloudAccount(cloud: "gcp", resolver: resolver, runner: runner, choices: choices)
        let accounts: [String: CloudAccount] = ["aws": aws, "gcp": gcp]
        let tailnet = TailnetIntegration(cli: reset ? nil : TailnetIntegration.defaultCLI(), http: URLSessionHTTPFetcher(),
                                         secrets: reset ? EphemeralTailnetSecrets() : KeychainTailnetSecrets())
        let controllerID: String
        do { controllerID = try Self.controllerID(directory: root) } catch {
            // `infra.json` lives in the same directory, so `up` cannot record a machine either;
            // a per-launch id only has to last until that refusal.
            controllerID = UUID().uuidString.lowercased()
        }
        let info = Bundle.main.infoDictionary
        let pluginCache = root.appendingPathComponent("tools", isDirectory: true).appendingPathComponent("tofu-plugins", isDirectory: true)
        let env = InfraEnvironment(
            tofu: { tool, environment in
                LiveTofuRunner(tofu: tool.url, pluginCache: pluginCache, runner: runner, environment: environment)
            },
            resolver: resolver,
            accounts: accounts,
            prices: PriceCatalog(sources: ["aws": aws.prices, "gcp": gcp.prices],
                                 cacheURL: root.appendingPathComponent("infra-prices.json")),
            tailnet: tailnet,
            publicIP: reset ? { throw InfraLiveError.refused("no public IP lookup in a reset launch") } : { try await Self.publicIP() },
            presetsRoot: (Bundle.main.resourceURL ?? URL(fileURLWithPath: "/"))
                .appendingPathComponent("Infra/presets", isDirectory: true),
            installer: (base: (info?[LinuxHostInstaller.baseURLKey] as? String ?? "").trimmingCharacters(in: .whitespaces),
                        sha256: (info?[LinuxHostInstaller.digestKey] as? String ?? "").trimmingCharacters(in: .whitespaces)),
            controllerName: controllerName,
            controllerID: controllerID,
            now: { Date() },
            budget: { choices.current.budget })
        let service = InfraService(
            registry: InfraRegistry(fileURL: root.appendingPathComponent("infra.json"),
                                    workRoot: root.appendingPathComponent("infra", isDirectory: true)),
            ledger: CostLedger(fileURL: root.appendingPathComponent("infra-ledger.json")),
            hosts: hosts, env: env)

        var reaper: Reaper?
        if !reset {
            let r = Reaper(service: service, hosts: hosts, clock: SystemHostLinkClock(),
                           notifier: UserNotificationInfraNotifier(), budget: { choices.current.budget })
            r.start()
            reaper = r
            Task { await service.resumeAfterLaunch() }
        }

        let run = Self.delegatedRun { [weak fleet] in fleet?.fleet?.delegation }
        let workRoot = root.appendingPathComponent("infra-setup-test", isDirectory: true)
        let context = CloudSettingsContext(service: service, tailnet: tailnet, makeSetup: {
            CloudSetupModel(
                service: service, tailnet: tailnet, accounts: accounts,
                open: { NSWorkspace.shared.open($0) },
                clipboard: { NSPasteboard.general.string(forType: .string) },
                copy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                },
                resolver: resolver, budget: { choices.current.budget }, regions: { choices.current.regions },
                run: run, workRoot: workRoot)
        })
        return InfraWiring(service: service, context: context, reaper: reaper, watch: watch)
    }
}
