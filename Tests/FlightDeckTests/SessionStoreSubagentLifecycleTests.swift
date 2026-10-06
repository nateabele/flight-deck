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
    private var clock = Date(timeIntervalSince1970: 5_000_000)

    /// A dialog a human answers has been on screen for seconds, not milliseconds; the retire
    /// rule's grace window (see `SessionStore.dialogRetireGrace`) depends on that difference.
    private func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    private func make() -> (SessionStore, Session) {
        let store = SessionStore(provider: nil, persistence: nil)
        store.now = { [unowned self] in self.clock }
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
        advance(5)
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        XCTAssertNil(store.pendingDialog(for: session.id))
    }

    func testLosingTheStatusWhileWaitingRetiresThePendingDialog() {
        let (store, session) = make()
        store.applyRegistryForTesting([
            session.id: SessionStatus(activity: .waiting, waitingFor: "permission prompt")])
        store.ingestDialogChangesForTesting([.raised(session.pinnedConversationID, dialog)])
        advance(5)
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
        advance(5)
        store.applyRegistryForTesting([
            session.id: SessionStatus(activity: .waiting, waitingFor: "input needed")])
        XCTAssertNil(store.pendingDialog(for: session.id))
    }

    /// The registry may write `waiting` before it fills in why. A reason appearing where there
    /// was none is the same wait, not a new one; counting it as a move retired the dialog on
    /// its very first wait.
    func testAWaitingForThatFillsInIsNotANewWait() {
        let (store, session) = make()
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        store.ingestDialogChangesForTesting([.raised(session.pinnedConversationID, dialog)])
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .waiting)])
        advance(5)
        store.applyRegistryForTesting([
            session.id: SessionStatus(activity: .waiting, waitingFor: "permission prompt")])
        XCTAssertEqual(store.pendingDialog(for: session.id), dialog)
    }

    /// Back-to-back dialogs: A is approved, B's PermissionRequest is ingested on the same tick as
    /// a registry read that still says `busy` (the hook leads the registry by ~70ms). The edge
    /// waiting → busy belongs to A; B was raised milliseconds ago and must survive it, then be
    /// retired normally when its own wait ends.
    func testABackToBackDialogRacingAStaleBusyReadSurvivesItsPredecessorsEdge() {
        let (store, session) = make()
        let conversation = session.pinnedConversationID
        let next = PendingDialog(agentID: "a28ad87b", callID: "toolu_NEXT")
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        store.ingestDialogChangesForTesting([.raised(conversation, dialog)])
        store.applyRegistryForTesting([
            session.id: SessionStatus(activity: .waiting, waitingFor: "permission prompt")])
        advance(5)
        store.ingestDialogChangesForTesting([.raised(conversation, next)])
        advance(0.1)
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        XCTAssertEqual(store.pendingDialog(for: session.id), next, "A's edge must not retire B")
        store.applyRegistryForTesting([
            session.id: SessionStatus(activity: .waiting, waitingFor: "permission prompt")])
        advance(5)
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        XCTAssertNil(store.pendingDialog(for: session.id), "B's own edge retires it")
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

    // MARK: 4. The Mac shows the blocked agent

    func testTheDisplayTreeMarksTheAttributedAgentBlocked() {
        let (store, session) = make()
        store.applySubagents(session.id, tree())
        store.openPromptProbe = { _ in .success("toolu_SUB") }
        store.openPromptAgentProbe = { _ in "a28ad87b" }
        store.applyRegistryForTesting([
            session.id: SessionStatus(activity: .waiting, waitingFor: "permission prompt")])
        XCTAssertEqual(store.displaySubagentTree(for: session.id).node("a28ad87b")?.state,
                       .blocked(callID: "toolu_SUB"))
        XCTAssertEqual(store.displaySubagentTree(for: session.id).node("a0aaaaaa")?.state, .running)
        XCTAssertEqual(store.subagentTree(for: session.id).node("a28ad87b")?.state, .running,
                       "the stored tree stays as the files say")
    }

    func testTheBadgeShowsWhileBusyWithAgentsOrWhileAnAgentIsBlocked() {
        let blocked = tree(childState: .blocked(callID: "toolu_SUB"))
        XCTAssertEqual(SubagentCount.badge(
            status: SessionStatus(activity: .busy, subagentCount: 2), tree: tree()), 2)
        XCTAssertNil(SubagentCount.badge(status: SessionStatus(activity: .busy), tree: tree()))
        XCTAssertNil(SubagentCount.badge(
            status: SessionStatus(activity: .waiting, subagentCount: 2), tree: tree()),
                     "a parent waiting on its own dialog is not about its agents")
        XCTAssertEqual(SubagentCount.badge(
            status: SessionStatus(activity: .waiting, subagentCount: 3), tree: blocked), 3)
        XCTAssertEqual(SubagentCount.badge(
            status: SessionStatus(activity: .waiting), tree: blocked), 1, "one minimum")
        XCTAssertNil(SubagentCount.badge(status: nil, tree: tree()))
    }

    func testANewTreeIsPublishedToTheSidebar() {
        let (store, session) = make()
        var published = 0
        let sink = store.objectWillChange.sink { published += 1 }
        defer { sink.cancel() }
        store.applySubagents(session.id, tree())
        XCTAssertGreaterThan(published, 0)
    }

    // MARK: 5. Only a wire-visible change is an event

    func testATreeDifferingOnlyInModifiedEmitsNothing() {
        let (store, session) = make()
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy, subagentCount: 1)])
        store.applySubagents(session.id, tree(modified: Date(timeIntervalSince1970: 1_000)))
        let replicator = attachedReplicator(to: store)
        let later = Date(timeIntervalSince1970: 2_000)
        store.applySubagents(session.id, tree(modified: later))
        XCTAssertTrue(replicator.recorded.isEmpty, "\(replicator.recorded)")
        XCTAssertEqual(store.subagentTree(for: session.id).node("a28ad87b")?.modified, later,
                       "the latest tree is still stored")
        store.applySubagents(session.id, tree(modified: later, childState: .done))
        XCTAssertEqual(activityEvents(replicator, session.id).count, 1)
    }
}
