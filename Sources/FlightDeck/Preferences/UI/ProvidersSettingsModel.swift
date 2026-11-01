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
    /// True until the first resolve lands, so the pane does not say "No providers found." early.
    @Published private(set) var isLoading = true
    /// Where the last resolve ran. Read by a test that pins it off the main thread.
    private(set) var lastResolveWasOnMainThread: Bool?
    /// The newest resolve. Each one waits for the one before, so they land in order.
    private var pending: Task<Void, Never>?

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

    /// Resolves off the main actor and publishes on it. A repo is untrusted input: its
    /// manifests are parsed and its generator providers digested, which reads files the repo
    /// chose, so none of it may hold up the Settings window.
    func refresh() {
        resolve(then: nil)
    }

    /// Waits until every resolve started so far has landed.
    func settle() async {
        await pending?.value
    }

    /// `work`, if any, runs first on the same background task (an approval digests the folder).
    /// Its result is a message for `approvalError`.
    private func resolve(then work: (@Sendable () -> String?)?) {
        let registry = registry, repo = repo, previous = pending
        pending = Task { @MainActor [weak self] in
            await previous?.value
            let outcome = await Task.detached(priority: .userInitiated) {
                let message = work?()
                return (message, registry.resolve(repo: repo), registry.trustStore.isUnreadable, pthread_main_np() != 0)
            }.value
            self?.publish(error: outcome.0, resolved: outcome.1, trustUnreadable: outcome.2, onMain: outcome.3)
        }
    }

    private func publish(error: String?, resolved: [ResolvedProvider], trustUnreadable: Bool, onMain: Bool) {
        if let error { approvalError = error }
        self.resolved = resolved
        lastResolveWasOnMainThread = onMain
        trustProblem = trustUnreadable
            ? "Approvals are saved in a file Flight Deck cannot read. Move it aside to start a new list; providers that run code will ask again."
            : nil
        republish()
        isLoading = false
    }

    private func republish() {
        let disabled = disabledIDs
        rows = resolved.map { row($0, disabled: disabled) }
    }

    func setEnabled(_ rowID: String, _ enabled: Bool) {
        guard let provider = resolved.first(where: { Self.rowID($0) == rowID }) else { return }
        let entry = ProviderRegistry.disabledEntry(provider)
        var disabled = disabledIDs
        if enabled { disabled.remove(entry) } else { disabled.insert(entry) }
        defaults.set(disabled.sorted(), forKey: Self.disabledKey)
        // The switch moves now, from what is already resolved; the fresh resolve follows.
        republish()
        refresh()
    }

    func approve(_ rowID: String) {
        approvalError = nil
        guard let repo, let provider = resolved.first(where: { Self.rowID($0) == rowID }),
              let digest = provider.digest else { return }
        let name = provider.manifest?.name ?? provider.id
        let registry = registry
        // `approve` digests the folder again, so it runs off the main actor with the resolve.
        resolve(then: {
            do {
                try registry.approve(provider, shownDigest: digest, repo: repo)
                return nil
            } catch ProviderRegistry.ApprovalError.changedSinceShown {
                return "\(name) changed while you were looking at it. Check it again, then approve."
            } catch ProviderTrustStore.StoreError.trustFileUnreadable {
                return "Nothing was approved: the approvals file is damaged. Move it aside first."
            } catch {
                return "Could not approve \(name). Check that Flight Deck can read the provider's folder, then try again."
            }
        })
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
