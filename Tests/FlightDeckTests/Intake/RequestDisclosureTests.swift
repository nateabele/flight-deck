import SwiftUI
import XCTest
@testable import FlightDeck

/// `RequestDisclosure`'s expanded request text must be selectable and copyable, which a SwiftUI
/// `Button`'s label can never allow — a button's label swallows every click and drag before
/// `.textSelection` sees them. That rules out the usual way to pin this: a real OS accessibility
/// walk needs Accessibility (TCC) permission this headless test host doesn't have
/// (`AXIsProcessTrusted() == false`, confirmed live), SwiftUI's own AX element tree reads empty
/// off an `NSView` in-process (`SidebarInputMonitor.swift` hit the same wall), and a synthetic
/// `NSEvent` click on a parked window hangs the run loop indefinitely (confirmed live, had to
/// `kill -9` the stuck process). None of those can tell "nested inside the button's label" from
/// "a sibling beside it" without crashing or permission this sandbox can't grant.
///
/// What this uses instead: `Mirror` on the actual `View` VALUE `RequestDisclosure.body` returns —
/// the same struct SwiftUI itself would render from, just inspected before rendering rather than
/// after. Walking its children finds every `.accessibilityIdentifier`, and tracks whether the walk
/// is currently inside a `Button`'s `label:` closure when it finds one — so "the text is outside
/// the button" is a structural fact this test can actually see and actually fail on, not an
/// assertion dressed up to always pass.
@MainActor
final class RequestDisclosureTests: XCTestCase {
    private let longIntent = "Build a field-service scheduling platform. Technicians start each day from a home depot. Check-in has to work offline."

    func testExpandedTextSitsOutsideTheButtonAndCarriesTheFullRequest() {
        let view = RequestDisclosure(intent: longIntent, expanded: true, setExpanded: { _ in })
        let ids = identifiers(in: view.body)

        let request = try? XCTUnwrap(ids.first { $0.identifier == "intake-request" })
        let requestText = try? XCTUnwrap(ids.first { $0.identifier == "intake-request-text" })
        let title = try? XCTUnwrap(ids.first { $0.identifier == "intake-title" })
        XCTAssertNotNil(request, "expected an \"intake-request\" element: found \(ids.map(\.identifier))")
        XCTAssertNotNil(requestText, "expected an \"intake-request-text\" element: found \(ids.map(\.identifier))")
        XCTAssertEqual(request?.insideButtonLabel, false, "the chevron button's own identifier isn't itself nested in a label")
        XCTAssertEqual(requestText?.insideButtonLabel, false,
                       "the request text must NOT be inside the button's label, or a click can never select it")
        XCTAssertEqual(title?.insideButtonLabel, false,
                       "the title text (same node `title()` stamps \"intake-title\" on) must also be free of the button's label")
        XCTAssertEqual(requestText?.text, "Build a field-service scheduling platform. Technicians start each day from a home depot. Check-in has to work offline.")
    }

    func testCollapsedRowIsStillOneButtonLabeledWithTheTitle() {
        let view = RequestDisclosure(intent: longIntent, expanded: false, setExpanded: { _ in })
        let ids = identifiers(in: view.body)

        let request = try? XCTUnwrap(ids.first { $0.identifier == "intake-request" })
        let title = try? XCTUnwrap(ids.first { $0.identifier == "intake-title" })
        XCTAssertNotNil(request, "expected an \"intake-request\" element: found \(ids.map(\.identifier))")
        XCTAssertNotNil(title, "expected an \"intake-title\" element: found \(ids.map(\.identifier))")
        XCTAssertEqual(title?.insideButtonLabel, true, "collapsed, the whole row — chevron and title — is the button's own label")
        XCTAssertNil(ids.first { $0.identifier == "intake-request-text" }, "collapsed, there is no separate text element yet")
    }

    func testOneSentenceRequestHasNoDisclosureAndIsSelectable() {
        let view = RequestDisclosure(intent: "Fix the flicker on resize.", expanded: false, setExpanded: { _ in })
        XCTAssertTrue(hasTextSelectionEnabled(view.body), "a one-sentence request has nothing to expand, but should still be copyable")
    }

    // MARK: - Structural reflection

    private struct Found {
        let identifier: String
        let insideButtonLabel: Bool
        let text: String?
    }

    /// Every `.accessibilityIdentifier` reachable from `any`, each paired with whether the walk
    /// was inside a `Button`'s `label:` when it found it, and the plain text of the identified
    /// element if `any` is itself a `Text`.
    private func identifiers(in any: Any) -> [Found] {
        var found: [Found] = []
        walk(any, insideButtonLabel: false, depth: 0, found: &found)
        return found
    }

    private func hasTextSelectionEnabled(_ any: Any, depth: Int = 0) -> Bool {
        guard depth < 30 else { return false }
        let typeName = String(reflecting: type(of: any))
        if typeName.contains("TextSelectabilityModifier") { return true }
        for child in Mirror(reflecting: any).children {
            if hasTextSelectionEnabled(child.value, depth: depth + 1) { return true }
        }
        return false
    }

    /// `rawValue` is where `.accessibilityIdentifier("...")` actually stores its string —
    /// `SwiftUI.AccessibilityAttachmentModifier` → ... → `AccessibilityIdentifierStorage.rawValue`.
    private func rawIdentifier(_ any: Any) -> String? {
        let mirror = Mirror(reflecting: any)
        let typeName = String(reflecting: type(of: any))
        if typeName.contains("AccessibilityIdentifierStorage") {
            for child in mirror.children where child.label == "rawValue" { return child.value as? String }
        }
        for child in mirror.children {
            if let id = rawIdentifier(child.value) { return id }
        }
        return nil
    }

    /// The concatenated plain text of a `Text` value (or something holding one), for pinning
    /// which text an identifier landed on. A dynamic-string `Text` stores its content directly as
    /// a `.verbatim(String)` case — found the moment a child's value is itself a `String` — and
    /// `Text(_:) + Text(_:)` nests its two halves as a `ConcatenatedTextStorage`'s `first`/
    /// `second`, rather than pre-joining them into one string.
    private func plainText(_ any: Any, depth: Int = 0) -> String? {
        guard depth < 20 else { return nil }
        if let s = any as? String { return s }
        let mirror = Mirror(reflecting: any)
        if let first = mirror.children.first(where: { $0.label == "first" }),
           let second = mirror.children.first(where: { $0.label == "second" }) {
            return (plainText(first.value, depth: depth + 1) ?? "") + (plainText(second.value, depth: depth + 1) ?? "")
        }
        for child in mirror.children {
            if let text = plainText(child.value, depth: depth + 1) { return text }
        }
        return nil
    }

    /// Framework view types declare `Body == Never`; calling `.body` on one traps. Only our own
    /// `FlightDeck.*` view types (or SwiftUI wrapper types that happen to carry one as a generic
    /// parameter, caught by `erasedBody` never being reached for them — they have no stored
    /// `body`-bearing child beyond their own primitives) are safe to expand this way. Everything
    /// else is walked purely through its stored properties, which `Mirror` can see without ever
    /// calling into the type.
    private func walk(_ any: Any, insideButtonLabel: Bool, depth: Int, found: inout [Found]) {
        guard depth < 60 else { return }
        let mirror = Mirror(reflecting: any)
        let typeName = String(reflecting: type(of: any))
        if typeName.contains("AccessibilityAttachmentModifier") {
            for child in mirror.children where child.label == "modifier" {
                if let id = rawIdentifier(child.value) {
                    found.append(Found(identifier: id, insideButtonLabel: insideButtonLabel, text: plainText(any)))
                }
            }
        }
        for child in mirror.children {
            let childInsideButton = insideButtonLabel || (typeName.hasPrefix("SwiftUI.Button<") && child.label == "label")
            walk(child.value, insideButtonLabel: childInsideButton, depth: depth + 1, found: &found)
        }
    }
}
