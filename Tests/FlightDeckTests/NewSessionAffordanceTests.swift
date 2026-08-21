import AppKit
import XCTest
@testable import FlightDeck

final class NewSessionAffordanceTests: XCTestCase {
    private let two: [AgentSettings] = [
        AgentSettings(id: .claude, options: .claude(FlagSet())),
        AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
    ]

    func testSlotsBindShortcutsByListPosition() {
        let slots = NewSessionAffordance.slots(for: two)
        XCTAssertEqual(slots.map(\.agent), [.claude, .codex])
        XCTAssertEqual(slots[0].modifiers, [.command])
        XCTAssertEqual(slots[1].modifiers, [.command, .shift])
    }

    func testAThirdAgentTakesCommandShiftOption() {
        var three = two
        three.append(AgentSettings(id: .claude, options: .claude(FlagSet())))
        XCTAssertEqual(NewSessionAffordance.slots(for: three)[2].modifiers, [.command, .shift, .option])
    }

    func testReorderingRebindsTheShortcuts() {
        // The whole point of the drag-to-reorder list: position IS the binding.
        let slots = NewSessionAffordance.slots(for: two.reversed())
        XCTAssertEqual(slots[0].agent, .codex)
        XCTAssertEqual(slots[0].modifiers, [.command])
    }

    func testLabelNamesTheAgentThatWouldLaunch() {
        XCTAssertEqual(NewSessionAffordance.slots(for: two)[1].label, "New Codex Session")
    }

    func testHeldModifiersResolveToTheSlotTheyWouldTrigger() {
        // Drives the live button label: holding ⇧ while ⌘ is down must read "New Codex Session".
        XCTAssertEqual(NewSessionAffordance.resolve([.command, .shift], in: two)?.agent, .codex)
        XCTAssertEqual(NewSessionAffordance.resolve([.shift], in: two)?.agent, .codex,
                       "the button shows the shift variant even before ⌘ goes down")
        XCTAssertEqual(NewSessionAffordance.resolve([], in: two)?.agent, .claude)
    }

    func testUnboundModifierCombinationsFallBackToTheFirstSlot() {
        XCTAssertEqual(NewSessionAffordance.resolve([.control], in: two)?.agent, .claude)
    }

    func testShortcutDisplayUsesTheStandardGlyphs() {
        let slots = NewSessionAffordance.slots(for: two)
        XCTAssertEqual(slots[0].shortcutDisplay, "⌘N")
        XCTAssertEqual(slots[1].shortcutDisplay, "⇧⌘N")
    }

    /// Shortcuts follow the project's order, so ⌘N is always the agent this project uses.
    func testSlotsFollowTheProjectOrder() {
        let order = [
            AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
            AgentSettings(id: .claude, options: .claude(FlagSet())),
        ]
        XCTAssertEqual(NewSessionAffordance.slots(for: order).first?.agent, .codex)
    }

    /// An agent with one account contributes one flat row; more than one nests them, so the
    /// common case does not grow a submenu.
    func testTheMenuNestsOnlyWhenAnAgentHasSeveralAccounts() {
        let one = AgentAccount(agent: .claude, displayName: "Personal", home: URL(fileURLWithPath: "/a"))
        let two = AgentAccount(agent: .claude, displayName: "Work", home: URL(fileURLWithPath: "/b"))
        let flat = NewSessionAffordance.menu(
            agents: [AgentSettings(id: .claude, options: .claude(FlagSet()))],
            accounts: [one], resolved: [.claude: one.id]
        )
        XCTAssertEqual(flat, [.agent(.claude, account: one.id, isResolved: true)])

        let nested = NewSessionAffordance.menu(
            agents: [AgentSettings(id: .claude, options: .claude(FlagSet()))],
            accounts: [one, two], resolved: [.claude: two.id]
        )
        XCTAssertEqual(nested, [
            .submenu(.claude, [
                .agent(.claude, account: one.id, isResolved: false),
                .agent(.claude, account: two.id, isResolved: true),
            ])
        ])
    }

    /// The resolved leaf gets the chord that a submenu's parent item cannot itself carry —
    /// the same row the checkmark already marks, so the shortcut and the visible default
    /// never disagree.
    func testShortcutLeafPicksTheResolvedAccount() {
        let rows: [NewSessionAffordance.MenuEntry] = [
            .agent(.claude, account: UUID(), isResolved: false),
            .agent(.claude, account: UUID(), isResolved: true),
        ]
        guard case .agent(_, let resolved, true) = rows[1] else { return XCTFail("expected the resolved row") }
        XCTAssertEqual(NewSessionAffordance.shortcutLeaf(in: rows), resolved)
    }

    /// A chord bound by list position must never simply go dead: if nothing in the submenu
    /// happens to be resolved, the first row still answers it.
    func testShortcutLeafFallsBackToTheFirstRowWhenNothingIsResolved() {
        let first = UUID()
        let rows: [NewSessionAffordance.MenuEntry] = [
            .agent(.claude, account: first, isResolved: false),
            .agent(.claude, account: UUID(), isResolved: false),
        ]
        XCTAssertEqual(NewSessionAffordance.shortcutLeaf(in: rows), first)
    }

    func testShortcutLeafOfEmptyRowsIsNil() {
        XCTAssertNil(NewSessionAffordance.shortcutLeaf(in: []))
    }

    // MARK: - chords

    /// A flat row wears its agent's list-position chord. This is what the sidebar dropdown
    /// renders, and it has to agree with the File menu, which reads the same function.
    func testChordsFollowAgentListPosition() {
        let claude = AgentAccount(agent: .claude, displayName: "Personal", home: URL(fileURLWithPath: "/a"))
        let codex = AgentAccount(agent: .codex, displayName: "Personal", home: URL(fileURLWithPath: "/b"))
        let entries = NewSessionAffordance.menu(
            agents: two, accounts: [claude, codex],
            resolved: [.claude: claude.id, .codex: codex.id]
        )
        let chords = NewSessionAffordance.chords(for: entries, agents: two)
        XCTAssertEqual(chords[claude.id], [.command])
        XCTAssertEqual(chords[codex.id], [.command, .shift])
    }

    /// Inside a submenu only the resolved leaf carries the chord — the sibling accounts stay
    /// bare, which is the bug the sidebar had when every row inherited ⌘N from its container.
    func testChordsLandOnOneLeafPerSubmenu() {
        let personal = AgentAccount(agent: .claude, displayName: "Personal", home: URL(fileURLWithPath: "/a"))
        let work = AgentAccount(agent: .claude, displayName: "Work", home: URL(fileURLWithPath: "/b"))
        let agents = [AgentSettings(id: .claude, options: .claude(FlagSet()))]
        let entries = NewSessionAffordance.menu(
            agents: agents, accounts: [personal, work], resolved: [.claude: work.id]
        )
        let chords = NewSessionAffordance.chords(for: entries, agents: agents)
        XCTAssertEqual(chords[work.id], [.command], "the resolved leaf answers the agent's chord")
        XCTAssertNil(chords[personal.id], "a sibling account is a mouse-only pick, not a rebind")
        XCTAssertEqual(chords.count, 1)
    }

    /// Reordering the agent list moves the chord with it, exactly as `slots(for:)` does —
    /// the dropdown must not keep showing ⌘N next to an agent that no longer answers it.
    func testChordsMoveWhenAgentsAreReordered() {
        let claude = AgentAccount(agent: .claude, displayName: "Personal", home: URL(fileURLWithPath: "/a"))
        let codex = AgentAccount(agent: .codex, displayName: "Personal", home: URL(fileURLWithPath: "/b"))
        let reversed = Array(two.reversed())
        let entries = NewSessionAffordance.menu(
            agents: reversed, accounts: [claude, codex],
            resolved: [.claude: claude.id, .codex: codex.id]
        )
        let chords = NewSessionAffordance.chords(for: entries, agents: reversed)
        XCTAssertEqual(chords[codex.id], [.command])
        XCTAssertEqual(chords[claude.id], [.command, .shift])
    }

    /// `slots(for:)` binds only three agents, so a fourth row shows no chord rather than
    /// inventing one.
    func testAFourthAgentGetsNoChord() {
        var agents = two
        agents.append(AgentSettings(id: .codex, options: .codex(CodexThreadOptions())))
        agents.append(AgentSettings(id: .claude, options: .claude(FlagSet())))
        let accounts = [
            AgentAccount(agent: .claude, displayName: "Personal", home: URL(fileURLWithPath: "/a")),
            AgentAccount(agent: .codex, displayName: "Personal", home: URL(fileURLWithPath: "/b")),
        ]
        let entries = NewSessionAffordance.menu(
            agents: agents, accounts: accounts,
            resolved: [.claude: accounts[0].id, .codex: accounts[1].id]
        )
        let chords = NewSessionAffordance.chords(for: entries, agents: agents)
        // Two distinct agent ids across four rows, so at most two accounts can be chorded.
        XCTAssertLessThanOrEqual(chords.count, 2)
        XCTAssertTrue(chords.values.allSatisfy { NewSessionAffordance.slots(for: agents).map(\.modifiers).contains($0) })
    }

    /// An agent with no account contributes no row, so it contributes no chord either.
    func testChordsAreEmptyWithoutAccounts() {
        XCTAssertTrue(NewSessionAffordance.chords(for: [], agents: two).isEmpty)
    }
}
