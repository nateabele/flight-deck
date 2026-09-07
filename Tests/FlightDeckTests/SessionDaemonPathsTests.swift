import XCTest
@testable import FlightDeck

final class SessionDaemonPathsTests: XCTestCase {
    private let sessionID = UUID(uuidString: "A8CF5A53-1A20-4E2C-B5D1-6FCA4E6D73AF")!

    private var tempDir: URL!
    private var fakeBinary: URL!

    override func setUpWithError() throws {
        // A space-free temp root: the whole point of the symlink under test is to hide the
        // real bundle's space-containing path from ghostty's tokenizer, and a scratch dir with
        // a space in it would defeat that from the test side before the code under test ever
        // runs.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fd-session-daemon-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        fakeBinary = tempDir.appendingPathComponent("fake-fd-abduco")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeBinary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDaemon(binary: URL? = nil) -> SessionDaemon {
        SessionDaemon(
            directory: tempDir.appendingPathComponent("run"),
            bundledBinary: binary ?? fakeBinary
        )
    }

    // MARK: - Path shapes

    func testSocketPathShape() {
        let daemon = makeDaemon()
        XCTAssertEqual(
            daemon.socketPath(for: sessionID),
            daemon.directory.path + "/a8cf5a53-1a20-4e2c-b5d1-6fca4e6d73af.sock"
        )
    }

    func testPidfilePathIsSocketPathPlusSuffix() {
        let daemon = makeDaemon()
        XCTAssertEqual(
            daemon.pidfilePath(for: sessionID),
            daemon.socketPath(for: sessionID) + ".pid"
        )
    }

    /// macOS caps `sun_path` (the field abduco's `AF_UNIX` socket name lands in) at 104 bytes,
    /// including the NUL terminator. A path that only fits by coincidence on this machine's
    /// temp-dir length would be a landmine on someone else's.
    func testSocketPathFitsInSunPathLimit() {
        let daemon = SessionDaemon(
            directory: URL(fileURLWithPath: "/tmp/flight-deck-501"),
            bundledBinary: fakeBinary
        )
        XCTAssertLessThan(daemon.socketPath(for: sessionID).utf8.count, 104)
    }

    // MARK: - ensureDirectory

    func testEnsureDirectoryCreatesMode0700() throws {
        let daemon = makeDaemon()
        try daemon.ensureDirectory()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: daemon.directory.path, isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)

        let attrs = try FileManager.default.attributesOfItem(atPath: daemon.directory.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o700)
    }

    func testEnsureDirectoryIsIdempotent() throws {
        let daemon = makeDaemon()
        try daemon.ensureDirectory()
        try daemon.ensureDirectory()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: daemon.directory.path, isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    // MARK: - resolvedBinaryPath

    func testResolvedBinaryPathCreatesSpaceFreeSymlinkToFakeBinary() throws {
        let daemon = makeDaemon()
        let resolved = try daemon.resolvedBinaryPath()

        XCTAssertFalse(resolved.contains(" "))
        XCTAssertEqual(resolved, daemon.directory.appendingPathComponent("fd-abduco").path)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: resolved)
        XCTAssertEqual(destination, fakeBinary.path)
    }

    func testResolvedBinaryPathIsIdempotent() throws {
        let daemon = makeDaemon()
        let first = try daemon.resolvedBinaryPath()
        let second = try daemon.resolvedBinaryPath()
        XCTAssertEqual(first, second)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: second)
        XCTAssertEqual(destination, fakeBinary.path)
    }

    /// A stale link (left over from an earlier bundle at a different path, e.g. after an app
    /// update) must be re-pointed, not merely tolerated.
    func testResolvedBinaryPathRePointsWhenTargetChanges() throws {
        let daemon = makeDaemon()
        _ = try daemon.resolvedBinaryPath()

        let otherBinary = tempDir.appendingPathComponent("other-fd-abduco")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: otherBinary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: otherBinary.path
        )

        let repointed = makeDaemon(binary: otherBinary)
        let resolved = try repointed.resolvedBinaryPath()

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: resolved)
        XCTAssertEqual(destination, otherBinary.path)
    }

    func testResolvedBinaryPathThrowsWhenBundledBinaryIsNil() {
        let daemon = SessionDaemon(directory: tempDir.appendingPathComponent("run"), bundledBinary: nil)
        XCTAssertThrowsError(try daemon.resolvedBinaryPath())
    }

    // MARK: - Commands

    func testAttachCommandHasNoSpacesInBinaryOrSocketTokens() throws {
        let daemon = makeDaemon()
        let command = try daemon.attachCommand(for: sessionID)

        let expectedBinary = try daemon.resolvedBinaryPath()
        let expectedSocket = daemon.socketPath(for: sessionID)
        XCTAssertEqual(command, "\(expectedBinary) -a \(expectedSocket)")
        XCTAssertFalse(expectedBinary.contains(" "))
        XCTAssertFalse(expectedSocket.contains(" "))
    }

    func testColdCreateCommandHasNoSpacesInBinaryOrSocketTokens() throws {
        let daemon = makeDaemon()
        let command = try daemon.coldCreateCommand(for: sessionID, shell: "/bin/zsh")

        let expectedBinary = try daemon.resolvedBinaryPath()
        let expectedSocket = daemon.socketPath(for: sessionID)
        XCTAssertEqual(command, "\(expectedBinary) -c \(expectedSocket) /bin/zsh")
        XCTAssertFalse(expectedBinary.contains(" "))
        XCTAssertFalse(expectedSocket.contains(" "))
    }
}
