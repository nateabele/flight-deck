import XCTest
@testable import FlightDeck

final class LaunchPlanTests: XCTestCase {
    private let sessionID = UUID(uuidString: "A8CF5A53-1A20-4E2C-B5D1-6FCA4E6D73AF")!

    private var tempDir: URL!
    private var fakeBinary: URL!

    override func setUpWithError() throws {
        // Space-free temp root, same reasoning as SessionDaemonPathsTests: the command builders
        // this decision is built on assert their tokens contain no spaces, and a scratch dir
        // with a space in it would defeat that from the test side.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fd-launch-plan-tests-\(UUID().uuidString)")
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

    private func makeDaemon() -> SessionDaemon {
        SessionDaemon(
            directory: tempDir.appendingPathComponent("run"),
            bundledBinary: fakeBinary
        )
    }

    func testLiveSessionDecidesAttach() throws {
        let daemon = makeDaemon()

        let plan = try LaunchPlan.decide(
            sessionID: sessionID,
            isLive: true,
            shell: "/bin/zsh",
            resumeOrLaunch: "claude --resume abc",
            daemon: daemon
        )

        guard case .attach(let command) = plan else {
            XCTFail("expected .attach, got \(plan)")
            return
        }
        XCTAssertEqual(command, try daemon.attachCommand(for: sessionID))
        XCTAssertFalse(command.contains(" -a  "))
        XCTAssertEqual(plan.command, command)
        XCTAssertEqual(plan.typed, "")
    }

    func testDeadSessionDecidesColdCreateWithNonemptyTyped() throws {
        let daemon = makeDaemon()
        let typed = "claude --resume abc"

        let plan = try LaunchPlan.decide(
            sessionID: sessionID,
            isLive: false,
            shell: "/bin/zsh",
            resumeOrLaunch: typed,
            daemon: daemon
        )

        guard case .coldCreate(let command, let planTyped) = plan else {
            XCTFail("expected .coldCreate, got \(plan)")
            return
        }
        XCTAssertEqual(command, try daemon.coldCreateCommand(for: sessionID, shell: "/bin/zsh"))
        XCTAssertEqual(planTyped, typed)
        XCTAssertEqual(plan.command, command)
        XCTAssertEqual(plan.typed, typed)
    }

    func testDeadSessionDecidesColdCreateWithEmptyTyped() throws {
        let daemon = makeDaemon()

        let plan = try LaunchPlan.decide(
            sessionID: sessionID,
            isLive: false,
            shell: "/bin/zsh",
            resumeOrLaunch: "",
            daemon: daemon
        )

        guard case .coldCreate(let command, let planTyped) = plan else {
            XCTFail("expected .coldCreate, got \(plan)")
            return
        }
        XCTAssertEqual(command, try daemon.coldCreateCommand(for: sessionID, shell: "/bin/zsh"))
        XCTAssertEqual(planTyped, "")
        XCTAssertEqual(plan.typed, "")
    }

    func testCommandsContainNoSpaceInBinaryOrSocketTokens() throws {
        let daemon = makeDaemon()

        let attachPlan = try LaunchPlan.decide(
            sessionID: sessionID, isLive: true, shell: "/bin/zsh",
            resumeOrLaunch: "", daemon: daemon
        )
        let coldPlan = try LaunchPlan.decide(
            sessionID: sessionID, isLive: false, shell: "/bin/zsh",
            resumeOrLaunch: "", daemon: daemon
        )

        let expectedBinary = try daemon.resolvedBinaryPath()
        let expectedSocket = daemon.socketPath(for: sessionID)
        XCTAssertFalse(expectedBinary.contains(" "))
        XCTAssertFalse(expectedSocket.contains(" "))
        XCTAssertTrue(attachPlan.command.contains(expectedBinary))
        XCTAssertTrue(attachPlan.command.contains(expectedSocket))
        XCTAssertTrue(coldPlan.command.contains(expectedBinary))
        XCTAssertTrue(coldPlan.command.contains(expectedSocket))
    }
}
