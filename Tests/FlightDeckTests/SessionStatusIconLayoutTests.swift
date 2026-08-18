import SwiftUI
import XCTest
@testable import FlightDeck

/// The sidebar reserves a fixed leading column for the status glyph so every row's title
/// starts at the same x. These measure that column the way the row builds it, since the
/// property under test is a layout one and no amount of reading the view code settles it.
@MainActor
final class SessionStatusIconLayoutTests: XCTestCase {
    /// Exactly the row's construction — see `SessionRow.body` in `SessionSidebar.swift`.
    /// Kept in sync by hand; the reservation lives there because holding the column open is
    /// the row's layout concern, not the icon's.
    @ViewBuilder
    private func statusColumn(_ status: SessionStatus?, unread: Bool) -> some View {
        ZStack(alignment: .leading) {
            Color.clear.frame(width: 16, height: 0)
            SessionStatusIcon(status: status, unread: unread)
        }
    }

    private func columnWidth(_ status: SessionStatus?, unread: Bool = false) -> CGFloat {
        let host = NSHostingView(rootView: statusColumn(status, unread: unread))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// Where the title actually lands, measured through the row's own `HStack` rather than
    /// on the icon alone: stack spacing is applied per *subview*, so a column that measures
    /// 16 in isolation can still shift the title if the stack treats it differently.
    private func titleOffset(_ status: SessionStatus?, unread: Bool = false) -> CGFloat {
        let row = HStack(spacing: 4) {
            statusColumn(status, unread: unread)
            Text("Session")
        }
        let host = NSHostingView(rootView: row)
        host.layoutSubtreeIfNeeded()
        // Total width minus a constant title = everything to the title's left.
        return host.fittingSize.width
    }

    func testTitleStartsAtTheSameOffsetWithAndWithoutAStatus() {
        let idle = titleOffset(SessionStatus(activity: .idle))
        XCTAssertEqual(titleOffset(nil), idle, accuracy: 0.5, "no status shifted the title")
        XCTAssertEqual(titleOffset(nil, unread: true), idle, accuracy: 0.5, "unread shifted the title")
        XCTAssertEqual(
            titleOffset(SessionStatus(activity: .waiting)), idle, accuracy: 0.5,
            "waiting shifted the title"
        )
        XCTAssertEqual(
            titleOffset(SessionStatus(activity: .shell)), idle, accuracy: 0.5,
            "shell shifted the title"
        )
        XCTAssertEqual(
            titleOffset(SessionStatus(activity: .busy)), idle, accuracy: 0.5,
            "busy shifted the title"
        )
    }

    func testEveryStateReservesTheColumn() {
        let states: [(String, CGFloat)] = [
            ("nil, read", columnWidth(nil)),
            ("nil, unread", columnWidth(nil, unread: true)),
            ("idle", columnWidth(SessionStatus(activity: .idle))),
            ("busy", columnWidth(SessionStatus(activity: .busy))),
            ("busy+3", columnWidth(SessionStatus(activity: .busy, subagentCount: 3))),
            ("waiting", columnWidth(SessionStatus(activity: .waiting))),
            ("shell", columnWidth(SessionStatus(activity: .shell))),
        ]

        for (name, width) in states {
            XCTAssertGreaterThanOrEqual(
                width, 16,
                "\(name) collapsed the reserved column to \(width), which shifts that row's title left"
            )
        }
    }
}
