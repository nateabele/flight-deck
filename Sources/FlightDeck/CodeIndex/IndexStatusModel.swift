import Foundation

/// Restarts the code index daemon. A seam so tests never touch the machine's real daemon,
/// which serves every agent on this Mac.
protocol IndexDaemonRestarting: Sendable {
    /// Blocking. Returns a note to show when the outcome is not a plain restart.
    func restart() throws -> String?
}

/// `fdindex service restart` with the bundled binary: stops the daemon over its socket, then
/// starts it through the launchd unit when one is installed, or on its own when not
/// (`service_install.rs`). Without the binary it can only stop the daemon over the socket; the
/// unit does not bring back a clean exit, so the next agent query starts it again.
struct FdindexServiceRestarter: IndexDaemonRestarting {
    let binary: URL?
    let client: IndexDaemonClient
    /// `service restart` waits up to 10 s for the old daemon to stop and 10 s for the new socket.
    var timeout: TimeInterval = 30

    /// `Contents/MacOS/fdindex`, beside the app's own executable (project.yml, `IndexCommand.locate`).
    static func bundled(_ bundle: Bundle = .main) -> URL? {
        guard let dir = bundle.executableURL?.deletingLastPathComponent() else { return nil }
        let url = dir.appendingPathComponent("fdindex")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func restart() throws -> String? {
        guard let binary else {
            try client.shutdown()
            return "Stopped. Flight Deck has no fdindex to start it with; the next agent query starts it again."
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["service", "restart"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        // Read before waiting, so a chatty child cannot fill the pipe and block on it.
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw IndexDaemonError.timedOut
        }
        guard process.terminationStatus == 0 else {
            let text = String(decoding: bytes, as: UTF8.self)
                .split(separator: "\n").last.map(String.init) ?? "exit status \(process.terminationStatus)"
            throw IndexDaemonError.system(text)
        }
        return nil
    }
}

/// An index restarter that restarts nothing: what a UITest reset launch gets.
struct InertIndexRestarter: IndexDaemonRestarting {
    func restart() throws -> String? { nil }
}

/// The Code Index section of Settings → Hosting: the machine-wide index daemon's status, read
/// over its socket, and a Restart button.
///
/// Every socket call blocks (connect and read with a 3 s deadline), so each runs on a detached
/// task and only its result comes back to the main actor, as in `HostingController`. Inert until
/// the tab polls it: it reads nothing at construction.
@MainActor
final class IndexStatusModel: ObservableObject {
    enum State: Equatable {
        /// Not read yet.
        case unknown
        case running(IndexDaemonStatus)
        /// Nothing listens on the socket. Not an error: any agent's next query starts it.
        case notRunning
        case failed(String)
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var restarting = false
    /// The last restart that did not go through. Kept apart from `state`, because a failed
    /// restart says nothing about whether the daemon is running now.
    @Published private(set) var actionError: String?
    @Published private(set) var actionNote: String?

    let client: IndexDaemonClient
    private let restarter: IndexDaemonRestarting
    /// The read in flight and the generation it started in. A restart's read-back never joins a
    /// read that started before the restart: that one is talking to the old daemon.
    private var refreshing: (generation: Int, task: Task<Void, Never>)?
    /// Bumped by every restart, so a status read before it cannot overwrite what came after.
    private var generation = 0

    init(client: IndexDaemonClient, restarter: IndexDaemonRestarting) {
        self.client = client
        self.restarter = restarter
    }

    /// One in flight at a time: the tab polls every 2 s and a read can take 3 s.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        if let refreshing, refreshing.generation == generation { return refreshing.task }
        let generation = generation
        let task = Task { [weak self] in
            await self?.performRefresh(generation: generation)
            if self?.refreshing?.generation == generation { self?.refreshing = nil }
        }
        refreshing = (generation, task)
        return task
    }

    @discardableResult
    func restart() -> Task<Void, Never> {
        guard !restarting else { return Task {} }
        restarting = true
        actionError = nil
        actionNote = nil
        generation += 1
        let restarter = restarter
        return Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try restarter.restart() }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let note): actionNote = note
            case .failure(let error): actionError = "Restart failed: \(Self.describe(error))"
            }
            restarting = false
            // Read back rather than assumed: the restart's outcome is the daemon's.
            await refresh().value
        }
    }

    private func performRefresh(generation: Int) async {
        let client = client
        let outcome = await Task.detached(priority: .utility) {
            Result { try client.status() }
        }.value
        guard generation == self.generation else { return }
        switch outcome {
        case .success(let status): state = .running(status)
        case .failure(IndexDaemonError.notRunning): state = .notRunning
        case .failure(let error): state = .failed(Self.describe(error))
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error as? IndexDaemonError {
        case .notRunning: return "The index daemon is not running."
        case .timedOut: return "The index daemon is not answering."
        case .protocolError: return "The index daemon answered with something Flight Deck didn't understand."
        case .refused(_, let message): return message
        case .system(let message): return message
        case nil: return error.localizedDescription
        }
    }
}

/// The section's wording, kept out of the view so it is tested without rendering.
enum IndexStatusText {
    /// "312.4 MB", "1.5 GB": the CLI's `human_bytes`, plus GB.
    static func bytes(_ b: UInt64) -> String {
        let mb = Double(b) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.1f MB", mb)
    }

    /// "45s", "2m05s", "3h07m": the CLI's `human_duration`.
    static func duration(_ secs: UInt64) -> String {
        switch secs {
        case 0..<60: return "\(secs)s"
        case 60..<3600: return String(format: "%dm%02ds", secs / 60, secs % 60)
        default: return String(format: "%dh%02dm", secs / 3600, secs % 3600 / 60)
        }
    }

    /// "Running · fdindex 0.1.0 · pid 42 · up 2m05s".
    static func running(_ s: IndexDaemonStatus) -> String {
        var parts = ["Running"]
        if let v = s.version { parts.append("fdindex \(v)") }
        if let pid = s.pid { parts.append("pid \(pid)") }
        if let up = s.uptimeSeconds { parts.append("up \(duration(up))") }
        return parts.joined(separator: " · ")
    }

    /// RSS over the target, 0...1+, or nil when either is unknown.
    static func memoryFraction(_ s: IndexDaemonStatus) -> Double? {
        guard let rss = s.rssBytes, let target = s.memoryTarget, target > 0 else { return nil }
        return Double(rss) / Double(target)
    }

    /// "312.4 MB of 1.0 GB target", or the resident size alone.
    static func memory(_ s: IndexDaemonStatus) -> String {
        guard let rss = s.rssBytes else { return "Unknown" }
        guard let target = s.memoryTarget, target > 0 else { return "\(bytes(rss)) resident" }
        return "\(bytes(rss)) of \(bytes(target)) target"
    }

    /// "80.0 MB in 3 repositories".
    static func store(_ s: IndexDaemonStatus) -> String {
        let n = s.stores?.count ?? 0
        return "\(bytes(s.storeBytes)) in \(n) \(n == 1 ? "repository" : "repositories")"
    }

    /// The view's worktree folder and repository: "feature-x (tessera)".
    static func view(_ v: IndexDaemonStatus.View) -> String {
        let folder = v.worktree.map { ($0 as NSString).lastPathComponent } ?? "?"
        guard let repo = v.repo, repo != folder else { return folder }
        return "\(folder) (\(repo))"
    }

    /// "feature-x: Parsing 40 of 1,636".
    static func build(_ b: IndexDaemonStatus.Build) -> String {
        let folder = b.worktree.map { ($0 as NSString).lastPathComponent } ?? "?"
        var line = "\(folder): \(b.phase ?? "Building")"
        if let done = b.done, let total = b.total, total > 0 { line += " \(done) of \(total)" }
        return line
    }

    /// "read: git cat-file failed (5m00s ago)", or nil when there is none.
    static func lastError(_ s: IndexDaemonStatus) -> String? {
        guard let e = s.lastError, let message = e.message else { return nil }
        var line = e.tool.map { "\($0): \(message)" } ?? message
        if let ago = e.secondsAgo { line += " (\(duration(ago)) ago)" }
        return line
    }
}
