import CryptoKit
import Darwin
import Foundation

/// Codex's private control socket speaks WebSocket, not JSONL. Keeping framing here
/// lets the RPC layer retain the same JSON messages as its legacy stdio transport.
final class CodexSharedConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var stopped = false
    private let writes = DispatchQueue(label: "dev.flightdeck.codex-socket-writes")
    private let onMessage: @Sendable (String) -> Void
    private let onClose: @Sendable () -> Void
    private static let maxMessage = 16 * 1024 * 1024

    init(path: String, onMessage: @escaping @Sendable (String) -> Void,
         onClose: @escaping @Sendable () -> Void) throws {
        self.onMessage = onMessage
        self.onClose = onClose
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw Self.failure("Codex control socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = Self.openSocket()
        guard fd >= 0 else { throw Self.failure("Cannot create Codex control socket") }
        descriptor = fd
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        do {
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw Self.failure("Cannot connect to Codex's control socket") }
            let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
            try Self.write(Data(request.utf8), to: fd)
            var header = Data()
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard header.count < 16_384 else { throw Self.failure("Oversized Codex socket handshake") }
                header.append(try Self.read(1, from: fd))
            }
            let response = String(decoding: header, as: UTF8.self)
            let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let accepted = response.components(separatedBy: "\r\n").contains { line in
                let parts = line.split(separator: ":", maxSplits: 1)
                return parts.count == 2 && parts[0].lowercased() == "sec-websocket-accept" &&
                    parts[1].trimmingCharacters(in: .whitespaces) == expected
            }
            guard response.hasPrefix("HTTP/1.1 101 "), accepted else {
                throw Self.failure("Codex refused the control-socket handshake")
            }
            timeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        } catch {
            Darwin.close(fd)
            descriptor = -1
            throw error
        }
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                lock.lock()
                let fd = descriptor
                descriptor = -1
                stopped = true
                lock.unlock()
                if fd >= 0 { Darwin.close(fd) }
                onClose()
            }
            do {
                var message = Data()
                while true {
                    let head = try Self.read(2, from: descriptor)
                    let opcode = head[0] & 0x0f
                    guard head[1] & 0x80 == 0 else { throw Self.failure("Masked Codex server frame") }
                    var length = UInt64(head[1] & 0x7f)
                    if length == 126 { length = try Self.number(2, from: descriptor) }
                    else if length == 127 { length = try Self.number(8, from: descriptor) }
                    guard length <= Self.maxMessage else { throw Self.failure("Oversized Codex message") }
                    let payload = try Self.read(Int(length), from: descriptor)
                    if opcode == 8 { return }
                    if opcode == 9 { send(payload, opcode: 10); continue }
                    if opcode == 10 { continue }
                    guard opcode == 0 || opcode == 1 else { throw Self.failure("Unsupported Codex frame") }
                    guard message.count + payload.count <= Self.maxMessage else { throw Self.failure("Oversized Codex message") }
                    message.append(payload)
                    if head[0] & 0x80 != 0 {
                        guard let text = String(data: message, encoding: .utf8) else { throw Self.failure("Invalid Codex UTF-8") }
                        onMessage(text)
                        message.removeAll(keepingCapacity: true)
                    }
                }
            } catch { /* Closing the transport fails pending RPCs through onClose. */ }
        }
    }

    func send(_ line: String) { send(Data(line.utf8), opcode: 1) }

    private func send(_ data: Data, opcode: UInt8) {
        writes.async { [self] in
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, descriptor >= 0 else { return }
            do { try Self.write(Self.frame(data, opcode: opcode), to: descriptor) }
            catch { Darwin.shutdown(descriptor, SHUT_RDWR) }
        }
    }

    /// Shutdown unblocks the reader; only that reader closes the fd, preventing descriptor
    /// reuse from turning a late read into a read from an unrelated connection.
    /// Close-on-exec, or every tab's `fd-abduco`, shell and TUI inherits this connection.
    /// Those processes outlive Flight Deck, so an inherited copy kept a quit app's
    /// connection — and every thread it had subscribed — alive in the daemon indefinitely,
    /// and a still-subscribed thread never reloads with a tab's settings.
    static func openSocket() -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return fd
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, descriptor >= 0 else { return }
        stopped = true
        Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    static func frame(_ data: Data, opcode: UInt8 = 1, mask: [UInt8]? = nil) -> Data {
        let mask = mask ?? (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        precondition(mask.count == 4)
        var bytes: [UInt8] = [0x80 | opcode]
        if data.count < 126 { bytes.append(0x80 | UInt8(data.count)) }
        else if data.count <= 65535 {
            bytes += [0x80 | 126, UInt8((data.count >> 8) & 255), UInt8(data.count & 255)]
        } else {
            bytes.append(0x80 | 127)
            bytes += (0..<8).reversed().map { UInt8((UInt64(data.count) >> ($0 * 8)) & 255) }
        }
        bytes += mask
        bytes += data.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        return Data(bytes)
    }

    private static func number(_ count: Int, from fd: Int32) throws -> UInt64 {
        try read(count, from: fd).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func read(_ count: Int, from fd: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw failure("Codex control socket closed") }
            offset += n
        }
        return data
    }

    private static func write(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw failure("Cannot write to Codex control socket") }
            offset += n
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "FlightDeck.CodexSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
