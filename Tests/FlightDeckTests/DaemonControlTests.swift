import Darwin
import Foundation
import XCTest
@testable import FlightDeck

/// `PosixDaemonControl` against real `AF_UNIX` sockets and, for the pid-bearing paths, a real
/// `fd-abduco` process — the same artifact `scripts/build-fd-abduco.sh` produces for the app
/// bundle. Not a stub: `isLive`'s whole job is distinguishing "nobody is listening" from "a
/// stale file is lying about it" from "something really is there", and that distinction lives
/// in kernel connect() semantics no fake can reproduce.
final class DaemonControlTests: XCTestCase {
    private let sessionID = UUID(uuidString: "9C2F9F3E-9C2A-4E6C-8E3D-4B6A3E7C9A11")!

    private var tempDir: URL!
    private var daemon: SessionDaemon!
    private var control: PosixDaemonControl!

    /// Any real `fd-abduco` this test spawned, so `tearDown` can make sure it is dead even if
    /// an assertion fails partway through — this worktree's process table is shared with other
    /// sessions and a leaked `sleep 30` (or the daemon holding it) is exactly the kind of orphan
    /// `SessionReaper` exists to prevent elsewhere in this app.
    private var spawnedPIDs: [pid_t] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Space-free and short, for the same `sun_path` reason `SessionDaemonPathsTests` gives:
        // a full-length descriptive directory name plus a `<uuid>.sock` file name blows well
        // past the 104-byte `sun_path` cap, which does not error here so much as silently
        // truncate (via `strlcpy`) — every socket op then targets a different path than the
        // test asserts against. An 8-character suffix is still unique enough to not collide
        // between parallel test runs, and leaves the whole budget for the session id.
        tempDir = URL(fileURLWithPath: "/tmp/fdc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        daemon = SessionDaemon(directory: tempDir, bundledBinary: nil)
        control = PosixDaemonControl(daemon: daemon)
    }

    override func tearDownWithError() throws {
        for pid in spawnedPIDs {
            kill(pid, SIGKILL)
        }
        spawnedPIDs.removeAll()
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - isLive, no real daemon

    func testIsLiveFalseWhenNoSocketExists() {
        XCTAssertFalse(control.isLive(sessionID))
    }

    func testIsLiveTrueWhenSomethingIsListening() throws {
        let listener = try bindListener(at: daemon.socketPath(for: sessionID))
        defer { close(listener) }

        XCTAssertTrue(control.isLive(sessionID))
    }

    func testIsLiveFalseAfterListenerGoesAway() throws {
        let listener = try bindListener(at: daemon.socketPath(for: sessionID))
        close(listener)
        // The listener closing does not remove the socket file by itself — only the explicit
        // `unlink` below (mirroring a crashed daemon) does, and that is the case this proves.
        unlink(daemon.socketPath(for: sessionID))

        XCTAssertFalse(control.isLive(sessionID))
    }

    func testIsLiveFalseAndUnlinksStaleSocketFileWithNoListener() throws {
        let path = daemon.socketPath(for: sessionID)
        let pidPath = daemon.pidfilePath(for: sessionID)

        // A socket *file* with nothing listening behind it — bind and immediately close,
        // leaving the name on disk exactly as a crashed daemon would.
        let listener = try bindListener(at: path)
        close(listener)
        try Data("12345\n".utf8).write(to: URL(fileURLWithPath: pidPath))

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(control.isLive(sessionID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidPath))
    }

    // MARK: - daemonPID / terminate, against a real fd-abduco

    func testDaemonPIDMatchesPidfileAndIsLiveIsTrueForARealDaemon() throws {
        let binary = try realFdAbducoBinary()
        let socketPath = daemon.socketPath(for: sessionID)
        try spawnDaemon(binary: binary, socketPath: socketPath)

        let pidFromFile = try waitForPidfile(daemon.pidfilePath(for: sessionID))
        XCTAssertEqual(control.daemonPID(sessionID), pidFromFile)
        XCTAssertTrue(control.isLive(sessionID))
    }

    func testTerminateKillsTheDaemonAndRemovesSocketAndPidfile() throws {
        let binary = try realFdAbducoBinary()
        let socketPath = daemon.socketPath(for: sessionID)
        try spawnDaemon(binary: binary, socketPath: socketPath)

        let pidfilePath = daemon.pidfilePath(for: sessionID)
        _ = try waitForPidfile(pidfilePath)
        XCTAssertTrue(control.isLive(sessionID))

        control.terminate(sessionID)

        XCTAssertFalse(control.isLive(sessionID))
        XCTAssertNil(control.daemonPID(sessionID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidfilePath))
    }

    // MARK: - Helpers

    /// A real `AF_UNIX`/`SOCK_STREAM` listener at `path`, mirroring the connect-side idiom in
    /// `AnswerTriggerSocket.start()`.
    private func bindListener(at path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PosixError.errno("socket", errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: 104) {
                _ = strlcpy($0, path, 104)
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
            throw PosixError.errno("bind", code)
        }
        guard listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            throw PosixError.errno("listen", code)
        }
        return fd
    }

    /// Builds `vendor/fd-abduco-artifacts/fd-abduco` if it is missing, then returns its path.
    private func realFdAbducoBinary() throws -> String {
        let path = "vendor/fd-abduco-artifacts/fd-abduco"
        if !FileManager.default.fileExists(atPath: path) {
            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            build.arguments = ["bash", "scripts/build-fd-abduco.sh"]
            try build.run()
            build.waitUntilExit()
            XCTAssertEqual(build.terminationStatus, 0, "scripts/build-fd-abduco.sh failed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        return path
    }

    /// `fd-abduco -n <sock> sh -c 'sleep 30'`: a real daemon backing a shell that outlives this
    /// test by design (30 s), so `tearDown`'s `SIGKILL` is what actually bounds its lifetime
    /// rather than it exiting on its own before that.
    private func spawnDaemon(binary: String, socketPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(binary)
        process.arguments = ["-n", socketPath, "sh", "-c", "sleep 30"]
        try process.run()
        spawnedPIDs.append(process.processIdentifier)
    }

    /// Polls for the pidfile `fd-abduco` writes at session creation (see
    /// `Tests/fd-abduco/run_pidfile_test.sh`), up to a couple of seconds.
    private func waitForPidfile(_ path: String) throws -> pid_t {
        for _ in 0..<40 {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8),
                let value = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid_t(value)
            }
            usleep(50_000)
        }
        throw PosixError.timedOut("pidfile never appeared at \(path)")
    }

    private enum PosixError: Error, CustomStringConvertible {
        case errno(String, Int32)
        case timedOut(String)

        var description: String {
            switch self {
            case .errno(let call, let code):
                return "\(call) failed: \(String(cString: strerror(code)))"
            case .timedOut(let message):
                return message
            }
        }
    }
}
