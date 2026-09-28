import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders `SplitFlapText` offscreen to a PNG for design review — skipped by default. Set
/// `FD_INTAKE_RENDER_DIR` to an output directory to run it; it writes `pui-splitflap.png`. A
/// picture rather than an assertion, like `IntakeDetailViewRenderTests`: the fit and the card
/// can be looked at without launching the app (AGENTS.md rule 2).
@MainActor
final class SplitFlapTextRenderTests: XCTestCase {
    func testRenderFullNameAndCodeWithCard() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_INTAKE_RENDER_DIR"] else {
            throw XCTSkip("set FD_INTAKE_RENDER_DIR to render the split-flap PNG")
        }
        let policy = FlapPolicy()
        let nsFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
        let font = Font(nsFont)
        let view = VStack(alignment: .leading, spacing: 14) {
            Text("NOW — wide slot, full name fits").font(.caption).foregroundStyle(.secondary)
            SplitFlapText(full: "Synthesis", code: "SYN", surface: "board.now", policy: policy, font: font, nsFont: nsFont)
                .frame(width: 200)
            Text("Tape slot — too narrow, code with its card open").font(.caption).foregroundStyle(.secondary)
            SplitFlapText(full: "Refine 2", code: "RF2", surface: "tape.refine-2", policy: policy, font: font, nsFont: nsFont,
                          detail: "landed 3:02", showsCardInitially: true)
                .frame(width: 48)
            Text("NOW with a failure diagnosis — the card wraps the full text").font(.caption).foregroundStyle(.secondary)
                .padding(.top, 70)
            SplitFlapText(full: "Refine 2", code: "RF2", surface: "board.now", policy: policy, font: font, nsFont: nsFont,
                          detail: "2 of 4 seats failed after 3 retries: the API answered 529 overloaded every time",
                          showsCardInitially: true, alwaysOffersCard: true)
                .frame(width: 200)
            Spacer()
        }
        .padding(20)
        try PlanningRender.write(view, size: NSSize(width: 460, height: 420),
                   to: URL(fileURLWithPath: dir).appendingPathComponent("pui-splitflap.png"))
    }
}
