import FleetKit
import Foundation

/// What a halt panel button does. Retry-with-another-model is its own case: it opens the rounds
/// editor first and only retries once the edit is saved.
enum HaltAction: String, Equatable {
    case retry, retryOther, toReview, resume
}

struct HaltButton: Equatable, Identifiable {
    let action: HaltAction
    let title: String
    let enabled: Bool
    /// In flight: the label wears an ack word so a tap never looks ignored.
    let busy: Bool
    var id: String { action.rawValue }
}

/// The Flight Control halt panel as decisions (MOBILE-UI: a decision reachable without SwiftUI is
/// one a test can run). The Mac's `actions` list is the authority on what it would accept right
/// now; this only drops what the phone cannot do (an op an older Mac drops the socket on, a
/// round editor it never sent menus for), and ignores action names it has never heard of.
struct HaltPanelModel: Equatable {
    let halt: WireHalt
    let buttons: [HaltButton]
    /// The kind has no calm reading: a stopped or paused run is the person's own doing.
    let isFailure: Bool

    /// The default play key `Resume` presses, as `TransportKeys` marks it.
    static func resumeKey(_ detail: WireIntakeDetail) -> String { detail.board?.defaultPlay ?? "step" }

    /// nil when nothing is halted.
    static func make(detail: WireIntakeDetail, inFlight: Set<IntakeAction>, live: Bool,
                     drafts: [String: RoundDraft] = [:]) -> HaltPanelModel? {
        guard let halt = detail.halted else { return nil }
        let canRetry = detail.retry == true
        let canEdit = RoundEditing.make(detail: detail, preset: nil, drafts: drafts) != nil
        let resume = resumeKey(detail)
        var buttons: [HaltButton] = []
        for name in halt.actions {
            switch name {
            case "retry" where canRetry:
                let busy = inFlight.contains(.retry)
                buttons.append(HaltButton(action: .retry, title: busy ? "Retrying…" : "Retry", enabled: live && !busy, busy: busy))
            case "retryOther" where canRetry && canEdit:
                buttons.append(HaltButton(action: .retryOther, title: "Retry with another model",
                                          enabled: live && !inFlight.contains(.retry) && !inFlight.contains(.rounds), busy: false))
            case "toReview" where detail.steer == true:
                let busy = inFlight.contains(.tape("toReview"))
                buttons.append(HaltButton(action: .toReview, title: busy ? "Starting…" : "To review", enabled: live && !busy, busy: busy))
            case "resume" where detail.steer == true:
                let busy = inFlight.contains(.tape(resume))
                buttons.append(HaltButton(action: .resume, title: busy ? "Resuming…" : "Resume", enabled: live && !busy, busy: busy))
            default: break  // "showOutput" is the disclosure, not a button; unknown names degrade away.
            }
        }
        return HaltPanelModel(halt: halt, buttons: buttons,
                              isFailure: !["paused", "stopped"].contains(halt.kind))
    }

    var title: String { halt.title }
    var reason: String { halt.reason }
    var whatToDo: String? { halt.whatToDo.flatMap { $0.isEmpty ? nil : $0 } }

    /// "Polisher · Gemini 3 Pro · high", or nil with no failed seat.
    var slotLine: String? {
        guard let slot = halt.slot else { return nil }
        let role = slot.role.prefix(1).uppercased() + slot.role.dropFirst()
        return slot.ran.isEmpty ? role : "\(role) · \(slot.ran)"
    }

    /// The captured output, only when the Mac offers `showOutput` and there is some. Collapsed
    /// until asked for (`outputExpanded` is view state).
    var output: String? {
        guard halt.actions.contains("showOutput"), let o = halt.output, !o.isEmpty else { return nil }
        return o
    }

    /// "Halted 4:12" on the Mac's clock, counted by the same `ClockPolicy` as the board strip.
    func haltedFor(now: Date, offset: TimeInterval, frozenAt: Date?) -> String? {
        halt.since.map {
            "Halted for " + ClockPolicy.text(ClockPolicy.elapsed(since: $0, now: now, offset: offset, frozenAt: frozenAt))
        }
    }

    /// What the rounds editor should scroll to and say for "another model".
    var retryOtherHint: String {
        slotLine.map { "Pick a different model for \($0), then save to retry." } ?? "Pick a different model, then save to retry."
    }
}
