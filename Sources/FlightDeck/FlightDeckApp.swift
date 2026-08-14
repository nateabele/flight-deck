import SwiftUI

@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences: PreferencesStore
    @StateObject private var store: SessionStore

    /// `-FlightDeckResetState YES`, the UITest's "start from a known slate" switch.
    ///
    /// It gates *both* stores. It used to cover only sessions, because `scripts/smoke.sh`
    /// deleted the whole defaults domain and so reset preferences as a side effect. That
    /// deletion also destroyed the developer's real sessions and preferences on every run, so
    /// it is gone — which means this flag now has to do the isolating itself.
    private static var isResettingState: Bool {
        UserDefaults.standard.bool(forKey: "FlightDeckResetState")
    }

    init() {
        // Constructed eagerly, unlike the store: this only reads `UserDefaults`, and both
        // the Settings scene and the store below need the *same* instance.
        //
        // A nil persistence is what makes a reset run hermetic: `PreferencesStore` then
        // starts from `Preferences()` and never writes back, so the test neither reads nor
        // clobbers the real `preferences.v1`.
        let preferences = PreferencesStore(
            persistence: Self.isResettingState ? nil : UserDefaultsPreferencesPersistence()
        )
        _preferences = StateObject(wrappedValue: preferences)

        // `wrappedValue` is an @autoclosure: this call is NOT evaluated here. That is
        // load-bearing for two unrelated reasons:
        //
        // 1. Constructing the store touches `GhosttyApp.shared`, which reads `NSApp.isActive`,
        //    and `NSApp` does not exist yet during `App.init`. SwiftUI evaluates the thunk
        //    later, once the app is up.
        // 2. `SessionStore.init` posts `.flightDeckStoreReady`, which is how `AppDelegate`
        //    finds the store it reaps every session through at quit. The delegate registers
        //    its observer in `applicationWillFinishLaunching` — *after* `App.init` — so an
        //    eagerly constructed store would post to nobody. `AppDelegate` now also falls back
        //    to `SessionStore.current` so that quit reaping does not silently become a no-op
        //    if this ever changes, but the ordering is still the primary path.
        //
        // Anyone tempted to construct the store here eagerly has to satisfy both.
        _store = StateObject(wrappedValue: Self.makeStore(preferences: preferences))
    }

    @MainActor
    private static func makeStore(preferences: PreferencesStore) -> SessionStore {
        let resetState = Self.isResettingState
        // Built here rather than inside the store: `UNUserNotificationCenter` traps
        // outside a signed bundle, and `SessionStore`'s convenience init is reachable
        // from tests (SessionPersistenceTests). This factory is not.
        //
        // Constructed and authorized BEFORE the store, then passed in, so `notifier` is
        // set before the convenience init's `startStatusWatching()` runs — see the
        // comment on that initializer.
        let notifier = SessionNotifier()
        notifier.requestAuthorization()

        // `preferences` is passed in rather than built here because the convenience init
        // restores sessions inline and resolves each one's flags as it goes, so it needs a
        // live store — and the Settings scene must observe that same instance.
        // A nil persistence under reset, for the same reason as `PreferencesStore` above and
        // one more: `resetState` suppresses *restore*, not *save*. The store seeds a session
        // and immediately persists it, so a reset run backed by the real
        // `FileSessionPersistence` overwrites the developer's own `sessions.json` with the
        // test's seed — which is precisely the data loss this whole change set is about.
        // Nil makes a reset run read nothing and write nothing.
        return SessionStore(
            ghostty: GhosttyApp.shared,
            resetState: resetState,
            preferences: preferences,
            notifier: notifier,
            // Passed in rather than assigned after construction for the same two reasons as
            // `notifier` above: `UNUserNotificationCenter` traps here too, and the
            // convenience init's launch-time orphan sweep reports through `reapReporter`
            // before this factory could ever assign it afterwards.
            reapReporter: UserNotificationReapReporter(),
            persistence: resetState ? nil : FileSessionPersistence()
        )
    }

    var body: some Scene {
        RootWindow(store: store, preferences: preferences)
            .commands {
                SessionCommands(store: store)
                EditCommands()
                TabNavigationCommands(store: store)
            }

        // A `Settings` scene gives ⌘, and the standard Preferences window for free.
        Settings {
            PreferencesView(preferences: preferences, sessions: store)
        }
    }
}
