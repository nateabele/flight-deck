import FleetKit
import SwiftUI

/// A test-only probe, reachable ONLY under a launch argument, that reproduces one question
/// in isolation: when a `Text(AttributedString)` carrying a `.link` run sits inside a whole-row
/// `NavigationLink(value:)`, does a tap on the URL open the link (Safari) or does the
/// `NavigationLink` swallow the tap and navigate?
///
/// This exists to settle the untested claim in `SessionTimelineScreen.entryRow`'s doc comment —
/// "a `NavigationLink` swallows the tap on any control inside it" — against the linkified
/// plain-kind rows introduced by `TimelineStyle.linkedPlainText`. It mirrors that exact
/// structure and nothing else: no fleet, no model, no data path, so the outcome is purely the
/// SwiftUI tap-precedence answer. See `FlightDeckMobileUITests`.
///
/// Gated behind `-UITestHarness <name>` so it can never appear in a shipping run: the app only
/// consults it when the argument is present, which XCUITest sets via `launchArguments`.
enum UITestHarness {
    /// The value passed as `-UITestHarness` for the link-in-NavigationLink probe.
    static let linkInNavLink = "linkInNavLink"
    /// The swarm card with fixture data, for `SwarmCardUITests`.
    static let swarmCard = "swarmCard"
    /// A two-question prompt card above the composer, lifted by the keyboard exactly as the
    /// conversation screen lifts them, for `PromptKeyboardUITests`.
    static let promptKeyboard = "promptKeyboard"

    /// The harness the current launch asks for, if any. `UserDefaults` surfaces a
    /// `-Key Value` launch argument pair as a string default, which is how XCUITest hands
    /// this in without the app parsing `CommandLine` itself.
    static var requested: String? {
        UserDefaults.standard.string(forKey: "UITestHarness")
    }

    /// The root view for a requested harness, or nil when none was asked for (the normal app).
    @ViewBuilder @MainActor
    static func view(for name: String) -> some View {
        switch name {
        case linkInNavLink:
            LinkInNavLinkHarness()
        case swarmCard:
            SwarmCardHarness()
        case promptKeyboard:
            PromptKeyboardHarness()
        default:
            // An unknown harness name is a test bug, not a state to render silently.
            Text("Unknown UITestHarness: \(name)")
        }
    }
}

/// A single row wrapped in `NavigationLink(value:)`, exactly as `entryRow` wraps a plain-kind
/// row, whose label is a `Text(AttributedString)` with a `.link` run over a bare URL. Tapping
/// the URL either follows the link (nothing navigates here) or fires the `NavigationLink` and
/// pushes the destination carrying the "probe-detail" identifier.
private struct LinkInNavLinkHarness: View {
    private static let url = URL(string: "https://example.com")!

    /// The whole visible label is the bare URL, styled exactly as `TimelineStyle.linkedPlainText`
    /// styles a detected run (`.link` + `.accentColor`). Making the URL the entire label means a
    /// tap anywhere on the row lands on the `.link` run — so the tap under test is unambiguously
    /// "on the link AND on the enclosing NavigationLink", which is the precedence question.
    private var linkedText: AttributedString {
        var attributed = AttributedString("https://example.com")
        attributed.link = Self.url
        attributed.foregroundColor = .accentColor
        return attributed
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink(value: "probe") {
                    Text(linkedText)
                        .accessibilityIdentifier("probe-row")
                }
            }
            .navigationDestination(for: String.self) { _ in
                Text("Detail screen")
                    .accessibilityIdentifier("probe-detail")
            }
        }
    }
}

/// The swarm card with fixture data and a local pause state — no fleet, no Mac — so the UI test
/// exercises the card's layout and its Pause/Resume swap in isolation.
private struct SwarmCardHarness: View {
    @State private var paused = false
    private var swarm: WireSwarm {
        WireSwarm(state: paused ? "paused" : "running", summary: paused ? "swarm paused · 2/3" : "swarm 2/3 · 1 waiting",
                  banner: nil, agents: [],
                  meters: [WireSwarmMeter(pool: "claude-subs", accountName: "Work", utilization: 0.62, state: "underSoft")],
                  waiting: 1)
    }
    var body: some View {
        List { SwarmCard(swarm: swarm, inFlight: false, onPause: { paused = true }, onResume: { paused = false }) }
    }
}

/// The bottom of `SessionTimelineScreen`, rebuilt around fixture data: a long `List`, and in its
/// bottom inset the prompt card over the composer inside the same `KeyboardLiftedInset`, with
/// the same keyboard modifiers. The prompt is a two-question set whose questions differ in
/// height, because what this exists to show is the card against the keyboard as it pages.
private struct PromptKeyboardHarness: View {
    private final class NoFleet: TimelinePaging, PromptSending, PromptAnswering, PresenceReporting {
        func viewing(_ session: UUID?) {}
        func markRead(_ id: UUID) {}
        func timelinePage(_ request: FleetRequest,
                          then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void) {}
        func sendPrompt(_ command: FleetCommand,
                        then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {}
        func answerPrompt(_ command: FleetCommand,
                          then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {}
    }

    @State private var model = SessionTimelineModel(sessionID: UUID(), fleet: NoFleet())
    @State private var typing = false
    private let session = WireSession(id: UUID(), title: "Harness", agent: "claude",
                                      activity: "waiting", acceptsTypedAnswers: true)
    private let open = OpenPrompt.question(callID: "toolu_HARNESS", [
        PromptQuestion(header: "Color", question: "Which color do you like best?",
                       options: [.init(label: "Red", detail: "Warm and bold"),
                                 .init(label: "Blue", detail: "Cool and calm")]),
        PromptQuestion(
            header: "Approach",
            question: "How should the group encapsulation land across the eight lanes?",
            options: [
                .init(label: "One lane at a time",
                      detail: "Merge each lane behind its own flag so a regression names its lane, at the cost of a longer critical path."),
                .init(label: "All lanes together",
                      detail: "One integration branch, one review, one merge; fastest if nothing goes wrong, hardest to bisect if something does."),
                .init(label: "Pairs of lanes",
                      detail: "Four merges of two lanes each, a middle path that keeps bisection cheap without serialising everything."),
                .init(label: "Spike first",
                      detail: "A throwaway end-to-end spike through one lane before committing to an order for the rest."),
            ]),
    ])

    var body: some View {
        NavigationStack {
            List(0..<40, id: \.self) { row in
                Text("Conversation row \(row)")
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                KeyboardLiftedInset {
                    PromptCard(open: open, agent: "claude", state: .idle, model: model,
                               blockedChaseExhausted: false, allowsBlockedAbort: false,
                               acceptsTypedAnswers: true, activity: "waiting",
                               openPromptCall: .call("toolu_HARNESS"), answerless: false,
                               onAbortBlocked: {}, fromSubagent: nil,
                               onTypingChange: { typing = $0 })
                    if !typing { PromptComposer(session: session, model: model) }
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navigationTitle("Harness")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
