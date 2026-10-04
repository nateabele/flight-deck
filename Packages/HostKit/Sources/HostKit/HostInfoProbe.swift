import Foundation

public struct HostInfoProbe: Sendable {
    private let stateRoot: URL
    private let hostdVersion: String
    private let run: @Sendable (String, [String]) -> String?

    /// `run` is injected so tests (and a host with no docker) never depend on what is
    /// installed on the machine running them.
    public init(stateRoot: URL, hostdVersion: String,
                run: @escaping @Sendable (String, [String]) -> String? = HostInfoProbe.runCommand) {
        self.stateRoot = stateRoot
        self.hostdVersion = hostdVersion
        self.run = run
    }

    /// Every field degrades to empty/nil rather than failing: a host without Docker or Xcode
    /// is a normal host, not an error.
    public func gather() -> HostInfo {
        HostInfo(hostName: Self.hostName(), platform: Self.platform, osVersion: osVersion(),
                 arch: Self.arch(), hostdVersion: hostdVersion, xcode: xcodeVersions(),
                 docker: dockerVersion(), diskFreeBytes: Self.diskFree(at: stateRoot))
    }

    /// Runs `path args`, returning trimmed stdout only on a clean exit 0. Because `host.info`
    /// is answered synchronously, a hang here blocks the transport, so every wait is bounded:
    /// SIGTERM at 5s, SIGKILL 1s later, and stdout is read on a side thread so a grandchild
    /// still holding the pipe cannot pin the call (worst case ~7s, returning nil).
    public static func runCommand(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }

        let box = OutputBox()
        let readDone = DispatchSemaphore(value: 0)
        let reader = out.fileHandleForReading
        DispatchQueue.global().async {
            box.data = reader.readDataToEndOfFile()
            readDone.signal()
        }

        func within(_ s: Double, _ sem: DispatchSemaphore) -> Bool { sem.wait(timeout: .now() + s) == .success }
        if !within(5, exited) {
            p.terminate()
            if !within(1, exited) {
                kill(p.processIdentifier, SIGKILL)
                _ = within(1, exited)
            }
            return nil
        }
        guard within(1, readDone) else { return nil }
        guard p.terminationReason == .exit, p.terminationStatus == 0 else { return nil }
        return String(decoding: box.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class OutputBox: @unchecked Sendable { var data = Data() }

    // MARK: - Fields

    private static var platform: String {
        #if os(Linux)
        "Linux"
        #else
        "macOS"
        #endif
    }

    private static func hostName() -> String {
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name.removeLast(".local".count) }
        return name
    }

    private static func arch() -> String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private func osVersion() -> String {
        #if os(Linux)
        let text = (try? String(contentsOfFile: "/etc/os-release", encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") where line.hasPrefix("PRETTY_NAME=") {
            return String(line.dropFirst("PRETTY_NAME=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return ""
        #else
        if let v = output("/usr/bin/sw_vers", ["-productVersion"]) { return v }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    /// The injected runner's stdout, trimmed, or nil when it failed or printed nothing.
    private func output(_ path: String, _ args: [String]) -> String? {
        guard let v = run(path, args)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    private func dockerVersion() -> String? {
        for dir in ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"] {
            if let v = output("\(dir)/docker", ["version", "--format", "{{.Server.Version}}"]) { return v }
        }
        return nil
    }

    /// Read from each bundle's version.plist rather than running `xcodebuild -version`, which
    /// reports only the *selected* Xcode and is slow.
    /// Skipped when `xcode-select -p` finds no developer directory: a Mac with neither Xcode
    /// nor the command-line tools has nothing to report, and the check keeps the probe
    /// driven by the injected runner rather than the machine it happens to run on.
    private func xcodeVersions() -> [String] {
        #if os(Linux)
        return []
        #else
        guard output("/usr/bin/xcode-select", ["-p"]) != nil else { return [] }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        return apps.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted().compactMap { app in
            let plist = "/Applications/\(app)/Contents/version.plist"
            guard let data = FileManager.default.contents(atPath: plist),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = obj as? [String: Any]
            else { return nil }
            return dict["CFBundleShortVersionString"] as? String
        }
        #endif
    }

    /// Measured at the state root (walking up to the nearest existing ancestor, since a fresh
    /// host has not created it yet) because that is the volume the host's data lands on.
    private static func diskFree(at root: URL) -> Int64 {
        var url = root
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        #if os(Linux)
        var s = statvfs()
        guard statvfs(url.path, &s) == 0 else { return 0 }
        return Int64(s.f_bavail) * Int64(s.f_frsize)
        #else
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(v?.volumeAvailableCapacity ?? 0)
        #endif
    }
}
