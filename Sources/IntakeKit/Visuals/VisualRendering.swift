import Foundation

// The pure rules under the Mac's visual blocks (planning v2 §8, P2a V1). They live in IntakeKit,
// not the app, so they run in the window-free logic lane and the phone could share them.

/// The one URL scheme a visual's web view loads (V-R2): `fdvisual://<visualID>/r<n>/<path>`.
///
/// Every byte a web view gets comes through `VisualSchemeHandler`, which resolves a `Target` and
/// reads files only through `VisualStoreReading.read`. That is why this layer only *parses*: it
/// never resolves `..` or follows anything, so a traversal reaches the store's confinement as
/// written and is refused there, in the one place that decides.
public enum VisualScheme {
    public static let name = "fdvisual"

    public enum Target: Hashable, Sendable {
        /// `fdvisual://<id>/r<n>/`: the page that draws revision `r` (the app builds it, it is
        /// not a file). `state` and `size` arrive as the query.
        case page(VisualID, r: Int, state: String?, size: String?)
        /// `fdvisual://<id>/r<n>/<path>`: a file of the revision, as its manifest names it.
        case file(VisualID, r: Int, path: String)
        /// `fdvisual://<id>/lib/<name>`: a vendored library the app bundles (Mermaid). On the
        /// visual's own host so the page and its script share one origin; `lib` can never be a
        /// revision folder, which is always `r<n>`.
        case library(VisualID, name: String)
    }

    public static func url(_ target: Target) -> URL {
        var c = URLComponents()
        c.scheme = name
        switch target {
        case .page(let id, let r, let state, let size):
            c.host = id.rawValue
            c.percentEncodedPath = "/r\(r)/"
            var items: [URLQueryItem] = []
            if let state { items.append(URLQueryItem(name: "state", value: state)) }
            if let size { items.append(URLQueryItem(name: "size", value: size)) }
            if !items.isEmpty { c.queryItems = items }
        case .file(let id, let r, let path):
            c.host = id.rawValue
            c.percentEncodedPath = "/r\(r)/" + path.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
        case .library(let id, let name):
            c.host = id.rawValue
            c.percentEncodedPath = "/lib/" + encode(name)
        }
        return c.url!
    }

    /// The target `url` names, or nil for anything that is not exactly one of the three shapes:
    /// another scheme, a user, password or port, a fragment, a query on a file, an id that is not a
    /// usable `VisualID`, a revision folder that is not a canonical `r<n>`, or a component that
    /// decodes to a `/` or a NUL (an encoded slash must not become a separator the store sees).
    public static func parse(_ url: URL) -> Target? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == name,
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
              let host = c.host, let id = VisualID(rawValue: host) else { return nil }
        let raw = c.percentEncodedPath
        guard raw.hasPrefix("/") else { return nil }
        var parts: [String] = []
        for piece in raw.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(piece).removingPercentEncoding, !decoded.contains("/"), !decoded.contains("\0") else { return nil }
            parts.append(decoded)
        }
        guard parts.count >= 2 else { return nil }
        if parts[0] == "lib" {
            guard parts.count == 2, !parts[1].isEmpty, c.query == nil else { return nil }
            return .library(id, name: parts[1])
        }
        guard let r = revision(parts[0]) else { return nil }
        let path = parts.dropFirst().joined(separator: "/")
        if path.isEmpty {
            let items = c.queryItems ?? []
            return .page(id, r: r, state: items.first { $0.name == "state" }?.value,
                         size: items.first { $0.name == "size" }?.value)
        }
        guard c.query == nil else { return nil }
        return .file(id, r: r, path: path)
    }

    /// `r<n>` with a plain decimal `n`, the same rule `DiskVisualStore` lists revisions by.
    private static func revision(_ folder: String) -> Int? {
        guard folder.first == "r", let n = Int(folder.dropFirst()), n >= 0, "r\(n)" == folder else { return nil }
        return n
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~@")
        return set
    }()

    private static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }
}

/// One snapshot of a revision: `snapshot@<state>-<size>.png`.
public struct VisualSnapshotKey: Hashable, Sendable {
    public var state: String
    public var size: String
    public init(state: String, size: String) { self.state = state; self.size = size }
    public var fileName: String { "snapshot@\(state)-\(size).png" }

    /// A state or size name goes into a file name, and the names come from a manifest an agent
    /// wrote, so only `[A-Za-z0-9._-]`, not starting with a dot, at most 64 characters.
    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 64, name.first != "." else { return false }
        return name.utf8.allSatisfy { b in
            (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 45 || b == 95 || b == 46
        }
    }
}

/// Which snapshots a revision gets when it becomes final (spec §8, VisualRenderHost): every
/// declared state at the default size, then the default state at every other size. The default
/// of each is the first listed, or `default` when the manifest lists none. Not every pair: a
/// manifest with five states and four sizes is nine pictures, not twenty, and the pairs left out
/// are the ones nobody looks at.
public enum VisualSnapshotPlan {
    public static func keys(states: [String], sizes: [String]) -> [VisualSnapshotKey] {
        let s = unique(states.isEmpty ? ["default"] : states.filter(VisualSnapshotKey.isSafeName))
        let z = unique(sizes.isEmpty ? ["default"] : sizes.filter(VisualSnapshotKey.isSafeName))
        guard let state = s.first, let size = z.first else { return [] }
        var out = s.map { VisualSnapshotKey(state: $0, size: size) }
        out += z.dropFirst().map { VisualSnapshotKey(state: state, size: $0) }
        return out
    }

    public static func keys(for manifest: VisualManifest) -> [VisualSnapshotKey] {
        keys(states: manifest.states, sizes: manifest.sizes)
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

/// The width a named size draws at, in points. A manifest's sizes are names (`phone`, `mac`), a
/// bare width (`640`), or `<w>x<h>`; anything else is the default. Clamped, because the width
/// is a bitmap the app allocates.
public enum VisualSize {
    public static let defaultWidth = 760
    public static let range = 200...2400

    public static func width(_ name: String) -> Int {
        let named: [String: Int] = ["default": defaultWidth, "phone": 390, "compact": 390, "narrow": 390, "tablet": 768,
                                    "mac": 1024, "desktop": 1280, "wide": 1280]
        if let w = named[name.lowercased()] { return w }
        let head = name.lowercased().split(separator: "x", maxSplits: 1).first.map(String.init) ?? ""
        guard let w = Int(head) else { return defaultWidth }
        return min(max(w, range.lowerBound), range.upperBound)
    }
}

/// How many visual blocks may hold a live web view at once, and which goes back to its snapshot
/// when another needs one: the least recently used. A plan with twenty diagrams then runs at
/// most `limit` web content processes, not twenty.
public struct VisualLiveBudget<Key: Hashable> {
    public let limit: Int
    /// The live keys, least recently used first.
    public private(set) var live: [Key] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    public var hasRoom: Bool { live.count < limit }
    public func isLive(_ key: Key) -> Bool { live.contains(key) }

    /// `key` is live and the most recently used. Returns the key that had to go back to its
    /// snapshot to make room, if one did.
    @discardableResult
    public mutating func use(_ key: Key) -> Key? {
        if let i = live.firstIndex(of: key) {
            live.remove(at: i)
            live.append(key)
            return nil
        }
        var evicted: Key?
        if live.count >= limit { evicted = live.removeFirst() }
        live.append(key)
        return evicted
    }

    public mutating func release(_ key: Key) {
        live.removeAll { $0 == key }
    }
}
