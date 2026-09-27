import SwiftUI

/// Stub so this worktree compiles while Task 18 builds the real review sheet in parallel
/// (parallel-17-19-contract.md). At merge, Task 18's file replaces this one wholesale.
struct ReleaseReviewView: View {
    let store: SessionStore
    let intakeID: UUID
    let onClose: () -> Void

    init(store: SessionStore, intakeID: UUID, onClose: @escaping () -> Void) {
        self.store = store
        self.intakeID = intakeID
        self.onClose = onClose
    }

    var body: some View {
        Text("Release review")
    }
}
