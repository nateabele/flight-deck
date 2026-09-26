import FleetKit
import XCTest
@testable import FlightDeck

final class ControlScopeTests: XCTestCase {
    private let me = UUID()
    private let other = UUID()
    private let project = UUID()

    private func commands(targeting id: UUID) -> [FleetCommand] {
        [.markRead(id: id), .markUnread(id: id), .closeSession(id: id),
         .renameSession(id: id, title: "t"), .prompt(id: id, token: UUID(), text: "x"),
         .answerPrompt(id: id, token: UUID(), call: "c", answer: .allow),
         .annotatePlan(id: id, token: UUID(), call: "c", text: "x", block: nil),
         .resolvePlan(id: id, token: UUID(), call: "c", approve: true, feedback: nil),
         .abortPrompt(id: id, token: UUID())]
    }
    private var fleetWide: [FleetCommand] {
        [.newSession(project: project), .reopenClosed(session: other),
         .setProjectCollapsed(id: project, isCollapsed: true)]
    }
    private let reads: [FleetRequest] = [.timeline(session: UUID(), anchor: .latest, limit: 5),
        .newSessionOptions(project: UUID()), .recentlyClosed, .macEndpoints, .conversations,
        .search(query: "q", limit: 5)]
    private let open = FleetRequest.openConversation(conversationID: "c", projectPath: "/p")

    func testFullPermitsEverythingFromAnyCaller() {
        for caller in [ControlCaller.human, .session(me), .invalid] {
            for c in commands(targeting: other) + fleetWide {
                XCTAssertTrue(ControlScope.permits(c, level: .full, caller: caller), "\(c)")
            }
            XCTAssertTrue(ControlScope.permits(open, level: .full, caller: caller))
        }
    }

    func testAHumanShellIsNeverScoped() {
        for level in ControlScopeLevel.allCases {
            for c in commands(targeting: other) + fleetWide {
                XCTAssertTrue(ControlScope.permits(c, level: level, caller: .human), "\(level) \(c)")
            }
        }
    }

    func testOwnSessionReachesOnlyItself() {
        for c in commands(targeting: me) {
            XCTAssertTrue(ControlScope.permits(c, level: .ownSession, caller: .session(me)), "\(c)")
        }
        for c in commands(targeting: other) + fleetWide {
            XCTAssertFalse(ControlScope.permits(c, level: .ownSession, caller: .session(me)), "\(c)")
        }
        for r in reads { XCTAssertTrue(ControlScope.permits(r, level: .ownSession, caller: .session(me))) }
        XCTAssertFalse(ControlScope.permits(open, level: .ownSession, caller: .session(me)),
                       "openConversation opens a tab, which is a write")
    }

    func testReadOnlyRefusesEveryWriteButStillReads() {
        for c in commands(targeting: me) + fleetWide {
            XCTAssertFalse(ControlScope.permits(c, level: .readOnly, caller: .session(me)), "\(c)")
        }
        for r in reads { XCTAssertTrue(ControlScope.permits(r, level: .readOnly, caller: .session(me))) }
        XCTAssertFalse(ControlScope.permits(open, level: .readOnly, caller: .session(me)))
    }

    func testViewingIsAlwaysPermitted() {
        for level in ControlScopeLevel.allCases {
            for caller in [ControlCaller.human, .session(me), .invalid] {
                XCTAssertTrue(ControlScope.permits(.viewing(session: other), level: level, caller: caller))
            }
        }
    }

    func testAnInvalidTokenFailsClosedWhenScoped() {
        for level in [ControlScopeLevel.ownSession, .readOnly] {
            for c in commands(targeting: me) + fleetWide {
                XCTAssertFalse(ControlScope.permits(c, level: level, caller: .invalid), "\(level) \(c)")
            }
        }
    }

    func testCallerResolution() {
        let secret = Data(repeating: 7, count: 32)
        XCTAssertEqual(ControlScope.caller(token: nil, secret: secret), .human)
        XCTAssertEqual(ControlScope.caller(token: "nope", secret: secret), .invalid)
        XCTAssertEqual(ControlScope.caller(token: ControlEnvironment.token(for: me, secret: secret),
                                           secret: secret), .session(me))
    }

    func testLevelDefaultsToFullAndReadsItsKey() {
        let suite = "ControlScopeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ControlScope.level(defaults), .full)
        defaults.set("readOnly", forKey: ControlScope.defaultsKey)
        XCTAssertEqual(ControlScope.level(defaults), .readOnly)
        defaults.set("bogus", forKey: ControlScope.defaultsKey)
        XCTAssertEqual(ControlScope.level(defaults), .full)
    }
}
