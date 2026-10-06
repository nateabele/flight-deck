import Combine
import XCTest
import FleetKit
@testable import FlightDeck

/// The lifetimes of the subagent state `SessionStore` keeps beside a tab's status: which dialog
/// the hook log attributed (`pendingDialogs`), the tree (`subagentTrees`), and what of either
/// reaches the wire and the sidebar.
@MainActor
final class SessionStoreSubagentLifecycleTests: XCTestCase {
    private let dialog = PendingDialog(agentID: "a28ad87b", callID: "toolu_SUB")

    private func make() -> (SessionStore, Session) {
        let store = SessionStore(provider: nil, persistence: nil)
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        return (store, session)
    }

    private func tree(modified: Date = Date(timeIntervalSince1970: 1_000),
                      childState: SubagentNode.State = .running) -> SubagentTree {
        SubagentTree(nodes: [
            SubagentNode(id: "a0aaaaaa", parentID: nil, type: "general-purpose",
                         description: "Controller", state: .running, modified: modified),
            SubagentNode(id: "a28ad87b", parentID: "a0aaaaaa", type: "implementer",
                         description: "Task 14", state: childState, modified: modified),
        ])
    }

    private let wireTree = [
        WireSubagent(id: "a0aaaaaa", parent: nil, type: "general-purpose",
                     description: "Controller", state: "running"),
        WireSubagent(id: "a28ad87b", parent: "a0aaaaaa", type: "implementer",
                     description: "Task 14", state: "running"),
    ]

    private func wireSession(_ store: SessionStore, _ id: UUID) -> WireSession? {
        FleetProjection.snapshot(of: store).projects.flatMap(\.sessions).first { $0.id == id }
    }

    private func activityEvents(_ replicator: FleetReplicator, _ id: UUID) -> [[WireSubagent]?] {
        replicator.recorded.compactMap {
            if case .activityChanged(id, _, _, _, _, _, _, let subs, _) = $0 { return subs }
            return nil
        }
    }

    // MARK: 1. A pending dialog dies with the wait it was raised for

    /// The trap: `PermissionRequest` lands ~70ms BEFORE the registry flips the tab to
    /// `waiting`, and the hook path recommits while the tab still reads busy. A rule of "clear
    /// whenever not waiting" would erase every attribution at birth.
    func testADialogRaisedWhileBusySurvivesTheFlipToWaiting() {
        let (store, session) = make()
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        store.ingestDialogChangesForTesting([.raised(session.pinnedConversationID, dialog)])
        XCTAssertEqual(store.pendingDialog(for: session.id), dialog, "the recommit while busy")
        store.applyRegistryForTesting([
            session.id: SessionStatus(activity: .waiting, waitingFor: "permission prompt")])
        XCTAssertEqual(store.pendingDialog(for: session.id), dialog)
    }

    /// Approve-in-terminal on a long-running subagent Bash fires no PostToolUse until the
    /// tool ends; leaving `waiting` is the only signal that the dialog is gone.
    func testLeavingWaitingRetiresThePendingDialog() {
        let (store, session) = make()
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        store.ingestDialogChangesForTesting([.raised(session.pinnedConversationID, dialog)])
        store.applyRegistryForTesting([
            session.id: SessionStatus(activity: .waiting, waitingFor: "permission prompt")])
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        XCTAssertNil(store.pendingDialog(for: session.id))
    }

    func testLosingTheStatusWhileWaitingRetiresThePendingDialog() {
        let (store, session) = make()
        store.applyRegistryForTesting([
            session.id: SessionStatus(activity: .waiting, waitingFor: "permission prompt")])
        store.ingestDialogChangesForTesting([.raised(session.pinnedConversationID, dialog)])
        store.applyRegistryForTesting([:])
        XCTAssertNil(store.pendingDialog(for: session.id))
    }

    /// A select list after Stop or an AskUserQuestion fires no PermissionRequest; the only
    /// trace is the registry's `waitingFor` moving under a tab that never left `waiting`.
    func testAWaitThatChangesWhatItWaitsForRetiresThePendingDialog() {
        let (store, session) = make()
        store.applyRegistryForTesting([
            session.id: SessionStatus(activity: .waiting, waitingFor: "permission prompt")])
        store.ingestDialogChangesForTesting([.raised(session.pinnedConversationID, dialog)])
        store.applyRegistryForTesting([
            session.id: SessionStatus(activity: .waiting, waitingFor: "permission prompt")])
        XCTAssertEqual(store.pendingDialog(for: session.id), dialog, "an unchanged wait keeps it")
        store.applyRegistryForTesting([
            session.id: SessionStatus(activity: .waiting, waitingFor: "input needed")])
        XCTAssertNil(store.pendingDialog(for: session.id))
    }

    func testAPromptSubmitRetiresThePendingDialogAndIsRemembered() {
        let (store, session) = make()
        let conversation = session.pinnedConversationID
        let at = Date(timeIntervalSince1970: 2_000_000)
        store.ingestDialogChangesForTesting([.raised(conversation, dialog)])
        store.ingestDialogChangesForTesting([.promptSubmitted(conversation, at)])
        XCTAssertNil(store.pendingDialog(for: session.id))
        XCTAssertEqual(store.lastPromptSubmits[conversation], at)
    }

    func testAClearedChangeRetiresThePendingDialog() {
        let (store, session) = make()
        store.ingestDialogChangesForTesting([.raised(session.pinnedConversationID, dialog)])
        store.ingestDialogChangesForTesting([.cleared(session.pinnedConversationID)])
        XCTAssertNil(store.pendingDialog(for: session.id))
    }

    // MARK: 2. The tree outlives a lost registry row

    /// A blocked agent writes nothing, so the watcher never republishes; a tree dropped on a
    /// registry blink would leave the phone holding `[]` for exactly the agent it needs.
    func testATreeSurvivesTheRegistryLosingTheTab() {
        let (store, session) = make()
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy, subagentCount: 1)])
        store.applySubagents(session.id, tree())
        let replicator = attachedReplicator(to: store)
        store.applyRegistryForTesting([:])
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy, subagentCount: 1)])
        XCTAssertEqual(activityEvents(replicator, session.id).last, wireTree,
                       "\(replicator.recorded)")
        XCTAssertEqual(wireSession(store, session.id)?.subagents, wireTree)
    }

    // MARK: 3b. No status, no tree on the wire

    func testATreeForATabWithNoStatusIsNotProjectedUntilTheStatusArrives() {
        let (store, session) = make()
        let replicator = attachedReplicator(to: store)
        store.applySubagents(session.id, tree())
        XCTAssertEqual(wireSession(store, session.id)?.subagents, [],
                       "still modelled, but the tree was never emitted")
        // Any later batch runs the drift check against what the phone was told.
        store.rename(session.id, to: "renamed")
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy, subagentCount: 1)])
        XCTAssertEqual(activityEvents(replicator, session.id).last, wireTree)
        XCTAssertEqual(wireSession(store, session.id)?.subagents, wireTree)
    }
}
