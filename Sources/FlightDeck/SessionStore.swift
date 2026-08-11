// Sources/FlightDeck/SessionStore.swift
import Foundation
import SwiftUI

/// Single source of truth for repos, sessions, selection, and live surfaces.
/// The sidebar and terminal pane render this and nothing else; only this type
/// creates or frees surfaces.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []
    /// `didSet` persists every change, including one made through `SessionSidebar`'s
    /// `List(selection:)` binding — the only way selection actually changes in
    /// production, since that binding writes here directly rather than through
    /// `selectSession(_:)`. `persist()` never re-assigns `selectedSessionID`, so this
    /// cannot recurse.
    @Published var selectedSessionID: UUID? {
        didSet { persist() }
    }

    /// Weak: the process-wide `GhosttyApp` is owned by the AppDelegate for the
    /// whole process; the Store must not co-own its lifetime.
    private weak var provider: SurfaceProvider?

    /// Live surfaces retained here (not by the SwiftUI view tree) so switching
    /// sessions re-parents rather than recreates. Dropping an entry frees it.
    private var surfaces: [UUID: Ghostty.SurfaceView] = [:]

    /// One transcript watcher per session, torn down with the session.
    private var watchers: [UUID: TranscriptWatcher] = [:]

    /// Injectable so tests can point at a temp directory.
    var projectsRoot: URL = ClaudeSession.defaultProjectsRoot

    private var sessionCounter = 0

    private let persistence: SessionPersisting?

    init(provider: SurfaceProvider?, persistence: SessionPersisting? = nil) {
        self.provider = provider
        self.persistence = persistence
    }

    /// Production entry point: build from the app singleton, restore the last run's
    /// sessions if any, and otherwise seed one.
    ///
    /// `resetState` skips `restore()` entirely. UITests launch the app multiple
    /// times within a single `smoke.sh` run, so sessions persisted by an earlier
    /// test case would otherwise survive (via UserDefaults) into a later one and
    /// make tests order-dependent. Every UITest passes the `-FlightDeckResetState
    /// YES` launch argument, which `RootView.init` translates into this flag.
    convenience init(ghostty: GhosttyApp?, resetState: Bool = false) {
        self.init(provider: ghostty, persistence: UserDefaultsSessionPersistence())
        if resetState || !restore() { seedInitialSession() }
    }

    func seedInitialSession(
        homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        guard repos.isEmpty else { return }
        newSession(in: homeURL)
    }

    @discardableResult
    func newSession(in url: URL) -> Session {
        sessionCounter += 1
        let session = Session(
            title: "session \(sessionCounter)", workingDirectory: url.path
        )
        insertSession(
            session,
            in: url,
            initialInput: ClaudeSession.launchCommand(
                sessionID: session.id, title: session.title
            )
        )
        selectedSessionID = session.id
        persist()
        return session
    }

    /// Shared by `newSession` and `restore`. `initialInput` is the only difference:
    /// a fresh session starts `claude`, a restored one resumes it.
    @discardableResult
    private func insertSession(
        _ session: Session, in url: URL, initialInput: String
    ) -> Session {
        let repoIndex: Int
        if let existing = indexOfRepo(for: url) {
            repoIndex = existing
        } else {
            repos.append(Repo(url: url))
            repoIndex = repos.count - 1
        }
        repos[repoIndex].sessions.append(session)

        var config = Ghostty.SurfaceConfiguration()
        config.command = ShellResolver.resolve()
        config.workingDirectory = url.path
        config.initialInput = initialInput
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
    @discardableResult
    func restore(
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
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
                    sessionID: entry.id, title: entry.title
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
    func rename(_ id: UUID, to newTitle: String) {
        guard let at = locate(id),
              let name = ClaudeSession.sanitizedName(newTitle)
        else { return }

        repos[at.repo].sessions[at.session].title = name
        injector(for: id)?.sendText("/rename \(name)\n")
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
