import XCTest
@testable import HostKit

/// The delegated-execution contract (spec §4–§9) as bytes. Seven tracks build against these
/// shapes in parallel and a Linux hostd decodes them months after a Mac encoded them, so every
/// frame is pinned to its literal rather than trusted to a round trip, which would pass just
/// as happily after a rename changed the wire on both ends of one build.
final class DelegationWireTests: XCTestCase {
    private let ref = SnapshotRef(repoRoot: "r00t", wtKey: "k1", worktreeName: "flight-deck",
                                  commit: "c0ffee", tree: "7ree")
    private let refJSON = #"{"commit":"c0ffee","repoRoot":"r00t","tree":"7ree","worktreeName":"flight-deck","wtKey":"k1"}"#

    private func req(_ r: DelegationRequest) throws -> String {
        try HostWire.encode(HostClientFrame.request(id: 1, .delegation(r)))
    }

    private func rep(_ r: DelegationReply) throws -> String {
        try HostWire.encode(HostServerFrame.reply(id: 1, .delegation(r)))
    }

    // MARK: Requests

    func testSyncRequestShapesArePinned() throws {
        XCTAssertEqual(try req(.syncTips(repoRoot: "r00t", wtKey: "k1")),
                       #"{"id":1,"req":{"op":"sync.tips","repoRoot":"r00t","wtKey":"k1"},"t":"req"}"#)
        XCTAssertEqual(try req(.syncPush(ref: ref, channel: 3)),
                       #"{"id":1,"req":{"channel":3,"op":"sync.push","ref":"# + refJSON + #"},"t":"req"}"#)
    }

    /// Submodule pins ride inside `ref`, only when there are any: a submodule-free snapshot is
    /// byte-identical to what every earlier build sent (pinned above), and a ref from one of
    /// those builds, which has no such key, still decodes.
    func testSnapshotRefCarriesSubmodulePinsOnlyWhenThereAreAny() throws {
        let pinned = SnapshotRef(repoRoot: "r00t", wtKey: "k1", worktreeName: "flight-deck", commit: "c0ffee", tree: "7ree",
                                 submodules: [SubmodulePin(path: "vendor/lib", commit: "b0b", url: "https://example.com/lib.git")])
        XCTAssertEqual(try req(.syncPush(ref: pinned, channel: 3)),
                       #"{"id":1,"req":{"channel":3,"op":"sync.push","ref":{"commit":"c0ffee","repoRoot":"r00t","#
                       + #""submodules":[{"commit":"b0b","path":"vendor/lib","url":"https://example.com/lib.git"}],"#
                       + #""tree":"7ree","worktreeName":"flight-deck","wtKey":"k1"}},"t":"req"}"#)
        let decoded = try JSONDecoder().decode(SnapshotRef.self, from: Data(try JSONEncoder().encode(pinned)))
        XCTAssertEqual(decoded, pinned)
        XCTAssertEqual(try JSONDecoder().decode(SnapshotRef.self, from: Data(refJSON.utf8)), ref)
        XCTAssertEqual(try JSONDecoder().decode(SnapshotRef.self, from: Data(refJSON.utf8)).submodules, [])
    }

    func testRunStartShapeIsPinned() throws {
        let spec = RunSpec(command: "make test", subdir: "pkg", env: ["A": "1"], pty: true, screen: false,
                           service: true, downCommand: "make down",
                           ports: [PortMapping(local: .fixed(15432), remote: 5432),
                                   PortMapping(local: .auto, remote: 3000)],
                           ptySize: TerminalSize(columns: 120, rows: 40), fetch: ["build/*.log"], pool: 3,
                           orphanTimeout: 600)
        XCTAssertEqual(try req(.runStart(ref: ref, spec: spec, owner: "laptop/tab", apply: true)),
                       #"{"id":1,"req":{"apply":true,"op":"run.start","owner":"laptop/tab","ref":"# + refJSON
                       + #","spec":{"command":"make test","downCommand":"make down","env":{"A":"1"},"#
                       + #""fetch":["build/*.log"],"orphanTimeout":600,"pool":3,"#
                       + #""ports":[{"local":15432,"remote":5432},{"local":"auto","remote":3000}],"#
                       + #""pty":true,"ptySize":{"columns":120,"rows":40},"screen":false,"service":true,"subdir":"pkg"}},"t":"req"}"#)
    }

    /// The optionals are omitted, not `null`: a hostd reading `"downCommand":null` and one
    /// reading no key must not be two different contracts.
    func testRunSpecOmitsAbsentOptionals() throws {
        let spec = RunSpec(command: "true", subdir: "", env: [:], pty: false, screen: false, service: false,
                           downCommand: nil, ports: [])
        XCTAssertEqual(try HostWire.encode(spec),
                       #"{"command":"true","env":{},"fetch":[],"ports":[],"pty":false,"screen":false,"service":false,"subdir":""}"#)
    }

    /// Every field added after the first wire version decodes when absent, so a 1.1 peer built
    /// before it (C0's shape) is still read: `fetch` as [], the optionals as nil.
    func testRunSpecDecodesTheFirstVersionsShape() throws {
        let spec = try HostWire.decode(RunSpec.self, from:
            #"{"command":"true","env":{},"ports":[],"pty":false,"screen":false,"service":false,"subdir":""}"#)
        XCTAssertEqual(spec, RunSpec(command: "true", subdir: "", env: [:], pty: false, screen: false,
                                     service: false, downCommand: nil, ports: []))
        XCTAssertEqual(spec.fetch, [])
        XCTAssertNil(spec.pool)
        XCTAssertNil(spec.orphanTimeout)
        XCTAssertNil(spec.ptySize)
    }

    func testSnapshotRefAndScreenStatusDecodeTheFirstVersionsShape() throws {
        XCTAssertEqual(try HostWire.decode(SnapshotRef.self, from: refJSON), ref)
        XCTAssertEqual(try HostWire.decode(ScreenStatus.self, from:
                        #"{"consoleUser":true,"locked":false,"queued":0,"supported":true}"#),
                       ScreenStatus(supported: true, consoleUser: true, locked: false, holder: nil, queued: 0))
    }

    func testRunControlRequestShapesArePinned() throws {
        XCTAssertEqual(try req(.runAttach(runID: "r1", offset: 4096)),
                       #"{"id":1,"req":{"offset":4096,"op":"run.attach","runID":"r1"},"t":"req"}"#)
        XCTAssertEqual(try req(.runSignal(runID: "r1", signal: 2)),
                       #"{"id":1,"req":{"op":"run.signal","runID":"r1","signal":2},"t":"req"}"#)
        XCTAssertEqual(try req(.runCancel(runID: "r1")),
                       #"{"id":1,"req":{"op":"run.cancel","runID":"r1"},"t":"req"}"#)
        XCTAssertEqual(try req(.runResult(runID: "r1", channel: 5)),
                       #"{"id":1,"req":{"channel":5,"op":"run.result","runID":"r1"},"t":"req"}"#)
        XCTAssertEqual(try req(.runArtifacts(runID: "r1", globs: ["build/**/*.xcresult"], channel: 7)),
                       #"{"id":1,"req":{"channel":7,"globs":["build/**/*.xcresult"],"op":"run.artifacts","runID":"r1"},"t":"req"}"#)
    }

    /// `run.ack` (ruling 24): sent once the controller has *stored* a result, so a connection
    /// that drops after the host's last write but before the bytes landed keeps the result.
    func testRunAckShapeIsPinned() throws {
        XCTAssertEqual(try req(.runAck(runID: "r1", repoRoot: "r00t")),
                       #"{"id":1,"req":{"op":"run.ack","repoRoot":"r00t","runID":"r1"},"t":"req"}"#)
        XCTAssertEqual(try rep(.runAck), #"{"id":1,"rep":{"op":"run.ack"},"t":"reply"}"#)
    }

    /// Lenient on `repoRoot`: an ack naming only the run still decodes, and the host finds the
    /// repo from the run it started. Strict, a peer that left the key off would have its ack
    /// answered `unsupported` and every result it fetched kept until the TTL.
    func testRunAckDecodesWithoutRepoRoot() throws {
        XCTAssertEqual(try HostWire.decode(HostRequest.self, from: #"{"op":"run.ack","runID":"r1"}"#),
                       .delegation(.runAck(runID: "r1", repoRoot: nil)))
    }

    func testServiceAndScreenRequestShapesArePinned() throws {
        XCTAssertEqual(try req(.portCheck(ports: [5432, 80])),
                       #"{"id":1,"req":{"op":"port.check","ports":[5432,80]},"t":"req"}"#)
        XCTAssertEqual(try req(.portOpen(service: "r1", remote: 5432, channel: 9)),
                       #"{"id":1,"req":{"channel":9,"op":"port.open","remote":5432,"service":"r1"},"t":"req"}"#)
        XCTAssertEqual(try req(.serviceDown(service: "r1")),
                       #"{"id":1,"req":{"op":"service.down","service":"r1"},"t":"req"}"#)
        XCTAssertEqual(try req(.serviceSync(service: "r1", ref: ref)),
                       #"{"id":1,"req":{"op":"service.sync","ref":"# + refJSON + #","service":"r1"},"t":"req"}"#)
        XCTAssertEqual(try req(.screenStatus),
                       #"{"id":1,"req":{"op":"screen.status"},"t":"req"}"#)
    }

    func testWorkspaceRequestShapesArePinned() throws {
        XCTAssertEqual(try req(.workspaceUsage),
                       #"{"id":1,"req":{"op":"workspace.usage"},"t":"req"}"#)
        XCTAssertEqual(try req(.workspacePrune(repoRoot: "r00t")),
                       #"{"id":1,"req":{"op":"workspace.prune","repoRoot":"r00t"},"t":"req"}"#)
        // Absent, not null: the whole controller's workspace.
        XCTAssertEqual(try req(.workspacePrune(repoRoot: nil)),
                       #"{"id":1,"req":{"op":"workspace.prune"},"t":"req"}"#)
    }

    // MARK: Replies

    func testReplyShapesArePinned() throws {
        XCTAssertEqual(try rep(.syncTips(tips: ["a1", "b2"])),
                       #"{"id":1,"rep":{"op":"sync.tips","tips":["a1","b2"]},"t":"reply"}"#)
        XCTAssertEqual(try rep(.syncPush), #"{"id":1,"rep":{"op":"sync.push"},"t":"reply"}"#)
        XCTAssertEqual(try rep(.runStart(runID: "r1")),
                       #"{"id":1,"rep":{"op":"run.start","runID":"r1"},"t":"reply"}"#)
        XCTAssertEqual(try rep(.runAttach), #"{"id":1,"rep":{"op":"run.attach"},"t":"reply"}"#)
        XCTAssertEqual(try rep(.runSignal), #"{"id":1,"rep":{"op":"run.signal"},"t":"reply"}"#)
        XCTAssertEqual(try rep(.runCancel), #"{"id":1,"rep":{"op":"run.cancel"},"t":"reply"}"#)
        XCTAssertEqual(try rep(.runResult(commit: "abc")),
                       #"{"id":1,"rep":{"commit":"abc","op":"run.result"},"t":"reply"}"#)
        // Nothing changed: no key, so "no result" is not a commit spelled `null`.
        XCTAssertEqual(try rep(.runResult(commit: nil)), #"{"id":1,"rep":{"op":"run.result"},"t":"reply"}"#)
        XCTAssertEqual(try rep(.runArtifacts(found: false)),
                       #"{"id":1,"rep":{"found":false,"op":"run.artifacts"},"t":"reply"}"#)
        XCTAssertEqual(try rep(.portOpen), #"{"id":1,"rep":{"op":"port.open"},"t":"reply"}"#)
        XCTAssertEqual(try rep(.serviceDown), #"{"id":1,"rep":{"op":"service.down"},"t":"reply"}"#)
        XCTAssertEqual(try rep(.serviceSync), #"{"id":1,"rep":{"op":"service.sync"},"t":"reply"}"#)
        XCTAssertEqual(try rep(.usage([WorkspaceUsage(repoRoot: "r00t", worktreeName: "flight-deck", bytes: 1 << 33)])),
                       #"{"id":1,"rep":{"op":"workspace.usage","usage":[{"bytes":8589934592,"repoRoot":"r00t","worktreeName":"flight-deck"}]},"t":"reply"}"#)
        XCTAssertEqual(try rep(.workspacePrune), #"{"id":1,"rep":{"op":"workspace.prune"},"t":"reply"}"#)
    }

    func testPortCheckReplyShapeIsPinned() throws {
        let statuses = [PortStatus(port: 1, holder: .free),
                        PortStatus(port: 2, holder: .process(name: "postgres", pid: 812)),
                        PortStatus(port: 3, holder: .container(name: "db-1")),
                        PortStatus(port: 4, holder: .flightDeck(session: "api tests")),
                        PortStatus(port: 5, holder: .unknown)]
        XCTAssertEqual(try rep(.portCheck(statuses)),
                       #"{"id":1,"rep":{"op":"port.check","ports":["#
                       + #"{"holder":{"kind":"free"},"port":1},"#
                       + #"{"holder":{"kind":"process","name":"postgres","pid":812},"port":2},"#
                       + #"{"holder":{"kind":"container","name":"db-1"},"port":3},"#
                       + #"{"holder":{"kind":"flightDeck","session":"api tests"},"port":4},"#
                       + #"{"holder":{"kind":"unknown"},"port":5}]},"t":"reply"}"#)
    }

    func testScreenStatusReplyShapeIsPinned() throws {
        XCTAssertEqual(try rep(.screenStatus(ScreenStatus(supported: true, consoleUser: true, locked: false,
                                                          holder: LeaseHolder(runID: "r7", session: "ui tests"),
                                                          queued: 1))),
                       #"{"id":1,"rep":{"op":"screen.status","screen":{"consoleUser":true,"holder":{"runID":"r7","session":"ui tests"},"locked":false,"queued":1,"supported":true}},"t":"reply"}"#)
        XCTAssertEqual(try HostWire.encode(ScreenStatus(supported: false, consoleUser: false, locked: false,
                                                       holder: nil, queued: 0)),
                       #"{"consoleUser":false,"locked":false,"queued":0,"supported":false}"#)
    }

    // MARK: Events

    func testEventShapesArePinned() throws {
        func ev(_ e: RunEvent) throws -> String { try HostWire.encode(HostServerFrame.event(runID: "r1", e)) }
        XCTAssertEqual(try ev(.queued(position: 2, on: .screen, holder: LeaseHolder(runID: "r0", session: "ui"))),
                       #"{"ev":{"holder":{"runID":"r0","session":"ui"},"kind":"queued","on":"screen","position":2},"runID":"r1","t":"event"}"#)
        XCTAssertEqual(try ev(.queued(position: 1, on: .slot, holder: nil)),
                       #"{"ev":{"kind":"queued","on":"slot","position":1},"runID":"r1","t":"event"}"#)
        XCTAssertEqual(try ev(.started(runID: "r1")),
                       #"{"ev":{"kind":"started","runID":"r1"},"runID":"r1","t":"event"}"#)
        XCTAssertEqual(try ev(.output(stream: .stderr, offset: 10, data: Data("hi".utf8))),
                       #"{"ev":{"data":"aGk=","kind":"output","offset":10,"stream":"stderr"},"runID":"r1","t":"event"}"#)
        XCTAssertEqual(try ev(.exited(.code(3))),
                       #"{"ev":{"exit":{"code":3},"kind":"exited"},"runID":"r1","t":"event"}"#)
        XCTAssertEqual(try ev(.serviceDied(.signal(9))),
                       #"{"ev":{"exit":{"signal":9},"kind":"serviceDied"},"runID":"r1","t":"event"}"#)
    }

    func testOutputStreamRawValuesArePinned() {
        XCTAssertEqual([RunOutputStream.stdout, .stderr, .pty].map(\.rawValue), ["stdout", "stderr", "pty"])
    }

    // MARK: Round trips

    func testEveryFrameRoundTrips() throws {
        let spec = RunSpec(command: "x", subdir: "", env: [:], pty: false, screen: true, service: false,
                           downCommand: nil, ports: [PortMapping(local: .fixed(80), remote: 80)])
        let requests: [DelegationRequest] = [
            .syncTips(repoRoot: "r", wtKey: "k"), .syncPush(ref: ref, channel: 1),
            .runStart(ref: ref, spec: spec, owner: "o", apply: false), .runAttach(runID: "r", offset: 0),
            .runSignal(runID: "r", signal: 15), .runCancel(runID: "r"), .runResult(runID: "r", channel: 2),
            .runArtifacts(runID: "r", globs: [], channel: 3), .portCheck(ports: [1]),
            .portOpen(service: "s", remote: 2, channel: 4), .serviceDown(service: "s"),
            .serviceSync(service: "s", ref: ref), .screenStatus, .workspaceUsage,
            .workspacePrune(repoRoot: nil), .workspacePrune(repoRoot: "r"),
            .runAck(runID: "r", repoRoot: "r"), .runAck(runID: "r", repoRoot: nil),
        ]
        for r in requests {
            let frame = HostClientFrame.request(id: 9, .delegation(r))
            XCTAssertEqual(try HostWire.decode(HostClientFrame.self, from: HostWire.encode(frame)), frame)
        }
        let replies: [DelegationReply] = [
            .syncTips(tips: []), .syncPush, .runStart(runID: "r"), .runAttach, .runSignal, .runCancel,
            .runResult(commit: nil), .runResult(commit: "c"), .runArtifacts(found: true),
            .portCheck([PortStatus(port: 1, holder: .process(name: "n", pid: 2))]), .portOpen, .serviceDown,
            .serviceSync,
            .screenStatus(ScreenStatus(supported: true, consoleUser: false, locked: true, holder: nil, queued: 0)),
            .usage([]), .usage([WorkspaceUsage(repoRoot: "r", worktreeName: "w", bytes: 0)]), .workspacePrune,
            .runAck,
        ]
        for r in replies {
            let frame = HostServerFrame.reply(id: 9, .delegation(r))
            XCTAssertEqual(try HostWire.decode(HostServerFrame.self, from: HostWire.encode(frame)), frame)
        }
        let events: [RunEvent] = [
            .queued(position: 1, on: .slot, holder: nil),
            .queued(position: 3, on: .screen, holder: LeaseHolder(runID: "r0", session: "s")), .started(runID: "r"),
            .output(stream: .pty, offset: 1 << 40, data: Data([0, 255, 10])), .exited(.code(0)),
            .exited(.signal(15)), .serviceDied(.code(1)),
        ]
        for e in events {
            let frame = HostServerFrame.event(runID: "r", e)
            XCTAssertEqual(try HostWire.decode(HostServerFrame.self, from: HostWire.encode(frame)), frame)
        }
    }

    /// `host.info` keeps its exact bytes beside the new ops, both ways: a 1.0 hostd must still
    /// read a 1.1 controller's `host.info` and vice versa.
    func testHostInfoKeepsItsShapeBesideTheNewOps() throws {
        XCTAssertEqual(try HostWire.encode(HostClientFrame.request(id: 1, .hostInfo)),
                       #"{"id":1,"req":{"op":"host.info"},"t":"req"}"#)
        XCTAssertEqual(try HostWire.decode(HostRequest.self, from: #"{"op":"host.info"}"#), .hostInfo)
    }

    /// An op neither 1.0 nor 1.1 knows still throws, so `HostServerCore` answers it
    /// `unsupported` by id rather than misreading it as some other request.
    func testUnknownOpThrows() {
        XCTAssertThrowsError(try HostWire.decode(HostRequest.self, from: #"{"op":"run.teleport"}"#))
        XCTAssertThrowsError(try HostWire.decode(HostReply.self, from: #"{"op":"run.teleport"}"#))
        XCTAssertThrowsError(try HostWire.decode(HostServerFrame.self,
                                                 from: #"{"t":"event","runID":"r","ev":{"kind":"teleported"}}"#))
    }

    /// A `RunExit` is exactly one of the two keys. Both, or neither, is a peer bug, and
    /// guessing which it meant would report the wrong exit status to an agent.
    func testRunExitRejectsAmbiguousShapes() {
        XCTAssertThrowsError(try HostWire.decode(RunExit.self, from: #"{"code":1,"signal":2}"#))
        XCTAssertThrowsError(try HostWire.decode(RunExit.self, from: #"{}"#))
    }

    // MARK: Capabilities

    func testNewCapabilitiesAreAdvertisedUnderTheirNames() throws {
        XCTAssertEqual(try HostWire.encode(HostClientFrame.hello(
            protocolVersion: .current, capabilities: [.hostInfo, .run, .sync, .service, .screen],
            controllerName: "laptop")),
            #"{"caps":["host.info","run","sync","service","screen"],"name":"laptop","t":"hello","v":{"major":1,"minor":1}}"#)
    }

    /// Each op names the capability a peer must advertise before it is sent, so a 1.1
    /// controller never sends `run.start` to a host that only said `host.info`.
    func testEveryOpNamesItsCapability() {
        XCTAssertEqual(DelegationRequest.syncTips(repoRoot: "", wtKey: "").capability, .sync)
        XCTAssertEqual(DelegationRequest.syncPush(ref: ref, channel: 1).capability, .sync)
        XCTAssertEqual(DelegationRequest.runCancel(runID: "").capability, .run)
        XCTAssertEqual(DelegationRequest.runArtifacts(runID: "", globs: [], channel: 1).capability, .run)
        XCTAssertEqual(DelegationRequest.portCheck(ports: []).capability, .service)
        XCTAssertEqual(DelegationRequest.serviceSync(service: "", ref: ref).capability, .service)
        XCTAssertEqual(DelegationRequest.screenStatus.capability, .screen)
        XCTAssertEqual(DelegationRequest.workspaceUsage.capability, .sync)
        XCTAssertEqual(DelegationRequest.workspacePrune(repoRoot: nil).capability, .sync)
    }

    func testWaitReasonRawValuesArePinned() {
        XCTAssertEqual([WaitReason.screen, .slot].map(\.rawValue), ["screen", "slot"])
    }

    // MARK: RunExit.cliStatus

    func testCliStatusMapsCodesAndSignals() {
        XCTAssertEqual(RunExit.code(3).cliStatus, 3)
        XCTAssertEqual(RunExit.code(0).cliStatus, 0)
        XCTAssertEqual(RunExit.signal(9).cliStatus, 137)
        XCTAssertEqual(RunExit.signal(2).cliStatus, 130)
    }

    // MARK: PortMapping.parse

    func testPortMappingParsesTheThreeNotations() throws {
        XCTAssertEqual(try PortMapping.parse("5432"), PortMapping(local: .fixed(5432), remote: 5432))
        XCTAssertEqual(try PortMapping.parse("15432:5432"), PortMapping(local: .fixed(15432), remote: 5432))
        XCTAssertEqual(try PortMapping.parse("auto:5432"), PortMapping(local: .auto, remote: 5432))
        XCTAssertEqual(try PortMapping.parse("65535:1"), PortMapping(local: .fixed(65535), remote: 1))
    }

    func testPortMappingRejectsNonsense() {
        for bad in ["0", "70000", "a:b", "auto:auto", "", "auto", "5432:", ":5432", "0:80", "80:0",
                    "1:2:3", "+80", "-1", " 80", "80 ", "5432:auto", "65536"] {
            XCTAssertThrowsError(try PortMapping.parse(bad), "accepted \"\(bad)\"")
        }
    }

    /// The wire refuses port 0 as `parse` does, on either side, so a peer bug cannot reach the
    /// forwarder as a mapping the command line could never have produced.
    func testPortMappingDecodeRefusesPortZero() throws {
        XCTAssertEqual(try HostWire.decode(PortMapping.self, from: #"{"local":"auto","remote":5432}"#),
                       PortMapping(local: .auto, remote: 5432))
        for bad in [#"{"local":0,"remote":5432}"#, #"{"local":15432,"remote":0}"#, #"{"local":"auto","remote":0}"#] {
            XCTAssertThrowsError(try HostWire.decode(PortMapping.self, from: bad), "accepted \(bad)")
        }
    }

    func testPortMappingNotationRoundTripsThroughParse() throws {
        for text in ["5432:5432", "15432:5432", "auto:3000"] {
            XCTAssertEqual(try PortMapping.parse(text).notation, text)
        }
    }

    // MARK: Channel frames

    /// `[u32 BE channel][u8 kind][payload]`, pinned byte for byte: the mux on a Linux hostd and
    /// the one in the app are two builds of one codec, and an endianness slip would only show
    /// up as a stall at the first channel numbered above 255.
    func testChannelFrameLayoutIsPinned() throws {
        XCTAssertEqual(Array(ChannelFrame(channel: 0x0102_0304, kind: .data, payload: Data([0xAA])).encoded()),
                       [1, 2, 3, 4, 0, 0xAA])
        XCTAssertEqual(Array(ChannelFrame.credit(channel: 7, bytes: 0x0004_0000).encoded()),
                       [0, 0, 0, 7, 1, 0, 4, 0, 0])
        XCTAssertEqual(Array(ChannelFrame(channel: 7, kind: .eof).encoded()), [0, 0, 0, 7, 2])
        XCTAssertEqual(Array(ChannelFrame(channel: 7, kind: .close).encoded()), [0, 0, 0, 7, 3])
        XCTAssertEqual(ChannelFrame.initialCredit, 256 * 1024)
        XCTAssertEqual(ChannelFrame.maxPayload, 64 * 1024)
    }

    func testChannelFrameDecodes() throws {
        XCTAssertEqual(try ChannelFrame(decoding: Data([0, 0, 1, 0, 0, 0x41, 0x42])),
                       ChannelFrame(channel: 256, kind: .data, payload: Data("AB".utf8)))
        let credit = try ChannelFrame(decoding: Data([0, 0, 0, 7, 1, 0, 4, 0, 0]))
        XCTAssertEqual(credit.creditBytes, 0x0004_0000)
    }

    /// A short frame, an unknown kind, a credit that is not exactly four bytes, or a payload on
    /// an eof/close all throw: each is a peer bug, and reading past it would desync every
    /// channel sharing the connection.
    func testChannelFrameRejectsMalformedFrames() {
        for bad: [UInt8] in [[], [0, 0, 0, 1], [0, 0, 0, 1, 4], [0, 0, 0, 1, 1, 0, 0],
                             [0, 0, 0, 1, 2, 0], [0, 0, 0, 1, 3, 9]] {
            XCTAssertThrowsError(try ChannelFrame(decoding: Data(bad)), "accepted \(bad)")
        }
    }

    // MARK: Config types

    /// A recipe read from JSON (`recipe.ls`, a future controller) fills every field `delegate.toml`
    /// may leave out with the spec's default, rather than throwing on the first absent key.
    func testRecipeDecodesWithDefaults() throws {
        let recipe = try HostWire.decode(Recipe.self, from: #"{"run":"make"}"#)
        XCTAssertEqual(recipe, Recipe(run: "make"))
        XCTAssertFalse(recipe.screen)
        XCTAssertEqual(recipe.apply, .review)
        XCTAssertNil(recipe.pool)
        XCTAssertEqual(ApplyMode.auto.rawValue, "auto")
    }
}
