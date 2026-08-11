// Sources/FlightDeck/SessionStore.swift
import Foundation
import SwiftUI

/// Single source of truth for repos, sessions, selection, and live surfaces.
/// The sidebar and terminal pane render this and nothing else; only this type
/// creates or frees surfaces.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []
    @Published var selectedSessionID: UUID?

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

    init(provider: SurfaceProvider?) {
        self.provider = provider
    }

    /// Production entry point: build from the app singleton and seed one session.
    convenience init(ghostty: GhosttyApp?) {
        self.init(provider: ghostty)
        seedInitialSession()
    }

    func seedInitialSession(
        homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        guard repos.isEmpty else { return }
        newSession(in: homeURL)
    }

    @discardableResult
    func newSession(in url: URL) -> Session {
        let repoIndex: Int
        if let existing = indexOfRepo(for: url) {
            repoIndex = existing
        } else {
            repos.append(Repo(url: url))
            repoIndex = repos.count - 1
        }

        sessionCounter += 1
        let session = Session(title: "session \(sessionCounter)", workingDirectory: url.path)
        repos[repoIndex].sessions.append(session)

        var config = Ghostty.SurfaceConfiguration()
        config.command = ShellResolver.resolve()
        config.workingDirectory = url.path
        // Bind `claude` to our own UUID so the transcript path is deterministic,
        // and seed it with the sidebar's title. See ClaudeSession.
        config.initialInput = ClaudeSession.launchCommand(
            sessionID: session.id, title: session.title
        )
        if let surface = provider?.makeSurface(config) {
            surfaces[session.id] = surface
        }
        provider?.tick()

        startWatching(session, workingDirectory: url.path)
        selectedSessionID = session.id
        return session
    }

    func selectSession(_ id: UUID) {
        guard locate(id) != nil else { return }
        selectedSessionID = id
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
