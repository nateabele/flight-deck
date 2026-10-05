import Foundation
import HostKit

/// `Preflighting` through C5's `Preflight.run`: the §7 order, and the release-on-failure, are
/// its. This supplies the checks — local ones here, remote ones as requests on the link — and
/// `PortForwarder` for the local listeners.
struct LivePreflight: Preflighting {
    let forwarder: PortForwarder
    var git = GitRunner()

    func preflight(_ plan: DelegationPlan, link: any HostLinking) async throws -> any PortReservation {
        let checks = LivePreflightChecks(plan: plan, link: LinkBox(link), forwarder: forwarder, git: git)
        let reservation = try await Preflight.run(checks)
        return reservation.ports ?? NoPorts()
    }
}

/// A plan with no ports holds nothing.
private final class NoPorts: PortReservation {
    var forwards: [PortForward] { [] }
    func startForwarding(_ connect: @escaping @Sendable (UInt16) -> any ChannelOpening) {}
    func release() {}
}

/// The link, carried into `PreflightChecks` (which is `Sendable`) and only ever used back on
/// the main actor.
private final class LinkBox: @unchecked Sendable {
    let link: any HostLinking
    init(_ link: any HostLinking) { self.link = link }
}

private struct LivePreflightChecks: PreflightChecks {
    let plan: DelegationPlan
    let link: LinkBox
    let forwarder: PortForwarder
    let git: GitRunner

    /// Step 1 happened in `DelegationService.start` (worktree, recipe, host, ports); this
    /// restates it in HostKit's terms.
    func resolve() async throws -> PreflightPlan {
        PreflightPlan(host: plan.host, ports: plan.spec.ports, screen: plan.spec.screen, service: plan.spec.service,
                      sync: plan.sync, include: plan.include, fetch: plan.fetch)
    }

    func hostCapabilities(_ host: String) async throws -> Set<HostCapability>? {
        await Self.capabilities(of: link.link)
    }

    /// What the host's helloAck advertised; nil when it is not connected. A `HostLinking` that
    /// is not a `LiveHostLink` has no helloAck to read, so everything is assumed and the
    /// host's own `not_implemented` answers whatever it lacks.
    @MainActor
    private static func capabilities(of link: any HostLinking) -> Set<HostCapability>? {
        guard let live = link as? LiveHostLink else { return [.hostInfo, .run, .sync, .service, .screen] }
        return live.capabilities
    }

    /// Step 3: every `include` exists here (a typo would otherwise sync nothing and fail on
    /// the host, far from its cause), and no `fetch` glob names a tracked file (tracked files
    /// come back through the patch, and a tar over them would clobber concurrent edits).
    func checkLocalPaths(_ plan: PreflightPlan) async throws {
        let worktree = self.plan.worktree
        let host = plan.host
        let missing = plan.include.filter { !FileManager.default.fileExists(atPath: worktree.appendingPathComponent($0).path) }
        if let first = missing.first {
            throw DelegationError(code: "missing_include",
                                  message: "\(first) is in include but does not exist in \(worktree.lastPathComponent) — create it or drop it from include, then rerun on \(host)")
        }
        guard plan.sync, !plan.fetch.isEmpty else { return }
        let git = git
        let tracked = try await offloaded { try git.fields(["ls-files", "-z"], in: worktree) }
        for glob in plan.fetch {
            if let hit = tracked.first(where: { Self.matches(glob, $0) }) {
                throw DelegationError(code: "fetch_tracked",
                                      message: "fetch glob \(glob) matches tracked file \(hit) — tracked files come back through flightdeck diff/apply; narrow the glob")
            }
        }
    }

    func reserveLocalPorts(_ ports: [PortMapping], host: String) async throws -> any PortReservation {
        // The worktree's name stands in for the session: `DelegationPlan` names no tab, and a
        // conflict message ("held by Flight Deck session "app"") still points at the right place.
        try await forwarder.reserve(ports, session: plan.worktree.lastPathComponent)
    }

    func remotePorts(_ ports: [UInt16], host: String) async throws -> [PortStatus] {
        guard case .portCheck(let statuses) = try await ask(.portCheck(ports: ports)) else {
            throw unexpected("port.check")
        }
        return statuses
    }

    func screenStatus(_ host: String) async throws -> ScreenStatus {
        guard case .screenStatus(let status) = try await ask(.screenStatus) else { throw unexpected("screen.status") }
        return status
    }

    /// Step 7 is the snapshot's: `Snapshotter` refuses an LFS repo before it adds or records
    /// anything, and the snapshot is taken before any sync or remote work, so a refusal there
    /// still changes nothing on either machine. Checking here as well would run the same
    /// `git check-attr` over every path twice per run.
    func checkLFS(_ plan: PreflightPlan) async throws {}

    // MARK: -

    private func ask(_ request: DelegationRequest) async throws -> DelegationReply {
        try await Self.ask(request, on: link.link)
    }

    /// A host `err` worded as its §5 line, as `DelegationService.hostRequest` words it.
    @MainActor
    private static func ask(_ request: DelegationRequest, on link: any HostLinking) async throws -> DelegationReply {
        do { return try await link.request(request) } catch HostLinkError.remote(let code, let message) {
            throw DelegationError(code: code, message: DelegationService.hostLine(code: code, message: message, host: link.name))
        }
    }

    private func unexpected(_ op: String) -> DelegationError {
        DelegationError(code: "unexpected_reply", message: "\(plan.host) answered \(op) with something else — update Flight Deck on both machines")
    }

    /// `fetch` glob semantics (§4.5), as the host's capture applies them: `/`-separated
    /// segments, each an fnmatch pattern, `**` any number of segments, and a glob matching a
    /// directory takes what is under it.
    static func matches(_ glob: String, _ path: String) -> Bool {
        let g = glob.split(separator: "/").map(String.init)
        let p = path.split(separator: "/").map(String.init)
        return (1...max(1, p.count)).contains { match(g[...], p[..<$0]) }
    }

    private static func match(_ g: ArraySlice<String>, _ p: ArraySlice<String>) -> Bool {
        guard let head = g.first else { return p.isEmpty }
        if head == "**" { return (p.startIndex...p.endIndex).contains { match(g.dropFirst(), p[$0...]) } }
        guard let name = p.first, fnmatch(head, name, 0) == 0 else { return false }
        return match(g.dropFirst(), p.dropFirst())
    }
}
