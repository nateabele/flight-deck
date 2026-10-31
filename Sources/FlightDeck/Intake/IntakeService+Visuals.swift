import Foundation
import FleetKit
import IntakeKit

/// What a refused visual op says; `code` is the wire `err` code.
struct VisualRefusal: Error, Equatable { let code: String }

/// The visual blocks' entry points on the Mac (planning v2 §7, §10). V3 owns this file and
/// fills these in; until then the one op refuses with `visuals_unavailable`, the detail's
/// `visuals` flag stays off so a phone never sends it, and nothing is read from `visuals/`.
extension IntakeService {
    static let visualsUnavailable = "visuals_unavailable"
    static var visualsRefusal: VisualRefusal { VisualRefusal(code: visualsUnavailable) }

    /// Whether this Mac serves visuals. The detail's `visuals` flag follows it.
    var visualsAvailable: Bool { false }

    /// The intake's visuals on disk: the disk store once the intake has a `visuals/` folder, nil
    /// before. The editor's hook (`PlanEditHooks.visuals`) takes this, so the renderer reads
    /// through it and never reaches into `IntakeDetailView` or the service itself.
    func visualReader(_ id: UUID) -> (any VisualStoreReading)? {
        let tape = tapeStore(id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: tape.visualsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return DiskVisualStore(tape: tape)
    }

    /// `intake.visual.fetch`: a byte range of one revision's snapshot or listed file, as a
    /// `WireFileChunk`. `async` so the real one can read and hash off the main actor, as
    /// `fileRead` does; the arm in `FleetService` already awaits it in a `Task`. Once real it
    /// refuses `unknown_visual`, `unknown_revision`, `bad_part` and `too_large` (over
    /// `VisualLimits.maxBytes`), and serves only files the revision's manifest lists
    /// (`DiskVisualStore.file`).
    func phoneVisualFetch(_ id: UUID, visualID: String, revision: Int, part: String, offset: Int64,
                          limit: Int) async -> Result<WireFileChunk, VisualRefusal> {
        .failure(Self.visualsRefusal)
    }
}
