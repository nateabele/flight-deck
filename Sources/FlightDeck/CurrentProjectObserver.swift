import Combine
import Foundation

/// Republishes `SessionStore.currentProjectPath` only when it actually changes, so
/// `SessionCommands` — which deliberately does not observe `store` wholesale (see that type's
/// own doc comment) — can still rebuild its agent-order-dependent items when the active
/// project changes, without also rebuilding for every unrelated `SessionStore` mutation (a
/// title edit, an unread flag, the transcript watcher's 500ms poll).
///
/// Task 14 gave `SessionCommands` a File-menu item whose key equivalent captures `slot.agent`
/// at the time `body` is built. Before this task, agent ordering was project-independent, so
/// a stale `body` could not disagree with the current project about which agent ⌘N launches.
/// Now it can — switching the active project with no intervening `preferences` change left the
/// old, still-observed `body` in place, and ⌘N kept firing whatever agent the *previous*
/// project's order put first. This is what closes that gap.
///
/// `store.objectWillChange` fires from `willSet`, before the property that triggered it has
/// actually been written — reading `store.currentProjectPath` synchronously from that
/// notification would see stale `repos`/`selectedSessionID`/`lastActiveProjectURL`.
/// `.debounce(for: .zero, scheduler: RunLoop.main)` defers the read to the next run-loop turn,
/// by which every `didSet` from the triggering change — including `lastActiveProjectURL`'s own
/// update inside `selectedSessionID`'s `didSet` — has already completed.
@MainActor
final class CurrentProjectObserver: ObservableObject {
    @Published private(set) var path: String?
    private var cancellable: AnyCancellable?

    init(store: SessionStore) {
        path = store.currentProjectPath
        cancellable = store.objectWillChange
            .debounce(for: .zero, scheduler: RunLoop.main)
            .sink { [weak self, weak store] in
                guard let self, let store else { return }
                let updated = store.currentProjectPath
                if updated != self.path { self.path = updated }
            }
    }
}
