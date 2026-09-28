import Foundation

/// When a board hover card opens — tooltip rules, so a card never pops under a pointer that is
/// only passing across the tape. An item has to be rested on for `delay` before its card opens;
/// once a card is up, moving onto the next item opens that one at once ("warm"), and the warmth
/// lasts `coolDown` after the pointer leaves the last card's item. A click, Esc, scroll or
/// window change (`dismiss`) closes the card and forgets the warmth, so it stays shut while the
/// pointer sits where it was.
///
/// Pure and timer-free: the caller says what the pointer did and when, and calls `advance` at
/// `deadline`. `HoverCardIntent` is that caller.
struct HoverIntent {
    static let delay: TimeInterval = 0.35
    static let coolDown: TimeInterval = 0.5

    /// The item whose card is open.
    private(set) var shown: String?
    /// The item under the pointer, card open or not.
    private(set) var hovered: String?
    private var enteredAt: TimeInterval = 0
    /// When the pointer last left an item whose card was open — the start of the cool-down.
    private var closedAt: TimeInterval?

    /// When `advance` next has something to decide: the pending item's delay running out.
    var deadline: TimeInterval? { hovered != nil && shown == nil ? enteredAt + Self.delay : nil }

    mutating func enter(_ id: String, at time: TimeInterval) {
        hovered = id
        enteredAt = time
        // SwiftUI may deliver the neighbour's enter before this item's exit, so "a card is up"
        // counts as warm just as a recent close does.
        if shown != nil || closedAt.map({ time - $0 <= Self.coolDown }) == true { shown = id }
    }

    mutating func exit(_ id: String, at time: TimeInterval) {
        if hovered == id { hovered = nil }
        if shown == id {
            shown = nil
            closedAt = time
        }
    }

    mutating func advance(to time: TimeInterval) {
        // Against `deadline`'s own sum: `time - enteredAt` can round just under the delay, and
        // the driver, woken exactly at the deadline, would then open nothing.
        guard let hovered, shown == nil, time >= enteredAt + Self.delay else { return }
        shown = hovered
    }

    mutating func dismiss() {
        shown = nil
        hovered = nil
        closedAt = nil
    }
}

/// Drives `HoverIntent` on the real clock for every board hover card in the app. One for the
/// app, not one per board: there is one pointer, and warmth carries from a tape slot to a board
/// field's code the way a tooltip's does. Items are keyed by a per-view token, so two boards
/// showing the same slot id never open each other's card.
@MainActor
final class HoverCardIntent: ObservableObject {
    static let shared = HoverCardIntent()

    @Published private(set) var shown: String?
    private var intent = HoverIntent()
    private var timer: Task<Void, Never>?

    func hover(_ id: String, _ inside: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if inside { intent.enter(id, at: now) } else { intent.exit(id, at: now) }
        sync()
    }

    /// Closes whatever is open and forgets the warmth. Called from AppKit notifications that can
    /// post mid-layout, so the publish waits for the next turn of the run loop rather than
    /// changing state during a view update.
    func dismiss() {
        intent.dismiss()
        DispatchQueue.main.async { [weak self] in self?.sync() }
    }

    private func sync() {
        if shown != intent.shown { shown = intent.shown }
        timer?.cancel()
        timer = nil
        guard let deadline = intent.deadline else { return }
        let wait = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.intent.advance(to: ProcessInfo.processInfo.systemUptime)
            self.sync()
        }
    }
}
