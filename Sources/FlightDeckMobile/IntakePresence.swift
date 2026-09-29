import SwiftUI

/// What every screen of one intake shares (spec §4.2, §6.2): it counts as "on screen" for the
/// banner policy, and it keeps the intake's detail fresh while it is the visible screen.
///
/// Presence is reference-counted rather than set/cleared because a pushed child's `onAppear`
/// can run BEFORE the parent's `onDisappear`: a plain set-then-clear ended with nothing on
/// screen and the intake's own banner dropping over its round detail. The refresh loop rides
/// on the same modifier so a pushed Round detail or Clarifications screen (which only read
/// `model.detail`) does not go stale the moment it covers the intake screen, whose own loop
/// the push would cancel.
private struct IntakePresence: ViewModifier {
    let id: UUID
    let model: IntakeDetailModel
    let flightControl: FlightControlModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { flightControl.enter(id) }
            .onDisappear { flightControl.leave(id) }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                model.refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(1_500))
                    // A vanished intake is not polled: nothing on the Mac answers for it.
                    guard !Task.isCancelled else { return }
                    if !model.gone { model.refresh() }
                }
            }
    }
}

extension View {
    func intakePresence(id: UUID, model: IntakeDetailModel, flightControl: FlightControlModel) -> some View {
        modifier(IntakePresence(id: id, model: model, flightControl: flightControl))
    }
}

/// A `TimelineView` schedule that follows `ClockPolicy.tickInterval`: once per second while the
/// clock is young or the intake is working, once a minute when it is idle and past a minute —
/// a parked intake would otherwise redraw its strip every second forever.
struct ClockSchedule: TimelineSchedule {
    let since: Date?
    let offset: TimeInterval
    let frozenAt: Date?
    let idle: Bool

    func entries(from start: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(schedule: self, cursor: start)
    }

    struct Entries: Sequence, IteratorProtocol {
        let schedule: ClockSchedule
        var cursor: Date
        mutating func next() -> Date? {
            let current = cursor
            let elapsed = schedule.since.map {
                ClockPolicy.elapsed(since: $0, now: current, offset: schedule.offset, frozenAt: schedule.frozenAt)
            } ?? 0
            cursor = current.addingTimeInterval(ClockPolicy.tickInterval(elapsed: elapsed, idle: schedule.idle))
            return current
        }
    }
}
