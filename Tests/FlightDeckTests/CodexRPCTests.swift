import XCTest
@testable import FlightDeck

@MainActor
final class CodexRPCTests: XCTestCase {
    /// In-memory transport: no subprocess, no pipes, no timing.
    final class StubTransport: CodexTransport {
        var sent: [String] = []
        var onLine: ((String) -> Void)?

        /// Runs synchronously inside `send`, before `send` returns. `CodexRPC.request`
        /// registers its continuation in `pending` *before* calling `send`, so a reply fed
        /// back through `onLine` from in here always finds it waiting — the request/response
        /// tests below need no sleep or `Task` scheduling at all, only real `await`.
        var onSend: ((String) -> Void)?

        func send(_ line: String) {
            sent.append(line)
            onSend?(line)
        }

        func reply(_ json: String) { onLine?(json) }
    }

    func testARequestSerialisesAsOneJSONLine() async throws {
        let t = StubTransport()
        t.onSend = { _ in t.reply(#"{"id":1,"result":{}}"#) }
        let rpc = CodexRPC(transport: t)

        _ = try await rpc.request("thread/start", ["cwd": "/w/a"])

        let line = try XCTUnwrap(t.sent.first)
        XCTAssertFalse(line.dropLast().contains("\n"), "the frame is exactly one line")
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["method"] as? String, "thread/start")
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        XCTAssertNotNil(obj["id"], "a request must be correlatable")
    }

    func testAResultResolvesTheMatchingRequest() async throws {
        let t = StubTransport()
        t.onSend = { _ in t.reply(#"{"id":1,"result":{"thread":{"id":"abc"}}}"#) }
        let rpc = CodexRPC(transport: t)

        let result = try await rpc.request("thread/start", ["cwd": "/w/a"])

        let thread = result["thread"] as? [String: Any]
        XCTAssertEqual(thread?["id"] as? String, "abc")
    }

    func testAnErrorResponseThrowsWithTheRemoteMessage() async throws {
        let t = StubTransport()
        t.onSend = { _ in t.reply(#"{"id":1,"error":{"code":-32602,"message":"no such thread"}}"#) }
        let rpc = CodexRPC(transport: t)

        do {
            _ = try await rpc.request("thread/name/set", ["threadId": "nope"])
            XCTFail("an error response must not resolve")
        } catch CodexRPCError.remote(let code, let message) {
            XCTAssertEqual(code, -32602)
            XCTAssertEqual(message, "no such thread")
        }
    }

    /// Codex sends notifications regardless of whether anyone here is listening, and nothing
    /// is — there is no `onNotification` hook any more. A notification line must still be
    /// read off the wire and silently dropped rather than disturb the responses around it:
    /// not treated as malformed, not consuming a `pending` entry, not dropping the reply
    /// that follows it.
    func testANotificationBetweenTwoResponsesDisturbsNeitherRequest() async throws {
        let t = StubTransport()
        t.onSend = { line in
            if line.contains(#""id":1"#) {
                t.reply(#"{"method":"thread/name/updated","params":{"threadId":"abc","threadName":"x"}}"#)
                t.reply(#"{"id":1,"result":{"which":"first"}}"#)
            } else {
                t.reply(#"{"id":2,"result":{"which":"second"}}"#)
            }
        }
        let rpc = CodexRPC(transport: t)

        let first = try await rpc.request("thread/start", ["cwd": "/w/a"])
        let second = try await rpc.request("thread/start", ["cwd": "/w/b"])

        XCTAssertEqual(first["which"] as? String, "first")
        XCTAssertEqual(second["which"] as? String, "second")
        XCTAssertEqual(rpc.pendingCount, 0, "the notification must not have left a phantom entry")
    }

    /// A non-JSON banner arriving before the real reply must be swallowed, not corrupt the
    /// stream or fail the pending request — codex genuinely emits these on occasion.
    func testNonJSONBannerLinesAreIgnoredNotTreatedAsErrors() async throws {
        let t = StubTransport()
        t.onSend = { _ in
            t.reply("codex-app-server v1.2.3 starting up")
            t.reply(#"{"id":1,"result":{"ok":true}}"#)
        }
        let rpc = CodexRPC(transport: t)

        let result = try await rpc.request("thread/start", ["cwd": "/w"])

        XCTAssertEqual(result["ok"] as? Bool, true)
    }

    /// `notify` shares `request`'s framing (one JSON-RPC 2.0 object, one line) but must never
    /// carry an `id` — there is nothing to correlate a reply to, because none is expected.
    func testNotifySendsAWellFormedLineWithNoID() throws {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        rpc.notify("thread/subscribe", ["threadId": "abc"])

        let line = try XCTUnwrap(t.sent.first)
        XCTAssertTrue(line.hasSuffix("\n"), "each frame ends with its own newline")
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.dropLast().utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["method"] as? String, "thread/subscribe")
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        XCTAssertNil(obj["id"], "a notification is not correlatable")
    }

    /// The strongest evidence that responses route by `id` rather than arrival order: two
    /// requests in flight at once, replied to out of order, must each resolve to their own
    /// result. Both requests must be genuinely in flight (no reply yet) before either gets
    /// answered, so — as below — this can't be driven by a synchronous reply inside `send`;
    /// the sleep lets each `async let` child actually reach its suspension point.
    func testTwoRequestsInFlightResolveIndependentlyOutOfOrder() async throws {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        async let first: [String: Any] = rpc.request("thread/start", ["cwd": "/a"])
        try await Task.sleep(nanoseconds: 50_000_000)
        async let second: [String: Any] = rpc.request("thread/start", ["cwd": "/b"])
        try await Task.sleep(nanoseconds: 50_000_000)

        t.reply(#"{"id":2,"result":{"cwd":"/b"}}"#)
        t.reply(#"{"id":1,"result":{"cwd":"/a"}}"#)

        let a = try await first
        let b = try await second
        XCTAssertEqual(a["cwd"] as? String, "/a")
        XCTAssertEqual(b["cwd"] as? String, "/b")
    }

    /// A request genuinely with no reply forthcoming — this is what `transportClosed` and
    /// `deinit` exist for, so nothing here can synthesise a reply the way the tests above do.
    /// Tried `Task.yield()` in place of the sleep first, on the theory that a cooperative FIFO
    /// executor would run the already-scheduled `async let` child before resuming this task.
    /// Measured, not assumed: it hangs (confirmed via a 25s `timeout`-wrapped run that had to
    /// be killed) — the runtime does not guarantee the child gets a turn before the yield
    /// returns. A short sleep is what actually, empirically, lets the child reach its
    /// suspension point and register in `pending` before `transportClosed()` runs; there is no
    /// synchronous reply to hook here because the whole point of the test is that none arrives.
    func testAClosedTransportFailsPendingRequestsRatherThanHanging() async throws {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        async let result: [String: Any] = rpc.request("thread/start", ["cwd": "/w"])
        try await Task.sleep(nanoseconds: 50_000_000)
        rpc.transportClosed()

        do {
            _ = try await result
            XCTFail("a dead app-server must surface, not hang the tab forever")
        } catch CodexRPCError.transportClosed {}
    }

    /// The literal "drop the caller's last reference while a request is pending" scenario
    /// turns out to be unconstructable in Swift, verified with an isolated `-Onone`- and
    /// `-O`-compiled repro: calling `object.asyncMethod()` retains `object` for the entire
    /// suspended duration of that call, in both build configurations, regardless of what any
    /// other code does with its own references to `object`. So `deinit`'s cleanup loop cannot
    /// fire while `pending` is non-empty via ordinary reference-dropping — the in-flight call
    /// itself is what's still holding `self` alive. `deinit` stays as a defensive backstop
    /// (matches the review's suggested fix, costs nothing, and covers a future refactor where
    /// `pending` might be populated by something other than a live suspended call), but a test
    /// that "drops the reference, then asserts the pending call throws rather than hangs"
    /// would deadlock by construction, not by defect — it would be asserting something false
    /// about Swift's ARC model. This test pins the real, verified behaviour instead: an
    /// in-flight request keeps `CodexRPC` alive even after the caller discards every reference
    /// it holds, and the object is only freed once the request actually resolves.
    func testAnInFlightRequestKeepsCodexRPCAliveEvenAfterTheCallerDropsItsReference() async throws {
        let t = StubTransport()
        var rpc: CodexRPC? = CodexRPC(transport: t)
        weak var weakRPC = rpc

        async let result: [String: Any] = rpc!.request("thread/start", ["cwd": "/w"])
        try await Task.sleep(nanoseconds: 50_000_000)
        rpc = nil

        XCTAssertNotNil(weakRPC, "the in-flight call itself keeps CodexRPC alive, not the caller's own var")

        t.reply(#"{"id":1,"result":{"ok":true}}"#)
        let value = try await result
        XCTAssertEqual(value["ok"] as? Bool, true)
    }

    /// `withCheckedThrowingContinuation` alone does not notice `Task` cancellation: a caller
    /// whose enclosing `Task` is cancelled while this is suspended would otherwise stay
    /// suspended forever, leaking `CodexRPC` along with it (it's the in-flight call, not the
    /// caller, that keeps `self` alive — see the test above). `request`'s
    /// `withTaskCancellationHandler` must resume with a cancellation error AND remove the
    /// entry from `pending`, not just unblock the caller.
    func testCancellingTheEnclosingTaskResumesWithCancellationErrorAndClearsPending() async throws {
        let t = StubTransport()   // never replies — nothing here may synthesise a reply
        let rpc = CodexRPC(transport: t)

        let task = Task { try await rpc.request("thread/start", ["cwd": "/w"]) }
        try await Task.sleep(nanoseconds: 50_000_000)   // let it actually register in `pending`
        XCTAssertEqual(rpc.pendingCount, 1, "the request must be in flight before we cancel it")

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled request must not resolve")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertEqual(rpc.pendingCount, 0, "cancellation must remove the entry, not just resume it")
    }

    /// Two requests in flight, only one of them cancelled: the survivor must still resolve
    /// normally off its own reply. Cancellation cleanup must be per-`id`, not "clear everything
    /// pending" — that would be indistinguishable from `transportClosed()`.
    func testCancellingOneRequestLeavesAnotherInFlightRequestUnaffected() async throws {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        let toCancel = Task { try await rpc.request("thread/start", ["cwd": "/a"]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        async let survivor: [String: Any] = rpc.request("thread/start", ["cwd": "/b"])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rpc.pendingCount, 2)

        toCancel.cancel()
        do {
            _ = try await toCancel.value
            XCTFail("the cancelled request must not resolve")
        } catch is CancellationError {}

        XCTAssertEqual(rpc.pendingCount, 1, "only the cancelled request's entry should be gone")

        t.reply(#"{"id":2,"result":{"cwd":"/b"}}"#)
        let value = try await survivor
        XCTAssertEqual(value["cwd"] as? String, "/b")
    }
}
