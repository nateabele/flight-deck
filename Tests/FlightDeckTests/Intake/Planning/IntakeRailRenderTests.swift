import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The Intakes list expanded and collapsed to its rail, the rail's + popover, and a rail row's
/// hover card — the whole window, toolbar included, so where the two sidebar toggles sit can be
/// looked at. Skipped unless `FD_PLANNING_RENDER_DIR` names an output directory; writes
/// `rail-*.png`, dark and light.
///
/// A titled window rather than `PlanningRender`'s borderless one: the toolbar is part of what is
/// being reviewed, and only a titled window gets a real `NSToolbar`. Rendered from the theme
/// frame (the window's root view), which holds the title bar as well as the content.
@MainActor
final class IntakeRailRenderTests: XCTestCase {
    private var root: URL!
    private var restoreDefaults: (() -> Void)?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IntakeRailRenderTests-\(UUID())")
    }

    override func tearDown() {
        restoreDefaults?()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testRenderRail() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the rail PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            try render(appearance: appearance, collapsed: false, to: out.appendingPathComponent("rail-expanded-\(suffix).png"))
            try render(appearance: appearance, collapsed: true, to: out.appendingPathComponent("rail-collapsed-\(suffix).png"))
            try render(appearance: appearance, collapsed: true, to: out.appendingPathComponent("rail-hover-\(suffix).png"),
                       prepare: { host, _ in self.openCard(onRow: 2, in: host) })
            try render(appearance: appearance, collapsed: true, to: out.appendingPathComponent("rail-composer-\(suffix).png"),
                       prepare: { host, _ in
                           self.showComposer(beside: NSPoint(x: 289, y: 860), in: host)
                       })
            try render(appearance: appearance, collapsed: true, inspector: true,
                       to: out.appendingPathComponent("rail-inspector-\(suffix).png"))
        }
    }

    // MARK: - Scene

    private func render(appearance: NSAppearance.Name, collapsed: Bool, inspector: Bool = false, to url: URL,
                        prepare: ((NSView, NSWindow) -> Void)? = nil) throws {
        let previous = NSApplication.shared.appearance
        // The hover card's and popover's windows take the app's appearance, not their parent's.
        NSApplication.shared.appearance = NSAppearance(named: appearance)
        defer { NSApplication.shared.appearance = previous }

        let prefs = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        let intakesRoot = root.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: prefs, intakesRoot: intakesRoot)
        let repoURL = URL(fileURLWithPath: "/Users/me/Projects/dispatch-\(UUID().uuidString.prefix(4))", isDirectory: true)
        store.newSession(in: repoURL)
        let repo = try XCTUnwrap(store.repos.first)
        var settings = prefs.projectSettings(repo.url.path)
        settings.flywheelEnabled = true
        prefs.setProjectSettings(repo.url.path, settings)
        let path = repo.url.standardizedFileURL.path
        // Seeded before the first read of `intakeService`: it loads its intakes once, at init.
        let selected = try seed(project: path, into: IntakeStore(root: intakesRoot))
        let service = store.intakeService
        service.pollTapes()
        service.select(selected, inProject: path)
        service.setIntakeListCollapsed(collapsed, inProject: path)
        service.setInspectorShown(inspector, inProject: path)
        restoreDefaults = {
            service.setIntakeListCollapsed(false, inProject: path)
            service.setInspectorShown(false, inProject: path)
            service.select(nil, inProject: path)
        }
        store.selectProject(repo.id)

        let size = NSSize(width: 1500, height: 900)
        let frame = NSRect(x: -12_000, y: -12_000, width: size.width, height: size.height)
        let window = ParkedWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = NSHostingController(rootView: RootView(store: store, preferences: prefs)
            .environment(\.controlActiveState, .key))
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        defer {
            window.childWindows?.forEach { window.removeChildWindow($0); $0.orderOut(nil) }
            window.orderOut(nil)
            window.contentViewController = nil
        }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let content = try XCTUnwrap(window.contentView)
        if let prepare {
            prepare(content, window)
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        }
        logToolbar(window)

        let frameView = try XCTUnwrap(content.superview)
        frameView.wantsLayer = true
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        let scale: CGFloat = 2
        let bounds = frameView.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
                                                 pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        // The theme frame is not flipped, so unlike a hosting view it needs no y-flip.
        if frameView.isFlipped {
            context.translateBy(x: 0, y: bounds.height * scale)
            context.scaleBy(x: scale, y: -scale)
        } else {
            context.scaleBy(x: scale, y: scale)
        }
        try XCTUnwrap(frameView.layer).render(in: context)
        for child in window.childWindows ?? [] where child.isVisible {
            guard let layer = child.contentView?.superview?.layer ?? child.contentView?.layer else { continue }
            context.saveGState()
            context.translateBy(x: child.frame.minX - window.frame.minX,
                                y: frameView.isFlipped ? window.frame.maxY - child.frame.maxY : child.frame.minY - window.frame.minY)
            layer.render(in: context)
            context.restoreGState()
        }
        if let (popover, point) = composerPopover, let contentView = popover.contentViewController?.view,
           let layer = contentView.layer {
            // The popover's own chrome is a vibrancy view `layer.render` can't draw (it came out
            // as a smear of false colour), so its body is drawn here — the popover background
            // colour, its corner radius and shadow — under the real content, beside the +.
            let size = contentView.frame.size
            let top = min(point.y - size.height / 2, bounds.height - size.height - 8)
            let origin = CGPoint(x: point.x + 24, y: bounds.height - top - size.height)
            let body = CGRect(origin: origin, size: size)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -8), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            let fill: NSColor = appearance == .darkAqua ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.97, alpha: 1)
            context.setFillColor(fill.cgColor)
            let path = CGMutablePath()
            path.addRoundedRect(in: body, cornerWidth: 12, cornerHeight: 12)
            // The arrow, pointing back at the +.
            let arrowY = min(max(bounds.height - point.y, body.minY + 20), body.maxY - 20)
            path.move(to: CGPoint(x: body.minX, y: arrowY - 9))
            path.addLine(to: CGPoint(x: body.minX - 10, y: arrowY))
            path.addLine(to: CGPoint(x: body.minX, y: arrowY + 9))
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
            context.saveGState()
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(0.5)
            context.addPath(CGPath(roundedRect: body, cornerWidth: 12, cornerHeight: 12, transform: nil))
            context.strokePath()
            // The hosting view is flipped; this context (the theme frame's) is not.
            context.translateBy(x: origin.x, y: origin.y + size.height)
            context.scaleBy(x: 1, y: -1)
            layer.render(in: context)
            context.restoreGState()
            popover.close()
            composerPopover = nil
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// Every state the rail draws, newest first, the shaping one selected with a plan on its tape.
    private func seed(project: String, into intakes: IntakeStore) throws -> UUID {
        let now = Date()
        let rows: [(IntakeState, String)] = [
            (.needsAnswers, "Let dispatchers reassign a job from the map view. Drag a pin onto a tech, confirm, and notify both techs."),
            (.shaping, "Route optimisation for multi-stop days: order a tech's stops to cut drive time, respecting time windows."),
            (.awaitingChoice, "Add an audit trail for price overrides, so finance can see who changed a quote and why."),
            (.review, "Offline mode for the tech app: queue check-ins and photos while out of signal, sync when back."),
            (.triaging, "Show a live ETA to the customer once the tech is en route."),
            (.releasing, "Split the invoices table by region."),
            (.released, "Fix the double-booking race when two dispatchers assign the same slot."),
            (.partiallyReleased, "Migrate job notes to Markdown, keeping the old plain-text renderer for exports."),
            (.failed, "Nightly report of techs who missed their first check-in."),
            (.interrupted, "Rename 'crew' to 'team' everywhere a customer can see it."),
            (.parked, "Explore letting customers pick a two-hour window instead of a full day."),
        ]
        var selected: UUID?
        for (offset, (state, intent)) in rows.enumerated() {
            var intake = Intake(projectPath: project, intent: intent, createdAt: now.addingTimeInterval(-Double(offset) * 3600))
            intake.state = state
            if state == .released || state == .partiallyReleased {
                intake.release = ReleaseRecord(releasedAt: now, appliedSteps: 4, idMap: [:])
            }
            if state == .shaping {
                intake.recommended = .featurePlan
                intake.chosenPreset = .featurePlan
                intake.roundConfig = PresetExpansion.config(for: .featurePlan, available: .defaults)
                selected = intake.id
            }
            try intakes.save(intake)
            if state == .shaping {
                let tapes = TapeStore(intakeDirectory: intakes.directory(for: intake.id))
                var tape = tapes.loadTape()
                let plan = """
                # Route optimisation for multi-stop days

                ## 1. Goal

                Order each technician's stops for the day to cut total drive time, while honouring every customer's booked window and the tech's own shift.

                ## 2. Constraints

                - Time windows are hard; drive time is soft.
                - A dispatcher's manual pin always wins over the optimiser.
                - Re-plan when a job runs over by more than 15 minutes.

                ## 3. Approach

                Solve per tech per day as a vehicle-routing problem with time windows, warm-started from yesterday's order.
                """
                try tapes.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: now),
                                          files: ["drafts/0.md": Data(plan.utf8)], into: &tape)
                tape.status = .paused
                try tapes.saveTape(tape)
            }
        }
        return try XCTUnwrap(selected)
    }

    // MARK: - Driving the scene

    /// Presents a rail row's hover card directly on its anchor, as a rested pointer would —
    /// the offscreen window gets no real pointer to hover with.
    private func openCard(onRow index: Int, in host: NSView) {
        let anchors = all(FloatingCardAnchor.self, in: host)
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
            .filter { $0.convert($0.bounds, to: nil).maxX < 320 }
        guard anchors.indices.contains(index) else { return XCTFail("only \(anchors.count) rail anchors") }
        var intake = Intake(projectPath: "/p", intent: "Add an audit trail for price overrides, so finance can see who changed a quote and why.")
        intake.state = .awaitingChoice
        anchors[index].placement = .trailing
        anchors[index].present(AnyView(IntakeRailCard(intake: intake)))
    }

    /// The rail's + popover: the same `NSPopover` SwiftUI's `.popover` presents, holding the
    /// same `IntakeComposer`, shown against the + button's spot. Presented here rather than by a
    /// click: a synthesized mouse-down on a SwiftUI button enters its tracking loop and waits
    /// for a mouse-up that never comes. Drawn at its anchored spot by `render`, since a window
    /// parked off every display gets its popover clamped back onto one.
    private func showComposer(beside point: NSPoint, in host: NSView) {
        var draft = "Let dispatchers bulk-reschedule a tech's remaining jobs when they call in sick"
        let composer = IntakeComposer(intent: Binding(get: { draft }, set: { draft = $0 }), onTriage: {}, onCancel: {})
            .frame(width: 340)
            .padding(14)
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: composer)
        popover.behavior = .applicationDefined
        let rect = NSRect(x: point.x - 14, y: host.bounds.height - point.y - 14, width: 28, height: 28)
        popover.show(relativeTo: host.isFlipped ? NSRect(x: rect.minX, y: point.y - 14, width: 28, height: 28) : rect,
                     of: host, preferredEdge: .maxX)
        composerPopover = (popover, point)
    }

    private var composerPopover: (NSPopover, NSPoint)?

    private func logToolbar(_ window: NSWindow) {
        guard let toolbar = window.toolbar else { return print("rail render: no toolbar") }
        for item in toolbar.items {
            let frame = item.view.map { $0.convert($0.bounds, to: nil) } ?? .zero
            print("rail render toolbar item:", item.itemIdentifier.rawValue, "label:", item.label, "frame:", frame)
        }
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
}
