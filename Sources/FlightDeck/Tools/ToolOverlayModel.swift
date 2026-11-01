import Foundation
import SwiftUI

/// Publishes `ToolOverlayVisibility` to SwiftUI, and schedules the one wake it needs.
///
/// Deliberately not a `WatchClock` subscriber: that clock exists to collapse *recurring* polls
/// into a single wakeup, while this wants one timer that fires once and is usually cancelled
/// before it does.
@MainActor
final class ToolOverlayModel: ObservableObject {
    @Published private(set) var isVisible = false

    private var state = ToolOverlayVisibility()
    private var idleTask: Task<Void, Never>?

    func mouseMoved() {
        state.mouseMoved(at: .now)
        refresh()
    }

    func keyPressed() {
        state.keyPressed()
        refresh()
    }

    func hoverChanged(_ inside: Bool) {
        state.hoverChanged(inside)
        refresh()
    }

    private func refresh() {
        publishVisibility()

        idleTask?.cancel()
        guard let deadline = state.idleDeadline() else { return }
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.publishVisibility()
        }
    }

    /// `@Published` announces on every write, equal value or not, and `refresh()` runs on every
    /// mouse move and key press: a bare assignment re-rendered the overlay's observers for each
    /// one. Only a real flip is written.
    private func publishVisibility() {
        let visible = state.isVisible(at: .now)
        if isVisible != visible { isVisible = visible }
    }

    deinit { idleTask?.cancel() }
}
