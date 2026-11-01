import FleetKit
import Foundation
import SwiftUI

/// What the loader needs from the fleet: one chunk of a revision's file or snapshot, or why not
/// (`intake.visual.fetch`). `FleetModel` is the real one.
@MainActor
protocol VisualFetching: AnyObject {
    func fetchVisual(
        intake: UUID, visualID: String, revision: Int, part: String, offset: Int64, limit: Int,
        then completion: @escaping (Result<WireFileChunk, FleetRequestError>) -> Void
    )
}

extension EnvironmentValues {
    /// Set once at the navigation root, beside `fileReader`. nil in a render or test that draws
    /// no visual, in which case a card shows its frame and no picture.
    @Entry var visualLoader: VisualLoader? = nil
}

/// Fetches a revision's files from the Mac a chunk at a time and puts them in the `VisualCache`.
///
/// **A file is only ever the whole listed file.** Chunks are stitched in order, the total must
/// equal the manifest's size, and the SHA-256 must match before the cache will take it, so a
/// half-finished or altered transfer yields nil and nothing is stored.
///
/// **Every call is for a file the ref lists.** The listed `sha256` and `size` are what a fetch is
/// checked against; a path the ref does not carry has nothing to be checked against and is not
/// asked for. The caller has already passed the `visuals` gate (`PlanReaderStyle.visualsAllowed`):
/// without it no segment is a `.visual`, so no card exists to call this.
@MainActor
final class VisualLoader {
    private weak var fetcher: VisualFetching?
    private let cache: VisualCache
    private let chunkSize: Int
    private let chunkDeadline: Duration
    /// Most files a revision may list; a hostile manifest cannot ask for a thousand fetches.
    static let maxFiles = 64
    private var inFlight: [VisualKey: Task<Data?, Never>] = [:]

    init(fetcher: VisualFetching, cache: VisualCache = .shared, chunkSize: Int = FileLimits.textChunk,
         chunkDeadline: Duration = .seconds(15)) {
        self.fetcher = fetcher
        self.cache = cache
        self.chunkSize = chunkSize
        self.chunkDeadline = chunkDeadline
    }

    /// The ref's file list if it is one the phone will fetch: present, non-empty, at most
    /// `maxFiles`, no negative size, and the sizes (added with overflow checked) within
    /// `VisualLimits.maxBytes`. Nothing is requested for a ref that fails.
    static func validFiles(_ ref: WireVisualRef) -> [WireVisualFile]? {
        guard let files = ref.files, !files.isEmpty, files.count <= maxFiles else { return nil }
        var total: Int64 = 0
        for file in files {
            guard file.size >= 0 else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(file.size)
            guard !overflow, sum <= Int64(VisualLimits.maxBytes) else { return nil }
            total = sum
        }
        return files
    }

    /// The cached bytes of a listed file, without a request.
    func cached(visualID: String, revision: Int, file: WireVisualFile) -> Data? {
        cache.data(for: VisualKey(visualID: visualID, revision: revision, path: file.path), sha256: file.sha256)
    }

    /// The listed file's bytes: from the cache, else fetched by `part` (`file:<path>` unless a
    /// snapshot part is given) and checked.
    func data(intake: UUID, visualID: String, revision: Int, file: WireVisualFile, part: String? = nil) async -> Data? {
        if let hit = cached(visualID: visualID, revision: revision, file: file) { return hit }
        let key = VisualKey(visualID: visualID, revision: revision, path: file.path)
        if let running = inFlight[key] { return await running.value }
        let task = Task { @MainActor [weak self] () -> Data? in
            guard let self else { return nil }
            let data = await self.fetch(intake: intake, visualID: visualID, revision: revision, file: file,
                                        part: part ?? WireVisualPart.file(file.path))
            self.inFlight[key] = nil
            return data
        }
        inFlight[key] = task
        return await task.value
    }

    /// A snapshot at `state` and `size` (the ref's first of each when nil). nil when the ref does
    /// not list that snapshot's file.
    func snapshot(intake: UUID, ref: WireVisualRef, state: String?, size: String?) async -> Data? {
        guard let files = Self.validFiles(ref) else { return nil }
        let name: String
        let part: String
        if let state, let size {
            name = "snapshot@\(state)-\(size).png"
            part = WireVisualPart.snapshot(state: state, size: size)
        } else if let first = files.first(where: { $0.path.hasPrefix("snapshot") }) {
            name = first.path
            part = WireVisualPart.snapshot
        } else {
            return nil
        }
        guard let file = files.first(where: { $0.path == name }) else { return nil }
        return await data(intake: intake, visualID: ref.id, revision: ref.revision, file: file, part: part)
    }

    /// Every listed file of the revision, so the live viewer can run with the network off.
    /// False if the ref lists none or any one fails.
    func ensureAll(intake: UUID, ref: WireVisualRef) async -> Bool {
        guard let files = Self.validFiles(ref) else { return false }
        for file in files {
            if await data(intake: intake, visualID: ref.id, revision: ref.revision, file: file) == nil { return false }
        }
        // The cache may have evicted an earlier file of this very revision to fit a later one;
        // success is only claimed for files that are still there for the handler to serve.
        return files.allSatisfy {
            cache.contains(VisualKey(visualID: ref.id, revision: ref.revision, path: $0.path), sha256: $0.sha256)
        }
    }

    private func fetch(intake: UUID, visualID: String, revision: Int, file: WireVisualFile, part: String) async -> Data? {
        guard file.size >= 0, file.size <= Int64(VisualLimits.maxBytes) else { return nil }
        var bytes = Data()
        while true {
            guard let fetcher else { return nil }
            let offset = Int64(bytes.count)
            // A deadline per chunk: a Mac that never answers must not leave `inFlight` stuck
            // for Retry to join. Whichever of reply and timer comes first resumes, once.
            let deadline = chunkDeadline
            let result: Result<WireFileChunk, FleetRequestError>? = await withCheckedContinuation { continuation in
                let once = ResumeOnce(continuation)
                let timer = Task { try? await Task.sleep(for: deadline); once.resume(nil) }
                fetcher.fetchVisual(intake: intake, visualID: visualID, revision: revision, part: part,
                                    offset: offset, limit: chunkSize) { once.resume($0); timer.cancel() }
            }
            // The reply must be for what was asked: this file, this offset, no more than the
            // limit, and the size the manifest promised.
            guard case .success(let chunk)? = result, chunk.offset == offset, chunk.path == file.path,
                  chunk.size == file.size, chunk.data.count <= chunkSize else { return nil }
            bytes.append(chunk.data)
            if Int64(bytes.count) > file.size { return nil }
            if Int64(bytes.count) == file.size { break }
            // A reply that adds nothing and is not the end would loop forever.
            if chunk.data.isEmpty { return nil }
        }
        let key = VisualKey(visualID: visualID, revision: revision, path: file.path)
        return cache.store(bytes, for: key, sha256: file.sha256) ? bytes : nil
    }
}

/// Resumes a continuation at most once, from whichever thread gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
    func resume(_ value: T?) {
        let c = lock.withLock { () -> CheckedContinuation<T?, Never>? in defer { continuation = nil }; return continuation }
        c?.resume(returning: value)
    }
}
