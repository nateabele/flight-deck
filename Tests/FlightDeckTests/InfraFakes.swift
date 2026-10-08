import FleetKit
import Foundation
import HostKit
import IntakeKit
import Network
@testable import FlightDeck

/// Canned HTTP for the infra tests: answers by exact URL and records every request, so no test
/// ever reaches a real cloud or Tailscale API. An unknown URL is a 404, which fails the test
/// loudly instead of handing back an empty body that decodes as "nothing there"; `statuses`
/// makes a URL fail with a chosen status instead.
final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    struct Request: Equatable {
        let method: String
        let url: String
        let headers: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private let responses: [String: String]
    private let responseHeaders: [String: [String: String]]
    private let statuses: [String: Int]
    private var recorded: [Request] = []

    init(responses: [String: String] = [:], responseHeaders: [String: [String: String]] = [:],
         statuses: [String: Int] = [:]) {
        self.responses = responses
        self.responseHeaders = responseHeaders
        self.statuses = statuses
    }

    var requests: [Request] { lock.withLock { recorded } }

    func lastBody(for url: String) -> Data? {
        requests.last { $0.url == url }?.body
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, [String: String]) {
        try answer("GET", url, headers, nil)
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (Data, [String: String]) {
        try answer("POST", url, headers, body)
    }

    func delete(_ url: URL, headers: [String: String]) async throws {
        _ = try answer("DELETE", url, headers, nil)
    }

    private func answer(_ method: String, _ url: URL, _ headers: [String: String], _ body: Data?) throws -> (Data, [String: String]) {
        let key = url.absoluteString
        lock.withLock { recorded.append(Request(method: method, url: key, headers: headers, body: body)) }
        if let status = statuses[key] { throw HTTPStatusError(status: status) }
        guard let text = responses[key] else { throw HTTPStatusError(status: 404) }
        return (Data(text.utf8), responseHeaders[key] ?? [:])
    }
}

/// The Tailscale OAuth client, held in memory: a test must never read or write the Keychain.
final class MemoryTailnetSecrets: TailnetSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var client: TailscaleOAuthClient?

    init(_ client: TailscaleOAuthClient? = nil) { self.client = client }

    func load() -> TailscaleOAuthClient? { lock.withLock { client } }
    func save(_ c: TailscaleOAuthClient) throws { lock.withLock { client = c } }
    func clear() { lock.withLock { client = nil } }
}

// MARK: - InfraService's seams (Task 14)

/// OpenTofu, scripted per step. Records each call by step name (`init`, `apply`, `output`,
/// `destroy`, `refresh`), the machine names destroyed, and the environment every runner was
/// built with, so a test can see exactly what reached the cloud — which here is nothing.
final class FakeTofu: TofuRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _destroyed: Set<String> = []
    private var _environments: [[String: String]] = []
    private var _outputs: TofuOutputs?
    private var _failApply: TofuError?
    private var _failDestroy: TofuError?
    private var _gone = false
    private var _afterApply: (@Sendable (URL) async -> Void)?

    var calls: [String] { lock.withLock { _calls } }
    var destroyed: Set<String> { lock.withLock { _destroyed } }
    var environments: [[String: String]] { lock.withLock { _environments } }
    var outputs: TofuOutputs? { get { lock.withLock { _outputs } } set { lock.withLock { _outputs = newValue } } }
    var failApply: TofuError? { get { lock.withLock { _failApply } } set { lock.withLock { _failApply = newValue } } }
    var failDestroy: TofuError? { get { lock.withLock { _failDestroy } } set { lock.withLock { _failDestroy = newValue } } }
    var refreshGone: Bool { get { lock.withLock { _gone } } set { lock.withLock { _gone = newValue } } }
    var afterApply: (@Sendable (URL) async -> Void)? {
        get { lock.withLock { _afterApply } } set { lock.withLock { _afterApply = newValue } }
    }

    func built(environment: [String: String]) -> FakeTofu {
        lock.withLock { _environments.append(environment) }
        return self
    }

    private func record(_ step: String) { lock.withLock { _calls.append(step) } }

    func initialize(workdir: URL) async throws { record("init") }

    /// When set, every `apply` suspends here until the test opens it.
    let applyGate = ApplyGate()
    private var _hold = false
    var holdApply: Bool { get { lock.withLock { _hold } } set { lock.withLock { _hold = newValue } } }

    func apply(workdir: URL, progress: @escaping @Sendable (TofuProgress) -> Void) async throws {
        record("apply")
        if holdApply { await applyGate.wait() }
        // From a background-priority thread, as the live runner's stdout reader is: a caller
        // that hops each event to the main actor without waiting can see them after it moved on.
        await Task.detached(priority: .background) {
            progress(TofuProgress(resource: "aws_instance.this", action: "create", done: false))
            progress(TofuProgress(resource: "aws_instance.this", action: "create", done: true))
        }.value
        if let failApply { throw failApply }
        await afterApply?(workdir)
    }

    func destroy(workdir: URL, progress: @escaping @Sendable (TofuProgress) -> Void) async throws {
        record("destroy")
        if let failDestroy { throw failDestroy }
        _ = lock.withLock { _destroyed.insert(workdir.lastPathComponent) }
    }

    func outputs(workdir: URL) async throws -> TofuOutputs {
        record("output")
        guard let outputs else { throw TofuError.missingOutput("fd_address") }
        return outputs
    }

    func refreshShowsGone(workdir: URL) async throws -> Bool {
        record("refresh")
        return refreshGone
    }
}

/// Suspends every `wait()` until `open()`; later waits pass straight through.
actor ApplyGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// A signed-in account with room for any machine, whose console output a test chooses.
final class FakeAccount: CloudAccount, @unchecked Sendable {
    let cloud: String
    private let lock = NSLock()
    private var _status: AccountStatus = .ready(identity: "123456789012")
    private var _console: String?

    init(cloud: String = "aws") { self.cloud = cloud }

    var accountStatus: AccountStatus { get { lock.withLock { _status } } set { lock.withLock { _status = newValue } } }
    var console: String? { get { lock.withLock { _console } } set { lock.withLock { _console = newValue } } }

    func status() async -> AccountStatus { accountStatus }
    func signIn() async throws {}
    func quota(region: String, instanceType: String) async throws -> QuotaCheck {
        QuotaCheck(ok: true, have: 64, need: 2, increaseURL: nil)
    }
    func providerEnvironment() -> [String: String] { ["AWS_PROFILE": "example"] }
    func moduleVars() -> [String: String] { cloud == "gcp" ? ["project": "example-project"] : [:] }
    func consoleOutput(instanceID: String, region: String) async -> String? { console }
}

struct ConstantPrice: PriceSource {
    let hourly: Double
    func hourly(_ q: PriceQuery) async throws -> Double { hourly }
}

/// A host connection that completes the hello handshake the moment it starts, if its host is
/// "up"; otherwise it waits until the test brings the host up.
final class InfraHostConnection: HostLinkConnection {
    var onReady: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClosed: (() -> Void)?
    var remoteAddress: String?
    let slot: UUID
    let isUp: () -> Bool
    private(set) var acked = false

    init(slot: UUID, isUp: @escaping () -> Bool) { self.slot = slot; self.isUp = isUp }

    func start() { if isUp() { ack() } }
    func send(_ text: String) {}
    func ping(onPong: @escaping () -> Void) { onPong() }
    func cancel() { onReady = nil; onText = nil; onClosed = nil }

    func ack() {
        guard !acked, let onReady else { return }
        acked = true
        onReady()
        onText?(try! HostWire.encode(HostServerFrame.helloAck(protocolVersion: .current, capabilities: [.hostInfo],
                                                               hostName: "cloud")))
    }
}

/// Dials `InfraHostConnection`s and brings a host's links online when the test says so.
@MainActor
final class InfraHostDialer: HostLinkDialing {
    private(set) var connections: [InfraHostConnection] = []
    private var up: Set<UUID> = []

    final class Handle: HostLinkCancellable { func cancel() {} }

    func bringUp(_ slot: UUID) {
        up.insert(slot)
        for c in connections where c.slot == slot { c.ack() }
    }

    func connection(to endpoint: NWEndpoint, key: FleetDeviceKey) -> HostLinkConnection {
        let slot = key.slot
        let c = InfraHostConnection(slot: slot) { [weak self] in
            MainActor.assumeIsolated { self?.up.contains(slot) ?? false }
        }
        connections.append(c)
        return c
    }

    func browse(serviceName: String, onChange: @escaping ([NWEndpoint]) -> Void) -> HostLinkCancellable { Handle() }
    func watchPath(onChange: @escaping () -> Void) -> HostLinkCancellable { Handle() }
}

extension InfraMachine {
    static let fixtureNow = Date(timeIntervalSince1970: 1_800_000_000)

    static func fixture(name: String, repoRoot: String = "/repo", cloud: String = "aws", instanceType: String = "t3.small",
                        region: String = "us-east-1", state: InfraState = .ready, slot: UUID? = nil,
                        network: NetworkMode = .public, hourlyUSD: Double? = 0.5,
                        createdAt: Date = InfraMachine.fixtureNow,
                        deadline: Date = InfraMachine.fixtureNow.addingTimeInterval(3600),
                        machineDeadline: Date? = nil, enrollingSince: Date? = nil) -> InfraMachine {
        InfraMachine(name: name, repoRoot: repoRoot, cloud: cloud, instanceType: instanceType, region: region, slot: slot,
                     state: state, failure: nil, network: network, createdAt: createdAt, deadline: deadline,
                     idle: .init(seconds: 1800), allowCIDR: nil, instanceID: "i-1", address: nil, hourlyUSD: hourlyUSD,
                     machineDeadline: machineDeadline, enrollingSince: enrollingSince)
    }
}

/// Everything `InfraService` touches, faked: registry and ledger in a temp directory, a
/// `HostService` over an in-memory Keychain and `InfraHostDialer`, a fake `tofu` binary for the
/// resolver to find, `FakeTofu` for every OpenTofu step, a constant price, and a tailnet that is
/// absent until `tailnetAvailable` installs one. The service is built on first use, so a test
/// may change the environment before then.
@MainActor
final class InfraHarness {
    enum Step { case applied }

    let root: URL
    let repo: URL
    let registry: InfraRegistry
    let ledger: CostLedger
    let dialer = InfraHostDialer()
    let hosts: HostService
    let tofu = FakeTofu()
    let account = FakeAccount()
    let now = InfraMachine.fixtureNow
    var budget = BudgetSettings.default
    var events: [InfraEvent] = []
    var enrollTimeout: TimeInterval = 600
    var consoleOutput: String? { get { account.console } set { account.console = newValue } }
    var tailnet: TailnetIntegration
    var resolver: ToolResolver
    var publicIPCalls = 0
    var controllerID = "00000000-0000-4000-8000-000000000001"

    lazy var service: InfraService = InfraService(registry: registry, ledger: ledger, hosts: hosts, env: environment())

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("infra-h-\(UUID().uuidString)")
        repo = root.appendingPathComponent("repo")
        let presets = root.appendingPathComponent("presets")
        for preset in ["aws-linux", "gcp-linux"] {
            let dir = presets.appendingPathComponent(preset)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "# \(preset)\n".write(to: dir.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        registry = InfraRegistry(fileURL: root.appendingPathComponent("infra.json"), workRoot: root.appendingPathComponent("infra"))
        ledger = CostLedger(fileURL: root.appendingPathComponent("infra-ledger.json"))
        hosts = HostService(registry: HostRegistry(fileURL: root.appendingPathComponent("hosts.json"), secrets: InMemoryHostSecretStore()),
                            controllerName: "test-mac", dial: dialer, clock: ManualHostLinkClock())
        tailnet = TailnetIntegration(cli: nil, http: FakeHTTP(), secrets: MemoryTailnetSecrets())
        let tofuBinary = try FakeExecutable.make("tofu", script: "echo 'OpenTofu v1.8.11'")
        resolver = ToolResolver(searchPath: [tofuBinary.deletingLastPathComponent()], managedRoot: root.appendingPathComponent("tools"),
                                runner: SystemCommandRunner(), downloader: ToolResolverTests.NoDownload(),
                                environment: ["PATH": "/usr/bin:/bin"], spaceFreeRoot: root.appendingPathComponent("tools-nospace"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func environment() -> InfraEnvironment {
        let tofu = tofu
        return InfraEnvironment(
            tofu: { _, environment in tofu.built(environment: environment) },
            resolver: resolver,
            accounts: ["aws": account, "gcp": FakeAccount(cloud: "gcp")],
            prices: PriceCatalog(sources: ["aws": ConstantPrice(hourly: 0.5), "gcp": ConstantPrice(hourly: 0.5)],
                                 cacheURL: root.appendingPathComponent("prices.json")),
            tailnet: tailnet,
            publicIP: { [weak self] in
                await MainActor.run { self?.publicIPCalls += 1 }
                return "203.0.113.9"
            },
            presetsRoot: root.appendingPathComponent("presets"),
            installer: (base: "https://example.com/hostd", sha256: String(repeating: "a", count: 64)),
            controllerName: "test-mac",
            controllerID: controllerID,
            now: { [now] in now },
            budget: { [unowned self] in self.budget },
            baseEnvironment: { ["PATH": "/usr/bin:/bin:/login/shell/bin"] },
            enrollTimeout: enrollTimeout,
            tailnetJoin: (interval: 0.01, timeout: 1),
            launchGrace: 0)
    }

    /// Brings the host named like the machine online as soon as `step` has happened.
    func hostComesOnline(after step: Step) {
        tofu.afterApply = { [weak self] workdir in
            await self?.hostOnline(workdir.lastPathComponent)
        }
    }

    func hostOnline(_ name: String) {
        guard case .success(let record) = hosts.registry.resolve(name: name) else { return }
        dialer.bringUp(record.slot)
    }

    /// A running tailnet with an OAuth client for it, on which the machine `fd-<name>` has
    /// joined with `nodeIP`.
    func tailnetAvailable(nodeIP: String) {
        let status = #"{"BackendState":"Running","CurrentTailnet":{"Name":"example-tailnet.ts.net"},"Self":{"TailscaleIPs":["100.64.0.2"]}}"#
        let cli = try! FakeExecutable.make("tailscale", script: "echo '\(status)'")
        let api = "https://api.tailscale.com/api/v2/"
        let http = FakeHTTP(responses: [
            api + "oauth/token": #"{"access_token":"tok"}"#,
            api + "tailnet/-/keys": #"{"key":"tskey-auth-EXAMPLE"}"#,
            api + "tailnet/-/devices": #"{"devices":[{"id":"7","hostname":"fd-gpu","addresses":["\#(nodeIP)"],"nodeKey":"nodekey:example","tags":["tag:flightdeck-cloud"]}]}"#,
            api + "device/7": "",
        ])
        tailnet = TailnetIntegration(cli: cli, http: http, secrets: MemoryTailnetSecrets(
            TailscaleOAuthClient(id: "k", secret: "s", tailnet: "example-tailnet.ts.net")))
    }

    /// `fd.auto.tfvars.json` as `up` wrote it.
    func tfvars(_ name: String) throws -> [String: Any] {
        let url = registry.workdir(for: name).appendingPathComponent("module").appendingPathComponent(InfraWorkdir.varsFile)
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    /// A work directory as `up` leaves one once OpenTofu has state, so `down` has something to destroy.
    func prepareWorkdir(_ name: String) throws {
        try FileManager.default.createDirectory(at: registry.workdir(for: name).appendingPathComponent("module"),
                                                withIntermediateDirectories: true)
    }
}
