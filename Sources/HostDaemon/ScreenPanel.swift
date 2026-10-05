import AppKit
import HostKit

// The "don't touch" panel (spec §6.3): while a delegated run holds this Mac's screen lease, a
// small floating panel says so, because a person who clicks into a running UI test steals its
// focus and fails it in a way that looks like a test bug.
//
// hostd is a LaunchAgent limited to the Aqua session, so it may run an `NSApplication`. It does
// so as an `.accessory` app (no Dock icon, no menu bar), and the panel is non-activating and
// ignores the mouse: it must never take focus or a click from the app under test.
//
// The logic is `ScreenPanelState`, pure and unit-tested; `ScreenPanel` is the thin AppKit
// shell that applies its effects on the main thread.

/// What the panel says for one lease holder.
struct ScreenPanelContent: Equatable {
    let title: String
    let detail: String

    init(holder: LeaseHolder) {
        title = "UI tests running — don't touch"
        // The session's display title, which is what the person at this Mac can recognise;
        // the run id is what `flightdeck ps` on the controller shows.
        detail = "\(holder.session) · run \(holder.runID)"
    }
}

/// The panel's state machine, driven by the lease's current holder.
struct ScreenPanelState: Equatable {
    enum Effect: Equatable {
        case none
        case present(ScreenPanelContent)
        /// Already up for another holder: change the text in place. A handover between two
        /// queued screen runs must not close and reopen the panel over a running test.
        case update(ScreenPanelContent)
        case dismiss
    }

    private(set) var shown: ScreenPanelContent?

    /// `holder` is the lease's holder now, nil when the screen is free. Idempotent: the lease
    /// notifies on every queue change, most of which leave the holder as it was.
    mutating func update(holder: LeaseHolder?) -> Effect {
        let next = holder.map(ScreenPanelContent.init(holder:))
        defer { shown = next }
        switch (shown, next) {
        case (nil, nil): return .none
        case (nil, let content?): return .present(content)
        case (_?, nil): return .dismiss
        case (let old?, let content?): return old == content ? .none : .update(content)
        }
    }
}

/// The AppKit shell. Every entry point is callable from any thread; the work hops to main.
enum ScreenPanel {
    @MainActor private static var state = ScreenPanelState()
    @MainActor private static var panel: NSPanel?
    @MainActor private static var titleLabel: NSTextField?
    @MainActor private static var detailLabel: NSTextField?

    /// Keeps the panel in step with `screen` for the life of the process: the hostd's one-line
    /// wiring. Reads the holder on the main queue rather than passing it along, so a grant and
    /// a release racing in from two threads can only ever leave the panel showing the lease's
    /// latest state, never an older one delivered late.
    static func follow(_ screen: ScreenLease) {
        screen.observe { DispatchQueue.main.async { MainActor.assumeIsolated { apply(holder: screen.holder) } } }
    }

    static func show(holder: LeaseHolder) {
        DispatchQueue.main.async { MainActor.assumeIsolated { apply(holder: holder) } }
    }

    static func hide() {
        DispatchQueue.main.async { MainActor.assumeIsolated { apply(holder: nil) } }
    }

    /// Runs the process as an `.accessory` AppKit app, in place of `dispatchMain()`: the
    /// panel needs the main run loop, which `dispatchMain()` never runs. The main queue is
    /// still drained, so everything that relied on it keeps working.
    @MainActor static func runApplication() -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
        exit(0)
    }

    @MainActor private static func apply(holder: LeaseHolder?) {
        switch state.update(holder: holder) {
        case .none:
            break
        case .present(let content):
            let panel = self.panel ?? makePanel()
            fill(content)
            place(panel)
            // Never `makeKey`: the app under test must keep focus.
            panel.orderFrontRegardless()
        case .update(let content):
            fill(content)
        case .dismiss:
            panel?.orderOut(nil)
        }
    }

    @MainActor private static func fill(_ content: ScreenPanelContent) {
        titleLabel?.stringValue = content.title
        detailLabel?.stringValue = content.detail
    }

    /// Top centre of the screen with the menu bar, clear of it.
    @MainActor private static func place(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12))
    }

    @MainActor private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 58),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Clicks pass through to whatever is underneath: an XCUITest tapping near the top of
        // the screen must hit its own app, not this.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "")
        title.font = .boldSystemFont(ofSize: 13)
        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: background.widthAnchor, constant: -24),
        ])
        panel.contentView = background

        self.panel = panel
        titleLabel = title
        detailLabel = detail
        return panel
    }
}
