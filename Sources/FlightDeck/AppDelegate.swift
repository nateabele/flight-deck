import AppKit
import Combine
import UserNotifications

/// App-level delegate: notification handling and the last-window-closed policy.
///
/// This type does NOT own libghostty. `GhosttyApp.shared` is a process-wide static that
/// owns itself for the life of the process, which is what keeps the deferred
/// `ghostty_surface_free` in `Ghostty.Surface.deinit` from racing a freed app. The
/// property below is a convenience handle, not ownership.
///
/// (The previous comment here claimed this type owned the libghostty app. Master
/// corrected the same stale claim in `RootView` and `SessionStore` in 6717cc5; this
/// file was missed. Corrected here since we are rewriting the file anyway.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    let ghostty: GhosttyApp? = GhosttyApp.shared

    /// The store the delegate does not own — see the type doc comment. Set from
    /// `.flightDeckStoreReady`, the same notification hop `flightDeckActivateSession` uses to
    /// bridge the same construction-order gap. `applicationShouldTerminate` falls back to
    /// `SessionStore.current` when this is nil, so quit reaping does not depend on that hop
    /// having landed.
    private weak var store: SessionStore?

    /// Owned here rather than by a SwiftUI scene: it inserts an AppKit menu into
    /// `NSApp.mainMenu`, which is app-level state with no SwiftUI owner. `lazy` rather than an
    /// eager default: `ToolsMenuController.init` is main-actor-isolated, and `AppDelegate`'s
    /// own (synthesized) init is not, so construction has to be deferred to first access from
    /// `installToolsMenu`, which is on the main actor.
    @MainActor
    private lazy var toolsMenu = ToolsMenuController()

    /// Watches `PreferencesStore.tools` so the menu stays in sync with edits made in the
    /// Settings window. Torn down implicitly on dealloc, same as any other `AnyCancellable`.
    private var toolsObserver: AnyCancellable?

    /// Registered before launch completes, which is required for the delegate to
    /// receive a click that launched or foregrounded the app. The store-ready observer is
    /// registered here rather than in `applicationDidFinishLaunching` for the same reason: a
    /// store created before launch completes must still be seen.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(
            forName: .flightDeckStoreReady, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.store = note.object as? SessionStore
                // The store can arrive after `applicationDidFinishLaunching` already tried
                // and bailed out for lack of one, so installation is retried from here too.
                self?.installToolsMenu()
            }
        }
    }

    /// SwiftUI builds `NSApp.mainMenu` asynchronously, so it may not exist yet when the
    /// store-ready notification lands above — this is the second, order-independent attempt.
    /// `installToolsMenu` is idempotent, so trying twice just means one of the two calls does
    /// the real work.
    func applicationDidFinishLaunching(_ notification: Notification) {
        installToolsMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Wires the Tools menu to the live store and its preferences. Safe to call more than
    /// once — see the two call sites above — because `install(in:)` removes any previous copy
    /// before inserting, and every closure assigned here is idempotent to reassign.
    @MainActor
    private func installToolsMenu() {
        // Same fallback as `applicationShouldTerminate`: the store-ready notification is not
        // guaranteed to have landed yet, so `SessionStore.current` covers the gap.
        let store = MainActor.assumeIsolated { self.store ?? SessionStore.current }
        guard let store else { return }
        guard let preferences = store.preferences else { return }

        toolsMenu.isEnabled = { [weak store] in store?.selectedSessionID != nil }
        // `.configured` — not a bare `ShellToolLauncher()` — so a Shell & Environment override
        // reaches menu-launched tools the same way it reaches session creation.
        toolsMenu.run = { [weak store] tool in
            guard let store else { return }
            ToolRunner.run(tool, store: store, launcher: ShellToolLauncher.configured(preferences))
        }
        // Shared with the overlay's ⌘-revealed sprocket — see `PreferencesOpener`, which
        // owns the pane-before-open sequencing this used to spell out inline.
        toolsMenu.openPreferences = { [weak preferences] in
            PreferencesOpener.open(preferences, tab: .tools)
        }
        toolsMenu.tools = preferences.tools

        toolsObserver = preferences.objectWillChange.sink { [weak self, weak preferences] _ in
            // `objectWillChange` fires BEFORE the mutation lands, so the read has to happen on
            // the next main-queue turn — and only reassign when the value actually changed, or
            // every unrelated preference edit would rebuild the menu.
            DispatchQueue.main.async { [weak self, weak preferences] in
                guard let self, let preferences else { return }
                if self.toolsMenu.tools != preferences.tools {
                    self.toolsMenu.tools = preferences.tools
                }
            }
        }

        if let mainMenu = NSApp.mainMenu { toolsMenu.install(in: mainMenu) }
    }

    /// Quitting used to kill nothing: the app just exited and left the kernel to SIGHUP each
    /// pty's foreground group, which anything ignoring SIGHUP survives. Now every session's
    /// tree is reaped first, under one total budget so quit cannot hang.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // `SessionStore.current` is the second, order-independent way to find the store. The
        // notification above only arrives because `FlightDeckApp` builds the store lazily, for
        // a reason that has nothing to do with this file; a future change constructing it
        // eagerly would post before the observer exists and quietly reduce quit to a no-op.
        // `assumeIsolated` rather than a hop: AppKit only calls this on the main thread, and
        // the reply below has to be arranged before returning.
        let store = MainActor.assumeIsolated { self.store ?? SessionStore.current }
        guard let store else { return .terminateNow }
        Task { @MainActor in
            await store.reapAllForQuit()
            // Exactly once, on every path: not calling this hangs the quit forever.
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension Notification.Name {
    /// Posted by `SessionStore.init` so the delegate can find the store it does not own.
    /// A notification hop for the same reason `flightDeckActivateSession` is one: the
    /// delegate is created by `@NSApplicationDelegateAdaptor` and the store by
    /// `FlightDeckApp.init`, with no ordering guarantee between them.
    static let flightDeckStoreReady = Notification.Name("FlightDeckStoreReady")
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Clicking a session notification brings Flight Deck forward and selects that
    /// session. The selection itself is the store's job, reached by notification because
    /// the delegate and the store are constructed independently.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let raw = response.notification.request.content.userInfo["sessionID"] as? String,
              let id = UUID(uuidString: raw)
        else { return }

        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(
            name: .flightDeckActivateSession, object: nil, userInfo: ["sessionID": id]
        )
    }
}
