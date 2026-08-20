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
}
