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
        isVisible = state.isVisible(at: .now)

        idleTask?.cancel()
        guard let deadline = state.idleDeadline() else { return }
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.isVisible = self.state.isVisible(at: .now)
        }
    }

    deinit { idleTask?.cancel() }
}
