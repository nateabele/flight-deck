import Foundation
import HostKit

/// One Providers row, already worded.
struct ProviderRowModel: Identifiable, Equatable {
    enum Status: Equatable {
        case none
        case approved
        case needsApproval(command: String)
        case needsNewerFlightDeck
        case broken(String)
    }
    var id: String
    var name: String
    var sourceCaption: String
    var status: Status
    var isEnabled: Bool
    /// False for a provider that cannot run yet: waiting for approval, too new, or broken.
    var canToggle: Bool
    var canApprove: Bool
}

/// What Settings → Flight Control → Providers shows: every provider the registry finds for the
/// selected project, whether it is switched on, and the repo trust gate. The off switches are
/// remembered by provider id, per person, not per project.
@MainActor
final class ProvidersSettingsModel: ObservableObject {
    static let disabledKey = "visualProviders.disabled.v1"

    @Published private(set) var rows: [ProviderRowModel] = []
    /// Set when `provider-trust.json` cannot be read. Approving is refused until it is moved aside.
    @Published private(set) var trustProblem: String?
    /// The last approval that did not go through, in words.
    @Published private(set) var approvalError: String?

    private let registry: ProviderRegistry
    private let repo: URL?
    private let defaults: UserDefaults
    private var resolved: [ResolvedProvider] = []

    init(registry: ProviderRegistry, repo: URL?, defaults: UserDefaults = .standard) {
        self.registry = registry
        self.repo = repo
        self.defaults = defaults
        refresh()
    }

    var repoCaption: String {
        guard let repo else { return "No project is selected, so repo providers are not shown." }
        return "Repo providers come from \(repo.lastPathComponent) (\(ProviderRegistry.repoSubpath))."
    }

    func refresh() {
        resolved = registry.resolve(repo: repo)
        trustProblem = registry.trustStore.isUnreadable
            ? "Flight Deck cannot read its list of approved providers, so every provider that runs code asks again, and Approve is off. "
            + "Approvals are kept in provider-trust.json. Move the damaged file aside to start a new list."
            : nil
        let disabled = disabledIDs
        rows = resolved.map { row($0, disabled: disabled) }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        var disabled = disabledIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        defaults.set(disabled.sorted(), forKey: Self.disabledKey)
        refresh()
    }

    func approve(_ id: String) {
        approvalError = nil
        guard let repo, let provider = resolved.first(where: { $0.id == id }), let digest = provider.digest else { return }
        do {
            try registry.approve(provider, shownDigest: digest, repo: repo)
        } catch ProviderRegistry.ApprovalError.changedSinceShown {
            approvalError = "\(provider.manifest?.name ?? id) changed while you were looking at it. Check it again, then approve."
        } catch ProviderTrustStore.StoreError.trustFileUnreadable {
            // refresh() below words this.
        } catch {
            approvalError = "Could not approve \(provider.manifest?.name ?? id): \(error)"
        }
        refresh()
    }

    func moveTrustFileAside() {
        do { try registry.trustStore.moveAside() } catch {
            approvalError = "Could not move the damaged file aside: \(error.localizedDescription)"
        }
        refresh()
    }

    private var disabledIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
    }

    private func row(_ p: ResolvedProvider, disabled: Set<String>) -> ProviderRowModel {
        let name = p.manifest?.name ?? p.id
        let version = p.manifest.map { " · v\($0.version)" } ?? ""
        let origin: String
        switch p.source {
        case .bundled: origin = "Built in"
        case .user: origin = "Yours"
        case .repo:
            let from = "From \(repo?.lastPathComponent ?? "repo")"
            origin = p.trust == .repoDataOnly ? from + " · data only" : from
        }
        let status: ProviderRowModel.Status
        switch p.trust {
        case _ where p.needsNewerFlightDeck: status = .needsNewerFlightDeck
        case .unusable:
            let issue = p.problems.first { $0.severity == .error } ?? p.problems.first
            status = .broken(issue.map { "\($0.line.map { "line \($0): " } ?? "")\($0.message)" } ?? "It could not be read.")
        case .repoNeedsApproval:
            status = .needsApproval(command: p.manifest?.generator?.command.joined(separator: " ") ?? "a program")
        case .repoApproved: status = .approved
        case .bundled, .user, .repoDataOnly: status = .none
        }
        let usable = p.isUsable
        return ProviderRowModel(
            id: p.id, name: name, sourceCaption: origin + version, status: status,
            isEnabled: usable && !disabled.contains(p.id), canToggle: usable,
            canApprove: p.trust == .repoNeedsApproval && p.digest != nil)
    }
}
