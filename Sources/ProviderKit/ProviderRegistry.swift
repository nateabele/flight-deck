import Foundation
import HostKit

/// Where a provider's folder came from.
public enum ProviderSource: Equatable, Sendable {
    case repo, user, bundled
}

public enum ProviderTrustState: Equatable, Sendable {
    case bundled, user
    /// A repo provider with no generator: it is data only, so there is nothing to approve.
    case repoDataOnly
    case repoApproved
    case repoNeedsApproval
    /// Listed with its problems and never used: a parse error, a newer contract, or a folder
    /// that cannot be hashed. A provider is never partly loaded.
    case unusable
}

public struct ResolvedProvider: Equatable, Sendable {
    /// The manifest id, or the folder name when the manifest could not be read.
    public var id: String
    /// Nil when the manifest failed to parse.
    public var manifest: ProviderManifest?
    public var source: ProviderSource
    public var folder: URL
    public var trust: ProviderTrustState
    public var problems: [ProviderManifestIssue]
    /// The folder digest an approval would record; nil unless this is a repo provider with a generator.
    public var digest: String?

    /// True when the provider may be offered and run.
    public var isUsable: Bool {
        switch trust {
        case .bundled, .user, .repoDataOnly, .repoApproved: return true
        case .repoNeedsApproval, .unusable: return false
        }
    }

    public var needsNewerFlightDeck: Bool { problems.contains { $0.needsNewerFlightDeck } }
}

/// Finds visual providers: the repo's `.flightdeck/visual-providers/`, then the user's, then the
/// bundled ones. All three roots are parameters so tests use temp folders.
public struct ProviderRegistry: Sendable {
    public static let repoSubpath = ".flightdeck/visual-providers"

    public let userRoot: URL?
    public let bundledRoot: URL?
    public let trustStore: ProviderTrustStore

    public init(userRoot: URL?, bundledRoot: URL?, trustStore: ProviderTrustStore) {
        self.userRoot = userRoot
        self.bundledRoot = bundledRoot
        self.trustStore = trustStore
    }

    /// Every provider visible from `repo`, sorted by id. The first source to define an id wins
    /// (repo, then user, then bundled), so a repo provider shadows the others in that repo only:
    /// another repo's resolution never sees it. Providers that fail to load are listed beside
    /// the winners and never shadow anything.
    public func resolve(repo: URL?) -> [ResolvedProvider] {
        var winners: [String: ResolvedProvider] = [:]
        var broken: [ResolvedProvider] = []
        var roots: [(ProviderSource, URL)] = []
        if let repo { roots.append((.repo, repo.appendingPathComponent(Self.repoSubpath, isDirectory: true))) }
        if let userRoot { roots.append((.user, userRoot)) }
        if let bundledRoot { roots.append((.bundled, bundledRoot)) }

        for (source, root) in roots {
            for folder in providerFolders(in: root) {
                let provider = load(folder, source: source, repo: repo)
                if provider.trust == .unusable {
                    broken.append(provider)
                } else if winners[provider.id] == nil {
                    winners[provider.id] = provider
                }
            }
        }
        let byID: (ResolvedProvider, ResolvedProvider) -> Bool = { $0.id < $1.id }
        return winners.values.sorted(by: byID) + broken.sorted(by: byID)
    }

    private func providerFolders(in root: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func load(_ folder: URL, source: ProviderSource, repo: URL?) -> ResolvedProvider {
        let result: ProviderManifestParseResult
        do {
            result = try ProviderManifestParser.load(folder: folder)
        } catch {
            let issue = (error as? ProviderManifestIssue) ?? ProviderManifestIssue(.error, "\(error)")
            return ResolvedProvider(id: folder.lastPathComponent, manifest: nil, source: source,
                                    folder: folder, trust: .unusable, problems: [issue], digest: nil)
        }
        let manifest = result.manifest
        func make(_ trust: ProviderTrustState, digest: String? = nil,
                  extra: [ProviderManifestIssue] = []) -> ResolvedProvider {
            ResolvedProvider(id: manifest.id, manifest: manifest, source: source, folder: folder,
                             trust: trust, problems: result.issues + extra, digest: digest)
        }

        switch source {
        case .bundled: return make(.bundled)
        case .user: return make(.user)
        case .repo:
            guard manifest.generator != nil, let repo else { return make(.repoDataOnly) }
            do {
                let digest = try ProviderTrust.digest(folder: folder)
                let approved = trustStore.isApproved(
                    repoPath: repo.standardizedFileURL.path, providerID: manifest.id, digest: digest)
                return make(approved ? .repoApproved : .repoNeedsApproval, digest: digest)
            } catch {
                return make(.unusable, extra: [ProviderManifestIssue(.error, "\(error)")])
            }
        }
    }

    /// Records the user's approval of a repo provider as it is on disk right now.
    public func approve(_ provider: ResolvedProvider, repo: URL) throws {
        let digest = try ProviderTrust.digest(folder: provider.folder)
        try trustStore.approve(repoPath: repo.standardizedFileURL.path, providerID: provider.id, digest: digest)
    }
}
