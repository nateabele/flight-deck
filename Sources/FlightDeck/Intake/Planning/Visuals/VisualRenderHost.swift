import AppKit
import IntakeKit
import WebKit

/// Draws a revision offscreen and takes its picture (spec §8): `WKWebView.takeSnapshot` on a web
/// view in a window no one sees, one PNG per `VisualSnapshotPlan` key, named
/// `snapshot@<state>-<size>.png`. It lives in the app because WebKit does; running it inside the
/// detached runner was rejected (spec §8).
///
/// **Where the pictures go.** `writeSnapshots(_:r:to:)` writes into the folder it is handed. In
/// P2a that is only ever a test's or a fixture's revision folder: the one writer of a real
/// intake's `visuals/` is ThreadRunner, which calls this in P2a-integration. The blocks use
/// `render` for pictures in memory (`VisualSnapshotCache`), which writes nothing.
///
/// **A parse error is a picture too.** The page draws Mermaid's message, so the snapshot shows the
/// same text the live block does (Review Focus 3); `Snapshot.status` says which it was.
///
/// One draw at a time: each is a web content process, and the plan's blocks ask for many.
@MainActor
final class VisualRenderHost {
    struct Snapshot {
        let key: VisualSnapshotKey
        let status: VisualRenderStatus
        let png: Data
        let pixelSize: CGSize
    }

    enum Failure: Error, Equatable {
        case noRevision, timedOut, noImage
    }

    let store: any VisualStoreReading
    private let library: @Sendable (String) -> Data?
    /// How long a page may take to say it is done. Mermaid draws a large diagram in well under a
    /// second; this is for a web content process that never answers.
    var timeout: Duration = .seconds(20)
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(store: any VisualStoreReading, library: @escaping @Sendable (String) -> Data? = { VisualSchemeHandler.bundledLibrary($0) }) {
        self.store = store
        self.library = library
    }

    /// Every snapshot the revision's manifest calls for, written into `folder` (created if
    /// needed). Returns them in plan order.
    func writeSnapshots(_ id: VisualID, r: Int, to folder: URL) async throws -> [Snapshot] {
        guard let revision = store.revision(id, r: r) else { throw Failure.noRevision }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var out: [Snapshot] = []
        for key in VisualSnapshotPlan.keys(for: revision.manifest) {
            let shot = try await render(id, r: r, key: key)
            try shot.png.write(to: folder.appendingPathComponent(key.fileName), options: .atomic)
            out.append(shot)
        }
        return out
    }

    /// One picture of revision `r` in `key`'s state at `key`'s size. Waits its turn behind any
    /// draw already running.
    func render(_ id: VisualID, r: Int, key: VisualSnapshotKey) async throws -> Snapshot {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        // Hands the turn straight to the next waiter, so `busy` never drops between two draws.
        defer { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
        return try await draw(id, r: r, key: key)
    }

    private func draw(_ id: VisualID, r: Int, key: VisualSnapshotKey) async throws -> Snapshot {
        guard store.revision(id, r: r) != nil else { throw Failure.noRevision }
        let width = CGFloat(VisualSize.width(key.size))
        let web = VisualWebView(store: store, frame: NSRect(x: 0, y: 0, width: width, height: 400), library: library)
        // In a window, never shown on screen: WebKit paints a view only while it is in one, and
        // `takeSnapshot` of a view that never painted is blank.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web.view
        window.orderFrontRegardless()
        defer {
            web.stop()
            window.orderOut(nil)
            window.contentView = nil
        }
        let status = try await waitForStatus(web) { web.show(id, r: r, state: key.state, size: key.size) }
        let reported: CGFloat
        switch status {
        case .rendered(_, let h), .failed(_, let h): reported = h
        case .loading: reported = 0
        }
        // The picture is as tall as what was drawn, within reason.
        let height = min(max(reported, 80), 4000)
        window.setContentSize(NSSize(width: width, height: height))
        web.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // A round trip through the page after the resize, so its layout is the new size's.
        _ = try? await web.view.evaluateJavaScript("document.documentElement.scrollHeight")
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
        config.afterScreenUpdates = true
        let image = try await web.view.takeSnapshot(configuration: config)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw Failure.noImage }
        return Snapshot(key: key, status: status, png: png, pixelSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    }

    private func waitForStatus(_ web: VisualWebView, start: () -> Void) async throws -> VisualRenderStatus {
        let timeout = timeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VisualRenderStatus, Error>) in
            var done = false
            let timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !done else { return }
                done = true
                continuation.resume(throwing: Failure.timedOut)
            }
            web.onStatus = { status in
                guard !done, status != .loading else { return }
                done = true
                timer.cancel()
                continuation.resume(returning: status)
            }
            start()
        }
    }
}

/// Pictures of revisions drawn by `VisualRenderHost` for the blocks, in memory: a block that is
/// off screen, or one that lost its live web view, shows one of these when the revision has no
/// stored snapshot. Shared by every editor, and bounded.
@MainActor
final class VisualSnapshotCache {
    static let shared = VisualSnapshotCache()

    struct Key: Hashable {
        /// Which intake's visuals (`VisualStoreIdentity`): two intakes may both have an `r1` of `flow`.
        let store: String
        let id: VisualID
        let r: Int
        let snapshot: VisualSnapshotKey
    }

    private var images: [Key: NSImage] = [:]
    private var order: [Key] = []
    private var inFlight: [Key: [(NSImage?) -> Void]] = [:]
    private var hosts: [String: VisualRenderHost] = [:]
    let capacity = 64

    func image(_ key: Key) -> NSImage? { images[key] }

    func put(_ image: NSImage, for key: Key) {
        if images[key] == nil { order.append(key) }
        images[key] = image
        while order.count > capacity { images[order.removeFirst()] = nil }
    }

    /// The cached picture, or one drawn now; `done` runs on the main actor once it is known.
    func fetch(_ key: Key, store: any VisualStoreReading, done: @escaping (NSImage?) -> Void) {
        if let image = images[key] { return done(image) }
        if inFlight[key] != nil { inFlight[key]?.append(done); return }
        inFlight[key] = [done]
        let host = hosts[key.store] ?? VisualRenderHost(store: store)
        hosts[key.store] = host
        Task { @MainActor in
            let shot = try? await host.render(key.id, r: key.r, key: key.snapshot)
            let image = shot.flatMap { NSImage(data: $0.png) }
            if let image { put(image, for: key) }
            let waiting = inFlight.removeValue(forKey: key) ?? []
            waiting.forEach { $0(image) }
        }
    }
}

/// A name for a store's contents, for keying what is drawn from it.
enum VisualStoreIdentity {
    static func of(_ store: any VisualStoreReading) -> String {
        if let disk = store as? DiskVisualStore { return disk.intakeDirectory.standardizedFileURL.path }
        return String(describing: type(of: store))
    }
}
