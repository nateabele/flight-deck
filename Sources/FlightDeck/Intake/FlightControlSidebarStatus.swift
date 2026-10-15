import Combine
import FleetKit
import Foundation
import IntakeKit

/// What a project's Flight Control is doing, folded into the one thing the sidebar draws at the
/// right of the project's row: needs you, working, or nothing.
///
/// Derived from `WireIntakeSummary` — the phone's per-plan row (`IntakeSummaryProjection`) — and
/// not from the intakes again. That projection already owns the attention rule
/// (`IntakeService.needsAttention`) and the "now" wording ("Refine 2"), so the sidebar, the
/// phone and the list cannot disagree about whether a plan needs you or what it is doing. This
/// type only ranks and words what those rows say. Pure: no service, no clock, no I/O.
struct FlightControlSidebarStatus: Equatable {
    enum Kind: Equatable {
        /// Nothing running and nothing waiting (or no plans, or only released ones): the row
        /// draws no glyph, the way an idle session does — the sidebar's resting state is quiet.
        case idle
        case working
        case needsYou
    }

    var kind: Kind = .idle
    /// Plans waiting on the human. The glyph shows it only above one.
    var attentionCount = 0
    var workingCount = 0
    /// Hover text, one line per plan (or one line for several plans that need you).
    var help = ""
    /// The plan a click opens: the first that needs you, else the first that is working.
    var target: UUID?

    static let idle = FlightControlSidebarStatus()

    /// `summaries` in the order the list draws them (newest first), so the click target is the
    /// plan at the top of the Intakes list among those that qualify.
    static func derive(_ summaries: [WireIntakeSummary]) -> FlightControlSidebarStatus {
        let attention = summaries.filter(\.needsAttention)
        let working = summaries.filter { !$0.needsAttention && isWorking($0) }
        guard !attention.isEmpty || !working.isEmpty else { return .idle }

        var lines: [String] = []
        if attention.count == 1, let one = attention.first {
            lines.append("\(shortTitle(one)): \(reason(one))")
        } else if attention.count > 1 {
            var reasons: [String] = []
            for r in attention.map(reason) where !reasons.contains(r) { reasons.append(r) }
            lines.append("\(attention.count) plans need you: \(reasons.joined(separator: "; "))")
        }
        lines += working.map { "\(shortTitle($0)): \(activity($0))" }

        return FlightControlSidebarStatus(
            kind: attention.isEmpty ? .working : .needsYou,
            attentionCount: attention.count,
            workingCount: working.count,
            help: lines.joined(separator: "\n"),
            target: (attention.first ?? working.first)?.id)
    }

    /// VoiceOver's reading: the same sentences, as one string.
    var accessibilityLabel: String {
        kind == .idle ? "" : "Flight Control, " + help.replacingOccurrences(of: "\n", with: ". ")
    }

    // MARK: Words

    /// Working is anything alive that is not waiting on the human: triage, a release, or a plan
    /// whose rounds are starting or running. A shaping plan whose runner stopped is `needsAttention`
    /// already (`IntakeService.shapingNeedsAttention`), so it never reaches here.
    private static func isWorking(_ s: WireIntakeSummary) -> Bool {
        switch s.state {
        case IntakeState.triaging.rawValue, IntakeState.releasing.rawValue, IntakeState.shaping.rawValue: true
        default: false
        }
    }

    /// What a working plan is doing, in the board's own "now" words.
    private static func activity(_ s: WireIntakeSummary) -> String {
        switch s.state {
        case IntakeState.releasing.rawValue: "Releasing"
        case IntakeState.shaping.rawValue:
            if s.runStatus == RunnerStatus.running.rawValue, let now = s.now { "\(now) running" } else { "Starting" }
        default: "\(s.now ?? "Triage") running"
        }
    }

    /// Why a plan needs you, as a verb phrase after the plan's name.
    private static func reason(_ s: WireIntakeSummary) -> String {
        switch s.state {
        case IntakeState.needsAnswers.rawValue: return "answer questions"
        case IntakeState.awaitingChoice.rawValue, IntakeState.parked.rawValue: return "choose a fidelity"
        case IntakeState.review.rawValue: return "review the plan"
        case IntakeState.partiallyReleased.rawValue: return "finish the release"
        case IntakeState.failed.rawValue: return "failed"
        case IntakeState.interrupted.rawValue: return "interrupted"
        default:
            // Shaping: the runner stopped and is waiting for the human.
            let at = s.now.map { " at \($0)" } ?? ""
            switch s.runStatus {
            case RunnerStatus.failed.rawValue: return "round failed\(at)"
            case RunnerStatus.stopped.rawValue: return "stopped\(at)"
            default: return "paused\(at)"
            }
        }
    }

    /// The title is the phone's lead, cut at 72 characters and sometimes ending on the sentence's
    /// period; a hover line needs fewer and no punctuation before its own colon.
    private static func shortTitle(_ s: WireIntakeSummary, limit: Int = 36) -> String {
        let title = s.title.trimmingCharacters(in: CharacterSet(charactersIn: ".:;, "))
        return title.count <= limit ? title : title.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Keeps one project's `FlightControlSidebarStatus` current, and publishes it only when it
/// CHANGES. `IntakeService` publishes on every tape write and seat beat, and `SessionStore`
/// forwards each to every view that observes it; a row that read the service in its own body
/// would redraw each time. The model absorbs those publishes, re-derives, and compares: a tape
/// tick that leaves the status as it was costs one derivation and no redraw (`RenderProbe`
/// "fcIndicator" counts it).
@MainActor
final class FlightControlSidebarModel: ObservableObject {
    @Published private(set) var status = FlightControlSidebarStatus.idle
    private var service: IntakeService?
    private var path = ""
    private var subscription: AnyCancellable?

    /// Follows `service`'s publishes for `path`, or stops (and goes quiet) when `service` is nil.
    /// Idempotent for the same arguments. The service is passed in, never fetched, so a project
    /// with Flight Control off never builds it (`SessionStore.intakeService` is lazy).
    func attach(service: IntakeService?, path: String) {
        guard service !== self.service || path != self.path else { return }
        self.service = service
        self.path = path
        subscription = service?.objectWillChange
            // `objectWillChange` fires before the change lands: read on the next turn.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        let next = service.map { Self.read($0, path: path) } ?? .idle
        if next != status { status = next }
    }

    static func read(_ service: IntakeService, path: String, now: Date = Date()) -> FlightControlSidebarStatus {
        .derive(service.intakes(forProject: path)
            .filter { IntakeSummaryProjection.isListed($0, now: now) }
            .map { IntakeSummaryProjection.summary($0, tape: service.tapes[$0.id], seats: nil, needsAttention: service.needsAttention($0)) })
    }

    /// The click: the project's own view, with the plan that needs you (else the running one)
    /// selected in its Intakes list.
    func open(in store: SessionStore, repoID: Repo.ID) {
        guard let target = status.target else { return }
        store.selectProject(repoID)
        service?.select(target, inProject: path)
    }
}
