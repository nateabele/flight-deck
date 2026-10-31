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
    /// A slice of one revision's snapshot (`part` `snapshot…`) or listed file (`file:<path>`) as a
    /// `WireFileChunk` whose `path` is the relative path. Until V3 it refuses `visuals_unavailable`.
    /// Once real it refuses `unknown_visual`, `unknown_revision`, `bad_part` and `too_large`.
    ///
    /// `probe` is a test seam, called inside the worker; a test asserts it ran off the main thread.
    nonisolated static func serve(
        _ reader: (any VisualStoreReading)?, visualID: String, revision: Int, part: String, offset: Int64,
        limit: Int, probe: @Sendable () -> Void = {}
    ) async -> Result<WireFileChunk, VisualRefusal> {
        probe()
        return .failure(VisualRefusal.unavailable)
    }
}
