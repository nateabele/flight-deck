import Foundation
import FleetKit
import IntakeKit

/// `intake.visual.fetch`'s worker. V3 owns this file and fills `serve` in.
///
/// **Why a `nonisolated` enum and not a method on `IntakeService`.** `IntakeService` is
/// `@MainActor`, so an `async` method on it still runs on the main actor, and reading and
/// hashing up to `VisualLimits.maxBytes` there would hitch the UI. `FleetService` grabs the
/// reader on the main actor (`IntakeService.visualReader`, cheap) and awaits this, which runs
/// on the global executor.
enum VisualFetch {
    /// **The gate, shut until V4.** The detail's `visuals` flag stays off until V4 turns it on
    /// with the rest of the visual path, so a phone never sends this op; this is the same answer
    /// on the Mac's side, for a phone that sends it anyway. The serve logic below works and is
    /// tested with the gate open, and `FleetService` (which this stream may not touch) calls it
    /// with the default, so V4 flips one constant.
    nonisolated static let gateOpen = false

    /// A slice of one revision's snapshot (`part` `snapshot…`) or listed file (`file:<path>`) as a
    /// `WireFileChunk` whose `path` is the relative path and whose `size` is the whole file's.
    ///
    /// Refuses `visuals_unavailable` (gate shut, or no reader), `unknown_visual`,
    /// `unknown_revision`, `bad_part`, `bad_range`, `unknown_file` (not in the manifest's `files`),
    /// `too_large` (the revision's files add up to more than `VisualLimits.maxBytes`, §10) and
    /// `unreadable` (the store would not hand the bytes over: gone, a symlink, a hard link).
    ///
    /// **Everything is read through `VisualStoreReading.read`**, which returns bytes: this file
    /// never learns a path, so there is nothing here to reopen or escape the folder with.
    ///
    /// `probe` is a test seam, called inside the worker; a test asserts it ran off the main thread.
    nonisolated static func serve(
        _ reader: (any VisualStoreReading)?, visualID: String, revision: Int, part: String, offset: Int64,
        limit: Int, gateOpen: Bool = VisualFetch.gateOpen, probe: @Sendable () -> Void = {}
    ) async -> Result<WireFileChunk, VisualRefusal> {
        probe()
        guard gateOpen, let reader else { return .failure(.unavailable) }
        guard let id = VisualID(rawValue: visualID), !reader.revisions(id).isEmpty else {
            return .failure(VisualRefusal(code: "unknown_visual"))
        }
        guard let rev = reader.revision(id, r: revision) else { return .failure(VisualRefusal(code: "unknown_revision")) }
        guard let name = fileName(for: part, in: rev.manifest) else { return .failure(VisualRefusal(code: "bad_part")) }
        guard offset >= 0, limit > 0 else { return .failure(VisualRefusal(code: "bad_range")) }
        // The manifest is the allow-list. Membership is the whole check: `..`, an absolute path
        // or `manifest.json` match no entry, so none needs its own rule.
        guard let entry = rev.manifest.files.first(where: { $0.path == name }) else {
            return .failure(VisualRefusal(code: "unknown_file"))
        }
        let total = rev.manifest.files.reduce(Int64(0)) { $0 + $1.size }
        guard total <= Int64(VisualLimits.maxBytes) else { return .failure(VisualRefusal(code: "too_large")) }
        guard offset <= entry.size else { return .failure(VisualRefusal(code: "bad_range")) }
        guard let slice = reader.read(id, r: revision, name: name, offset: offset, limit: min(limit, FileLimits.maxChunk)) else {
            return .failure(VisualRefusal(code: "unreadable"))
        }
        return .success(WireFileChunk(path: name, size: slice.size, offset: offset, data: slice.data))
    }

    /// The revision-relative file a `part` names, or nil for a part this Mac does not know. A
    /// snapshot's name is its state and size (`snapshot@<state>-<size>.png`); plain `snapshot` is
    /// the first of each, or `snapshot.png` for a revision that declares neither.
    nonisolated static func fileName(for part: String, in manifest: VisualManifest) -> String? {
        if let path = WireVisualPart.filePath(in: part) { return path }
        if part == WireVisualPart.snapshot {
            guard let state = manifest.states.first, let size = manifest.sizes.first else { return "snapshot.png" }
            return "snapshot@\(state)-\(size).png"
        }
        let prefix = "snapshot@"
        guard part.hasPrefix(prefix) else { return nil }
        let rest = part.dropFirst(prefix.count)
        guard let dash = rest.lastIndex(of: "-"), dash != rest.startIndex, rest.index(after: dash) != rest.endIndex else { return nil }
        return part + ".png"
    }
}
