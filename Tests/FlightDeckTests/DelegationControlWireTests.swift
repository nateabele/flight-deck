import FleetKit
import XCTest
@testable import FlightDeck

/// The CLI ↔ app half of the delegated-execution contract (task C0). The CLI and the app are
/// separate binaries that a release can skew, and two tracks build each side in parallel, so
/// every op and tag is pinned to its bytes rather than trusted to a round trip.
@MainActor
final class DelegationControlWireTests: XCTestCase {
    private func sorted<T: Encodable>(_ value: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    private func roundTrips(_ request: FleetRequest, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(ClientFrame.req(cid: 2, request))
        XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), .req(cid: 2, request),
                       file: file, line: line)
    }

    private func roundTrips(_ frame: ServerFrame, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(frame)), frame,
                       file: file, line: line)
    }

    private let everyRequest: [DelegateRequest] = [
        .run(WireDelegateRun(cwd: "/r")), .exec(WireDelegateRun(cwd: "/r")), .up(WireDelegateRun(cwd: "/r")),
        .down(service: "db", cwd: "/r"), .restart(service: "db", cwd: "/r"), .sync(service: "db", cwd: "/r"),
        .ps, .wait(run: "r1", timeout: 60), .wait(run: "r1", timeout: nil), .logs(run: "r1", follow: true),
        .stop(run: "r1"), .diff(run: "r1"), .apply(run: "r1"), .recipeList(cwd: "/r"),
        .recipeAdd(cwd: "/r", name: "t", recipe: WireRecipe(name: "t", run: "make")), .recipeCheck(cwd: "/r"),
    ]

    // MARK: Requests

    func testRunRequestShapeIsPinned() throws {
        let run = WireDelegateRun(cwd: "/w/app", host: "mini", recipe: nil, command: ["xcodebuild", "test"],
                                  include: [".env"], fetch: ["build/*.xcresult"], env: ["K": "V"],
                                  ports: ["auto:5432"], pty: true, screen: true, detach: false,
                                  columns: 120, rows: 40)
        XCTAssertEqual(try sorted(FleetRequest.delegate(.run(run))),
                       #"{"op":"delegate.run","run":{"columns":120,"command":["xcodebuild","test"],"cwd":"/w/app","#
                       + #""detach":false,"env":{"K":"V"},"fetch":["build/*.xcresult"],"host":"mini","#
                       + #""include":[".env"],"ports":["auto:5432"],"pty":true,"rows":40,"screen":true}}"#)
    }

    /// A CLI that leaves every flag off sends only `cwd`, and that must read as all defaults:
    /// the lenient decode is what lets the C6 CLI omit empty lists without a second contract.
    func testRunRequestDecodesWithDefaults() throws {
        let req = try JSONDecoder().decode(FleetRequest.self,
                                           from: Data(#"{"op":"delegate.exec","run":{"cwd":"/w"}}"#.utf8))
        XCTAssertEqual(req, .delegate(.exec(WireDelegateRun(cwd: "/w"))))
    }

    func testEveryOpIsPinned() throws {
        let ops = try everyRequest.map { request -> String in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(FleetRequest.delegate(request)))
                                     as? [String: Any])
            return try XCTUnwrap(json["op"] as? String)
        }
        XCTAssertEqual(ops, ["delegate.run", "delegate.exec", "delegate.up", "delegate.down", "delegate.restart",
                             "delegate.sync", "delegate.ps", "delegate.wait", "delegate.wait", "delegate.logs",
                             "delegate.stop", "delegate.diff", "delegate.apply", "recipe.ls", "recipe.add",
                             "recipe.check"])
    }

    func testTargetedRequestShapesArePinned() throws {
        XCTAssertEqual(try sorted(FleetRequest.delegate(.down(service: "db", cwd: "/r"))),
                       #"{"cwd":"/r","op":"delegate.down","service":"db"}"#)
        XCTAssertEqual(try sorted(FleetRequest.delegate(.ps)), #"{"op":"delegate.ps"}"#)
        XCTAssertEqual(try sorted(FleetRequest.delegate(.wait(run: "r1", timeout: 60))),
                       #"{"op":"delegate.wait","run":"r1","timeout":60}"#)
        XCTAssertEqual(try sorted(FleetRequest.delegate(.wait(run: "r1", timeout: nil))),
                       #"{"op":"delegate.wait","run":"r1"}"#)
        XCTAssertEqual(try sorted(FleetRequest.delegate(.logs(run: "r1", follow: true))),
                       #"{"follow":true,"op":"delegate.logs","run":"r1"}"#)
        XCTAssertEqual(try sorted(FleetRequest.delegate(.recipeAdd(cwd: "/r", name: "t",
                                                                   recipe: WireRecipe(name: "t", run: "make")))),
                       #"{"cwd":"/r","name":"t","op":"recipe.add","recipe":{"apply":"review","env":{},"fetch":[],"#
                       + #""long":false,"name":"t","ports":[],"restartOnSync":false,"run":"make","screen":false,"service":false}}"#)
    }

    func testEveryRequestRoundTrips() throws {
        for request in everyRequest { try roundTrips(.delegate(request)) }
    }

    /// The forwarding case must not swallow the ops that were here first, nor an op nobody
    /// knows: the first would answer a `host.info` as a delegation, the second would guess.
    func testOlderOpsAndUnknownOpsAreUntouched() throws {
        XCTAssertEqual(try JSONDecoder().decode(FleetRequest.self, from: Data(#"{"op":"host.list"}"#.utf8)), .hostList)
        XCTAssertThrowsError(try JSONDecoder().decode(FleetRequest.self, from: Data(#"{"op":"delegate.teleport"}"#.utf8)))
    }

    // MARK: Replies

    func testReplyShapesArePinned() throws {
        XCTAssertEqual(try sorted(ServerFrame.delegateStarted(cid: 3, WireDelegateStarted(runID: "r1", host: "mini"))),
                       #"{"cid":3,"run":{"host":"mini","runID":"r1"},"t":"delegateStarted"}"#)
        XCTAssertEqual(try sorted(ServerFrame.delegateNotice(cid: 3, message: "waiting for mini's screen")),
                       #"{"cid":3,"message":"waiting for mini's screen","t":"delegateNotice"}"#)
        XCTAssertEqual(try sorted(ServerFrame.delegateOutput(cid: 3, stream: "stdout", data: Data("hi".utf8))),
                       #"{"cid":3,"data":"aGk=","stream":"stdout","t":"delegateOutput"}"#)
        XCTAssertEqual(try sorted(ServerFrame.delegateExit(cid: 3, status: 137)),
                       #"{"cid":3,"status":137,"t":"delegateExit"}"#)
        XCTAssertEqual(try sorted(ServerFrame.delegatePatch(cid: 3, WireDelegatePatch(runID: "r1", patch: "diff"))),
                       #"{"cid":3,"patch":{"patch":"diff","runID":"r1"},"t":"delegatePatch"}"#)
        XCTAssertEqual(try sorted(ServerFrame.delegateApplied(cid: 3, WireDelegateApplied(runID: "r1", conflicts: ["a.swift"]))),
                       #"{"applied":{"conflicts":["a.swift"],"runID":"r1"},"cid":3,"t":"delegateApplied"}"#)
        XCTAssertEqual(try sorted(ServerFrame.recipeCheck(cid: 3, problems: [])),
                       #"{"cid":3,"problems":[],"t":"recipeCheck"}"#)
        XCTAssertEqual(try sorted(ServerFrame.delegateRuns(cid: 3, [WireDelegateRunRow(
                           runID: "r1", host: "mini", command: "make", recipe: nil, kind: "service",
                           state: "running", status: nil, ports: ["5432:5432"], startedAt: nil)])),
                       #"{"cid":3,"runs":[{"command":"make","host":"mini","kind":"service","ports":["5432:5432"],"#
                       + #""runID":"r1","state":"running"}],"t":"delegateRuns"}"#)
        XCTAssertEqual(try sorted(ServerFrame.recipes(cid: 3, WireRecipeBook(defaultHost: "mini", include: [".env"],
                           recipes: [], routes: [WireRoute(match: "xcodebuild test *", recipe: "ui")]))),
                       #"{"cid":3,"recipes":{"defaultHost":"mini","include":[".env"],"recipes":[],"#
                       + #""routes":[{"match":"xcodebuild test *","recipe":"ui"}]},"t":"recipes"}"#)
    }

    func testEveryReplyRoundTripsAndIsCorrelated() throws {
        let frames: [ServerFrame] = [
            .delegateStarted(cid: 5, WireDelegateStarted(runID: "r", host: "h")),
            .delegateNotice(cid: 5, message: "m"),
            .delegateOutput(cid: 5, stream: "pty", data: Data([0, 255])),
            .delegateExit(cid: 5, status: 0),
            .delegateRuns(cid: 5, []),
            .delegatePatch(cid: 5, WireDelegatePatch(runID: "r", patch: "")),
            .delegateApplied(cid: 5, WireDelegateApplied(runID: "r", conflicts: [])),
            .recipes(cid: 5, WireRecipeBook(defaultHost: nil, include: [], recipes: [WireRecipe(name: "n", run: "r")],
                                            routes: [])),
            .recipeCheck(cid: 5, problems: ["recipe.x: run is required"]),
        ]
        for frame in frames {
            try roundTrips(frame)
            XCTAssertEqual(frame.correlationID, 5, "\(frame)")
        }
    }

    // MARK: Scope

    private let me = UUID()
    private var writes: [DelegateRequest] { everyRequest.filter { !$0.isReadOnly } }

    /// The ruling: `ps`, `logs`, `diff` and `recipe ls` read; everything else writes.
    func testReadOnlySetIsExactlyTheRuling() {
        XCTAssertEqual(everyRequest.filter(\.isReadOnly),
                       [.ps, .logs(run: "r1", follow: true), .diff(run: "r1"), .recipeList(cwd: "/r")])
    }

    func testDelegateReadsArePermittedEverywhere() {
        for r in everyRequest where r.isReadOnly {
            for level in ControlScopeLevel.allCases {
                for caller in [ControlCaller.human, .session(me), .invalid] {
                    XCTAssertTrue(ControlScope.permits(.delegate(r), level: level, caller: caller), "\(level) \(caller) \(r)")
                }
            }
        }
    }

    /// A delegation write is the caller's own, like `prompt`: allowed for a human, and for a
    /// valid session at `.full` and `.ownSession` — unlike `openConversation`, which a session
    /// may not reach under `.ownSession`.
    func testDelegateWritesFollowTheOwnSessionRule() {
        for r in writes {
            for level in ControlScopeLevel.allCases {
                XCTAssertTrue(ControlScope.permits(.delegate(r), level: level, caller: .human), "\(level) \(r)")
            }
            XCTAssertTrue(ControlScope.permits(.delegate(r), level: .full, caller: .session(me)), "\(r)")
            XCTAssertTrue(ControlScope.permits(.delegate(r), level: .ownSession, caller: .session(me)), "\(r)")
            XCTAssertFalse(ControlScope.permits(.delegate(r), level: .readOnly, caller: .session(me)), "\(r)")
            XCTAssertFalse(ControlScope.permits(.delegate(r), level: .ownSession, caller: .invalid), "\(r)")
            XCTAssertFalse(ControlScope.permits(.delegate(r), level: .readOnly, caller: .invalid), "\(r)")
        }
    }

    // MARK: Service

    /// Until `DelegationService` lands, the app refuses every delegation request by name, with
    /// a message the CLI prints, rather than leaving a CLI waiting on an answer.
    func testFleetServiceRefusesDelegationAsNotImplemented() async throws {
        let harness = try FleetServiceHarness(hosts: ["mini"])
        try await harness.start()
        defer { harness.stop() }
        for request in [DelegateRequest.run(WireDelegateRun(cwd: "/", command: ["true"])), .ps, .recipeList(cwd: "/")] {
            let reply = try await harness.request(.delegate(request))
            guard case .err(_, let code, let message) = reply else { return XCTFail("\(request): \(reply)") }
            XCTAssertEqual(code, "not_implemented")
            XCTAssertNotNil(message)
        }
    }
}
