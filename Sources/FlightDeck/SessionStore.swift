// Sources/FlightDeck/SessionStore.swift
import AppKit
import Foundation
import SwiftUI

/// One session's status edge across a single registry tick.
///
/// Three things act on these edges — the unread mark, notifications, and the auto-resume
/// prompt — and each used to re-walk the before/after maps itself. Computing the edges once
/// and handing them out means "what changed" has a single definition. A proper state machine
/// over `SessionActivity` is the next step and is recorded in docs/FOLLOWUPS.md; this is the
/// seam it would slot into.
struct StatusTransition: Equatable {
    let id: UUID
    let old: SessionStatus?
    let new: SessionStatus?
}

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
            // Activating a tab is what marks it read. Deliberately not gated on
            // `appIsActive()`: selecting a row is an explicit act, so it counts as looking
            // at it even if the window is not frontmost at that instant.
            if let id = selectedSessionID { unreadIdle.remove(id) }
            // Safety net against a stranded `renameRequest`: `SessionSidebar`'s Return
            // handler only sets it for a session with a rendered row, but the selection
            // it was issued for can still move out from under it afterward — collapsing
            // the project that owns the selected session, `cycleSelection` (⌘⇧[/⌘⇧])
            // landing on a session inside a collapsed project, or simply the user
            // clicking a different row before the request is consumed. Any selection
            // change, including one that reassigns the same id, clears the request, so
            // it can never outlive the selection state it was issued for. Swift fires
            // `didSet` on every assignment, not only on a change, which is exactly the
            // guarantee this leans on.
            renameRequest = nil
            persist()
        }
    }

    /// Sessions that finished while the user was not looking at them, rendered as the unread
    /// dot in the sidebar. See `SessionReadPolicy`.
    ///
    /// Held here rather than on `SessionStatus` for the same reason as `subagentCounts`:
    /// `applyRegistry` rebuilds every `SessionStatus` wholesale from the registry, so a field
    /// on that type would be clobbered on the next poll. This is view state about the user,
    /// not state `claude` reports.
    ///
    /// Persisted, as of the auto-resume work: what finished while you were away is exactly
    /// what you want to find when you come back, and quitting for the day is the longest
    /// "away" there is. Written by `persist()`, seeded by `restore()`.
    @Published private(set) var unreadIdle: Set<UUID> = []

    /// One-shot request channel for the keyboard rename path: the sidebar's `List` sets this
    /// on Return (it has the selection but no way to reach a specific row's private `@State`),
    /// the matching `SessionRow` observes it via `.onChange`, starts editing, and clears it
    /// back to `nil`. Double-click and the context menu skip this entirely — they already hold
    /// the row and call `beginRename()` directly.
    ///
    /// Transient signal, not durable state: never persisted, and deliberately absent from
    /// `SessionSnapshot`, so it does not appear in what `persist()` writes or `restore()` reads.
    @Published var renameRequest: UUID?

    /// The session whose rename field is currently open, or nil.
    ///
    /// Exists to stop the sidebar's Return-to-rename handler from eating the Return that
    /// COMMITS a rename. Measured: without it, typing a new name and pressing Return left the
    /// title unchanged, because the sidebar's Return handler claimed the key before the field's
    /// `onSubmit` ever saw it, and the smoke test's context-menu rename failed.
    ///
    /// The first-responder check in `SidebarInputMonitor` covers most of this on its own (an
    /// open field editor is not an `NSTableView`), but this flag is what makes the intent
    /// explicit and survives a focus state that has not settled yet. `SessionRow` clears it on
    /// commit, on Esc, on focus loss, and on teardown — all four matter, because a stranded
    /// value disables Return-to-rename for the rest of the process.
    ///
    /// Transient, like `renameRequest`: never persisted, never in the snapshot.
    @Published var renamingSessionID: UUID?

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

    /// This run's own identity, stamped into every snapshot as `owner`. Computed once: it
    /// cannot change for the life of the process, and `persist()` runs on every mutation —
    /// every tab switch, every rename, every registry tick.
    ///
    /// **It must read the real process table, never `processInspector`.** That property is a
    /// test seam, and `owner` is the interlock the launch sweep gates on: a snapshot whose
    /// `owner` is reported alive is left entirely alone. Routing this through the seam would
    /// let a test (or a future refactor tidying "duplicate" inspector use) stamp a fabricated
    /// owner into a real `sessions.json`, and the next launch would then either decline to
    /// sweep real orphans or — worse, if the fake identity is one that happens to be dead —
    /// sweep somebody else's live children. The one value in this file that must come from
    /// the operating system and nowhere else.
    private static let selfIdentity: ProcessIdentity? = ProcessTree().identity(of: getpid())

    /// The most recently constructed store.
    ///
    /// A fallback for `AppDelegate`, which normally learns about the store through
    /// `.flightDeckStoreReady`. That notification only reaches the delegate because
    /// `FlightDeckApp` happens to build the store inside a SwiftUI `@autoclosure`, deferred for
    /// an entirely unrelated reason (`NSApp` does not exist during `App.init`). Constructing it
    /// eagerly instead — a plausible "cleanup" — would post the notification before the
    /// delegate's observer exists, turning `applicationShouldTerminate` into an immediate
    /// `.terminateNow` that reaps nothing at all, silently, with no test failing. Weak so the
    /// store's lifetime is still owned by the `@StateObject` that holds it.
    static weak var current: SessionStore?

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

    /// Set the instant `reapAllForQuit` begins, before its first `await`. Nothing stops
    /// `statusWatcher`'s poll or the `WatchClock` timer while that reap is in flight — there
    /// is no `applicationWillTerminate` — so a tick can land mid-reap and see every tracked
    /// `claude` already gone. Every session's transition would then read `old != nil, new ==
    /// nil`, which `applyReadState` treats as "the process exited" and prunes the unread mark
    /// for, and the `persist()` at the end of `applyRegistry` would write `activity: nil,
    /// unread: nil` for every tab — erasing exactly the state the next launch's auto-resume
    /// needs to read back. `applyRegistry` returns immediately once this is set, so the state
    /// on disk is whatever the last real tick before quit left there.
    private var isTerminating = false

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
    private var appActivationObserver: NSObjectProtocol?

    /// Renames typed into the sidebar but not yet typed into `claude`, one per tab.
    /// See `flushPendingRename` for why an injection waits.
    private var pendingRenames: [UUID: String] = [:]

    /// Sessions restored from a snapshot that recorded them working, each mapped to the
    /// instant its prompt stops being worth sending. Drained by `flushPendingResumePrompts`
    /// on the registry tick, because a resumed `claude` takes seconds to boot and there is
    /// nothing to type into until it does.
    ///
    /// Internal rather than private so the tests can observe the queue without scripting a
    /// whole surface; nothing outside this type writes it.
    private(set) var pendingResumePrompts: [UUID: Date] = [:]

    /// Tabs with a `sendKillLine()` already out and a settle still pending. Guarding here,
    /// inside `inject` itself, rather than in each caller is load-bearing: `rename()` calls
    /// `flushPendingRename` straight off the user's keystroke with no interval to race
    /// against, unlike the registry tick's ~500ms poll against a 120ms settle. Without this a
    /// rename landing inside a prompt's settle window sends a second Ctrl+U into a viewport
    /// the first settle is still comparing against, and the prompt's settle then lands into a
    /// session the rename just made busy — exactly what the idle gate above exists to
    /// prevent, because it was evaluated before that second send, not after.
    private var injecting: Set<UUID> = []

    /// Test seam, in the style of `appIsActive` and `injectionSettle`. Production reads the
    /// wall clock.
    var now: () -> Date = { Date() }

    /// Test seam. Production pauses between killing the input line and reading the screen
    /// back, because Claude Code repaints asynchronously; tests run the continuation inline.
    var injectionSettle: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

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
        // Shell records land asynchronously, up to half a second after the tab they belong to
        // (see `SurfaceProcessRegistry`), so the `persist()` that `newSession`/`restore` already
        // ran is too early to contain them. Without this the snapshot names no shell for any
        // tab until some unrelated mutation happens to save again — and a crash before that
        // leaves the next launch's orphan sweep nothing to find.
        processRegistry.onChange = { [weak self] in self?.persist() }
        observeActivationRequests()
        observeSurfaceClose()
        observeAppActivation()
        // Two independent ways for `AppDelegate` to find the store it does not own, because
        // quit reaping silently does nothing if it finds neither — see `.flightDeckStoreReady`
        // and `SessionStore.current`.
        Self.current = self
        NotificationCenter.default.post(name: .flightDeckStoreReady, object: self)
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
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
        reapReporter: ReapReporting? = nil,
        persistence: SessionPersisting?
    ) {
        self.init(
            provider: ghostty,
            persistence: persistence,
            preferences: preferences
        )
        self.notifier = notifier
        // Before the sweep below, which reports through it.
        if let reapReporter { self.reapReporter = reapReporter }
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
        // A session landing in a collapsed project is otherwise invisible: `SidebarRow.rows`
        // renders only the header for a collapsed repo, so the new row exists in `repos` but
        // nothing in the sidebar shows it happened. Un-collapsing here — not in
        // `insertSession` — is deliberate: `restore()` calls `insertSession` directly rather
        // than going through `newSession`, precisely so a project's persisted collapsed state
        // survives relaunch undisturbed. Moving this expansion down into `insertSession` would
        // spring every restored collapsed project open on the next launch.
        if let target = indexOfRepo(for: url) {
            repos[target].isCollapsed = false
        }
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
    ///
    /// `url` decides only which project the tab is filed under. Both the shell's cwd and the
    /// watcher come from `session.transcriptDirectory`, and deliberately from the same field:
    /// `ClaudeSession.resumeCommand` runs `claude --resume <id>` in the shell's cwd and
    /// `claude` derives the transcript path from that same cwd, so the two disagreeing means
    /// watching a file the process it just started will never write. They differ from `url`
    /// for one caller — `restore`, rebuilding a tab that was last writing somewhere other
    /// than its project, a worktree being the usual reason — where
    /// starting the shell at the project would make `--resume` find no conversation and fall
    /// through to its `|| claude --session-id <id>` branch, losing the history.
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
        config.workingDirectory = session.transcriptDirectory
        config.initialInput = initialInput
        config.environmentVariables = preferences?.sessionEnvironment() ?? [:]
        // Wrapped so the registry can identify the shell libghostty forks for this surface;
        // libghostty exposes no pid of its own. The identification finishes asynchronously,
        // after `makeSurface` returns — see `SurfaceProcessRegistry`.
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
                workingDirectory: session.transcriptDirectory,
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
    /// That drop is harsher for a project than for a session: a session with a missing
    /// directory is just not rebuilt, but an *empty* project (nothing left in it but its own
    /// record in `SessionSnapshot.projects`) whose directory is missing is skipped entirely in
    /// pass one below, and the `persist()` at the end of this method then writes a snapshot
    /// that no longer mentions it. A project on an unmounted external or network volume is
    /// therefore not merely hidden until the volume returns — it is permanently forgotten by a
    /// single launch that happens to occur while the volume is offline. This matches the
    /// long-standing behavior for sessions and is not being changed here; a future fix would
    /// need to distinguish "genuinely deleted" from "temporarily unreachable" before pruning an
    /// empty project.
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
        guard let snapshot = persistence?.load() else { return false }
        // Projects outlive their sessions, so a snapshot can legitimately carry projects and
        // no sessions — the state you get after closing every session but no project. The
        // old "no sessions means nothing to restore" guard would have discarded it.
        let recorded = snapshot.projects ?? []
        guard !snapshot.sessions.isEmpty || !recorded.isEmpty else { return false }

        sessionCounter = snapshot.sessionCounter

        // One deadline for the whole restore, not one per session: they all resume together,
        // and staggering them by loop position would be noise.
        let autoResume = preferences?.autoResumesRunningSessions ?? false
        let promptDeadline = now().addingTimeInterval(Self.resumePromptWindow)

        // Pass one: seed the projects, in the recorded order, so the sessions below land in
        // existing repos rather than conjuring them in encounter order.
        for project in recorded where directoryExists(project.path) {
            let url = URL(fileURLWithPath: project.path, isDirectory: true)
            guard indexOfRepo(for: url) == nil else { continue }
            repos.append(Repo(url: url, isCollapsed: project.isCollapsed))
        }

        // Pass two: file the sessions. `insertSession` appends a repo for any working
        // directory pass one did not cover, which is what keeps a v1 snapshot working.
        for entry in snapshot.sessions where directoryExists(entry.workingDirectory) {
            let url = URL(fileURLWithPath: entry.workingDirectory, isDirectory: true)
            let conversationID = entry.pinnedConversationID ?? entry.id
            // Absent means the snapshot predates the split, when the one field meant both.
            let recorded = entry.transcriptDirectory ?? entry.workingDirectory
            // A worktree deleted between runs takes the tab's transcript directory with it.
            // The resumed `claude` is started in the project instead (see `insertSession`)
            // and will write its transcript there, so the tab has to be rebuilt as a
            // project-directory session outright — leaving the dead path in place would
            // start the watcher on a transcript nobody writes, persist it back out, and
            // leave the tab without titles or sub-agent counts until the first registry
            // tick happened to retarget it.
            let transcriptDirectory = directoryExists(recorded) ? recorded : entry.workingDirectory
            let session = Session(
                id: entry.id,
                title: entry.title,
                workingDirectory: entry.workingDirectory,
                transcriptDirectory: transcriptDirectory,
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
                    // Resolved per entry, from that entry's own *project* directory rather
                    // than from wherever `claude` was writing, so a restored session picks
                    // up its project's overrides rather than the first repo's — and a
                    // session restored inside a worktree still gets its project's, which
                    // resolving from the transcript directory would silently lose.
                    flags: preferences?.resolvedFlags(forProject: entry.workingDirectory) ?? FlagSet()
                )
            )
            // Seeded here rather than after the loop so it covers exactly the sessions that
            // were actually rebuilt — a session whose directory has gone has no row to draw a
            // mark on. Before the `selectedSessionID` assignment below on purpose: its
            // `didSet` clears the mark for the tab you land on, which is correct.
            if entry.unread == true { unreadIdle.insert(entry.id) }

            if autoResume,
               let activity = entry.activity.flatMap(SessionActivity.init(rawValue:)),
               Self.resumableActivities.contains(activity) {
                pendingResumePrompts[entry.id] = promptDeadline
            }
        }

        let restoredIDs = repos.flatMap(\.sessions).map(\.id)
        selectedSessionID = snapshot.selectedSessionID.flatMap {
            restoredIDs.contains($0) ? $0 : nil
        } ?? restoredIDs.first
        persist()
        // Projects count as "restored something": `SessionStore.init` reads this as
        // `if resetState || !restore() { seedInitialSession() }`, and seeding a home-directory
        // session on top of a restored project list would be wrong. (`seedInitialSession`
        // guards on `repos.isEmpty` too, so this is belt and braces — but the return value is
        // also read by tests, and it should mean what it says.)
        return !restoredIDs.isEmpty || !repos.isEmpty
    }

    /// Saved on every mutation rather than at terminate, so a crash cannot lose the list.
    private func persist() {
        // `var`, because the process table and owner stamp below are assigned after
        // construction. `projects` carries the sidebar order and collapse state, which the
        // session list alone cannot express.
        var snapshot = SessionSnapshot(
            sessions: repos.flatMap(\.sessions).map {
                .init(
                    id: $0.id,
                    title: $0.title,
                    workingDirectory: $0.workingDirectory,
                    // Written on every entry, not just the diverging ones: absence is
                    // reserved for pre-split snapshots, and a file that names each tab's
                    // transcript directory outright shows which sessions are running
                    // somewhere other than the project they are filed under — the state this
                    // whole split exists for.
                    transcriptDirectory: $0.transcriptDirectory,
                    pinnedConversationID: $0.pinnedConversationID,
                    // `nil` rather than a sentinel when no `claude` is registered: restore
                    // has to distinguish "was not running" from "was running and idle".
                    activity: statuses[$0.id]?.activity.rawValue,
                    // `nil` rather than `false` so the common case adds no noise to a file
                    // that is meant to stay readable.
                    unread: unreadIdle.contains($0.id) ? true : nil
                )
            },
            projects: repos.map { .init(path: $0.url.path, isCollapsed: $0.isCollapsed) },
            selectedSessionID: selectedSessionID,
            sessionCounter: sessionCounter
        )
        let processes = Dictionary(
            uniqueKeysWithValues: processRegistry.all.map { ($0.key.uuidString, $0.value) }
        )
        // `nil` rather than `{}` when there is nothing recorded. Equivalent in effect —
        // `sweepOrphans` returns early on either — and this file is meant to stay readable by
        // a human, which an empty object in every snapshot works against.
        snapshot.processes = processes.isEmpty ? nil : processes
        // Stamped on every save so the next launch can tell "this run is still going" from
        // "this run died and left its children behind".
        snapshot.owner = Self.selfIdentity
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

    /// Context-menu "Mark as Unread". `unreadIdle` is `private(set)`, so this is the sidebar's
    /// only way in.
    ///
    /// Deliberately does not special-case the *currently selected* session: `selectedSessionID`
    /// already removes an id from `unreadIdle` in its `didSet`, but only when that property is
    /// next assigned. Marking the active tab unread inserts it right back, and the dot
    /// typically stays up — even though the user is looking at that tab right now — until
    /// they navigate away and return, which reassigns `selectedSessionID` and clears it. That
    /// is not the *only* way it clears, though: `applyReadState` can also clear it sooner, if
    /// this session's status edges from working back to idle while it is still selected and
    /// the app is active — `SessionReadPolicy.change` returns `.clear` rather than `.mark` for
    /// exactly that edge when `isViewed` is true, because a running `claude` reporting it
    /// finished counts as the user having seen it too. Either way, marking here without a
    /// guard is intentional and matches Mail, where marking the open message unread sticks
    /// until something counts as having read it again; do not "fix" it by adding a guard here.
    ///
    /// Persists immediately, same as `rename(_:to:)`: unread marks are meant to survive a
    /// relaunch (see `unreadIdle`'s doc comment), so there is no "mark now, save later" here.
    func markUnread(_ id: UUID) {
        unreadIdle.insert(id)
        persist()
    }

    /// The order is `repos.flatMap(\.sessions)` — the sidebar top to bottom, crossing project
    /// sections. Flattening is not a convenience: both `closeSession` and `moveSession`
    /// deliberately leave an emptied project standing rather than pruning it, so the first repo
    /// can hold no sessions while live tabs sit in a later section, and anything reading through
    /// `repos.first` would walk off the live list.
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
        // Read, don't remove: the record has to survive until `reapSession` below has
        // actually confirmed the process is gone. See `reapSession`'s doc comment for why
        // forgetting it here — before the reap has even started — is the bug.
        let doomed = processRegistry.process(for: id)

        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
        subagentCounts.removeValue(forKey: id)
        anchors.removeValue(forKey: id)
        // The blanket intersection in `applyReadState` used to cover this implicitly. Now
        // that it only prunes what it saw disappear, a closed tab has to say so itself —
        // its id is in neither snapshot, so no tick will ever clean it up.
        unreadIdle.remove(id)
        // Closing the row is the most literal case of "a prompt that will never resolve",
        // and applyRegistry cannot observe the waiting -> gone edge here because both its
        // before and after snapshots already lack this id.
        notifier?.withdraw(sessionID: id)
        // The project deliberately stays, even emptied. A project's lifetime is explicit:
        // it appears when added or when a session lands in it, and is removed only by
        // `closeProject` — the sidebar's project close button. That also settles a
        // long-standing disagreement with `moveSession`, which has always left an emptied
        // source project standing.
        if selectedSessionID == id {
            // The first *session*, not the first repo's first session: this method just above
            // may have emptied `repos[repoIndex]` without removing it, and `moveSession` leaves
            // an emptied source project standing the same way — so `repos.first` can be empty
            // while live tabs sit in a later section. Reading through it would clear the
            // selection and drop the whole app to the "No Session" empty state.
            selectedSessionID = repos.flatMap(\.sessions).first?.id
        }
        persist()

        Task { [weak self] in
            await self?.reapSession(id, process: doomed, context: "tab close")
        }
    }

    /// Kill a tab's process tree, then release its parked surface. Shared by tab close and
    /// app quit, which differ only in their budget and in who waits for them.
    ///
    /// `processRegistry.forget` and the `persist()` that makes it stick happen here, only
    /// after the reap has run — never synchronously inside `closeSession`. `closeSession`
    /// used to forget the record immediately, which opened a window (up to the reap's own
    /// budget, worst case ~10 s) during which the doomed process existed in *no* record at
    /// all: gone from `processRegistry.all`, so `reapAllForQuit` would skip it, and already
    /// absent from the snapshot `closeSession`'s own `persist()` had just written, so the next
    /// launch's orphan sweep could not find it either. A quit or crash inside that window
    /// leaked the process permanently and invisibly — forgetting has to happen *after* the
    /// window closes, not before it opens.
    ///
    /// A consequence worth naming rather than hiding: quit and a tab's own close reap can now
    /// race the same session concurrently (quit sees the record because close hasn't forgotten
    /// it yet). That redundancy is benign, not invariant-violating — `SessionReaper.reap`'s
    /// `isAlive` gate makes a second reap of an already-dead target return `.clean` without
    /// signalling anything, and a second `forget`/`parkedSurfaces.removeValue` is a plain
    /// no-op. But the two ladders are genuinely independent: the actor serializes the calls,
    /// it does not deduplicate targets, so a session still alive when both race *can* receive
    /// the same signal twice from two separate `deliver` calls. That is fine because POSIX
    /// signals are idempotent, not because it cannot happen.
    ///
    /// The group to signal is re-derived here, from the live process table, exactly as
    /// `sweepOrphans` does — it is never carried on the record. Reading a pgid at record time
    /// races the child's own `setsid()`, and a read that wins that race captures Flight Deck's
    /// *own* process group and pins it to the session for the rest of its life: the self-group
    /// rail then downgrades every one of that session's signals to per-pid, silently, forever.
    /// A live process that has just passed the identity gate is the authority on its own group;
    /// nothing else is. That is why `SessionProcess` no longer carries a `pgid` at all.
    ///
    /// `forget` only fires on a confirmed-clean outcome. A budget expiry or an unkillable
    /// process reports `.survivors` — see this method's `if handled` below — and the
    /// record must stay exactly where it is, because "clean" here is the *only* signal this
    /// method has that the process is actually gone. Forgetting on `.survivors` would erase a
    /// still-live process from the one place (`processRegistry`, and therefore the persisted
    /// snapshot) that gives the next launch's orphan sweep a chance at it — reopening the same
    /// hole this method's window-closing fix above was written to close. `persist()` always
    /// runs regardless, because the snapshot must reflect whichever registry state is current
    /// — including "still recorded, because still alive" — not just the forgetting case.
    func reapSession(_ id: UUID, process: SessionProcess?, context: String) async {
        var handled = true
        if let process {
            let livePgid = processInspector.pgid(of: process.identity.pid)
            let outcome = await reaper.reap(shell: process.identity, pgid: livePgid)
            reapReporter?.report(outcome, context: context)
            handled = (outcome == .clean)
        }
        if handled { processRegistry.forget(id) }
        persist()
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
    /// The pgid used to signal is re-derived from the live process table. A number carried on
    /// the record would be evidence about some previous boot's process table, not this one —
    /// which is why `SessionProcess` carries none at all any more, and why `reapSession`
    /// re-derives on the live path too. A process whose identity has just been confirmed to
    /// match is authoritative about its own process group; nothing else is. Re-deriving only
    /// after `isAlive` has passed means this is asking a process we have positively identified,
    /// not a stranger that happens to share a pid.
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
        var survived = false
        // The map's keys are deliberately dropped. They are *previous-run tab ids*, and
        // `restore()` has already recreated this run's tabs under those very same UUIDs, each
        // with a live shell of its own recorded against them. Re-keying a survivor under its
        // old id would overwrite one of those live records — discarding a live process without
        // proof of death, and leaving it unreaped on close and on quit.
        for process in recorded.values where processInspector.isAlive(process.identity) {
            // `pgid` is the live process's own answer — see this method's doc comment above.
            // `reap` takes it as an `Optional` all the way through so "we could not ask" and
            // "killpg some sentinel group" are never conflated; `nil` here makes
            // `SessionReaper.deliver` signal the pid directly instead of guessing.
            let livePgid = processInspector.pgid(of: process.identity.pid)
            let outcome = await reaper.reap(shell: process.identity, pgid: livePgid)
            reapReporter?.report(outcome, context: "orphan sweep")
            if outcome == .clean {
                cleaned += 1
            } else {
                // A survivor of the *previous* run's sweep must not vanish once this run's
                // first unrelated `persist()` fires. `processRegistry` starts this run empty
                // (nothing here forked these children), so unless the survivor is put back
                // into it, the very next save anywhere in the app would silently drop the
                // one record that gives the *next* launch's sweep a chance at it.
                //
                // Under a fresh id: this is an orphan, not a tab. Nothing downstream reads the
                // key except `reapSession`'s `forget`, and a collision with a live tab's id
                // would be a live record destroyed. See the loop header above.
                processRegistry.keep(UUID(), as: process)
                survived = true
            }
        }
        if cleaned > 0 { reapReporter?.reportSweep(cleaned: cleaned) }
        if survived { persist() }
    }

    /// Total wall-clock budget for reaping every session at quit. Not per-session: quitting
    /// with twelve tabs open must not take twelve times as long. `nonisolated` because it is
    /// a plain `Sendable` constant referenced from `reapAllForQuit`'s default parameter value,
    /// which Swift evaluates outside this type's actor isolation — without this, the compiler
    /// warns (and Swift 6 mode errors) that a main-actor-isolated property cannot be read from
    /// that nonisolated context.
    nonisolated static let quitBudget: Double = 8.0

    /// What a resumed session is told. A constant rather than a preference: if the fixed
    /// string turns out to be wrong in practice, making it configurable is a smaller change
    /// than un-shipping a setting nobody wanted.
    static let resumePrompt = "Keep going"

    /// How long after a restore a pending prompt is still worth sending. Without a deadline
    /// an entry that never met its gates would sit in the queue and fire hours later, into a
    /// session the user has long since been working in.
    static let resumePromptWindow: TimeInterval = 120

    /// The activities that mean "this session was working when we went away". `waiting` is
    /// excluded: what it was blocked on does not survive the restart.
    static let resumableActivities: Set<SessionActivity> = [.busy, .shell]

    /// Reap every live session concurrently, returning when they are all done or the budget
    /// expires — whichever comes first. Survivors are left for the next launch's sweep: each
    /// `reapSession` call already forgets its own record on `.clean` and keeps it on
    /// `.survivors`, so there is nothing left for this method to do about the registry once
    /// the group above returns. It must not do anything either — a blanket
    /// `processRegistry.restore([:])` here would erase precisely the records a budget expiry
    /// (or an unkillable process) needs kept, undoing `reapSession`'s own bookkeeping the
    /// instant it finishes.
    ///
    /// The deadline races the *aggregate* of every reap, not the fastest one: the fan-out
    /// lives in a single child task nested inside its own group, so `group.next()` above it
    /// only resolves once every reap inside has finished (or the sibling deadline task wins
    /// first). An earlier draft raced the deadline against each reap individually — the first
    /// session to finish would win the outer `group.next()`, and the `cancelAll()` that
    /// followed cancelled every reap still in flight, so quitting with several tabs open
    /// reaped only one of them.
    func reapAllForQuit(budget: Double = SessionStore.quitBudget) async {
        // Before any `await` — see `isTerminating`'s doc comment for the race this closes.
        isTerminating = true
        let live = processRegistry.all
        guard !live.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withTaskGroup(of: Void.self) { inner in
                    for (id, process) in live {
                        inner.addTask { await self?.reapSession(id, process: process, context: "app quit") }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Closes every session in a project, then removes the project.
    ///
    /// Deliberately routed through `closeSession` per child rather than reimplementing the
    /// teardown: that method is where surface release, watcher shutdown, status and
    /// subagent-count removal, anchor removal, and notification withdrawal all live, and a
    /// second copy of that list would rot.
    func closeProject(_ id: Repo.ID) {
        guard let index = repos.firstIndex(where: { $0.id == id }) else { return }
        // Snapshot the ids first: `closeSession` mutates `repos`, so iterating the live
        // array would walk off the end.
        for sessionID in repos[index].sessions.map(\.id) {
            closeSession(sessionID)
        }
        // Re-found rather than reusing `index`: every `closeSession` above rewrote `repos`.
        repos.removeAll { $0.id == id }
        persist()
    }

    // MARK: Projects

    /// The sidebar's rendering order, flattened. Computed rather than stored so it cannot
    /// drift from `repos`; it is cheap, and `repos` is already `@Published`.
    var sidebarRows: [SidebarRow] { SidebarRow.rows(for: repos) }

    func setCollapsed(_ isCollapsed: Bool, forProjectAt id: Repo.ID) {
        guard let index = repos.firstIndex(where: { $0.id == id }),
              repos[index].isCollapsed != isCollapsed else { return }
        repos[index].isCollapsed = isCollapsed
        persist()
    }

    /// The sidebar's single `.onMove` target. The policy — what may move where — lives in
    /// `SidebarReorder`, which is tested without a store; this only applies the result.
    func moveSidebarRows(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let updated = SidebarReorder.apply(
            to: repos, rows: sidebarRows, from: source, to: destination
        ) else { return }
        repos = updated
        persist()
    }

    /// The one status a collapsed project header shows: the most demanding thing any child
    /// is doing. Idle and unstatused children contribute nothing, so a quiet project shows
    /// no glyph at all — the same "renders nothing" that an unstatused session row gets.
    ///
    /// The subagent count is deliberately dropped. `SessionStatusIcon` draws it beside the
    /// spinner, and the collapsed header already carries a number (the session count); two
    /// adjacent numerals read as two counts of the same thing.
    func collapsedStatus(forProjectAt id: Repo.ID) -> SessionStatus? {
        guard let repo = repos.first(where: { $0.id == id }) else { return nil }
        guard var best = repo.sessions
            .compactMap({ statuses[$0.id] })
            .filter({ $0.activity != .idle })
            .max(by: { $0.activity.summaryRank < $1.activity.summaryRank })
        else { return nil }
        best.subagentCount = 0
        return best
    }

    /// Test seam. Production statuses arrive through `applyRegistry`, which takes registry
    /// rows keyed by pid; a test that only cares about the sidebar's reading of a status
    /// should not have to fabricate those.
    func applyRegistryForTesting(_ next: [UUID: SessionStatus]) {
        statuses = next
    }

    /// Test seams. Production drives both from `applyRegistry`; a test that only cares about
    /// the prompt queue should not have to fabricate registry rows.
    func flushPendingResumePromptsForTesting() { flushPendingResumePrompts() }
    func cancelSupersededPromptsForTesting(_ transitions: [StatusTransition]) {
        cancelSupersededPrompts(transitions)
    }

    /// Test seam. Production marks come from `applyReadState` and from restore; a test that
    /// only cares about how a mark is *pruned* should not have to script an edge to create it.
    func markUnreadForTesting(_ ids: Set<UUID>) {
        unreadIdle.formUnion(ids)
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
    /// tailing. Presence alone cannot catch a watcher left behind on the pre-retarget or
    /// pre-repin path, which is the failure both of those paths exist to prevent.
    func watchedTranscriptURL(of id: UUID) -> URL? { watchers[id]?.url }

    func title(of id: UUID) -> String? {
        guard let at = locate(id) else { return nil }
        return repos[at.repo].sessions[at.session].title
    }

    /// Sidebar → Claude. Updates the title immediately, then types `/rename <name>` into
    /// the pty so the *running* interactive session renames itself and records it.
    ///
    /// The title lands here and now; only the injection can be deferred. A rename is
    /// therefore never lost, just occasionally late reaching `claude`.
    ///
    /// The command text and the Return are sent separately, and that split is load-bearing.
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
        persist()
        // One pending rename per tab, replaced rather than queued: renaming twice before
        // the injection lands should type the second name once, not both names in turn.
        pendingRenames[id] = name
        flushPendingRename(id)
    }

    /// Types `text` into a session's input box and submits it, preserving whatever draft was
    /// there. Returns false when this is a bad moment — nothing was sent, and the caller
    /// should leave its request pending and try again on a later tick.
    ///
    /// The gates, and why each one:
    ///
    /// - **Idle only.** While `busy` the text queues behind the running turn; while
    ///   `waiting` a Return answers a permission prompt or dialog instead of submitting;
    ///   `shell` means no `claude` is running at all, so the text would hit a bare shell.
    /// - **One row only.** Ctrl+U kills a single logical line and yank-pop *replaces* rather
    ///   than appends, so a draft spanning rows cannot be taken apart and put back.
    ///
    /// The kill happens *before* we know whether there was anything to kill, because that is
    /// the only way to find out: Claude Code renders its placeholder hint in exactly the same
    /// shape as a real draft (see `InputBar`), so the screen cannot be trusted to say whether
    /// the buffer is empty. Killing and then comparing measures the effect instead. A kill
    /// that changed nothing means the line was empty and there is nothing to restore —
    /// yanking there would paste the user's *previous* kill into the bar.
    ///
    /// The yank comes after the Return, so a wrong guess can only leave text sitting in the
    /// bar, never submit it. `sendText` and `sendReturn` are separate because a paste is not
    /// typing — see `TextInjecting.sendReturn()`.
    ///
    /// `stillWanted` is re-checked after the settle delay, because the request can be
    /// replaced or cancelled while Claude Code repaints. `onSent` runs once the text has been
    /// submitted, and is where the caller retires its pending entry.
    @discardableResult
    private func inject(
        _ text: String,
        into id: UUID,
        stillWanted: @escaping @MainActor () -> Bool,
        onSent: @escaping @MainActor () -> Void
    ) -> Bool {
        guard statuses[id]?.activity == .idle,
              let injector = injector(for: id),
              let viewport = injector.readViewport(),
              let bar = InputBar.read(fromViewport: viewport),
              bar.rows.count == 1
        else { return false }
        // See `injecting`'s doc comment: this is the one place both callers funnel through,
        // so it is the one place that can refuse a second injection for a tab that already
        // has one resolving.
        guard !injecting.contains(id) else { return false }

        injecting.insert(id)
        let before = bar.content
        injector.sendKillLine()
        // Claude Code needs a moment to repaint before the screen reflects the kill.
        injectionSettle { [weak self] in
            defer { self?.injecting.remove(id) }
            guard stillWanted() else { return }
            let after = injector.readViewport().flatMap(InputBar.read(fromViewport:))?.content
            injector.sendText(text)
            injector.sendReturn()
            // Restore only on a *confirmed* change. If the screen went unreadable we do not
            // know, and the draft is one Ctrl+Y away in Claude's own ring — better than
            // pasting text the user never typed into a bar that was empty.
            if let after, after != before { injector.sendYank() }
            onSent()
        }
        return true
    }

    /// Types a pending rename into a session, or leaves it pending if this is a bad moment.
    private func flushPendingRename(_ id: UUID) {
        guard let name = pendingRenames[id] else { return }
        inject(
            "/rename \(name)",
            into: id,
            // A second rename during the settle window replaces the first; typing the
            // superseded name would be wrong, and typing both in turn worse.
            stillWanted: { [weak self] in
                guard let self else { return false }
                return self.pendingRenames[id] == name
            },
            onSent: { [weak self] in self?.pendingRenames[id] = nil }
        )
    }

    /// Retries every deferred rename. Driven by the registry scan, which is what turns a
    /// deferral into a delay rather than a loss.
    private func flushPendingRenames() {
        for id in pendingRenames.keys { flushPendingRename(id) }
    }

    /// Types "Keep going" into every restored session that is finally ready for it.
    ///
    /// Driven by the registry scan for the same reason the rename retry is: a resumed
    /// `claude` needs seconds to boot, and until it registers there is nothing to type into.
    /// A tab that is not ready stays queued and is tried again on the next tick.
    private func flushPendingResumePrompts() {
        let currentTime = now()
        for (id, deadline) in pendingResumePrompts {
            guard currentTime < deadline else {
                // Dropped unsent. See `resumePromptWindow`.
                pendingResumePrompts.removeValue(forKey: id)
                continue
            }
            // A rename is a direct user action and wants the same input box. It will clear
            // itself within a tick or two, and this is queued anyway.
            guard pendingRenames[id] == nil else { continue }
            inject(
                Self.resumePrompt,
                into: id,
                // Cancelled during the settle window — the session started working on its
                // own, or the deadline passed on another path.
                stillWanted: { [weak self] in self?.pendingResumePrompts[id] != nil },
                onSent: { [weak self] in self?.pendingResumePrompts.removeValue(forKey: id) }
            )
        }
    }

    /// Drops a queued prompt for any session that has started working on its own.
    ///
    /// Covers both the user getting there first and a resumed `claude` picking its own turn
    /// back up: either way something is already in flight, and "Keep going" would be a second
    /// instruction on top of it. Conservative on purpose — a session that flickers through
    /// `busy` while booting loses its prompt, which is a silent no-op rather than a stray
    /// message typed into someone's work.
    private func cancelSupersededPrompts(_ transitions: [StatusTransition]) {
        guard !pendingResumePrompts.isEmpty else { return }
        for transition in transitions {
            switch transition.new?.activity {
            case .busy, .waiting:
                pendingResumePrompts.removeValue(forKey: transition.id)
            case .idle, .shell, nil:
                continue
            }
        }
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
        // Quitting: see `isTerminating`'s doc comment. A tick landing here reads an emptied
        // registry, not a real one — returning before even the `defer` below runs is
        // deliberate, so nothing prunes a mark or persists over the state auto-resume wants.
        guard !isTerminating else { return }
        // The scan is also the retry tick for deferred renames. `defer` because this method
        // returns early when nothing changed, and a rename usually waits on something that
        // never shows up in `statuses` at all — the user clearing their half-typed draft
        // moves no status, so gating the retry on a status change would strand it.
        defer {
            flushPendingRenames()
            // Same reason as the line above: this is the retry tick, and a prompt usually
            // waits on a `claude` that has not finished booting — which is not a status
            // change, so gating the retry on one would strand it.
            flushPendingResumePrompts()
        }

        // Resolve against a snapshot of the list before touching anything. Later tasks
        // apply repins and project moves here, and those mutate `repos` — iterating it
        // while it changes would resolve some tabs against a stale view.
        let resolutions: [(tab: UUID, resolution: ConversationPin.Resolution)] =
            repos.flatMap(\.sessions).map { session in
                (session.id, ConversationPin.resolve(
                    conversationID: session.pinnedConversationID,
                    // The transcript directory, not the project: this is the value echoed
                    // back when no row names one, and what comes back feeds
                    // `ClaudeSession.transcriptURL`. Passing the project would move a
                    // worktree session's watcher back onto the project's transcript the
                    // first time a row omitted its cwd.
                    transcriptDirectory: session.transcriptDirectory,
                    anchor: anchors[session.id],
                    rows: rows
                ))
            }
        // Two independent questions per tab, because a reported cwd now answers both: where
        // `claude` is writing (the transcript always follows it) and which project the tab
        // is filed under (it moves only into a project that is already open).
        for (tab, resolution) in resolutions {
            anchors[tab] = resolution.anchor
            guard let session = session(for: tab) else { continue }
            // Safe on every tick: it is the tab's own transcript directory echoed back when
            // no row named one, so the two branches below simply find nothing to do.
            let cwd = resolution.transcriptDirectory
            if resolution.conversationID != session.pinnedConversationID {
                // `repin` stores this same directory and rebuilds the watcher from it, so
                // the retarget below would stop and restart an identical watcher. `else`
                // rather than a second `if` keeps exactly one owner of "who repoints this
                // tab's watcher" per tick — which is the assumption the deferral in
                // `repin`'s async title-read completion is written against.
                repin(tab, to: resolution.conversationID, transcriptDirectory: cwd)
            } else if !cwd.isEmpty, cwd != session.transcriptDirectory {
                // Compared raw, deliberately, unlike the project comparison below:
                // `ClaudeSession.encodedProjectDirName` is a byte-for-byte encoding of this
                // exact string, so two paths that `comparablePath` calls equal (a symlink
                // and its target) name two different transcript files. Normalizing here
                // would leave a project opened through a symlink watching a path `claude`
                // never writes to.
                retarget(tab, to: cwd)
            }
            // `reportedDirectory`, emphatically not `cwd`: refiling a tab is the one decision
            // here that must fire only on new information. `cwd` is the echo above, so on a
            // tick that reported nothing — no rows at all, or a live row with an empty `cwd`
            // — it comes back naming the tab's *transcript* directory, and a tab whose
            // transcript is inside a worktree the user still has open as a project would be
            // refiled into it on no evidence at all. Before the split the echo was the tab's
            // own project and always compared equal, which is why this branch could read it.
            //
            // A cwd that matches no open project still creates nothing — that is what filed
            // a tab under a phantom project every time `EnterWorktree` ran. Moving into a
            // project that is *already* open remains allowed: the resumed-into-another-
            // project case §7 of the pinning design describes.
            if let reported = resolution.reportedDirectory,
               Self.comparablePath(reported) != Self.comparablePath(session.workingDirectory),
               let destination = indexOfRepo(
                   for: URL(fileURLWithPath: reported, isDirectory: true)
               ) {
                // The repo's own recorded path, not the row's cwd: they differ when the
                // project was opened through a symlink, and filing the tab under the
                // resolved path would leave `Repo.url` and `Session.workingDirectory`
                // disagreeing about the project they both name.
                moveSession(tab, toProjectAt: repos[destination].url)
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
        let transitions = Set(previous.keys).union(next.keys).map {
            StatusTransition(id: $0, old: previous[$0], new: next[$0])
        }
        applyReadState(transitions)
        deliverNotifications(transitions)
        cancelSupersededPrompts(transitions)
        // Below the `guard next != statuses` above, so this writes only on a real
        // transition — a handful of small atomic writes a minute, not one per poll.
        // Recording activity here rather than at quit is what covers a SIGKILL (which is
        // how scripts/swap-release.sh stops the app) and a panic, and an unplanned exit is
        // the case auto-resume is most wanted for.
        persist()
    }

    /// One read/unread decision per session, over every edge this tick produced.
    private func applyReadState(_ transitions: [StatusTransition]) {
        let active = appIsActive()
        for transition in transitions {
            switch SessionReadPolicy.change(
                old: transition.old, new: transition.new,
                isViewed: active && selectedSessionID == transition.id
            ) {
            case .none:
                continue
            case .mark:
                unreadIdle.insert(transition.id)
            case .clear:
                unreadIdle.remove(transition.id)
            }
        }

        // Prune only what actually went away this tick. A blanket intersection against the
        // live statuses looks equivalent and is not: at launch `statuses` is empty until each
        // resumed `claude` re-registers, so it wiped every mark restore had just seeded,
        // before any of them had a chance to be viewed. A mark for a session that has never
        // had a status is waiting for its process to appear, not stale.
        //
        // The prune below — dropping a session's unread mark the moment its status goes
        // back to nil — was originally justified by "SessionStatusIcon renders nothing for
        // a nil status, so the entry has no icon left to carry the mark and would leak
        // invisibly." That justification no longer holds: SessionStatusIcon now renders an
        // unread dot for a nil status too, when `unread` is true (see its `else if unread`
        // branch). An unread, statusless session IS drawn today. The prune's behavior is
        // deliberately left UNCHANGED here regardless — whether unread marks should still
        // be dropped on this transition is a separate, user-facing call, out of scope for
        // this branch and already raised with the user separately. What is recorded here is
        // that the rule below is now kept without the reason that originally motivated it,
        // pending a deliberate decision, not that the rule has been re-justified.
        for transition in transitions where transition.old != nil && transition.new == nil {
            unreadIdle.remove(transition.id)
        }
    }

    /// One notification decision per session, over every edge this tick produced — so a
    /// session that vanished while waiting still gets its banner withdrawn.
    private func deliverNotifications(_ transitions: [StatusTransition]) {
        guard let notifier else { return }
        let active = appIsActive()
        for transition in transitions {
            switch SessionNotificationPolicy.action(
                old: transition.old, new: transition.new, appActive: active
            ) {
            case .none:
                continue
            case .notify:
                guard let status = transition.new, let title = title(of: transition.id)
                else { continue }
                notifier.notify(sessionID: transition.id, title: title, body: status.tooltip)
            case .withdraw:
                notifier.withdraw(sessionID: transition.id)
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

    /// Returning to the app marks the tab you return *to* as read.
    ///
    /// Distinct from `observeActivationRequests`, which handles an explicit click on a
    /// notification. This covers the ordinary case: a session finished while you were in
    /// another app, you ⌘-tab back, and the tab you are already looking at should not keep
    /// telling you there is something new in it.
    private func observeAppActivation() {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.selectedSessionID else { return }
                self.unreadIdle.remove(id)
            }
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
        // Stored, not just used below: a resumed conversation carries its own directory, and
        // the next tick compares the row's cwd against this field to decide whether anything
        // moved. Leaving it at the pre-resume value would make that comparison fire a
        // pointless retarget on every subsequent tick.
        repos[at.repo].sessions[at.session].transcriptDirectory = transcriptDirectory

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
            // Only when nothing has re-watched this tab in the meantime. `repin` cleared the
            // entry, so a watcher being present means a `retarget` landed during the read
            // and already pointed one at the tab's *newer* directory; `url` was built from
            // the pre-retarget one. A project move cannot be the cause: `moveSession` stopped
            // touching watchers when the transcript path stopped depending on the project.
            if self.watchers[tabID] == nil {
                self.startWatching(tabID: tabID, conversationID: conversationID, url: url)
            }
        }

        persist()
    }

    /// The tab's `claude` changed directory without changing conversation — a plain `cd`, or
    /// the case this exists for: `EnterWorktree` moving it into
    /// `<project>/.claude/worktrees/<name>`.
    ///
    /// Only the transcript follows. The project the tab is filed under deliberately does not
    /// change, because a worktree is not another project — see `applyRegistry`. The watcher
    /// must follow, though: `claude` names the transcript's directory after its live cwd, so
    /// the old watcher is now tailing a file nothing will ever append to, and the tab would
    /// stop receiving renames and sub-agent counts with nothing to show for it.
    ///
    /// Unlike `repin` there is no title read to defer to: the conversation is the same one,
    /// so its title is already correct and only the path it is written at has moved. The
    /// sub-agent count *is* reset like a repin's, though — see below.
    private func retarget(_ tabID: UUID, to directory: String) {
        guard let at = locate(tabID) else { return }
        repos[at.repo].sessions[at.session].transcriptDirectory = directory
        let conversationID = repos[at.repo].sessions[at.session].pinnedConversationID

        // Same reasoning as `repin`, and for the same reason it is only the backing count:
        // the new watcher starts with an empty `outstandingAgents`, so an `agentFinished`
        // for an id the old one was tracking is a no-op and `countChanged` never fires. The
        // badge would sit at its pre-retarget value until some later turn boundary with a
        // non-empty set, which for a tab that entered a worktree mid-turn may be never.
        subagentCounts[tabID] = 0

        watchers[tabID]?.stop()
        startWatching(
            tabID: tabID,
            conversationID: conversationID,
            url: ClaudeSession.transcriptURL(
                sessionID: conversationID,
                workingDirectory: directory,
                projectsRoot: projectsRoot
            )
        )
        persist()
    }

    /// Files a session under a different project, creating that project if it is new.
    ///
    /// This does not prune a source project it empties, matching `closeSession`: a
    /// project's lifetime is explicit, and an empty project is a legitimate sidebar state
    /// that now survives a relaunch too, via `SessionSnapshot.projects`.
    ///
    /// The tab id does not change, so `selectedSessionID` needs no fixing up and SwiftUI
    /// animates the same row moving within the sidebar's one flat `ForEach` rather than
    /// recreating it — there are no `Section`s in the sidebar to move between.
    ///
    /// The watcher is deliberately left alone. It used to be restarted here, because
    /// `workingDirectory` was also the input to `ClaudeSession.transcriptURL` — since the
    /// split it is not, `transcriptDirectory` is, and that field is untouched by a move. A
    /// tab moved into another project keeps tailing the transcript `claude` is actually
    /// writing; only `retarget` and `repin` may repoint a watcher now.
    func moveSession(_ id: UUID, toProjectAt url: URL) {
        guard let at = locate(id) else { return }
        let target = url.standardizedFileURL
        guard Self.comparablePath(repos[at.repo].url.path)
                != Self.comparablePath(target.path) else { return }

        var session = repos[at.repo].sessions.remove(at: at.session)
        // Stored as reported, not as compared: normalization is for deciding *whether* to
        // move. `transcriptDirectory` is not touched — where `claude` writes has nothing to
        // do with which project the user files this tab under.
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
        // Same reasoning as `newSession`: a session landing in a collapsed destination must
        // make that destination visible, or the move is invisible in the sidebar.
        repos[destination].isCollapsed = false

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
