import Foundation
import IntakeKit
@testable import FlightDeck

/// Scriptable `HandoffHost`: answers what it is told and records every side effect, in order.
///
/// `events` is ONE ordered log across every side effect (and the spawn, via `host.noteSpawn()`),
/// because per-effect arrays cannot tell "spawn, then reassign, then release, then stop" from any
/// other order — the safety property of the hand-off is exactly that order.
@MainActor
final class FakeHandoffHost: HandoffHost {
    var activities: [UUID: SessionActivity] = [:]
    var rateLimited: Set<UUID> = []
    var confirmAnswer = true
    var kinds: [KindID: TaskKind] = [:]
    var reserved: [String]?
    var reassignWarning: String?
    private(set) var events: [String] = []
    private(set) var interrupted: [UUID] = []
    private(set) var confirmations: [HandoffRequest] = []
    private(set) var reassigned: [(task: String, agent: String)] = []
    private(set) var released: [String] = []
    private(set) var stopped: [UUID] = []
    private(set) var marked: [(old: UUID, new: UUID)] = []
    private(set) var log: [HandoffLogEntry] = []
    private(set) var notices: [String] = []

    func noteSpawn() { events.append("spawn") }

    func activity(of session: SessionRef) -> SessionActivity? { activities[session.id] }
    func isRateLimited(_ session: SessionRef) -> Bool { rateLimited.contains(session.id) }
    var interruptSucceeds = true
    func interrupt(_ session: SessionRef) -> Bool { events.append("interrupt"); interrupted.append(session.id); return interruptSucceeds }
    func confirm(_ request: HandoffRequest) async -> Bool { events.append("confirm"); confirmations.append(request); return confirmAnswer }
    func kind(for block: ExecutionBlock, project: URL) -> TaskKind? { kinds[block.kind] }
    func catalogs() async -> AdapterCatalogs { AdapterCatalogs([]) }
    func reservedFiles(of agent: String, project: URL) async -> [String]? { reserved }
    func reassign(task: TaskRef, to agentName: String) async -> String? {
        events.append("reassign"); reassigned.append((task.id, agentName)); return reassignWarning
    }
    func releaseReservations(of agent: String, project: URL) async -> String? { events.append("release"); released.append(agent); return nil }
    func stopAgent(_ session: SessionRef) async { events.append("stop"); stopped.append(session.id) }
    func markHandedOff(_ old: SessionRef, to new: SessionRef) { events.append("mark"); marked.append((old.id, new.id)) }
    func record(_ entry: HandoffLogEntry) { events.append("record:\(entry.outcome.rawValue)"); log.append(entry) }
    func notify(title: String, body: String, session: SessionRef) { events.append("notify"); notices.append(title) }
}
