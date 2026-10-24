import Darwin
import Dispatch
import Foundation

/// A helper has one serial executor and no polling threads. Each connection is bounded in
/// bytes, lifetime, and count; otherwise an idle peer could hold the whole fleet's memory.
final class PeerSocket {
    private struct Connection {
        let source: DispatchSourceRead
        let deadline: DispatchWorkItem
        let pid: Int32
        var decoder = PeerFrameDecoder()
        var first = true
    }
    private let fd: Int32
    private let source: DispatchSourceRead
    private var connections: [Int32: Connection] = [:]
    let path: String
    var token = ""
    var onFrame: (([String: Any], Int32) -> Void)?

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        guard path.utf8.count < 104 else { throw PeerFailure.invalid("Unix socket path exceeds 103 bytes") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
    init(path: String) throws {
        self.path = path
        try PeerRegistry.privateDirectory((path as NSString).deletingLastPathComponent)
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PeerFailure.invalid("cannot create peer socket") }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        do {
            guard try Self.withAddress(path, { Darwin.bind(fd, $0, $1) }) == 0,
                  chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
                throw PeerFailure.invalid("cannot bind peer socket: \(String(cString: strerror(errno)))")
            }
        } catch { Darwin.close(fd); throw error }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        source.resume()
    }
    private func accept() {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 { return }
            var uid: uid_t = 0, gid: gid_t = 0, pid: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard connections.count < 32, getpeereid(client, &uid, &gid) == 0, uid == getuid(),
                  getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else {
                Darwin.close(client); continue
            }
            _ = fcntl(client, F_SETFL, O_NONBLOCK)
            let read = DispatchSource.makeReadSource(fileDescriptor: client, queue: .main)
            let deadline = DispatchWorkItem { [weak self] in self?.close(client) }
            connections[client] = Connection(source: read, deadline: deadline, pid: pid)
            read.setEventHandler { [weak self] in self?.read(client) }
            read.setCancelHandler { Darwin.close(client) }
            read.resume()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: deadline)
        }
    }
    private func read(_ fd: Int32) {
        guard var connection = connections[fd] else { return }
        var bytes = [UInt8](repeating: 0, count: 16384)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count < 0 { if errno != EAGAIN && errno != EINTR { close(fd) }; return }
        do {
            let frames = try connection.decoder.push(count > 0 ? Data(bytes.prefix(count)) : Data(), eof: count == 0)
            connections[fd] = connection
            for frame in frames {
                if connection.first, frame["type"] as? String == "auth" {
                    connection.first = false
                    guard let supplied = frame["token"] as? String,
                          supplied.utf8.count == token.utf8.count,
                          zip(supplied.utf8, token.utf8).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
                        close(fd); return
                    }
                } else {
                    connection.first = false
                    // Transport identity wins over the envelope's untrusted sender claim.
                    guard let from = frame["from"] as? String, let path = try? PeerJSON.path(from),
                          Int32(((path as NSString).lastPathComponent as NSString).deletingPathExtension) == connection.pid,
                          (try? PeerRegistry.socket(path)) != nil else { continue }
                    onFrame?(frame, connection.pid)
                }
            }
            if connections[fd] != nil { connections[fd] = connection }
        } catch { close(fd) }
        if count == 0 { close(fd) }
    }
    private func close(_ fd: Int32) {
        guard let connection = connections.removeValue(forKey: fd) else { return }
        connection.deadline.cancel(); connection.source.cancel()
    }
    func stop() {
        for fd in Array(connections.keys) { close(fd) }
        source.cancel()
        unlink(path)
    }
    static func post(to address: String, frames: [[String: Any]], configs: [String]) throws {
        let path = try PeerJSON.path(address)
        try PeerRegistry.socket(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PeerFailure.invalid("cannot create outgoing peer socket") }
        defer { Darwin.close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let connected = try withAddress(path, { Darwin.connect(fd, $0, $1) })
        if connected != 0 && errno != EINPROGRESS { throw PeerFailure.invalid("peer connect failed: \(String(cString: strerror(errno)))") }
        var pollfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollfd, 1, 2000) > 0 else { throw PeerFailure.invalid("peer connect timed out") }
        var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
            throw PeerFailure.invalid("peer connect refused")
        }
        var all: [[String: Any]] = []
        if let token = PeerRegistry.token(configs: configs, socket: path) { all.append(["type": "auth", "token": token]) }
        all += frames
        for frame in all {
            let bytes = try PeerJSON.line(frame)
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count; continue }
                    if errno == EINTR { continue }
                    guard errno == EAGAIN, poll(&pollfd, 1, 2000) > 0 else {
                        throw PeerFailure.invalid("peer write failed or timed out")
                    }
                }
            }
        }
        shutdown(fd, SHUT_WR)
    }
}
