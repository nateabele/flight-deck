import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Three branches each needed a Settings home and, built in parallel, each made a temporary one.
/// The joined build has exactly one: Flight Control, with four sections. A leftover top-level
/// tab would show the same pane twice and leave one copy unmaintained.
@MainActor
final class FlightControlTabIntegrationTests: XCTestCase {
    func testOneTabFourSections() {
        XCTAssertEqual(FlightControlSettingsTab.Section.allCases.map(\.identifier),
                       ["fc-section-routing", "fc-section-kinds", "fc-section-index", "fc-section-capacity"])
        let raw = PreferencesTab.allCases.map { "\($0)" }
        XCTAssertTrue(raw.contains("flightControl"))
        XCTAssertFalse(raw.contains("capabilityIndex"))
        XCTAssertFalse(raw.contains("capacity"))
    }

    func testFlightControlTabRendersEverySectionWithNoTools() throws {
        // The store has no capability index service here, so that section shows its fallback text.
        let prefs = PreferencesStore(persistence: nil)
        let store = SessionStore(provider: nil, persistence: nil)
        let routing = RoutingServiceSupport.make(prefs: prefs)
        for section in FlightControlSettingsTab.Section.allCases {
            let view = FlightControlSettingsTab(preferences: prefs, sessions: store, routing: routing,
                                                initialSection: section)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0, "\(section) drew nothing")
        }
    }
}
