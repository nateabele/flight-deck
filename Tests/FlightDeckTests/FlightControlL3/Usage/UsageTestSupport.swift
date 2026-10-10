import Foundation
import XCTest
import IntakeKit
@testable import FlightDeck

/// Shared by the L3-U tests. Every name is prefixed `Usage…`: the test target is one module, so an
/// unprefixed `TestClock` here would collide with a sibling branch's at integration.
enum UsageFixtures {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Token.self).url(forResource: name, withExtension: "json", subdirectory: "Fixtures/FlightControlL3/Usage"),
            "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    static func object(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
    }
}

/// ISO 8601 with or without fractional seconds, for writing times in tests the way the
/// fixtures spell them.
func usageISO(_ text: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: text) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: text)!
}

final class UsageTestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date = usageISO("2026-10-04T18:00:00Z")) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

enum UsageRefs {
    /// The account `usage-timeline.json` (L3-0) is written for.
    static let workID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let spareID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let codexID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let work = AccountRef(agent: .claude, id: workID, label: "Work")
    static let spare = AccountRef(agent: .claude, id: spareID, label: "Spare")
    static let codex = AccountRef(agent: .codex, id: codexID, label: "Codex")

    static func reading(_ account: AccountRef, _ worst: Double, at: Date, resetsAt: Date? = nil,
                        rejection: Bool = false) -> UsageReading {
        UsageReading(account: account, windows: [UsageWindow(name: "five_hour", utilization: worst, resetsAt: resetsAt)],
                     readAt: at, source: "test", hardRejection: rejection)
    }
}

/// Records `br`/`am` invocations instead of running them.
final class UsageRecordingRunner: FlywheelProcessRunner, @unchecked Sendable {
    struct Call: Equatable { let executable: String; let args: [String]; let cwd: String? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var exitCode: Int32 = 0
    var stdout = ""
    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        lock.withLock { recorded.append(Call(executable: executable, args: args, cwd: cwd)) }
        return (stdout, exitCode)
    }
}

final class UsageSpyNotifier: Notifying {
    struct Note: Equatable { let session: UUID; let title: String; let body: String }
    private(set) var notes: [Note] = []
    func requestAuthorization() {}
    func notify(sessionID: UUID, title: String, subtitle: String, body: String) {
        notes.append(Note(session: sessionID, title: title, body: body))
    }
    func withdraw(sessionID: UUID) {}
}
