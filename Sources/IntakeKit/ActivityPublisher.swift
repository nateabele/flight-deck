import Foundation

/// Owns one seat's `activity.json`: feeds the harness's stdout through an `ActivityParser` and
/// writes the result atomically — once at start, at most every `interval` while events arrive,
/// and once at finish — so the app only ever reads a small finished file and never parses a
/// stream itself. A write held back by the throttle gets a trailing flush when the interval
/// runs out: without it the last event before a quiet spell (a seat's long-running command)
/// would stay unpublished until the next event, however long that took.
///
/// Called from the runner's stdout reader thread and from the seat's own task, so everything
/// is under one lock. Every write is best-effort: activity is what the human watches, never
/// what a round depends on, so a failed write must not fail the seat.
public final class ActivityPublisher: @unchecked Sendable {
    public static let interval: TimeInterval = 2

    private let lock = NSLock()
    private var parser: ActivityParser
    private let destination: URL
    private let now: @Sendable () -> Date
    private let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private var lastWrite: Date?
    private var dirty = false
    private var flushPending = false
    private var finished = false

    /// `schedule` runs the trailing flush after a delay — injectable so a test fires it by hand.
    /// `accountID` is the account the seat bills (`SeatActivity.accountID`).
    public init(agent: AgentID, project: URL, cwd: URL? = nil, accountID: UUID? = nil, destination: URL,
                now: @escaping @Sendable () -> Date,
                schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, work in
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
                }) {
        parser = ActivityParser(agent: agent, project: project, cwd: cwd, accountID: accountID, now: now)
        self.destination = destination
        self.now = now
        self.schedule = schedule
    }

    public var activity: SeatActivity { lock.withLock { parser.activity } }

    public func start() {
        lock.withLock { write() }
    }

    public func feed(_ data: Data) {
        lock.withLock {
            guard !finished else { return }
            parser.feed(data)
            dirty = true
            let elapsed = lastWrite.map { now().timeIntervalSince($0) } ?? .infinity
            if elapsed >= Self.interval {
                write()
            } else if !flushPending {
                flushPending = true
                schedule(Self.interval - elapsed) { [weak self] in self?.flush() }
            }
        }
    }

    /// `error` is for a seat that failed without a stream to say why (it never spawned).
    public func finish(exitCode: Int32?, error: String? = nil) {
        lock.withLock {
            guard !finished else { return }
            parser.finish(exitCode: exitCode, error: error)
            finished = true
            write()
        }
    }

    private func flush() {
        lock.withLock {
            flushPending = false
            if dirty && !finished { write() }
        }
    }

    /// Caller holds `lock`.
    private func write() {
        dirty = false
        lastWrite = now()
        guard let data = try? IntakeJSON.encoder.encode(parser.activity) else { return }
        try? data.write(to: destination, options: .atomic)
    }
}
