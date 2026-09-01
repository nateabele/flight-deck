import Foundation
import OSLog

/// The transport under `AnswerTrigger`: one line of JSON in, one line of JSON out, over a unix
/// socket, one request per connection.
///
/// **A unix socket rather than a URL scheme or a watched file, because the caller needs an
/// answer back.** `open "flightdeck://…"` is fire-and-forget — there is nowhere for `list`'s
/// JSON to go and nowhere for a refusal to be reported — and a watched command file turns
/// every call into a poll for a reply file that may never appear. A socket makes the request
/// and its response one synchronous exchange a shell can read with `nc -U`, which is what
/// makes `scripts/answer-trigger.sh` fifteen lines instead of a retry loop.
///
/// **No framing, no length prefix, no session.** The fleet's own socket earns its framing:
/// it multiplexes events and commands over a long-lived TLS connection. This carries one
/// request from a developer's shell and closes, so a newline is the entire protocol and there
/// is nothing for a second frame to be confused with.
///
/// Nothing here authenticates, and nothing here should: any process that can open the socket
/// is already running as the user whose terminal it would drive. The authorization is the
/// socket's existence, which is `AnswerTrigger.isEnabled`'s to decide, plus `0600` on the file.
final class AnswerTriggerSocket {
    enum Failure: Error, Equatable {
        /// The path did not fit in `sockaddr_un`. See `maxPathLength`.
        case pathTooLong(Int)
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
    }

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin and holds a NUL-terminated path, so 103
    /// bytes is every path a unix socket can have — and `bind` does not truncate, it fails.
    ///
    /// Checked rather than assumed because the socket sits wherever the state directory is,
    /// and `-FlightDeckStateDir` can point that at a path of any length. The default
    /// (`~/Library/Application Support/Flight Deck`) leaves room; a deeply nested override
    /// does not, and a refusal that names the limit beats `EINVAL` from `bind`.
    static let maxPathLength = 103

    /// A whole set of selections is a few hundred bytes. The cap is here so a client that
    /// never sends a newline cannot make this read until it runs out of memory.
    private static let maxRequestBytes = 64 * 1024

    /// A client that connects and then says nothing holds one worker on `queue`. Bounded so
    /// it holds it for two seconds rather than for the life of the app.
    private static let ioTimeout = timeval(tv_sec: 2, tv_usec: 0)

    /// How long one request may take the app to answer.
    ///
    /// **Fifteen seconds, and it is deliberately longer than what it bounds.** The only
    /// operation that is not answered inline is `logs`, which puts a frame on a phone's socket
    /// and waits; `FleetSocketServer.askDeadline` already gives that ten and releases the
    /// caller itself. So this never fires in a working system — it is the backstop for a
    /// handler that fails to call back at all, which would otherwise hold this worker, and the
    /// caller's `nc -U`, forever.
    private static let handlerDeadline = DispatchTimeInterval.seconds(15)

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "answer"
    )

    let url: URL
    /// **A completion rather than a return value, and the `logs` op is why** — see
    /// `AnswerTrigger.handle`. `list` and `answer` still call back before they return; a fetch
    /// from a phone cannot, because it is waiting for a phone.
    private let handle: @MainActor (String, @escaping (String) -> Void) -> Void
    /// Serial, so one request is served at a time. Serving two at once would let two answers
    /// race into the same terminal, which is the thing `SessionStore.injecting` exists to
    /// prevent and not something to hand it a second way to happen.
    private let queue = DispatchQueue(label: "dev.flightdeck.answer-trigger")
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    init(url: URL, handle: @escaping @MainActor (String, @escaping (String) -> Void) -> Void) {
        self.url = url
        self.handle = handle
    }

    deinit { stop() }

    func start() throws {
        let path = url.path
        guard path.utf8.count <= Self.maxPathLength else {
            throw Failure.pathTooLong(path.utf8.count)
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // The file is a name, not the listener: a crashed or force-quit run leaves it behind
        // and `bind` then fails `EADDRINUSE` forever. Removing it is what makes this survive
        // a `SIGKILL`, which `scripts/swap-release.sh` does on every release swap.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: Self.maxPathLength + 1) {
                _ = strlcpy($0, path, Self.maxPathLength + 1)
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Failure.bind(code)
        }
        guard listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw Failure.listen(code)
        }
        // Belt to `isEnabled`'s braces: only this user can open it even on a machine with
        // other accounts logged in.
        chmod(path, 0o600)

        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.serveOne() }
        source.setCancelHandler {
            close(fd)
            unlink(path)
        }
        self.source = source
        source.resume()
        Self.logger.info("answer trigger listening on \(path, privacy: .public)")
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    /// One connection, start to finish, on `queue`.
    private func serveOne() {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var timeout = Self.ioTimeout
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)

        guard let request = readRequest(from: client) else { return }
        // **A semaphore, and it cannot deadlock.** The main actor never waits on this queue —
        // the trigger is reached from here and from nowhere else — so the only thing this
        // blocks is one request while the app is busy, exactly as the `DispatchQueue.main.sync`
        // this replaces did. What changed is that the handler may now answer *after* returning:
        // `logs` waits on a phone, so it cannot be a return value, and a `sync` that ran a
        // handler which called back later would answer the caller before the answer existed.
        //
        // `nonisolated(unsafe)`: `response` is written once, on the main actor, and read here
        // only after `wait` observes the signal — the semaphore is the ordering, so there is no
        // race for the compiler's checking to protect.
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var response: String?
        // `self.handle` rather than a bare `handle`: this closure outlives the call, so the
        // capture has to be explicit. The socket owns the closure and cancels its source in
        // `deinit`, so there is no cycle to break with a weak capture.
        let handle = self.handle
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handle(request) { answer in
                    response = answer
                    ready.signal()
                }
            }
        }
        // Bounded, because a handler that never calls back would otherwise hold this worker —
        // and the caller's `nc -U` — for the life of the app. The refusal names the deadline
        // rather than saying "error", so a caller can tell "the app is wedged" from "the app
        // said no".
        guard ready.wait(timeout: .now() + Self.handlerDeadline) == .success,
              let response
        else {
            Self.logger.error("answer trigger handler did not answer in time")
            let bytes = Array(#"{"error":"timed_out","ok":false}"#.utf8) + [UInt8(ascii: "\n")]
            bytes.withUnsafeBytes { _ = write(client, $0.baseAddress!, $0.count) }
            return
        }
        var bytes = Array(response.utf8)
        bytes.append(UInt8(ascii: "\n"))
        bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = write(client, buffer.baseAddress! + sent, buffer.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    /// Reads up to the first newline, EOF, or `maxRequestBytes` — whichever comes first.
    ///
    /// EOF counts as a terminator so `printf '%s' '{"op":"list"}' | nc -U …` works as well as
    /// an `echo` that appends one; a caller should not have to know which.
    private func readRequest(from client: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < Self.maxRequestBytes {
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { break }
            let chunk = buffer[0..<n]
            data.append(contentsOf: chunk)
            if chunk.contains(UInt8(ascii: "\n")) { break }
        }
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
