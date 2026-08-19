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
}
