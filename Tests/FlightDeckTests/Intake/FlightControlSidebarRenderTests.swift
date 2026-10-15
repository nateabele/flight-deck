import AppKit
import FleetKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The sidebar's Flight Control indicator, offscreen, light and dark, for design review. Skipped
/// unless `FD_FC_SIDEBAR_RENDER_DIR` names an output directory. Pictures, not assertions.
///
/// The sidebar picture is a replica List-free column: project rows and session rows laid out the
/// way `ProjectHeaderRow` and `SessionRow` lay them out, drawn with the REAL glyph views
/// (`FlightControlSidebarIndicator`, `SessionStatusIcon`) and statuses derived from real summaries.
/// A real `SessionSidebar` cannot show a RUNNING plan here: a running tape in a store makes its
/// runner controller try to spawn a runner. `fc-header-*` are real `ProjectHeaderRow`s.
@MainActor
final class FlightControlSidebarRenderTests: XCTestCase {
    private func summary(_ title: String, _ state: IntakeState, attention: Bool = false, now: String? = nil,
                         run: RunnerStatus? = nil) -> WireIntakeSummary {
        WireIntakeSummary(id: UUID(), title: title, state: state.rawValue, needsAttention: attention, now: now,
                          runStatus: run?.rawValue, createdAt: Date())
    }

    private struct Project: Identifiable {
        let id = UUID()
        var name: String
        var collapsed = false
        var selected = false
        var sessions: [(String, SessionStatus?)] = []
        var plans: [WireIntakeSummary] = []
        var status: FlightControlSidebarStatus { .derive(plans) }
    }

    private struct ProjectRow: View {
        let project: Project
        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right").imageScale(.small)
                    .foregroundStyle(project.selected ? .primary : .secondary)
                    .rotationEffect(.degrees(project.collapsed ? 0 : 90))
                Text(project.name).fontWeight(.semibold).foregroundStyle(project.selected ? .primary : .secondary)
                Spacer(minLength: 4)
                if project.collapsed {
                    Text("\(project.sessions.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    SessionStatusIcon(status: project.sessions.compactMap(\.1).first { $0.activity != .idle })
                }
                FlightControlSidebarIndicator(status: project.status).equatable()
            }
            .padding(.horizontal, 16).padding(.vertical, 5)
            .background(project.selected ? RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor)).padding(.horizontal, 10) : nil)
        }
    }

    private struct SessionLine: View {
        let title: String
        let status: SessionStatus?
        var body: some View {
            HStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    Color.clear.frame(width: 16, height: 0)
                    SessionStatusIcon(status: status)
                }
                Text(title)
                Spacer()
            }
            .padding(.leading, 32).padding(.trailing, 16).padding(.vertical, 4)
        }
    }

    private struct Column: View {
        let projects: [Project]
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(projects) { project in
                    ProjectRow(project: project)
                    if !project.collapsed {
                        ForEach(Array(project.sessions.enumerated()), id: \.offset) { _, s in
                            SessionLine(title: s.0, status: s.1)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var projects: [Project] {
        [
            Project(name: "LarkOS", sessions: [("Dispatch board", .init(activity: .busy)), ("Fix login", .init(activity: .idle)),
                                                ("Schema review", .init(activity: .waiting))],
                    plans: [summary("Crew calendar", .shaping, now: "Refine 2", run: .running)]),
            Project(name: "Larkspur", sessions: [("Migrate billing", .init(activity: .busy))],
                    plans: [summary("Invoice export", .needsAnswers, attention: true),
                            summary("Usage alerts", .awaitingChoice, attention: true),
                            summary("Audit log", .review, attention: true)]),
            Project(name: "Harbor", sessions: [("Docs", .init(activity: .idle))],
                    plans: [summary("Old plan", .released)]),
            Project(name: "Beacon", collapsed: true, sessions: [("a", .init(activity: .busy)), ("b", .init(activity: .idle))],
                    plans: [summary("Retry queue", .triaging, now: "Triage")]),
            Project(name: "Pelican", collapsed: true, sessions: [("a", .init(activity: .waiting))],
                    plans: [summary("Cache layer", .shaping, attention: true, now: "Refine 3", run: .paused)]),
            Project(name: "Quill", collapsed: true, sessions: [("a", .init(activity: .idle))]),
        ]
    }

    func testRenderTheSidebar() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_FC_SIDEBAR_RENDER_DIR"] else {
            throw XCTSkip("set FD_FC_SIDEBAR_RENDER_DIR to render the Flight Control sidebar PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        var rows = projects
        rows[1].selected = true
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            try PlanningRender.write(Column(projects: rows), size: NSSize(width: 300, height: 360),
                                     to: out.appendingPathComponent("fc-sidebar-\(name).png"), appearance: appearance)
        }
    }

    /// The two glyphs at the size a row draws them, large, beside a session's own, so the
    /// distinction reads.
    func testRenderTheGlyphsBesideSessionStatus() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_FC_SIDEBAR_RENDER_DIR"] else {
            throw XCTSkip("set FD_FC_SIDEBAR_RENDER_DIR to render the Flight Control sidebar PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        let one = FlightControlSidebarStatus.derive([summary("A", .needsAnswers, attention: true)])
        let three = FlightControlSidebarStatus.derive((0..<3).map { _ in summary("A", .review, attention: true) })
        let working = FlightControlSidebarStatus.derive([summary("A", .shaping, now: "Refine 2", run: .running)])
        let strip = HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Plans (right of a project row)").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    FlightControlSidebarIndicator(status: working)
                    FlightControlSidebarIndicator(status: one)
                    FlightControlSidebarIndicator(status: three)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Sessions (left of a tab)").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    SessionStatusIcon(status: .init(activity: .busy))
                    SessionStatusIcon(status: .init(activity: .waiting))
                    SessionStatusIcon(status: .init(activity: .idle))
                }
            }
        }
        .scaleEffect(2.5, anchor: .topLeading)
        .padding(16)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            try PlanningRender.write(strip, size: NSSize(width: 760, height: 150),
                                     to: out.appendingPathComponent("fc-glyphs-\(name).png"), appearance: appearance)
        }
    }

    /// The real header, expanded and collapsed, over a real store with a plan waiting on answers.
    func testRenderTheRealHeader() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_FC_SIDEBAR_RENDER_DIR"] else {
            throw XCTSkip("set FD_FC_SIDEBAR_RENDER_DIR to render the Flight Control sidebar PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FCSidebarRender-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = URL(fileURLWithPath: "/w/larkos", isDirectory: true)
        for text in ["Add a crew calendar", "Usage alerts"] {
            var i = Intake(projectPath: project.standardizedFileURL.path, intent: text)
            i.state = .needsAnswers
            try IntakeStore(root: root).save(i)
        }
        let preferences = PreferencesStore(persistence: nil)
        preferences.setProjectSettings(project.standardizedFileURL.path, ProjectSettings(flywheelEnabled: true))
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: preferences, intakesRoot: root)
        store.newSession(in: project)
        for collapsed in [false, true] {
            store.setCollapsed(collapsed, forProjectAt: store.repos[0].id)
            let repo = store.repos[0]
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                try PlanningRender.write(
                    ProjectHeaderRow(store: store, repo: repo, isSidebarFocused: false, onClose: {}),
                    size: NSSize(width: 300, height: 36),
                    to: out.appendingPathComponent("fc-header-\(collapsed ? "collapsed" : "expanded")-\(name).png"),
                    appearance: appearance)
            }
        }
    }
}
