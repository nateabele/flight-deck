import AppKit
import Combine
import FleetKit
import OSLog
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

    private static let logger = Logger(
        subsystem: "dev.flightdeck.FlightDeck", category: "answer"
    )

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

    /// The search index, its backfill, and the overlay panel.
    ///
    /// Owned here rather than by `RootView` because the panel is a window, the backfill
    /// outlives any view, and the index file must be opened exactly once per launch.
    private var searchIndex: SQLiteSearchIndex?
    private var searchModel: SearchModel?
    private var searchPanel: SearchPanel?
    private var searchBuildTask: Task<Void, Never>?

    /// The shell's way into the answer drive, and the socket it listens on. Both nil unless
    /// `AnswerTrigger.isEnabled` — see that type for why this is off by default. Owned here
    /// for the reason the search index is: a socket outlives any view and must be opened
    /// exactly once per launch.
    private var answerTrigger: AnswerTrigger?
    private var answerTriggerSocket: AnswerTriggerSocket?

    /// Beside `sessions.json`, and honouring `-FlightDeckStateDir` for the same reason that
    /// flag exists: a debug instance pointed at a copy of a real deck must not also write
    /// into the real index.
    @MainActor
    private static func searchIndexURL() -> URL {
        (FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory())
            .appendingPathComponent("search-index.sqlite")
    }

    /// Beside the index, and honouring `-FlightDeckStateDir` for the same reason it does: two
    /// instances pointed at different decks must not share one socket, or a shell would drive
    /// whichever of them happened to bind first.
    @MainActor
    private static func answerTriggerURL() -> URL {
        (FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory())
            .appendingPathComponent("answer-trigger.sock")
    }

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
                if let store = note.object as? SessionStore {
                    self?.startSearch(store: store)
                    self?.startAnswerTrigger(store: store)
                    self?.startUsage(store: store)
                }
            }
        }
    }

    /// SwiftUI builds `NSApp.mainMenu` asynchronously, so it may not exist yet when the
    /// store-ready notification lands above — this is the second, order-independent attempt.
    /// `installToolsMenu` is idempotent, so trying twice just means one of the two calls does
    /// the real work.
    func applicationDidFinishLaunching(_ notification: Notification) {
        installToolsMenu()
        // Same order-independent retry `installToolsMenu` gets, and for the same reason: the
        // store can be constructed either side of this delegate registering its
        // `.flightDeckStoreReady` observer, so neither hop alone is guaranteed to see it.
        //
        // Search shipped without this and ⌘K was dead on arrival — silently, which is the whole
        // problem. `startSearch` is what registers the `.flightDeckOpenSearch` observer, so when
        // it never runs the menu item still renders, still shows its shortcut, and does nothing
        // at all. No unit test could catch it: every component was correct in isolation and the
        // only symptom is a key that does nothing in a launched app.
        //
        // `startSearch` guards on `searchIndex == nil`, so whichever hop arrives second is a
        // no-op rather than a second index handle and a doubled backfill.
        if let store = store ?? SessionStore.current {
            startSearch(store: store)
            startAnswerTrigger(store: store)
            startUsage(store: store)
        }
    }

    /// Starts Flight Control's usage meters. Reached from both store-ready hops for the reason
    /// `startSearch` is, and idempotent for the same reason (`UsageService.attach` guards).
    @MainActor
    private func startUsage(store: SessionStore) {
        guard let preferences = store.preferences, !UsageService.shared.isAttached else { return }
        UsageService.shared.attach(store: store, preferences: preferences)
    }

    /// Opens the answer trigger's socket, if this launch was told to.
    ///
    /// Reached from both store-ready hops for the reason `startSearch` is, and idempotent for
    /// the same reason: whichever arrives second must not bind a second listener over the
    /// first one's socket file.
    ///
    /// A socket that will not bind is logged and dropped rather than raised. This is a
    /// developer's diagnostic channel; an app that refused to finish launching because of one
    /// would be a far worse failure than the one it exists to diagnose.
    @MainActor
    private func startAnswerTrigger(store: SessionStore) {
        guard answerTriggerSocket == nil, AnswerTrigger.isEnabled() else { return }
        let trigger = AnswerTrigger(store: store)
        let socket = AnswerTriggerSocket(url: Self.answerTriggerURL()) { [weak trigger] line, reply in
            guard let trigger else { return reply(#"{"ok":false,"error":"stopped"}"#) }
            trigger.handle(line, then: reply)
        }
        do {
            try socket.start()
        } catch {
            Self.logger.error(
                "answer trigger failed to open its socket: \(String(describing: error), privacy: .public)"
            )
            return
        }
        answerTrigger = trigger
        answerTriggerSocket = socket
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

    /// What one backfill pass should do, decided from what discovery found rather than why it
    /// found it — the difference between an empty sidebar and a failed walk is the shape of
    /// the inputs, not a reason attached to the empty list.
    ///
    /// `SearchIndexBuilder.build` opens with a prune derived from the refs it is handed, so
    /// `build([])` deletes every already-indexed row. Asking every account of every agent
    /// gives discovery new ways to come back empty for reasons that have nothing to do with
    /// the user's history — an unreadable account home, an accounts list that is momentarily
    /// empty at launch, a filesystem hiccup — and `.skip` is what stops one of those from
    /// being read as "delete everything".
    enum BackfillPlan: Equatable {
        /// Build with these refs, empty included — correct only when the sidebar itself has
        /// no projects, so there is genuinely nothing left to keep.
        case build([TranscriptRef])
        /// Discovery came back empty while the sidebar still has projects. Leave the index
        /// alone; the next backfill gets another chance rather than pruning it to nothing.
        case skip
    }

    static func backfillPlan(projects: [String], refs: [TranscriptRef]) -> BackfillPlan {
        refs.isEmpty && !projects.isEmpty ? .skip : .build(refs)
    }

    /// The refs every agent contributes, as ONE list.
    ///
    /// One list, never one build per agent: `SearchIndexBuilder.build` opens with a prune
    /// that drops every source outside the set it is handed, so per-agent passes would take
    /// turns deleting each other's rows and leave an index that looks populated and is
    /// missing half its corpus.
    ///
    /// `corpus` is injectable rather than always `\.searchCorpus`, for the same reason
    /// `SearchIndexBuilder`'s own lookup is: a test proving an agent that answers nil is
    /// skipped needs such an agent to exist, and both real corpora are non-nil today.
    static func corpusRefs(
        projects: [String], accounts: [AgentAccount],
        corpus: (AgentID) -> AgentSearchCorpus? = { $0.searchCorpus }
    ) -> [TranscriptRef] {
        AgentID.allCases
            .compactMap(corpus)
            .flatMap { $0.transcripts(forProjects: projects, accounts: accounts) }
            .sorted { $0.modified > $1.modified }
    }

    /// Fills in a built-in-home fallback for any agent `live` holds no account for.
    ///
    /// A gap here is not necessarily a user with nothing to search: a real accounts list can
    /// also come back empty from a preferences-load race, or hold zero entries for an agent
    /// whose only login the user removed. Falling back to that agent's built-in home rather
    /// than asking nothing keeps the common single-login case working exactly as the
    /// single synthesized account this replaces did — this only narrows "always synthesize"
    /// down to "synthesize where `live` is silent".
    static func resolvedAccounts(_ live: [AgentAccount]) -> [AgentAccount] {
        AgentID.allCases.flatMap { agent -> [AgentAccount] in
            let mine = live.filter { $0.agent == agent }
            return mine.isEmpty
                ? [AgentAccount(agent: agent, displayName: "Default", home: agent.builtInHome)]
                : mine
        }
    }

    /// Fills in a name match's working directory and transcript path from the index, the same
    /// lookup `FleetService.openConversation` already does for the phone.
    ///
    /// `SearchCandidates.build` has no filesystem-cheap way to know either field for a
    /// conversation found by name rather than by transcript content — see its own
    /// `lastActivity` comment for why a stat-per-candidate is off the table — so both arrive
    /// here empty. Left empty, `SearchActivation.plan` passes them straight through:
    /// `CodexAdapter` sees no rollout and types a bare `codex`, starting an unrelated thread
    /// while the tab stays pinned to the conversation that was searched for, and a claude
    /// conversation that ran in a worktree resumes at the project root instead. `location`
    /// is the one index lookup that answers both, so a name match resumes exactly where a
    /// transcript hit on the same conversation already does.
    ///
    /// Only fills gaps: a transcript hit already carries both fields from the corpus walk
    /// itself, so this leaves those untouched rather than re-deriving them from a possibly
    /// stale index read.
    static func enrichedForActivation(
        _ result: SearchResult,
        location: (String) -> (workingDirectory: String, transcriptPath: String, agent: String)?
    ) -> SearchResult {
        guard let conversationID = result.conversationID,
              result.workingDirectory.isEmpty || result.transcriptPath.isEmpty,
              let found = location(conversationID)
        else { return result }
        return SearchResult(
            id: result.id, kind: result.kind, title: result.title, projectName: result.projectName,
            projectPath: result.projectPath, tier: result.tier, recency: result.recency,
            highlightedRanges: result.highlightedRanges, snippet: result.snippet,
            conversationID: result.conversationID, isContinuation: result.isContinuation,
            offset: result.offset, agent: result.agent,
            workingDirectory: found.workingDirectory, transcriptPath: found.transcriptPath
        )
    }

    /// Unlike `installToolsMenu`, not naturally idempotent: it opens a file handle, builds a
    /// panel, and registers a `.flightDeckOpenSearch` observer, none of which tolerate being
    /// done twice. The `searchIndex == nil` guard is therefore load-bearing rather than
    /// defensive — this is called from BOTH the `.flightDeckStoreReady` observer and
    /// `applicationDidFinishLaunching`, because the store can be built either side of the
    /// observer being registered and neither hop alone is guaranteed to see it. Whichever
    /// arrives second must be a no-op: without the guard it would leak the first index's
    /// `sqlite3*` handle (see `deinit`'s `_v2` comment for why a leaked-but-unclosed handle is
    /// only survivable, not free), double the backfill, and stack a second
    /// `.flightDeckOpenSearch` observer that would present the panel twice per ⌘K.
    @MainActor
    private func startSearch(store: SessionStore) {
        guard searchIndex == nil else { return }
        guard let index = try? SQLiteSearchIndex(at: Self.searchIndexURL()) else { return }
        let model = SearchModel(index: index, projects: { store.repos.map(\.url.path) })
        let panel = SearchPanel(model: model) { [weak store] result in
            guard let store else { return }
            let open = store.repos.flatMap(\.sessions).map {
                SearchActivation.ActiveSession(
                    id: $0.id, conversationID: $0.pinnedConversationID
                )
            }
            let activated = Self.enrichedForActivation(result) {
                try? index.transcriptLocation(forConversation: $0)
            }
            store.openConversation(SearchActivation.plan(
                for: activated, openSessions: open, projects: store.repos.map(\.url.path)
            ))
        }

        searchIndex = index
        searchModel = model
        searchPanel = panel

        // Set before `restore()` attaches this launch's sessions: `restore()` runs later in
        // the same `init` chain that just posted `.flightDeckStoreReady`, which is what this
        // method is responding to. `SessionStore.runtime(for:)` reads `searchIndex` live
        // rather than latching it at construction (see `ClaudeRuntime.init`), so the ordering
        // here is a nicety, not a requirement — but every session watched from launch
        // reporting into the index from its first message, rather than only sessions
        // attached after this line, is worth not leaving to that safety net.
        store.searchIndex = index

        NotificationCenter.default.addObserver(
            forName: .flightDeckOpenSearch, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentSearch() }
        }

        // Deferred off the launch path: a backfill parsing hundreds of megabytes must not
        // compete with restoring the deck and resuming its agents. Name search works from
        // the first keystroke regardless.
        let builder = SearchIndexBuilder(index: index)
        searchBuildTask = Task { [weak model] in
            try? await Task.sleep(for: .seconds(3))
            let projects = store.repos.map(\.url.path)
            let accounts = Self.resolvedAccounts(store.preferences?.preferences.liveAccounts ?? [])
            let refs = Self.corpusRefs(projects: projects, accounts: accounts)
            guard case .build(let refs) = Self.backfillPlan(projects: projects, refs: refs) else {
                return
            }
            await builder.build(refs) { progress in
                Task { @MainActor in
                    model?.indexingProgressChanged(progress)
                    // Mirrors the same progress into `FleetService`, so a phone searching
                    // mid-backfill gets the same "partial results" footer the desktop
                    // overlay shows — see `FleetService.indexingProgress`'s doc comment.
                    FleetService.current?.indexingProgress = progress
                }
            }
            await MainActor.run {
                model?.indexingProgressChanged(nil)
                FleetService.current?.indexingProgress = nil
            }
        }
    }

    @MainActor
    private func presentSearch() {
        guard let panel = searchPanel, let model = searchModel, let store = SessionStore.current,
              let host = SessionWindow.main
        else { return }
        model.candidatesChanged(SearchCandidates.build(
            repos: store.repos,
            conversations: (try? searchIndex?.conversationNames()) ?? [:],
            modified: { url in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            }
        ))
        panel.present(over: host)
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
