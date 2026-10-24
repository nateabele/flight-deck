import Foundation

/// One Foundation-only child per native PID identity. Pipes carry host commands; there is
/// no second control socket to grant to every agent sandbox, and no polling subprocess.
@MainActor
final class PeerHelperProcess {
    let process = Process()
    private let input = Pipe(), output = Pipe()
    private var next = 0
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var reader: PeerPipeReader?
    private var stopping = false
    private(set) var address: String?
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?

    init(executable: URL, arguments: [String], directory: String) {
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = input; process.standardOutput = output
        // A helper never prints payloads or tokens on stderr. Use the app's inherited log
        // rather than another undrained pipe that could deadlock on a diagnostic burst.
        process.standardError = FileHandle.standardError
        // No unrelated account/API secrets need to be inherited by a socket relay.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TZ": "UTC"]
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            let reader = PeerPipeReader { [weak self] object in
                Task { @MainActor in self?.received(object) }
            }
            self.reader = reader
            output.fileHandleForReading.readabilityHandler = { handle in reader.accept(handle.availableData) }
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard let self else { return }
                    self.failed(PeerFailure.invalid("peer helper exited (\(process.terminationStatus))"))
                    if !self.stopping { self.onExit?() }
                }
            }
            do { try process.run() }
            catch { failed(error) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.readyContinuation != nil else { return }
                self.failed(PeerFailure.invalid("peer helper did not become ready")); self.stop()
            }
        }
    }
    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> Any {
        guard process.isRunning, address != nil else { throw PeerFailure.invalid("peer helper is not running") }
        next += 1; let id = next
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try input.fileHandleForWriting.write(contentsOf: PeerJSON.line(["id": id, "method": method, "params": params])) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.pending.removeValue(forKey: id)?.resume(throwing: PeerFailure.invalid("peer helper request timed out"))
            }
        }
    }
    private func received(_ object: [String: Any]) {
        if object["type"] as? String == "ready", let path = object["socket"] as? String {
            address = "uds:" + path
            readyContinuation?.resume(); readyContinuation = nil
        } else if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = object["error"] as? String { continuation.resume(throwing: PeerFailure.invalid(error)) }
            else { continuation.resume(returning: object["result"] ?? [:]) }
        } else { onEvent?(object) }
    }
    private func failed(_ error: Error) {
        address = nil
        output.fileHandleForReading.readabilityHandler = nil
        reader = nil
        readyContinuation?.resume(throwing: error); readyContinuation = nil
        let waiting = pending; pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
    func stop() {
        stopping = true
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        failed(PeerFailure.invalid("peer endpoint closed"))
    }
    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// FileHandle calls its handler off-main. Decode there, then cross the actor boundary with
/// complete frames; reparsing an ever-growing String on the UI thread stalls large fleets.
private final class PeerPipeReader: @unchecked Sendable {
    private var decoder = PeerFrameDecoder()
    private let deliver: ([String: Any]) -> Void
    private let lock = NSLock()
    init(_ deliver: @escaping ([String: Any]) -> Void) { self.deliver = deliver }
    func accept(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        for frame in (try? decoder.push(data, eof: data.isEmpty)) ?? [] { deliver(frame) }
    }
}
