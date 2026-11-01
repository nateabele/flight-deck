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
        case off
    }
    var id: String
    var providerID: String
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
    static let disabledKey = "visualProviders.disabled.v2"
    /// Plain provider ids, from before a switch knew its source. Read once as bundled and user entries.
    static let legacyDisabledKey = "visualProviders.disabled.v1"

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
        if defaults.object(forKey: Self.disabledKey) == nil, let old = defaults.stringArray(forKey: Self.legacyDisabledKey) {
            defaults.set(old.flatMap { ["bundled:\($0)", "user:\($0)"] }.sorted(), forKey: Self.disabledKey)
        }
        refresh()
    }

    var repoCaption: String {
        guard let repo else { return "No project is selected, so repo providers are not shown." }
        return "Repo providers come from \(repo.lastPathComponent) (\(ProviderRegistry.repoSubpath))."
    }

    func refresh() {
        resolved = registry.resolve(repo: repo)
        trustProblem = registry.trustStore.isUnreadable
            ? "Approvals are saved in a file Flight Deck cannot read. Move it aside to start a new list; providers that run code will ask again."
            : nil
        let disabled = disabledIDs
        rows = resolved.map { row($0, disabled: disabled) }
    }

    func setEnabled(_ rowID: String, _ enabled: Bool) {
        guard let provider = resolved.first(where: { Self.rowID($0) == rowID }) else { return }
        let entry = ProviderRegistry.disabledEntry(provider)
        var disabled = disabledIDs
        if enabled { disabled.remove(entry) } else { disabled.insert(entry) }
        defaults.set(disabled.sorted(), forKey: Self.disabledKey)
        refresh()
    }

    func approve(_ rowID: String) {
        approvalError = nil
        guard let repo, let provider = resolved.first(where: { Self.rowID($0) == rowID }),
              let digest = provider.digest else { return }
        let id = provider.id
        do {
            try registry.approve(provider, shownDigest: digest, repo: repo)
        } catch ProviderRegistry.ApprovalError.changedSinceShown {
            approvalError = "\(provider.manifest?.name ?? id) changed while you were looking at it. Check it again, then approve."
        } catch ProviderTrustStore.StoreError.trustFileUnreadable {
            approvalError = "Nothing was approved: the approvals file is damaged. Move it aside first."
        } catch {
            approvalError = "Could not approve \(provider.manifest?.name ?? id). Check that Flight Deck can read the provider's folder, then try again."
        }
        refresh()
    }

    func moveTrustFileAside() {
        approvalError = nil
        do { try registry.trustStore.moveAside() } catch ProviderTrustStore.StoreError.fileIsReadable {
            approvalError = "The approvals file can be read now, so it was left where it is."
        } catch {
            approvalError = "Could not move the approvals file aside."
        }
        refresh()
    }

    /// Unique per provider folder, so a broken repo provider and a good bundled one with the same
    /// id are two rows.
    static func rowID(_ p: ResolvedProvider) -> String {
        "\(ProviderRegistry.disabledEntry(p))@\(p.folder.standardizedFileURL.path)"
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
        let enabled = ProviderRegistry.isEnabled(p, disabled: disabled)
        return ProviderRowModel(
            id: Self.rowID(p), providerID: p.id, name: name, sourceCaption: origin + version, status: usable && !enabled && status == .none ? .off : status,
            isEnabled: enabled, canToggle: usable,
            canApprove: p.trust == .repoNeedsApproval && p.digest != nil && trustProblem == nil)
    }
}
