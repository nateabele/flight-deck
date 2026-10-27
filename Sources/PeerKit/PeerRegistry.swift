import CryptoKit
import Darwin
import Foundation

enum PeerRegistry {
    static func privateDirectory(_ path: String, create: Bool = true) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard create, errno == ENOENT else { throw PeerFailure.invalid("peer directory does not exist: \(path)") }
            let parent = (path as NSString).deletingLastPathComponent
            var parentInfo = stat()
            if lstat(parent, &parentInfo) != 0 { try privateDirectory(parent) }
            // Foundation creates then chmods when given attributes. With 32 helpers starting
            // together a sibling sees that transient 0755 directory and correctly refuses it.
            // mkdir(mode:) makes ownership/privacy atomic; EEXIST is revalidated below.
            guard mkdir(path, 0o700) == 0 || errno == EEXIST else {
                throw PeerFailure.invalid("cannot create private peer directory: \(path)")
            }
            guard lstat(path, &info) == 0 else { throw PeerFailure.invalid("cannot stat peer directory") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw PeerFailure.invalid("peer directory must be owned by this user, mode 0700, and not a symlink: \(path)")
        }
    }
    static func socket(_ path: String) throws {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw PeerFailure.invalid("unsafe peer path")
        }
        try privateDirectory((path as NSString).deletingLastPathComponent, create: false)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw PeerFailure.invalid("unsafe peer socket: \(path)")
        }
    }
    static func processStart(_ pid: Int32) throws -> String {
        guard pid > 0 else { throw PeerFailure.invalid("invalid peer PID") }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart="]
        process.environment = ["TZ": "UTC", "LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !value.isEmpty else { throw PeerFailure.invalid("peer process exited") }
        return value
    }
    /// Every process's start time, from ONE `ps`, in `processStart`'s exact format. A registry
    /// scan used to spawn `ps` once per record: with ~100 records across eight account homes
    /// that took 5-15 s on a loaded machine (measured 2026-10-26), long enough that a
    /// `flightdeck peer send`, which lists before it sends, ran past the CLI's 15 s limit.
    /// This call takes ~40 ms.
    static func processStarts() -> [Int32: String] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,lstart="]
        process.environment = ["TZ": "UTC", "LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var starts: [Int32: String] = [:]
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            starts[pid] = trimmed[space...].trimmingCharacters(in: .whitespaces)
        }
        return starts
    }
    static func atomic(_ object: Any, at path: String) throws {
        let data = try PeerJSON.data(object)
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        guard chmod(path, 0o600) == 0 else { throw PeerFailure.invalid("cannot protect peer record") }
    }
    static func keyPath(config: String, pid: Int32, socket: String) -> String {
        let absolute = URL(fileURLWithPath: socket).standardizedFileURL.path
        let hash = SHA256.hash(data: Data(absolute.utf8)).map { String(format: "%02x", $0) }.joined()
        return config + "/sessions/\(pid).\(hash).key"
    }
    static func configurations(home: String = NSHomeDirectory()) -> [String] {
        var roots = [ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [] {
            if name.hasPrefix(".claude-") { roots.append(home + "/" + name) }
        }
        return Array(Set(roots)).sorted().filter {
            var info = stat()
            return lstat($0 + "/sessions", &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
        }
    }
    static func token(configs: [String], socket: String) -> String? {
        guard let pid = Int32(((socket as NSString).lastPathComponent as NSString).deletingPathExtension) else { return nil }
        for root in configs {
            let key = keyPath(config: root, pid: pid, socket: socket)
            var info = stat()
            guard lstat(key, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o077 == 0, let bytes = try? Data(contentsOf: URL(fileURLWithPath: key)),
                  let object = PeerJSON.object(bytes), object["procStart"] as? String == (try? processStart(pid)),
                  let token = object["peerToken"] as? String, token.count == 32,
                  token.allSatisfy({ $0.isHexDigit }) else { continue }
            return token
        }
        return nil
    }
    static func sessions(configs: [String]) -> [[String: Any]] {
        var result: [String: [String: Any]] = [:]
        let starts = processStarts()
        for root in configs {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: root + "/sessions")) ?? [] {
                guard file.hasSuffix(".json"), let pid = Int32(file.dropLast(5)) else { continue }
                let path = root + "/sessions/" + file
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                      let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)), var item = PeerJSON.object(bytes),
                      (item["pid"] as? NSNumber)?.int32Value == pid, item["peerProtocol"] as? Int == 1,
                      let start = starts[pid], item["procStart"] as? String == start,
                      item["pidDomain"] as? String == nil || item["pidDomain"] as? String == "darwin",
                      let socket = item["messagingSocketPath"] as? String, (try? self.socket(socket)) != nil else { continue }
                item["address"] = "uds:" + socket
                result[socket] = item
            }
        }
        return Array(result.values)
    }
}
