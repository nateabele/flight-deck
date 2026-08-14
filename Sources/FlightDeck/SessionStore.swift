// Sources/FlightDeck/SessionStore.swift
import AppKit
import Foundation
import SwiftUI

/// Single source of truth for repos, sessions, selection, and live surfaces.
/// The sidebar and terminal pane render this and nothing else; only this type
/// creates or frees surfaces.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []

    /// Live activity per session, merged from two sources: the status registry supplies
    /// `activity`/`waitingFor`, the transcript watchers supply `subagentCount`.
    /// A session with no entry is absent from the map — that renders no icon, which is
    /// deliberately distinct from `.idle`.
    @Published private(set) var statuses: [UUID: SessionStatus] = [:]
    /// `didSet` persists every change, including one made through `SessionSidebar`'s
    /// `List(selection:)` binding — the only way selection actually changes in
    /// production, since that binding writes here directly rather than through
    /// `selectSession(_:)`. `persist()` never re-assigns `selectedSessionID`, so this
    /// cannot recurse.
    @Published var selectedSessionID: UUID? {
        didSet {
            if let id = selectedSessionID, let at = locate(id) {
                lastActiveProjectURL = URL(
                    fileURLWithPath: repos[at.repo].sessions[at.session].workingDirectory,
                    isDirectory: true
                )
            }
            persist()
        }
    }

    /// Weak: `GhosttyApp.shared` is a process-wide static that owns itself for the life of
    /// the process (see `GhosttyApp.shared`'s doc comment); the store must not co-own it.
    private weak var provider: SurfaceProvider?

    /// Live surfaces retained here (not by the SwiftUI view tree) so switching
    /// sessions re-parents rather than recreates. Dropping an entry frees it.
    private var surfaces: [UUID: Ghostty.SurfaceView] = [:]

    /// Which OS process each tab owns, for teardown. See `SurfaceProcessRegistry`.
    let processRegistry = SurfaceProcessRegistry()

    /// The process table the orphan sweep reads. Settable so tests can script it.
    var processInspector: ProcessInspecting = ProcessTree()

    /// Off-main-actor process teardown. See `SessionReaper`.
    private let reaper: SessionReaper
    var reapReporter: ReapReporting? = LoggingReapReporter()

    /// Surfaces whose tab is gone but whose process is still being killed.
    ///
    /// Holding the view here is what orders the teardown correctly: releasing it runs
    /// `ghostty_surface_free`, which joins libghostty's IO thread and spins in its own
    /// `killpg` loop *on the main actor*. Reaping first means that loop finds a dead child
    /// and returns at once instead of blocking the UI.
    private var parkedSurfaces: [UUID: Ghostty.SurfaceView] = [:]

    /// One transcript watcher per session, torn down with the session.
    private var watchers: [UUID: TranscriptWatcher] = [:]

    /// The one timer behind every watcher above, plus `statusWatcher`. Created lazily so a
    /// store built by a test that never starts watching never schedules anything; see
    /// `WatchClock` for why the app polls from a single coalesced source.
    ///
    /// It reads the store's `appIsActive` seam rather than `NSApplication` directly, so a
    /// test that needs the foreground (500 ms) cadence gets it from the same switch that
    /// already governs notification delivery. The closure re-reads the seam on every
    /// activation change, so assigning `appIsActive` after construction still takes effect.
    private lazy var clock = WatchClock(appIsActive: { [weak self] in
        self?.appIsActive() ?? false
    })

    /// Injectable so tests can point at a temp directory.
    var projectsRoot: URL = ClaudeSession.defaultProjectsRoot

    /// Injectable so tests can point at a temp directory.
    var sessionsRoot: URL = SessionStatusWatcher.defaultRoot

    /// Sub-agent counts kept separately so one arriving before the registry has been
    /// read is not lost, and so a registry refresh never clobbers it.
    private var subagentCounts: [UUID: Int] = [:]
    private var statusWatcher: SessionStatusWatcher?

    /// Which process each tab is following, keyed by tab id. Established the first time a
    /// registry row carries the tab's conversation, and thereafter the only thing consulted
    /// — see `ConversationPin.resolve`.
    private var anchors: [UUID: ConversationPin.Anchor] = [:]

    private var sessionCounter = 0

    /// The project of the most recently activated tab, used as ⌘N's target when there is
    /// no selection. Deliberately not cleared when the selection goes nil or when the
    /// project empties — surviving the tab leaving is the entire point.
    private(set) var lastActiveProjectURL: URL?

    private let persistence: SessionPersisting?

    /// Read at session-creation time only. Preferences configure *new* sessions; a
    /// running `claude` is never reconfigured, because its command line is already spent.
    private let preferences: PreferencesStore?

    /// Test seam. Production sets this from the convenience init.
    var notifier: Notifying?
    /// Test seam for frontmost-ness; production reads `NSApplication`.
    var appIsActive: () -> Bool = { NSApplication.shared.isActive }

    private var activationObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    init(
        provider: SurfaceProvider?,
        persistence: SessionPersisting? = nil,
        preferences: PreferencesStore? = nil,
        reaper: SessionReaper = SessionReaper(
            inspector: ProcessTree(), signals: PosixSignals(), sleeper: RealSleeper()
        )
    ) {
        self.provider = provider
        self.persistence = persistence
        self.preferences = preferences
        self.reaper = reaper
        observeActivationRequests()
        observeSurfaceClose()
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    /// `resetState` comes from the `-FlightDeckResetState YES` launch argument. The UITest
    /// bundle launches the app once per test case, so a session persisted by an earlier case
    /// would otherwise survive into a later one and make tests order-dependent. This argument
    /// is the *only* thing keeping the UI tests hermetic with respect to session state —
    /// `smoke.sh` deliberately no longer deletes stored state to achieve it, because doing so
    /// destroyed the user's real sessions on every run.
    /// `notifier` is assigned before `startStatusWatching()` runs, deliberately: the
    /// watcher's first drain is what can reach `deliverNotifications`, and that must never
    /// see a nil notifier land on a live `waiting` session at launch. It happens to be
    /// safe today even when the caller assigns `notifier` after construction (as
    /// `FlightDeckApp.makeStore()` used to) — `startStatusWatching()`'s first fire is an
    /// async main-queue hop that lands after this initializer returns — but that safety
    /// is incidental to the timer's current implementation, not guaranteed by this
    /// method's contract. Taking `notifier` as a parameter here removes the dependency on
    /// that timing.
    ///
    /// `preferences` is a parameter for a stricter reason: `restore()` below resolves each
    /// restored session's flags as it rebuilds it, so the store must already be readable by
    /// the time this initializer runs — assigning it afterwards would launch every restored
    /// session unconfigured.
    ///
    /// `persistence` is deliberately **not** defaulted: every caller has to say where state
    /// goes. This initializer seeds *and persists*, and `resetState` only suppresses the
    /// restore — so a caller that quietly got the real `FileSessionPersistence` would
    /// overwrite the developer's own `sessions.json` with a test seed. Passing `nil` means
    /// read nothing and write nothing, which is what a reset/UITest run wants.
    convenience init(
        ghostty: GhosttyApp?,
        resetState: Bool = false,
        preferences: PreferencesStore? = nil,
        notifier: Notifying? = nil,
        persistence: SessionPersisting?
    ) {
        self.init(
            provider: ghostty,
            persistence: persistence,
            preferences: preferences
        )
        self.notifier = notifier
        // Captured BEFORE `restore()`, which persists at the end and would otherwise replace
        // the previous run's records with this one's. The sweep itself is async and may land
        // well after that write; it works from this snapshot, not from disk.
        let previousRun = persistence?.load()
        if resetState || !restore() { seedInitialSession() }
        startStatusWatching()
        if let previousRun {
            Task { [weak self] in await self?.sweepOrphans(from: previousRun) }
        }
    }

    func seedInitialSession(
        homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        guard repos.isEmpty else { return }
        newSession(in: homeURL)
    }

    @discardableResult
    func newSession(in url: URL, at index: Int? = nil) -> Session {
        sessionCounter += 1
        let session = Session(
            title: "session \(sessionCounter)", workingDirectory: url.path
        )
        insertSession(
            session,
            in: url,
            initialInput: ClaudeSession.launchCommand(
                sessionID: session.id,
                title: session.title,
                flags: preferences?.resolvedFlags(forProject: url.path) ?? FlagSet()
            ),
            at: index
        )
        selectedSessionID = session.id
        persist()
        return session
    }

    /// ⌘N. Creates a session in the ACTIVE session's project, directly below it, and
    /// activates it. Returns nil when nothing is active — the caller routes that case to
    /// `addProject` instead (see `SessionCreateAction`).
    @discardableResult
    func newSessionBelowActive() -> Session? {
        guard let activeID = selectedSessionID, let at = locate(activeID) else { return nil }
        let active = repos[at.repo].sessions[at.session]
        let url = URL(fileURLWithPath: active.workingDirectory, isDirectory: true)
        return newSession(in: url, at: at.session + 1)
    }

    /// ⌘⇧A and folder drops. A new folder becomes a project; a known one gains another
    /// session. Either way the new session is appended to its project and activated.
    @discardableResult
    func addProject(at url: URL) -> Session {
        newSession(in: url)
    }

    /// The ⌘N / sidebar-button action. Routes to Add Project when nothing is open, which is
    /// why the menu item can stay enabled in both states.
    @discardableResult
    func createFromMenu(chooseFolder: () -> URL? = { FolderPicker.choose() }) -> Session? {
        switch SessionCreateAction.forState(hasProjects: !repos.isEmpty) {
        case .newSession:
            if let created = newSessionBelowActive() {
                return created
            }
            // `newSessionBelowActive` needs a selection, not just a non-empty `repos` — and
            // selection can be nil with sessions still present (e.g. clicking below the last
            // row in the sidebar's List clears it). Prefer the project the user was last
            // working in, *including* when it is now empty; only fall back to an arbitrary
            // project if we have never had one, and only prompt when nothing is open.
            if let url = lastActiveProjectURL, indexOfRepo(for: url) != nil {
                return addProject(at: url)
            }
            if let first = repos.first {
                return addProject(at: first.url)
            }
            guard let url = chooseFolder() else { return nil }
            return addProject(at: url)
        case .addProject:
            guard let url = chooseFolder() else { return nil }
            return addProject(at: url)
        }
    }

    /// ⌘⇧A. Always prompts, regardless of what is open.
    @discardableResult
    func addProjectFromMenu(chooseFolder: () -> URL? = { FolderPicker.choose() }) -> Session? {
        guard let url = chooseFolder() else { return nil }
        return addProject(at: url)
    }

    /// Folder drop. Each URL becomes a project with one session; the last is activated.
    /// A file resolves to its containing folder, so dropping a file out of a repo adds
    /// that repo — see `SessionCreateAction.projectDirectory(for:)`.
    @discardableResult
    func acceptDroppedURLs(_ urls: [URL]) -> Session? {
        var last: Session?
        for url in urls {
            last = addProject(at: SessionCreateAction.projectDirectory(for: url))
        }
        return last
    }

    /// Shared by `newSession` and `restore`. `initialInput` is the only difference:
    /// a fresh session starts `claude`, a restored one resumes it.
    @discardableResult
    private func insertSession(
        _ session: Session, in url: URL, initialInput: String, at index: Int? = nil
    ) -> Session {
        let repoIndex: Int
        if let existing = indexOfRepo(for: url) {
            repoIndex = existing
        } else {
            repos.append(Repo(url: url))
            repoIndex = repos.count - 1
        }
        // `index` is a position within this repo's sessions; out-of-range falls back to
        // appending so a stale index can never trap.
        if let index, index >= 0, index <= repos[repoIndex].sessions.count {
            repos[repoIndex].sessions.insert(session, at: index)
        } else {
            repos[repoIndex].sessions.append(session)
        }

        var config = Ghostty.SurfaceConfiguration()
        config.command = preferences?.resolvedShell() ?? ShellResolver.resolve()
        config.workingDirectory = url.path
        config.initialInput = initialInput
        config.environmentVariables = preferences?.sessionEnvironment() ?? [:]
        // Bracketed so the registry can identify the shell libghostty forks inside
        // `makeSurface`; libghostty exposes no pid of its own.
        let created = processRegistry.record(for: session.id) { provider?.makeSurface(config) }
        if let surface = created {
            surfaces[session.id] = surface
        }
        provider?.tick()

        startWatching(
            tabID: session.id,
            conversationID: session.pinnedConversationID,
            url: ClaudeSession.transcriptURL(
                sessionID: session.pinnedConversationID,
                workingDirectory: url.path,
                projectsRoot: projectsRoot
            )
        )
        return session
    }

    /// Rebuilds sessions from the last run. Returns false when there was nothing to
    /// restore, which is the caller's signal to seed a first session instead.
    /// Sessions whose working directory has since disappeared are dropped rather
    /// than resurrected as broken terminals.
    ///
    /// Kept internal rather than `private`: `SessionPersistenceTests` calls it directly
    /// to exercise restore in isolation, and `@testable import` only lifts `internal`
    /// access — a `private` method stays invisible even to `@testable` callers outside
    /// this file. Idempotency is guarded instead, on `repos.isEmpty`: a second call
    /// (there is no production path that makes one, but nothing stops a test or a
    /// future caller from trying) would otherwise re-insert every restored session on
    /// top of the ones already there.
    @discardableResult
    func restore(
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard repos.isEmpty else { return false }
        guard let snapshot = persistence?.load(), !snapshot.sessions.isEmpty else {
            return false
        }

        sessionCounter = snapshot.sessionCounter
        for entry in snapshot.sessions where directoryExists(entry.workingDirectory) {
            let url = URL(fileURLWithPath: entry.workingDirectory, isDirectory: true)
            let conversationID = entry.pinnedConversationID ?? entry.id
            let session = Session(
                id: entry.id,
                title: entry.title,
                workingDirectory: entry.workingDirectory,
                pinnedConversationID: conversationID
            )
            insertSession(
                session,
                in: url,
                initialInput: ClaudeSession.resumeCommand(
                    // The pinned conversation, not the tab's own id — a tab that resumed an
                    // existing conversation must keep following that one across relaunches.
                    sessionID: conversationID,
                    title: entry.title,
                    // Resolved per entry, from that entry's own working directory, so a
                    // restored session picks up its project's overrides rather than the
                    // first repo's.
                    flags: preferences?.resolvedFlags(forProject: entry.workingDirectory) ?? FlagSet()
                )
            )
        }

        let restoredIDs = repos.flatMap(\.sessions).map(\.id)
        selectedSessionID = snapshot.selectedSessionID.flatMap {
            restoredIDs.contains($0) ? $0 : nil
        } ?? restoredIDs.first
        persist()
        return !restoredIDs.isEmpty
    }

    /// Saved on every mutation rather than at terminate, so a crash cannot lose the list.
    private func persist() {
        var snapshot = SessionSnapshot(
            sessions: repos.flatMap(\.sessions).map {
                .init(
                    id: $0.id,
                    title: $0.title,
                    workingDirectory: $0.workingDirectory,
                    pinnedConversationID: $0.pinnedConversationID
                )
            },
            selectedSessionID: selectedSessionID,
            sessionCounter: sessionCounter
        )
        snapshot.processes = Dictionary(
            uniqueKeysWithValues: processRegistry.all.map { ($0.key.uuidString, $0.value) }
        )
        // Stamped on every save so the next launch can tell "this run is still going" from
        // "this run died and left its children behind".
        snapshot.owner = ProcessTree().identity(of: getpid())
        persistence?.save(snapshot)
    }

    /// No `persist()` call here: assigning `selectedSessionID` runs its `didSet`, which
    /// persists. Swift fires `didSet` on every assignment rather than only on a change, so
    /// this is covered even when re-selecting the already-selected tab. The explicit call
    /// that used to follow made every tab switch encode the snapshot twice and perform two
    /// synchronous atomic write-and-rename cycles on the main thread.
    func selectSession(_ id: UUID) {
        guard locate(id) != nil else { return }
        selectedSessionID = id
    }

    /// ⌘⇧] — moves the selection one session down the sidebar's visual order, wrapping to the
    /// top. ⌘⇧[ is the mirror image.
    func selectNextSession() { cycleSelection(forward: true) }

    /// ⌘⇧[. See `selectNextSession()`.
    func selectPreviousSession() { cycleSelection(forward: false) }

    /// The order is `repos.flatMap(\.sessions)` — the sidebar top to bottom, crossing project
    /// sections. Flattening is not a convenience: `moveSession` deliberately leaves an emptied
    /// source project standing, so the first repo can hold no sessions while live tabs sit in a
    /// later section, and anything reading through `repos.first` would walk off the live list.
    /// `closeSession` documents the same hazard.
    ///
    /// No-ops on an empty list, and a lone session wraps to itself. A `selectedSessionID` that
    /// names no live session is treated as no selection at all, which lands on the first
    /// session going forward and the last going backward — the same place a nil selection goes.
    ///
    /// Assigning `selectedSessionID` is the whole effect: its `didSet` persists the change and
    /// updates `lastActiveProjectURL`, so ⌘N after a tab switch already targets the newly
    /// active session's project.
    private func cycleSelection(forward: Bool) {
        let ordered = repos.flatMap(\.sessions)
        guard !ordered.isEmpty else { return }

        guard
            let current = selectedSessionID,
            let index = ordered.firstIndex(where: { $0.id == current })
        else {
            selectedSessionID = forward ? ordered.first?.id : ordered.last?.id
            return
        }

        let destination = forward
            ? ordered.indexWrapping(after: index)
            : ordered.indexWrapping(before: index)
        selectedSessionID = ordered[destination].id
    }

    func closeSession(_ id: UUID) {
        guard let (repoIndex, sessionIndex) = locate(id) else { return }
        repos[repoIndex].sessions.remove(at: sessionIndex)

        // Detach and park rather than release. Two reasons this is not just `= nil`:
        //
        // 1. `closeSession` never removed the view from its superview, so a *selected*
        //    tab's surface stayed retained by `TerminalHostView` until SwiftUI's next
        //    `updateNSView` pass (`TerminalPane.swift:40-42`). Detaching here makes the
        //    close immediate and independent of that pass.
        // 2. Releasing the view runs `ghostty_surface_free` on the main actor, which joins
        //    the IO thread and spins in libghostty's SIGHUP-only `killpg` loop
        //    (`vendor/ghostty/src/termio/Exec.zig:1152-1185`). We hold the view until our
        //    own reap has killed the tree, so that loop finds a dead child and returns.
        if let surface = surfaces.removeValue(forKey: id) {
            surface.removeFromSuperview()
            parkedSurfaces[id] = surface
        }
        let doomed = processRegistry.forget(id)

        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
        subagentCounts.removeValue(forKey: id)
        anchors.removeValue(forKey: id)
        // Closing the row is the most literal case of "a prompt that will never resolve",
        // and applyRegistry cannot observe the waiting -> gone edge here because both its
        // before and after snapshots already lack this id.
        notifier?.withdraw(sessionID: id)
        if repos[repoIndex].sessions.isEmpty {
            repos.remove(at: repoIndex)
        }
        if selectedSessionID == id {
            // The first *session*, not the first repo's first session: `moveSession`
            // deliberately leaves an emptied source project standing, so `repos.first` can
            // be empty while live tabs sit in a later section. Reading through it would
            // clear the selection and drop the whole app to the "No Session" empty state.
            selectedSessionID = repos.flatMap(\.sessions).first?.id
        }
        persist()

        Task { [weak self] in
            await self?.reapSession(id, process: doomed, context: "tab close")
        }
    }

    /// Kill a tab's process tree, then release its parked surface. Shared by tab close and
    /// app quit, which differ only in their budget and in who waits for them.
    func reapSession(_ id: UUID, process: SessionProcess?, context: String) async {
        if let process {
            let outcome = await reaper.reap(shell: process.identity, pgid: process.pgid)
            reapReporter?.report(outcome, context: context)
        }
        // Releasing last: the deferred `ghostty_surface_free` this triggers now has nothing
        // left to wait for.
        parkedSurfaces.removeValue(forKey: id)
    }

    /// Terminate processes recorded by a previous run that outlived it.
    ///
    /// Gated twice over: the recording instance must be gone (otherwise these are somebody
    /// else's live children, and killing them would be a second Flight Deck instance
    /// sabotaging the first), and each identity's start time must still match (otherwise the
    /// pid has been recycled and now belongs to an unrelated process).
    ///
    /// The pgid used to signal is re-derived from the live process table, never taken from
    /// `process.pgid` — the persisted value came out of JSON written by a previous boot and
    /// is not evidence about the current process table. A live process whose identity has
    /// just been confirmed to match is authoritative about its own process group; a number
    /// on disk is not. Re-deriving only after `isAlive` has passed means this is asking a
    /// process we have positively identified, not a stranger that happens to share a pid.
    func sweepOrphans(from snapshot: SessionSnapshot) async {
        guard let recorded = snapshot.processes, !recorded.isEmpty else { return }
        // Fails closed, not open: a snapshot whose provenance cannot be established (no
        // `owner`, e.g. a truncated/hand-edited file, a nil read at write time, or a future
        // writer that skips `persist()`) is left alone rather than swept. The identity gate
        // below cannot substitute for this — a live instance's own recorded children pass
        // `isAlive` by design, so matching identity is exactly what would make them killable
        // if this fell through.
        guard let owner = snapshot.owner else { return }
        if processInspector.isAlive(owner) { return }

        var cleaned = 0
        for (_, process) in recorded where processInspector.isAlive(process.identity) {
            // `pgid` is the live process's own answer, not the persisted one — see this
            // method's doc comment above. `reap` takes it as an `Optional` all the way
            // through so "we could not ask" and "killpg some sentinel group" are never
            // conflated; `nil` here makes `SessionReaper.deliver` signal the pid directly
            // instead of guessing.
            let livePgid = processInspector.pgid(of: process.identity.pid)
            let outcome = await reaper.reap(shell: process.identity, pgid: livePgid)
            reapReporter?.report(outcome, context: "orphan sweep")
            if outcome == .clean { cleaned += 1 }
        }
        if cleaned > 0 { reapReporter?.reportSweep(cleaned: cleaned) }
    }

    /// Test seam. Production leaves this nil and injection goes to the live surface.
    var injectorOverride: TextInjecting?

    /// Test seam. The default reads the resumed conversation's transcript off the main
    /// actor and calls back on it; tests substitute a synchronous closure so they need no
    /// expectations. The read is one-shot per resume and can touch a multi-megabyte file,
    /// which is why it does not run inline.
    var titleResolver: @MainActor (URL, @escaping @MainActor (String?) -> Void) -> Void = {
        url, done in
        Task.detached(priority: .userInitiated) {
            let title = ConversationTitle.resolve(transcriptAt: url)
            await done(title)
        }
    }

    func pinnedConversationID(of id: UUID) -> UUID? {
        guard let at = locate(id) else { return nil }
        return repos[at.repo].sessions[at.session].pinnedConversationID
    }

    /// Test seam: which tabs currently have a live `TranscriptWatcher`. `watchers` itself
    /// stays private; this exposes just enough to assert a closed tab's late `repin`
    /// completion did not resurrect one.
    var watchedSessionIDs: Set<UUID> { Set(watchers.keys) }

    /// Test seam, the other half of `watchedSessionIDs`: *which* transcript a tab is
    /// tailing. Presence alone cannot catch a watcher left behind on the pre-move or
    /// pre-repin path, which is the failure both of those paths exist to prevent.
    func watchedTranscriptURL(of id: UUID) -> URL? { watchers[id]?.url }

    func title(of id: UUID) -> String? {
        guard let at = locate(id) else { return nil }
        return repos[at.repo].sessions[at.session].title
    }

    /// Sidebar → Claude. Updates the title, then types `/rename <name>` into the pty
    /// so the *running* interactive session renames itself and records it.
    ///
    /// Return is sent *before* the paste as well as after. Without the leading one, whatever
    /// the user had half-typed in the input bar is still sitting there and `/rename <name>`
    /// is appended to it, producing a garbage prompt instead of a slash command. The leading
    /// Return submits that pending text (it is sent to Claude as a message, not discarded)
    /// and leaves an empty bar for the command.
    ///
    /// The command text and the Returns are sent separately, and that split is load-bearing.
    /// `sendText` is a *paste* in libghostty, and Claude Code enables bracketed-paste mode, so
    /// any line terminator inside the text is delivered between `\u{1b}[200~` and
    /// `\u{1b}[201~` and treated as pasted content — it lands in the input bar as a literal
    /// newline and never submits. Return has to arrive outside the paste, as a real key
    /// event. See `TextInjecting.sendReturn()`.
    func rename(_ id: UUID, to newTitle: String) {
        guard let at = locate(id),
              let name = ClaudeSession.sanitizedName(newTitle)
        else { return }

        repos[at.repo].sessions[at.session].title = name
        let injector = injector(for: id)
        injector?.sendReturn()
        injector?.sendText("/rename \(name)")
        injector?.sendReturn()
        persist()
    }

    /// Claude → sidebar. Applied from the transcript watcher; never injects.
    /// The equality check is the loop guard: a `custom-title` line caused by our own
    /// `rename` matches the title we already set and stops here.
    func applyExternalTitle(_ id: UUID, _ title: String) {
        guard let at = locate(id),
              let name = ClaudeSession.sanitizedName(title),
              repos[at.repo].sessions[at.session].title != name
        else { return }

        repos[at.repo].sessions[at.session].title = name
        persist()
    }

    /// Tabs sharing a conversation with another tab. Computed rather than stored so it can
    /// never go stale: `repos` is `@Published`, so any change to a pin or to the list
    /// re-evaluates this on the next view update.
    var conflictedSessionIDs: Set<UUID> {
        ConversationPin.conflicted(repos.flatMap(\.sessions))
    }

    func status(for id: UUID) -> SessionStatus? { statuses[id] }

    /// Starts registry polling. Called from the production convenience init only, so
    /// tests using `init(provider:persistence:)` never touch the real registry or spin
    /// a timer.
    func startStatusWatching() {
        guard statusWatcher == nil else { return }
        let watcher = SessionStatusWatcher(root: sessionsRoot, clock: clock) { [weak self] entries in
            self?.applyRegistry(entries)
        }
        watcher.start()
        statusWatcher = watcher
    }

    /// Rebuilds `statuses` from a registry scan and keeps each tab's anchor current.
    /// Entries for processes Flight Deck does not own are dropped: the registry lists
    /// every `claude` on the machine.
    func applyRegistry(_ rows: [pid_t: ClaudeStatusFile.Entry]) {
        // Resolve against a snapshot of the list before touching anything. Later tasks
        // apply repins and project moves here, and those mutate `repos` — iterating it
        // while it changes would resolve some tabs against a stale view.
        let resolutions: [(tab: UUID, resolution: ConversationPin.Resolution)] =
            repos.flatMap(\.sessions).map { session in
                (session.id, ConversationPin.resolve(
                    conversationID: session.pinnedConversationID,
                    workingDirectory: session.workingDirectory,
                    anchor: anchors[session.id],
                    rows: rows
                ))
            }
        for (tab, resolution) in resolutions {
            anchors[tab] = resolution.anchor
            guard let session = session(for: tab) else { continue }
            let repinned = resolution.conversationID != session.pinnedConversationID
            if repinned {
                repin(
                    tab,
                    to: resolution.conversationID,
                    transcriptDirectory: resolution.workingDirectory
                )
            }
            if !resolution.workingDirectory.isEmpty,
               Self.comparablePath(resolution.workingDirectory)
                   != Self.comparablePath(session.workingDirectory) {
                moveSession(
                    tab,
                    toProjectAt: URL(
                        fileURLWithPath: resolution.workingDirectory, isDirectory: true
                    ),
                    // A repin has already rebuilt the watcher, from the registry row's cwd
                    // — which is this same destination — and it is the authority on where
                    // `claude` writes. Restarting again here would start a second watcher
                    // for one tab, or (in production, where the repin's watcher starts only
                    // after an async title read) leave the later completion to displace it.
                    restartsWatcher: !repinned
                )
            }
        }

        var next: [UUID: SessionStatus] = [:]
        for session in repos.flatMap(\.sessions) {
            guard let anchor = anchors[session.id], let entry = rows[anchor.pid] else {
                continue
            }
            next[session.id] = SessionStatus(
                activity: entry.activity,
                waitingFor: entry.waitingFor,
                subagentCount: subagentCounts[session.id] ?? 0
            )
        }

        guard next != statuses else { return }
        // A session that HAD a status and no longer does means its `claude` exited.
        // Drop its sub-agent count too, so a later process reusing the same session
        // UUID does not inherit a count from the dead one. Counts for sessions that
        // never had a status are deliberately left alone — that is the
        // count-arrives-before-registry case.
        for id in statuses.keys where next[id] == nil {
            subagentCounts.removeValue(forKey: id)
        }
        let previous = statuses
        statuses = next
        deliverNotifications(previous: previous, current: next)
    }

    /// One notification decision per session, over the union of both snapshots so a
    /// session that vanished while waiting still gets its banner withdrawn.
    private func deliverNotifications(
        previous: [UUID: SessionStatus], current: [UUID: SessionStatus]
    ) {
        guard let notifier else { return }
        let active = appIsActive()
        for id in Set(previous.keys).union(current.keys) {
            switch SessionNotificationPolicy.action(
                old: previous[id], new: current[id], appActive: active
            ) {
            case .none:
                continue
            case .notify:
                guard let status = current[id], let title = title(of: id) else { continue }
                notifier.notify(sessionID: id, title: title, body: status.tooltip)
            case .withdraw:
                notifier.withdraw(sessionID: id)
            }
        }
    }

    /// Click-to-activate. The window ordering is the AppDelegate's job; this only moves
    /// the selection.
    private func observeActivationRequests() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: .flightDeckActivateSession, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?["sessionID"] else { return }
            let id = (raw as? UUID) ?? (raw as? String).flatMap(UUID.init(uuidString:))
            guard let id else { return }
            MainActor.assumeIsolated { self?.selectSession(id) }
        }
    }

    /// The shell exited (or a `close_surface` binding fired), so retire the tab it belonged to.
    ///
    /// libghostty posts this through `GhosttyApp.closeSurface`. Without it the row stayed in
    /// the sidebar pointing at a dead terminal — the surface would render its final frame
    /// forever and never accept input again.
    ///
    /// The notification's object is the `SurfaceView`, so the session is found by identity
    /// rather than by an id libghostty does not know about.
    private func observeSurfaceClose() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main
        ) { [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            MainActor.assumeIsolated {
                guard let self,
                      let id = self.surfaces.first(where: { $0.value === view })?.key
                else { return }
                self.closeSession(id)
            }
        }
    }

    /// Applied from a transcript watcher. Stored even when the registry has not yet
    /// reported this session, so the next `applyRegistry` picks it up.
    func applySubagentCount(_ id: UUID, _ count: Int) {
        guard subagentCounts[id] != count else { return }
        subagentCounts[id] = count
        guard var status = statuses[id] else { return }
        status.subagentCount = count
        statuses[id] = status
    }

    private func injector(for id: UUID) -> TextInjecting? {
        injectorOverride ?? surfaces[id]
    }

    func surface(for id: UUID) -> Ghostty.SurfaceView? { surfaces[id] }

    func tick() { provider?.tick() }

    // MARK: - Helpers

    /// The tab's `claude` switched conversations in place (an in-session `/resume`).
    ///
    /// Step order is load-bearing at the end: the title is resolved *before* the new
    /// watcher starts. `TranscriptWatcher` seeds its offset to the file's current size on
    /// its first look, so it will not replay history — but if it were started first, an
    /// old rename record could still land before the resolved title and overwrite it.
    private func repin(
        _ tabID: UUID, to conversationID: UUID, transcriptDirectory: String
    ) {
        guard let at = locate(tabID) else { return }

        // Refers to a prompt in a conversation this tab has left.
        notifier?.withdraw(sessionID: tabID)

        repos[at.repo].sessions[at.session].pinnedConversationID = conversationID

        // The old conversation's outstanding Agent ids can never be answered in the new
        // transcript, so the count would otherwise stick at its last value forever.
        // Only the backing count is reset, not `statuses`: the sole caller is
        // `applyRegistry`, which rebuilds `statuses` from these counts immediately after
        // and diffs the result against the pre-call snapshot to decide notifications.
        // Editing `statuses` here would corrupt that "before" picture.
        subagentCounts[tabID] = 0

        watchers[tabID]?.stop()
        watchers.removeValue(forKey: tabID)

        // Directory comes from the registry row, not the tab: a resumed conversation
        // carries its own project path, and the row is authoritative about where `claude`
        // is actually writing.
        let url = ClaudeSession.transcriptURL(
            sessionID: conversationID,
            workingDirectory: transcriptDirectory,
            projectsRoot: projectsRoot
        )
        titleResolver(url) { [weak self] title in
            // Two things can happen during a read that is a whole-file load: the tab can
            // close, and the tab can be repinned again (a second resume, or a fork).
            // `pinnedConversationID(of:)` covers both — it is nil for a closed tab, whose
            // completion would otherwise resurrect a `TranscriptWatcher` nothing will ever
            // stop again, and it differs for a re-repinned one, whose completion would
            // otherwise apply a superseded title and hand the tab a watcher tailing the
            // conversation it has already left. It is also what makes `startWatching`'s
            // unconditional `watchers[tabID] =` safe by construction.
            guard let self, self.pinnedConversationID(of: tabID) == conversationID else {
                return
            }
            if let title { self.applyExternalTitle(tabID, title) }
            // Only when nothing has re-watched this tab in the meantime. `repin` cleared
            // the entry, so a watcher being present means a project move landed during the
            // read and already pointed one at the tab's *newer* directory; `url` was built
            // from the pre-move one.
            if self.watchers[tabID] == nil {
                self.startWatching(tabID: tabID, conversationID: conversationID, url: url)
            }
        }

        persist()
    }

    /// Files a session under a different project, creating that project if it is new.
    ///
    /// Unlike `closeSession`, this does **not** prune a source project it empties: a
    /// project with no sessions is a legitimate sidebar state. (An empty project does not
    /// currently survive a relaunch, because `SessionSnapshot` stores only sessions and
    /// rebuilds `repos` from their `workingDirectory` — known, deferred.)
    ///
    /// The tab id does not change, so `selectedSessionID` needs no fixing up and SwiftUI
    /// animates the same row from one section to the other rather than recreating it.
    ///
    /// The watcher is restarted, because `Session.workingDirectory` is an input to
    /// `ClaudeSession.transcriptURL`: a tab that moved without one would keep tailing the
    /// transcript under its *old* encoded project directory and silently stop receiving
    /// renames and sub-agent counts — the exact failure a resume already causes for the
    /// conversation half. `restartsWatcher: false` is for the one caller that rebuilds the
    /// watcher itself; see `applyRegistry`.
    func moveSession(_ id: UUID, toProjectAt url: URL, restartsWatcher: Bool = true) {
        guard let at = locate(id) else { return }
        let target = url.standardizedFileURL
        guard Self.comparablePath(repos[at.repo].url.path)
                != Self.comparablePath(target.path) else { return }

        var session = repos[at.repo].sessions.remove(at: at.session)
        // Stored as reported, not as compared: the destination comes from the registry
        // row's `cwd`, and that exact string is what `claude` encodes into the transcript's
        // project directory name. Normalization is for deciding *whether* to move.
        session.workingDirectory = target.path

        // Resolved after the removal so the index cannot be stale. Removing a *session*
        // never removes a repo, so `at.repo` stays valid either way.
        let destination: Int
        if let existing = indexOfRepo(for: target) {
            destination = existing
        } else {
            repos.append(Repo(url: target))
            destination = repos.count - 1
        }
        repos[destination].sessions.append(session)

        if restartsWatcher {
            watchers[id]?.stop()
            startWatching(
                tabID: id,
                conversationID: session.pinnedConversationID,
                url: ClaudeSession.transcriptURL(
                    sessionID: session.pinnedConversationID,
                    workingDirectory: session.workingDirectory,
                    projectsRoot: projectsRoot
                )
            )
        }

        if selectedSessionID == id { lastActiveProjectURL = target }
        persist()
    }

    /// `tabID` keys our own state; `conversationID` is what the transcript is named after
    /// and what its rename records are stamped with. They differ after a resume.
    private func startWatching(tabID: UUID, conversationID: UUID, url: URL) {
        let watcher = TranscriptWatcher(
            sessionID: conversationID,
            url: url,
            clock: clock
        ) { [weak self] title in
            self?.applyExternalTitle(tabID, title)
        } onSubagentCount: { [weak self] count in
            self?.applySubagentCount(tabID, count)
        }
        watcher.start()
        watchers[tabID] = watcher
    }

    private func indexOfRepo(for url: URL) -> Int? {
        let target = Self.comparablePath(url.path)
        return repos.firstIndex { Self.comparablePath($0.url.path) == target }
    }

    /// The form in which two directory paths are compared for "same project".
    ///
    /// The two sides come from different places: `claude` reports `process.cwd()`, which
    /// `getcwd` has already resolved through symlinks, while Flight Deck stores whatever
    /// the folder picker or a drop handed it — `standardizedFileURL` collapses `.`/`..`
    /// but never follows a symlink. Comparing those raw makes a project reached through a
    /// symlink look like a different project, which files a duplicate repo and leaves an
    /// empty ghost behind on the first registry tick.
    ///
    /// `resolvingSymlinksInPath()` is a no-op for a path that does not exist on disk, so
    /// directories that are only ever named (tests, a project on an unmounted volume)
    /// still compare exactly as written.
    private static func comparablePath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func session(for id: UUID) -> Session? {
        guard let at = locate(id) else { return nil }
        return repos[at.repo].sessions[at.session]
    }

    private func locate(_ id: UUID) -> (repo: Int, session: Int)? {
        for (r, repo) in repos.enumerated() {
            if let s = repo.sessions.firstIndex(where: { $0.id == id }) {
                return (r, s)
            }
        }
        return nil
    }
}
