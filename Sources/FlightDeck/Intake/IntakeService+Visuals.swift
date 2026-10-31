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

    /// The intake's visuals, nil until the store ships.
    func visualReader(_ id: UUID) -> (any VisualStoreReading)? { nil }

    /// `intake.visual.fetch`: a byte range of one revision's snapshot or bundle, as a
    /// `WireFileChunk`. Once real it refuses `unknown_visual`, `unknown_revision`, `bad_part`
    /// and `too_large` (over `VisualLimits.maxBytes`), and serves only files the revision's
    /// manifest lists.
    func phoneVisualFetch(_ id: UUID, visualID: String, revision: Int, part: String, offset: Int64,
                          limit: Int) -> Result<WireFileChunk, VisualRefusal> {
        .failure(Self.visualsRefusal)
    }
}
