import Foundation
import FleetKit
import IntakeKit

/// What a refused visual op says; `code` is the wire `err` code.
struct VisualRefusal: Error, Equatable, Sendable {
    let code: String
    /// Nonisolated, so `VisualFetch.serve` (off the main actor) can refuse with it.
    static let unavailable = VisualRefusal(code: "visuals_unavailable")
}

/// The visual blocks' entry points on the Mac (planning v2 §7, §10). V3 owns this file and
/// fills these in; until then the one op (`VisualFetch.serve`) refuses with `visuals_unavailable`, the detail's
/// `visuals` flag stays off so a phone never sends it, and nothing is read from `visuals/`.
extension IntakeService {
    static let visualsUnavailable = "visuals_unavailable"
    static var visualsRefusal: VisualRefusal { .unavailable }

    /// Whether this Mac serves visuals. The detail's `visuals` flag follows it.
    var visualsAvailable: Bool { false }

    /// The intake's visuals on disk: always a disk store, even before the intake has a
    /// `visuals/` folder, in which case it serves nothing until the folder appears. Always
    /// non-nil on purpose: the editor's hook (`PlanEditHooks.visuals`) takes this, and
    /// `DocumentPlan.==` ignores the hooks, so a reader that was nil at first render would stay
    /// nil. The renderer reads through it and never reaches into `IntakeDetailView` or the
    /// service itself.
    func visualReader(_ id: UUID) -> any VisualStoreReading {
        DiskVisualStore(tape: tapeStore(id))
    }
}
