import Foundation
import HostKit

enum CloudSetupError: Error, Equatable, CustomStringConvertible {
    /// The OAuth client is recorded against this Mac's tailnet, so one must be running.
    case tailscaleNotRunning

    var description: String {
        switch self {
        case .tailscaleNotRunning: "Tailscale isn't running on this Mac, so there is no tailnet to save the client for."
        }
    }
}

/// Settings → Cloud → Set up… (spec §9): a checklist whose items turn green as the live checks
/// `infra doctor` makes pass, each with its automation. Every step can be skipped — Tailscale
/// entirely (public mode), either cloud, or the test.
///
/// Logic only; `CloudSetupSheet` draws it. Every outside effect — opening a URL, the clipboard,
/// a delegated run — is a closure the app supplies and a test spies on.
@MainActor
final class CloudSetupModel: ObservableObject {
    enum StepID: String, CaseIterable { case tools, aws, gcp, quota, tailnet, policy, oauth, lock, budget, test }

    struct Step: Equatable {
        let id: StepID
        var state: State
        var detail: String
        /// The automation's button title, nil when there is nothing to press.
        var action: String?
        var skipped: Bool
        enum State: Equatable { case pending, running, ok, failed }
    }

    /// Runs `command` on the host named `host`, from `cwd`, and returns its output.
    typealias HostRun = @MainActor (_ host: String, _ command: [String], _ cwd: URL) async throws -> String

    static let keysPage = URL(string: "https://login.tailscale.com/admin/settings/keys")!
    static let oauthPage = URL(string: "https://login.tailscale.com/admin/settings/oauth")!
    static let policyEditor = URL(string: "https://login.tailscale.com/admin/acls/file")!
    /// Who may assign `tag:flightdeck-cloud`: the tailnet's admins, whose OAuth client mints the keys.
    static let tagOwner = "autogroup:admin"
    static let testMachineName = "fd-setup-test"
    /// The cheapest machine of each preset that the default allowlist admits.
    static let cheapestType = ["aws": "t4g.nano", "gcp": "e2-micro"]
    /// Task 0 probe P1: the Tailscale API cannot create OAuth clients, so this is the page's checklist.
    static let oauthChecklist = "On the OAuth clients page, generate a client with Keys → Auth Keys: Write and Tags: tag:flightdeck-cloud, then copy its ID and secret and choose Paste from Clipboard."

    static let testPitch = "Creates the cheapest machine for at most 15 minutes, runs uname -a on it, destroys it, and shows the time and cost (about a cent)."

    @Published private(set) var steps: [Step]
    /// The policy change `applyPolicy` found, waiting for the user to read it and Apply.
    @Published private(set) var pendingPatch: HuJSONPatcher.Patch?

    private let service: InfraService
    private let tailnet: TailnetIntegration
    private let accounts: [String: CloudAccount]
    private let open: (URL) -> Void
    private let clipboard: () -> String?
    private let copy: (String) -> Void
    private let resolver: ToolResolver?
    private let budget: () -> BudgetSettings
    private let regions: () -> [String: String]
    private let run: HostRun
    private let workRoot: URL

    private var userSkipped: Set<StepID> = []
    private var autoSkipped: Set<StepID> = []
    private var policyETag: String?
    private var policyApplied = false
    private var localTailnet: String?

    init(service: InfraService, tailnet: TailnetIntegration, accounts: [String: CloudAccount],
         open: @escaping (URL) -> Void, clipboard: @escaping () -> String?,
         copy: @escaping (String) -> Void = { _ in }, resolver: ToolResolver? = nil,
         budget: @escaping () -> BudgetSettings = { .default },
         regions: @escaping () -> [String: String] = { CloudPreferences().regions },
         run: @escaping HostRun = { _, _, _ in throw InfraLiveError.noDelegation },
         workRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("flightdeck-setup-test")) {
        self.service = service
        self.tailnet = tailnet
        self.accounts = accounts
        self.open = open
        self.clipboard = clipboard
        self.copy = copy
        self.resolver = resolver
        self.budget = budget
        self.regions = regions
        self.run = run
        self.workRoot = workRoot
        steps = StepID.allCases.map { Step(id: $0, state: .pending, detail: "", action: nil, skipped: false) }
        // The one step no check fills in: it runs only when asked, because it costs money.
        set(.test, .pending, Self.testPitch, action: "Run Test")
    }

    static func title(_ id: StepID) -> String {
        switch id {
        case .tools: "Tools"
        case .aws: "AWS sign-in"
        case .gcp: "GCP sign-in"
        case .quota: "Quota"
        case .tailnet: "Tailscale: tailnet"
        case .policy: "Tailscale: policy"
        case .oauth: "Tailscale: OAuth client"
        case .lock: "Tailnet Lock"
        case .budget: "Budget"
        case .test: "Test machine"
        }
    }

    func step(_ id: StepID) -> Step { steps.first { $0.id == id }! }

    // MARK: - Checks

    /// Re-runs every check. The test step keeps its last result: it costs money to repeat.
    func refresh() async {
        await refreshTools()
        await refreshAccount("aws")
        await refreshAccount("gcp")
        await runQuota(openWhenLow: false)
        await refreshTailnet()
        refreshBudget()
    }

    private func refreshTools() async {
        guard let resolver else { return set(.tools, .pending, "Not checked.") }
        var tools: [InfraTool] = [.tofu]
        if !isSkipped(.aws) { tools.append(.aws) }
        if !isSkipped(.gcp) { tools.append(.gcloud) }
        var found: [String] = [], missing: [String] = []
        for tool in tools {
            do {
                let resolved = try await resolver.resolve(tool, provision: false)
                found.append("\(tool.rawValue) \(resolved.version)")
            } catch {
                missing.append(Self.describe(error))
            }
        }
        if missing.isEmpty { return set(.tools, .ok, found.joined(separator: " · ")) }
        let downloadable = missing.contains { $0.contains("can download") }
        set(.tools, .failed, missing.joined(separator: "\n"), action: downloadable ? "Download" : nil)
    }

    private func refreshAccount(_ cloud: String) async {
        let id: StepID = cloud == "aws" ? .aws : .gcp
        guard !isSkipped(id) else { return apply() }
        guard let account = accounts[cloud] else { return set(id, .failed, "No \(cloud) account is configured.") }
        switch await account.status() {
        case .ready(let identity): set(id, .ok, "Signed in: \(identity)")
        case .signedOut(let fix): set(id, .failed, "Signed out. `\(fix)` signs in.", action: "Sign in")
        case .unavailable(let why): set(id, .failed, why)
        }
    }

    /// The cheapest preset machine's quota in each cloud not skipped; `openWhenLow` opens the
    /// increase page of the first that is too low.
    private func runQuota(openWhenLow: Bool) async {
        let clouds = ["aws", "gcp"].filter { !isSkipped($0 == "aws" ? .aws : .gcp) && accounts[$0] != nil }
        guard !clouds.isEmpty else { return set(.quota, .pending, "No cloud to check.") }
        set(.quota, .running, "Checking…")
        var lines: [String] = [], low: [URL] = [], failed = false
        for cloud in clouds {
            let type = Self.cheapestType[cloud]!, region = regions()[cloud] ?? ""
            do {
                let q = try await accounts[cloud]!.quota(region: region, instanceType: type)
                lines.append("\(cloud) \(type) in \(region): \(Self.number(q.have)) available, \(Self.number(q.need)) needed")
                if !q.ok {
                    failed = true
                    if let url = q.increaseURL { low.append(url) }
                }
            } catch {
                failed = true
                lines.append("\(cloud): \(Self.describe(error))")
            }
        }
        set(.quota, failed ? .failed : .ok, lines.joined(separator: "\n"), action: low.isEmpty ? nil : "Request increase")
        if openWhenLow, let url = low.first { open(url) }
    }

    private func refreshTailnet() async {
        let local = await tailnet.local()
        let mode = await tailnet.mode()
        guard local.running, let name = local.tailnet else {
            autoSkipped = [.tailnet, .policy, .oauth, .lock]
            set(.tailnet, .pending, "Tailscale isn't running on this Mac, so cloud machines use public mode. Start Tailscale and check again to use tailnet mode.")
            for id in [StepID.policy, .oauth, .lock] { set(id, .pending, "Needs Tailscale running on this Mac.") }
            return
        }
        autoSkipped = []
        localTailnet = name
        switch mode {
        case .available(let client):
            set(.tailnet, .ok, "This Mac is on \(name).")
            set(.oauth, .ok, "OAuth client \(client.id) is in the Keychain.")
        case .mismatch(let local, let other):
            set(.tailnet, .failed, "This Mac is on \(local), but the saved OAuth client is for \(other).")
            set(.oauth, .failed, "Create a client for \(local). " + Self.oauthChecklist, action: "Open OAuth Clients")
        case .notConfigured, .notRunning:
            set(.tailnet, .ok, "This Mac is on \(name).")
            // Not a failure: nothing is wrong yet, there is only something to do.
            set(.oauth, .pending, Self.oauthChecklist, action: "Open OAuth Clients")
        }
        if policyApplied {
            set(.policy, .ok, "The policy has Flight Deck's tag owner and grant.")
        } else {
            set(.policy, .pending, "Generate a short-lived API access token, paste it here, and Flight Deck shows the exact change before applying it.",
                action: "Get Token")
        }
        if !local.lockEnabled {
            set(.lock, .ok, "Tailnet Lock is off.")
        } else if local.lockSigner {
            set(.lock, .ok, "Tailnet Lock is on, and this Mac signs each new machine.")
        } else {
            set(.lock, .failed, "Tailnet Lock is on and this Mac isn't a signer: each new machine must be signed with `tailscale lock sign` on a signing device.")
        }
    }

    private func refreshBudget() {
        let b = budget(), usd = InfraPreflight.usd
        let parts = [
            b.monthlyCapUSD.map { "Monthly \(usd($0))" } ?? "No monthly cap",
            b.perMachineCapUSD.map { "per machine \(usd($0))" } ?? "no per-machine cap",
            "warn at \(Int((b.warnFraction * 100).rounded()))%",
            "\(b.maxConcurrent) at once, TTL ≤ \(b.maxTTL.formatted), idle ≤ \(b.maxIdle.formatted)",
        ]
        set(.budget, .ok, parts.joined(separator: " · "))
    }

    // MARK: - Automations

    func perform(_ id: StepID) async {
        switch id {
        case .tools:
            set(.tools, .running, "Downloading…")
            for tool in [InfraTool.tofu, .aws, .gcloud] {
                if tool == .aws && isSkipped(.aws) || tool == .gcloud && isSkipped(.gcp) { continue }
                do { _ = try await service.tool(tool) } catch {
                    // Reported by the check below, in the resolver's own words.
                }
            }
            await refreshTools()
        case .aws, .gcp:
            let cloud = id == .aws ? "aws" : "gcp"
            guard let account = accounts[cloud] else { return await refreshAccount(cloud) }
            set(id, .running, "Finish signing in in the browser…")
            do { try await account.signIn() } catch {
                return set(id, .failed, Self.describe(error), action: "Sign in")
            }
            await refreshAccount(cloud)
        case .quota:
            await runQuota(openWhenLow: true)
        case .tailnet, .lock:
            await refreshTailnet()
        case .policy:
            open(Self.keysPage)
            set(.policy, .pending, "Generate an API access token on the page that opened, paste it below and choose Check Policy.",
                action: "Get Token")
        case .oauth:
            open(Self.oauthPage)
            set(.oauth, .pending, Self.oauthChecklist, action: "Open OAuth Clients")
        case .budget:
            refreshBudget()
        case .test:
            await runTest()
        }
    }

    func skip(_ id: StepID) {
        userSkipped.insert(id)
        // Skipping the tailnet is skipping Tailscale: public mode needs none of its steps.
        if id == .tailnet { userSkipped.formUnion([.policy, .oauth, .lock]) }
        apply()
    }

    func unskip(_ id: StepID) {
        userSkipped.remove(id)
        if id == .tailnet { userSkipped.subtract([.policy, .oauth, .lock]) }
        apply()
    }

    // MARK: - Tailscale policy

    /// Fetches the policy and diffs Flight Deck's two rules into it. Nil when it fell back to
    /// copy-and-open (the patcher could not place them safely), and when the policy could not
    /// be read — then the step says why, and nothing is opened on a mistyped token.
    func applyPolicy(token: String) async -> HuJSONPatcher.Patch? {
        set(.policy, .running, "Reading the policy…")
        pendingPatch = nil
        let fetched: (hujson: String, etag: String)
        do { fetched = try await tailnet.fetchPolicy(token: token) } catch {
            set(.policy, .failed, "Couldn't read the policy (\(Self.describe(error))). Check the token and try again.", action: "Get Token")
            return nil
        }
        guard let patch = HuJSONPatcher.addFlightDeckRules(to: fetched.hujson, tag: TailnetIntegration.cloudTag,
                                                           ownerAutogroup: Self.tagOwner) else {
            copy(HuJSONPatcher.snippet(tag: TailnetIntegration.cloudTag, ownerAutogroup: Self.tagOwner))
            open(Self.policyEditor)
            set(.policy, .failed, "Flight Deck couldn't place its rules in this policy safely, so they are on the clipboard: paste them into the policy editor that opened.")
            return nil
        }
        policyETag = fetched.etag
        if patch.diff.isEmpty {
            policyApplied = true
            set(.policy, .ok, "The policy already has Flight Deck's tag owner and grant.")
        } else {
            pendingPatch = patch
            set(.policy, .pending, "Review the change below, then Apply.")
        }
        return patch
    }

    /// Writes the patch only over the policy it was made from; a 412 means someone edited it
    /// since, and the step asks for a fresh check rather than overwriting their change.
    func confirmPolicy(_ patch: HuJSONPatcher.Patch, token: String) async throws {
        guard let etag = policyETag else { throw TailnetError.policyChanged }
        set(.policy, .running, "Applying…")
        do {
            try await tailnet.savePolicy(token: token, hujson: patch.patched, etag: etag)
        } catch {
            pendingPatch = nil
            let why = error as? TailnetError == .policyChanged
                ? "The policy changed since it was read. Check it again to see a fresh diff."
                : "Couldn't apply the policy (\(Self.describe(error)))."
            set(.policy, .failed, why, action: "Get Token")
            throw error
        }
        pendingPatch = nil
        policyApplied = true
        set(.policy, .ok, "Policy updated: Flight Deck's tag owner and grant are in.")
    }

    // MARK: - OAuth client

    /// Reads an OAuth client's ID and secret off the clipboard into the Keychain. False when
    /// the clipboard does not hold both; throws when there is no tailnet to record it for.
    func captureOAuthClientFromClipboard() throws -> Bool {
        guard let text = clipboard(), let parsed = Self.parseOAuthClient(text) else {
            set(.oauth, .failed, "The clipboard doesn't hold both a client ID (k…) and a secret (tskey-client-…). "
                + Self.oauthChecklist, action: "Open OAuth Clients")
            return false
        }
        let name: String
        if let localTailnet { name = localTailnet } else {
            let local = tailnet.localNow()
            guard local.running, let current = local.tailnet else {
                set(.oauth, .failed, CloudSetupError.tailscaleNotRunning.description)
                throw CloudSetupError.tailscaleNotRunning
            }
            name = current
        }
        try tailnet.saveClient(TailscaleOAuthClient(id: parsed.id, secret: parsed.secret, tailnet: name))
        set(.oauth, .ok, "OAuth client \(parsed.id) is in the Keychain.")
        return true
    }

    /// The client ID (`k…`) and secret (`tskey-client-…`) anywhere in `text`. Tailscale's
    /// secret carries the ID inside it, so a standalone token equal to that one is preferred
    /// over any other word that happens to start with `k`.
    static func parseOAuthClient(_ text: String) -> (id: String, secret: String)? {
        guard let secretRange = text.range(of: #"tskey-client-[A-Za-z0-9-]+"#, options: .regularExpression) else { return nil }
        let secret = String(text[secretRange])
        let embedded = secret.dropFirst("tskey-client-".count).split(separator: "-").first.map(String.init)
        var rest = text
        rest.removeSubrange(secretRange)
        let pattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9-])k[A-Za-z0-9]+(?![A-Za-z0-9-])"#)
        let ids = pattern.matches(in: rest, range: NSRange(rest.startIndex..., in: rest))
            .compactMap { Range($0.range, in: rest).map { String(rest[$0]) } }
        guard let id = ids.first(where: { $0 == embedded }) ?? ids.first else { return nil }
        return (id, secret)
    }

    // MARK: - Test machine

    /// The cheapest preset machine of the first signed-in cloud, a 15-minute TTL, `uname -a`
    /// run on it as a delegated run, then destroyed — whatever happened in between — with the
    /// time and cost reported.
    func runTest() async {
        set(.test, .running, "Choosing a cloud…")
        var chosen: String?
        for cloud in ["aws", "gcp"] where !isSkipped(cloud == "aws" ? .aws : .gcp) {
            if let account = accounts[cloud], case .ready = await account.status() { chosen = cloud; break }
        }
        guard let cloud = chosen else {
            return set(.test, .failed, "Sign in to AWS or GCP first, or skip this step.", action: "Run Test")
        }
        let name = Self.testMachineName, type = Self.cheapestType[cloud]!
        let config = InfraConfig(source: .preset("\(cloud)-linux"), region: regions()[cloud], instanceType: type,
                                 ttl: HostKit.Duration(seconds: 900), idle: HostKit.Duration(seconds: 900))
        let started = Date()
        var output: String?, failure: String?
        do {
            _ = try await service.up(name: name, config: config, repoRoot: workRoot) { [weak self] event in
                if case .progress(let line) = event { self?.set(.test, .running, line) }
            }
            set(.test, .running, "Running uname -a on \(name)…")
            output = try await run(name, ["uname", "-a"], workRoot)
        } catch {
            failure = Self.describe(error)
        }
        // Only a machine this step created (same name, same scratch repo) is destroyed here.
        if let m = service.registry.machine(named: name), m.repoRoot == workRoot.standardizedFileURL.path {
            set(.test, .running, "Destroying \(name)…")
            do { try await service.down(name: name) { _ in } } catch {
                failure = (failure.map { $0 + "; and " } ?? "")
                    + "\(name) could not be destroyed (\(Self.describe(error))): run `flightdeck infra down \(name)`"
            }
        }
        let cost = InfraPreflight.usd(service.ledger.spent(name: name, now: service.now))
        let took = Self.elapsed(Date().timeIntervalSince(started))
        if let failure {
            set(.test, .failed, failure, action: "Run Test")
        } else {
            let first = output?.split(separator: "\n").first.map(String.init) ?? ""
            set(.test, .ok, "\(first)\n\(cloud) \(type) · \(took) · ~\(cost) est.", action: "Run Test")
        }
    }

    // MARK: - Plumbing

    private func isSkipped(_ id: StepID) -> Bool { userSkipped.contains(id) || autoSkipped.contains(id) }

    private func set(_ id: StepID, _ state: Step.State, _ detail: String, action: String? = nil) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i] = Step(id: id, state: state, detail: detail, action: action, skipped: isSkipped(id))
    }

    /// Re-stamps every step's `skipped` after a skip or unskip.
    private func apply() {
        steps = steps.map { var s = $0; s.skipped = isSkipped(s.id); return s }
    }

    private static func number(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(x) }

    private static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }

    /// An error in words the user can act on, not Swift's enum spelling.
    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case ToolError.missing(_, let why): why
        case ToolError.checksumMismatch(let tool): "the \(tool.rawValue) download did not match its pinned checksum"
        case ToolError.downloadFailed(let tool, let why): "\(tool.rawValue) download failed: \(why)"
        case CloudAccountError.failed(let why): why
        case CloudAccountError.unsupportedInstanceType(let type): "no quota is known for \(type)"
        case let e as HTTPStatusError: "HTTP \(e.status)"
        case InfraError.preflight(let checks):
            checks.filter { !$0.ok }.map { "\($0.detail)\($0.fix.map { " \($0)" } ?? "")" }.joined(separator: "\n")
        case InfraError.refused(let why), InfraError.nameInUse(let why): why
        case InfraError.notFound(let name): "\(name) was not found"
        case TofuError.failed(let step, let message): "\(step): \(message)"
        case TofuError.missingOutput(let output): "the module has no \(output) output"
        case InfraError.enrollTimeout: "the machine did not enroll in time"
        default: String(describing: error)
        }
    }
}
