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
        didSet { persist() }
    }

    /// Weak: `GhosttyApp.shared` is a process-wide static that owns itself for the life of
    /// the process (see `GhosttyApp.shared`'s doc comment); the store must not co-own it.
    private weak var provider: SurfaceProvider?

    /// Live surfaces retained here (not by the SwiftUI view tree) so switching
    /// sessions re-parents rather than recreates. Dropping an entry frees it.
    private var surfaces: [UUID: Ghostty.SurfaceView] = [:]

    /// One transcript watcher per session, torn down with the session.
    private var watchers: [UUID: TranscriptWatcher] = [:]

    /// Injectable so tests can point at a temp directory.
    var projectsRoot: URL = ClaudeSession.defaultProjectsRoot

    /// Injectable so tests can point at a temp directory.
    var sessionsRoot: URL = SessionStatusWatcher.defaultRoot

    /// Sub-agent counts kept separately so one arriving before the registry has been
    /// read is not lost, and so a registry refresh never clobbers it.
    private var subagentCounts: [UUID: Int] = [:]
    private var statusWatcher: SessionStatusWatcher?

    private var sessionCounter = 0

    private let persistence: SessionPersisting?

    /// Read at session-creation time only. Preferences configure *new* sessions; a
    /// running `claude` is never reconfigured, because its command line is already spent.
    private let preferences: PreferencesStore?

    /// Test seam. Production sets this from the convenience init.
    var notifier: Notifying?
    /// Test seam for frontmost-ness; production reads `NSApplication`.
    var appIsActive: () -> Bool = { NSApplication.shared.isActive }

    private var activationObserver: NSObjectProtocol?

    init(
        provider: SurfaceProvider?,
        persistence: SessionPersisting? = nil,
        preferences: PreferencesStore? = nil
    ) {
        self.provider = provider
        self.persistence = persistence
        self.preferences = preferences
        observeActivationRequests()
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// `resetState` comes from the `-FlightDeckResetState YES` launch argument: `smoke.sh`
    /// wipes defaults once per run, but the UITest bundle launches the app once per test
    /// case, so a session persisted by an earlier case would otherwise survive into a later
    /// one and make tests order-dependent.
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
    convenience init(
        ghostty: GhosttyApp?,
        resetState: Bool = false,
        preferences: PreferencesStore? = nil,
        notifier: Notifying? = nil
    ) {
        self.init(
            provider: ghostty,
            persistence: UserDefaultsSessionPersistence(),
            preferences: preferences
        )
        self.notifier = notifier
        if resetState || !restore() { seedInitialSession() }
        startStatusWatching()
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
        switch SessionCreateAction.forState(hasSessions: !repos.isEmpty) {
        case .newSession:
            if let created = newSessionBelowActive() {
                return created
            }
            // `newSessionBelowActive` needs a selection, not just a non-empty `repos` — and
            // selection can be nil with sessions still present (e.g. clicking below the last
            // row in the sidebar's List clears it). Fall back to the first project rather than
            // silently doing nothing; only prompt for a folder when there is truly nothing.
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
        if let surface = provider?.makeSurface(config) {
            surfaces[session.id] = surface
        }
        provider?.tick()

        startWatching(session, workingDirectory: url.path)
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
            let session = Session(
                id: entry.id, title: entry.title, workingDirectory: entry.workingDirectory
            )
            insertSession(
                session,
                in: url,
                initialInput: ClaudeSession.resumeCommand(
                    sessionID: entry.id,
                    title: entry.title,
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
        persistence?.save(
            SessionSnapshot(
                sessions: repos.flatMap(\.sessions).map {
                    .init(id: $0.id, title: $0.title, workingDirectory: $0.workingDirectory)
                },
                selectedSessionID: selectedSessionID,
                sessionCounter: sessionCounter
            )
        )
    }

    func selectSession(_ id: UUID) {
        guard locate(id) != nil else { return }
        selectedSessionID = id
        persist()
    }

    func closeSession(_ id: UUID) {
        guard let (repoIndex, sessionIndex) = locate(id) else { return }
        repos[repoIndex].sessions.remove(at: sessionIndex)
        // Dropping the retained view triggers Ghostty.Surface.deinit, which
        // defers ghostty_surface_free to a main-actor task. The singleton app
        // outlives that free, so there is no use-after-free.
        surfaces[id] = nil
        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
        subagentCounts.removeValue(forKey: id)
        // Closing the row is the most literal case of "a prompt that will never resolve",
        // and applyRegistry cannot observe the waiting -> gone edge here because both its
        // before and after snapshots already lack this id.
        notifier?.withdraw(sessionID: id)
        if repos[repoIndex].sessions.isEmpty {
            repos.remove(at: repoIndex)
        }
        if selectedSessionID == id {
            selectedSessionID = repos.first?.sessions.first?.id
        }
        persist()
    }

    /// Test seam. Production leaves this nil and injection goes to the live surface.
    var injectorOverride: TextInjecting?

    func title(of id: UUID) -> String? {
        guard let at = locate(id) else { return nil }
        return repos[at.repo].sessions[at.session].title
    }

    /// Sidebar → Claude. Updates the title, then types `/rename <name>` into the pty
    /// so the *running* interactive session renames itself and records it.
    ///
    /// The command text and the Return are sent separately, and that split is load-bearing.
    /// `sendText` is a *paste* in libghostty, and Claude Code enables bracketed-paste mode, so
    /// any line terminator inside the text is delivered between `\u{1b}[200~` and
    /// `\u{1b}[201~` and treated as pasted content — it lands in the input bar as a literal
    /// newline and never submits. Return has to arrive after the paste closes, as a real key
    /// event. See `TextInjecting.sendReturn()`.
    func rename(_ id: UUID, to newTitle: String) {
        guard let at = locate(id),
              let name = ClaudeSession.sanitizedName(newTitle)
        else { return }

        repos[at.repo].sessions[at.session].title = name
        let injector = injector(for: id)
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

    func status(for id: UUID) -> SessionStatus? { statuses[id] }

    /// Starts registry polling. Called from the production convenience init only, so
    /// tests using `init(provider:persistence:)` never touch the real registry or spin
    /// a timer.
    func startStatusWatching() {
        guard statusWatcher == nil else { return }
        let watcher = SessionStatusWatcher(root: sessionsRoot) { [weak self] entries in
            self?.applyRegistry(entries)
        }
        watcher.start()
        statusWatcher = watcher
    }

    /// Rebuilds `statuses` from a registry scan. Entries for sessions Flight Deck does
    /// not own are dropped: the registry lists every `claude` on the machine.
    func applyRegistry(_ entries: [UUID: ClaudeStatusFile.Entry]) {
        var next: [UUID: SessionStatus] = [:]
        for repo in repos {
            for session in repo.sessions {
                guard let entry = entries[session.id] else { continue }
                next[session.id] = SessionStatus(
                    activity: entry.activity,
                    waitingFor: entry.waitingFor,
                    subagentCount: subagentCounts[session.id] ?? 0
                )
            }
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

    private func startWatching(_ session: Session, workingDirectory: String) {
        let watcher = TranscriptWatcher(
            sessionID: session.id,
            url: ClaudeSession.transcriptURL(
                sessionID: session.id,
                workingDirectory: workingDirectory,
                projectsRoot: projectsRoot
            )
        ) { [weak self] title in
            self?.applyExternalTitle(session.id, title)
        } onSubagentCount: { [weak self] count in
            self?.applySubagentCount(session.id, count)
        }
        watcher.start()
        watchers[session.id] = watcher
    }

    private func indexOfRepo(for url: URL) -> Int? {
        let target = url.standardizedFileURL.path
        return repos.firstIndex { $0.url.standardizedFileURL.path == target }
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
