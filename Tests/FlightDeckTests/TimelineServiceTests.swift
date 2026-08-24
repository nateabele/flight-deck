import FleetKit
import XCTest
@testable import FlightDeck

/// Tab id → agent + transcript → page, and the three answers that are not a page.
///
/// The distinctions here are the ones a phone renders differently: a tab that does not exist
/// is a stale row, a tab whose agent reports no transcript can never have one, and a tab
/// whose transcript is not on disk yet is the ordinary state of a claude session before its
/// first turn. Collapsing them into one error makes all three read as "something is broken".
@MainActor
final class TimelineServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    /// Mirrors `AgentRoutingTests.StubAdapter`, with a transcript URL this test controls —
    /// the real `ClaudeAdapter` derives one under `~/.claude/projects`, and a test has no
    /// business writing there.
    private struct FixedTranscriptAdapter: AgentAdapter {
        static let id: AgentID = .claude
        /// Claude's answer, because this stands in for claude — the store reads the
        /// capability off `AgentID`, so a stub that disagreed would describe an agent that
        /// does not exist.
        static let hasTextChannel = true
        let url: URL?

        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            binding(for: session)
        }
        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: url)
        }
        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: session.transcriptDirectory,
                          binding: binding(for: session))
        }
        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func rename(_: AgentBinding, to: String) async throws {}
        func loginInvocation(for account: AgentAccount) -> LoginInvocation {
            LoginInvocation(command: "", inject: nil)
        }
    }

    private func store(transcript: URL?) -> (SessionStore, Session) {
        let store = SessionStore(provider: nil, persistence: nil)
        store.overrideAdapter(
            FixedTranscriptAdapter(url: transcript), for: .claude, account: nil
        )
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        return (store, session)
    }

    /// The fixture's size, which is also the `end` cursor every page below reports: the file
    /// ends on a line boundary, so the pager's forward edge is the last byte of it.
    /// 79 bytes of user record, 111 of assistant, and the `\n` that ends each.
    private static let transcriptBytes = 192

    /// How long a substituted reader will sit parked before giving up. A recovery valve, not
    /// a timing assumption: it exists only so that an implementation which never releases the
    /// read fails its assertion instead of hanging the suite, and it is six times `arrived`'s
    /// window so that "eventually" can never be mistaken for "at once".
    private static let readerRelease: Double = 30

    private func writeTranscript() throws -> URL {
        let url = directory.appendingPathComponent("t.jsonl")
        try Data(#"""
            {"type":"user","isSidechain":false,"message":{"role":"user","content":"hello"}}
            {"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}

            """#.utf8).write(to: url)
        return url
    }

    /// Waits for a semaphore **without holding the main actor.**
    ///
    /// Every rendezvous below is with work the service dispatched off the main actor, and the
    /// service cannot even reach that dispatch until the main actor is free — so waiting
    /// inline here would deadlock the test rather than fail it. A GCD global thread is the
    /// right thing to block: it is built to be, and unlike a cooperative-pool thread there is
    /// no fixed supply of them to exhaust.
    ///
    /// Returns whether the signal arrived, rather than trapping, so an implementation that
    /// never gets there fails the assertion that named the expectation instead of hanging the
    /// whole suite.
    ///
    /// **The window is deliberately far shorter than `readerRelease`'s**, and that ratio is
    /// what makes the rendezvous tests capable of failing at all. A serialized — or inline —
    /// implementation still *eventually* reaches every read, once the one ahead of it has
    /// timed out; with the two waits set to the same duration, "both reads are in flight at
    /// once" would be satisfied by two reads twenty seconds apart and the test would be green
    /// against exactly the implementation it exists to reject.
    private func arrived(_ semaphore: DispatchSemaphore, within seconds: Double = 5) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + seconds) == .success)
            }
        }
    }

    func testAKnownTabResolvesToItsAgentAndTranscript() throws {
        let url = try writeTranscript()
        let (store, session) = store(transcript: url)
        XCTAssertEqual(store.timelineSource(of: session.id), .file(agent: .claude, url: url))
    }

    func testAnUnknownTabResolvesToUnknownSession() {
        let (store, _) = store(transcript: nil)
        XCTAssertEqual(store.timelineSource(of: UUID()), .unknownSession)
    }

    /// A codex thread whose `thread/start` never returned a path has no transcript and never
    /// will. That is a different fact from "the file is not there yet" and reads differently
    /// on screen.
    func testATabWhoseAgentReportsNoTranscriptSaysSo() {
        let (store, session) = store(transcript: nil)
        XCTAssertEqual(store.timelineSource(of: session.id), .noTranscript)
    }

    /// Every field of the page, not just its text. The cursors are what the next request is
    /// made from, so a page whose content is right and whose `end` is one byte off is a
    /// conversation the client can never page past — and the content assertion alone would
    /// never say so.
    func testTheServiceReturnsAPageForAKnownTab() async throws {
        let url = try writeTranscript()
        let (store, session) = store(transcript: url)
        let page = try await TimelineService(store: store)
            .page(session: session.id, anchor: .latest, limit: 40).get()
        XCTAssertEqual(page.items.map(\.body.text), ["hello", "hi"])
        // `"<offset>#<block>"`: the user line begins the file, the assistant line begins one
        // byte past its 79-byte predecessor.
        XCTAssertEqual(page.items.map(\.id), ["0#0", "80#0"])
        XCTAssertEqual(page.session, session.id)
        XCTAssertEqual(page.start, 0)
        XCTAssertEqual(page.end, Self.transcriptBytes)
        XCTAssertFalse(page.hasMore, "both records fit, so there is nothing above `start`")
        XCTAssertFalse(page.reset, "the file the cursor came from is the file that was read")
    }

    func testEachFailureHasItsOwnCode() async throws {
        let (emptyStore, _) = store(transcript: nil)
        let service = TimelineService(store: emptyStore)

        let unknown = await service.page(session: UUID(), anchor: .latest, limit: 40)
        XCTAssertEqual(unknown, .failure("unknown_session"))

        let (noneStore, noneSession) = store(transcript: nil)
        let missing = await TimelineService(store: noneStore)
            .page(session: noneSession.id, anchor: .latest, limit: 40)
        XCTAssertEqual(missing, .failure("no_transcript"))

        let (pendingStore, pendingSession) = store(
            transcript: directory.appendingPathComponent("not-written-yet.jsonl")
        )
        let pending = await TimelineService(store: pendingStore)
            .page(session: pendingSession.id, anchor: .latest, limit: 40)
        XCTAssertEqual(pending, .failure("unreadable"),
                       "a claude tab before its first turn: claude creates the transcript "
                       + "only when it first has something to persist")
    }

    /// The service must not become another way to change the fleet. Nothing it does writes,
    /// so a replicator attached to the store sees no event and the DEBUG drift check has
    /// nothing new to catch — which is exactly why the timeline could be added without
    /// touching the fleet event log at all.
    func testAnsweringAPageEmitsNoFleetEvent() async throws {
        let url = try writeTranscript()
        let (store, session) = store(transcript: url)
        let replicator = attachedReplicator(to: store)
        let before = replicator.seq
        _ = await TimelineService(store: store)
            .page(session: session.id, anchor: .latest, limit: 40)
        XCTAssertEqual(replicator.seq, before, "reading a transcript is not a fleet mutation")
    }

    /// The boundary itself. A page is up to 128 KB assembled from an 8 MB scan, and running
    /// that on the main actor is the difference between a responsive Mac and a beachball
    /// while a phone scrolls — the same reason `TranscriptWatcher.poll` dispatches
    /// `Scan.read`.
    ///
    /// Asserted from inside the read, because that is the only place the answer exists: a
    /// caller cannot see which thread a callee ran on once it has returned.
    func testTheReadRunsOffTheMainActor() async throws {
        let url = try writeTranscript()
        let (store, session) = store(transcript: url)
        let service = TimelineService(store: store)
        let offMainActor = DispatchSemaphore(value: 0)
        service.reader = { session, agent, url, anchor, limit in
            if !Thread.isMainThread { offMainActor.signal() }
            return TimelineReader.page(
                session: session, agent: agent, url: url, anchor: anchor, limit: limit
            )
        }

        let page = try await service.page(session: session.id, anchor: .latest, limit: 40).get()

        XCTAssertEqual(page.items.map(\.body.text), ["hello", "hi"],
                       "the substituted reader must still be the real one")
        XCTAssertEqual(offMainActor.wait(timeout: .now()), .success,
                       "the transcript read must not run on the main actor")
    }

    /// **The ordinary case, not an edge one**: a phone asks for history, the user closes the
    /// tab, and the read is still in flight — the whole point of taking it off the main actor
    /// is that the main actor is free to do exactly that.
    ///
    /// The answer is still the page. Resolution happens once, on the main actor, and hands
    /// the read three plain values (`agent`, `url`, the tab id to echo); nothing downstream
    /// of it asks the store anything, so there is no window in which the tab going away can
    /// turn a page that was legitimately resolved into `unknown_session`. Re-checking the
    /// store after the read would be the bug: a page the Mac already has in hand would be
    /// thrown away and reported as a stale row.
    ///
    /// "Mid-read" is established by construction, not by timing: the read is held until the
    /// close has actually happened, and `closedMidRead` is signalled only on the path where
    /// it did. Without that witness the test is green against a service that reads on the
    /// main actor — the close simply happens after the read instead of during it, the page
    /// comes back correct anyway, and nothing says the window under test was never open.
    func testATabClosedMidReadStillAnswersWithItsPage() async throws {
        let url = try writeTranscript()
        let (store, session) = store(transcript: url)
        let service = TimelineService(store: store)
        let reading = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        let closedMidRead = DispatchSemaphore(value: 0)
        service.reader = { session, agent, url, anchor, limit in
            reading.signal()
            if closed.wait(timeout: .now() + Self.readerRelease) == .success {
                closedMidRead.signal()
            }
            return TimelineReader.page(
                session: session, agent: agent, url: url, anchor: anchor, limit: limit
            )
        }

        let inFlight = Task { await service.page(session: session.id, anchor: .latest, limit: 40) }
        let started = await arrived(reading)
        XCTAssertTrue(started, "the read must be dispatched before the tab is closed")

        store.closeSession(session.id)
        XCTAssertEqual(store.timelineSource(of: session.id), .unknownSession,
                       "the tab really is gone by the time the read finishes")
        closed.signal()

        let page = try await inFlight.value.get()
        XCTAssertEqual(closedMidRead.wait(timeout: .now()), .success,
                       "the tab must have been closed while the read was still in flight")
        XCTAssertEqual(page.items.map(\.body.text), ["hello", "hi"])
        XCTAssertEqual(page.items.map(\.id), ["0#0", "80#0"])
        XCTAssertEqual(page.start, 0)
        XCTAssertEqual(page.end, Self.transcriptBytes)
        XCTAssertEqual(page.session, session.id,
                       "the page is still about the tab that was asked for")
    }

    /// Two phones, or one phone scrolling while another screen refreshes. Nothing is
    /// serialized behind anything: each request resolves independently and reads the file
    /// through its own handle, so both are in flight at once and neither waits on the other.
    /// A service that queued reads would leave the second phone waiting out the first
    /// phone's 8 MB scan.
    ///
    /// The two reads rendezvous **with each other**, which is what makes the claim provable
    /// rather than merely plausible: each signals its own arrival and then waits for the
    /// other's, so both can only get past that point if both were running at the same time.
    /// Serialized, the read that goes first waits out `readerRelease` for a partner that
    /// cannot start, and only one of the two ever signals `overlapped`. A test that instead
    /// watched for two arrivals from outside would see them arrive one after the other and
    /// call that concurrency.
    func testTwoPagesForOneSessionCanBeInFlightAtOnce() async throws {
        let url = try writeTranscript()
        let (store, session) = store(transcript: url)
        let service = TimelineService(store: store)
        // The two requests are told apart by their anchor, which is also the pair a real
        // fleet produces: one phone opening a screen, another picking up what was appended.
        let latestReading = DispatchSemaphore(value: 0)
        let afterReading = DispatchSemaphore(value: 0)
        let overlapped = DispatchSemaphore(value: 0)
        service.reader = { session, agent, url, anchor, limit in
            let mine = anchor == .latest ? latestReading : afterReading
            let theirs = anchor == .latest ? afterReading : latestReading
            mine.signal()
            if theirs.wait(timeout: .now() + Self.readerRelease) == .success {
                overlapped.signal()
            }
            return TimelineReader.page(
                session: session, agent: agent, url: url, anchor: anchor, limit: limit
            )
        }

        let latest = Task { await service.page(session: session.id, anchor: .latest, limit: 40) }
        let after = Task { await service.page(session: session.id, anchor: .after(0), limit: 40) }
        let pages = [try await latest.value.get(), try await after.value.get()]

        XCTAssertEqual(overlapped.wait(timeout: .now()), .success)
        XCTAssertEqual(overlapped.wait(timeout: .now()), .success,
                       "both reads must have been in flight at the same time, not one after "
                       + "the other")
        XCTAssertEqual(pages.map { $0.items.map(\.body.text) },
                       [["hello", "hi"], ["hello", "hi"]])
        XCTAssertEqual(pages.map { $0.items.map(\.id) }, [["0#0", "80#0"], ["0#0", "80#0"]])
        XCTAssertEqual(pages.map(\.start), [0, 0])
        XCTAssertEqual(pages.map(\.end), [Self.transcriptBytes, Self.transcriptBytes])
        XCTAssertEqual(pages.map(\.session), [session.id, session.id])
    }
}
