import FleetKit
import HostKit
import SwiftUI

// MARK: - Actions

/// What the sidebar's cloud popover can do, injected through the SwiftUI environment so the
/// views compile (and render in tests and previews) without an `InfraService`. The default is
/// `unavailable`: its controls draw disabled.
struct SessionCloudActions {
    var isAvailable = true
    /// Moves the machine's deadline out by `SessionCloudFormat.extendStep`.
    var extend: @MainActor (_ name: String) async throws -> Void
    /// Destroys the machine (the confirmation is the popover's, before this is called).
    var destroy: @MainActor (_ name: String) async throws -> Void
    /// Opens Settings on the Cloud pane.
    var openSettings: @MainActor () -> Void

    static let unavailable = SessionCloudActions(
        isAvailable: false, extend: { _ in }, destroy: { _ in }, openSettings: {})

    /// Backed by the app's one `InfraService`; Settings opens through `PreferencesOpener`.
    @MainActor
    static func live(service: InfraService, preferences: PreferencesStore?) -> SessionCloudActions {
        SessionCloudActions(
            // `onOperationFinished` after each, as the `infra.*` request path does, so the icon
            // and any phone see the new deadline or the machine gone without waiting a tick.
            extend: { name in
                defer { service.onOperationFinished?() }
                _ = try await service.extend(name: name, by: HostKit.Duration(seconds: Int(SessionCloudFormat.extendStep)))
            },
            destroy: { name in
                defer { service.onOperationFinished?() }
                try await service.down(name: name) { _ in }
            },
            openSettings: { PreferencesOpener.open(preferences, tab: .cloud) })
    }
}

private struct SessionCloudActionsKey: EnvironmentKey {
    static let defaultValue = SessionCloudActions.unavailable
}

extension EnvironmentValues {
    var sessionCloudActions: SessionCloudActions {
        get { self[SessionCloudActionsKey.self] }
        set { self[SessionCloudActionsKey.self] = newValue }
    }
}

// MARK: - Presenter

/// Decides when the popover is shown: a click toggles it and pins it open until dismissed; a
/// hover opens it after a short delay and lets it go shortly after the pointer has left both the
/// icon and the popover itself.
@MainActor
final class SessionCloudPresenter: ObservableObject {
    @Published private(set) var isShown = false
    private(set) var isPinned = false
    private var overIcon = false
    private var overPopover = false
    private var pending: Task<Void, Never>?

    static let openDelay: Swift.Duration = .milliseconds(350)
    static let closeDelay: Swift.Duration = .milliseconds(250)

    func hoverIcon(_ over: Bool) { overIcon = over; reconsider() }
    func hoverPopover(_ over: Bool) { overPopover = over; reconsider() }

    /// First click on a hover-opened popover pins it; a click on a pinned one closes it.
    func click() {
        pending?.cancel()
        if isShown && isPinned { dismiss() } else { isShown = true; isPinned = true }
    }

    /// Keeps the popover open regardless of the pointer (a destroy is awaiting confirmation).
    func pin() { isPinned = true }

    /// The popover closed itself (a click elsewhere) or was closed here.
    func dismiss() {
        pending?.cancel()
        isShown = false
        isPinned = false
    }

    private func reconsider() {
        pending?.cancel()
        let over = overIcon || overPopover
        if over && !isShown {
            pending = Task { [weak self] in
                try? await Task.sleep(for: Self.openDelay)
                guard !Task.isCancelled else { return }
                self?.isShown = true
            }
        } else if !over && isShown && !isPinned {
            pending = Task { [weak self] in
                try? await Task.sleep(for: Self.closeDelay)
                guard !Task.isCancelled else { return }
                self?.isShown = false
            }
        }
    }

    deinit { pending?.cancel() }
}

// MARK: - Controls model

/// The popover's in-flight and error state. Owned by the icon, not the popover, so a hover
/// that closes the popover mid-request does not forget the request or its error.
@MainActor
final class SessionCloudControls: ObservableObject {
    @Published var busy: Set<String> = []
    @Published var errors: [String: String] = [:]
    @Published var pendingDestroy: String?

    func extend(_ name: String, using actions: SessionCloudActions) {
        run(name) { try await actions.extend(name) }
    }

    func confirmDestroy(using actions: SessionCloudActions) {
        guard let name = pendingDestroy else { return }
        pendingDestroy = nil
        run(name) { try await actions.destroy(name) }
    }

    private func run(_ name: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard !busy.contains(name) else { return }
        busy.insert(name)
        errors[name] = nil
        Task {
            do { try await work() } catch { errors[name] = CloudSetupModel.describe(error) }
            busy.remove(name)
        }
    }
}

// MARK: - Icon

/// The cloud glyph at a session row's trailing edge, and the popover it opens. A borderless
/// `Button`, like the row's close button: the one construct the row tolerates (see the
/// comments in `SessionRow`), and an `NSControl`, which `SidebarInputMonitor.pressedControl`
/// already treats as "not a row click".
struct SessionCloudIcon: View {
    let cloud: WireSessionCloud
    @StateObject private var presenter = SessionCloudPresenter()
    @StateObject private var controls = SessionCloudControls()

    var body: some View {
        Button { presenter.click() } label: {
            Image(systemName: Self.symbol(cloud.badge))
                .imageScale(.small)
                .foregroundStyle(Self.tint(cloud.badge))
        }
        .buttonStyle(.borderless)
        .onHover { presenter.hoverIcon($0) }
        .popover(isPresented: Binding(
            get: { presenter.isShown },
            set: { if !$0 { presenter.dismiss() } }
        ), arrowEdge: .trailing) {
            SessionCloudPopover(cloud: cloud, controls: controls)
                .onHover { presenter.hoverPopover($0) }
                .onChange(of: controls.pendingDestroy) { _, pending in if pending != nil { presenter.pin() } }
        }
        .help("Cloud machines for this session")
        .accessibilityLabel(SessionCloudFormat.accessibilitySummary(cloud, at: Date()))
        .accessibilityIdentifier("session-cloud")
    }

    static func symbol(_ badge: WireSessionCloud.Badge) -> String {
        badge == .failed ? "exclamationmark.icloud.fill" : "cloud.fill"
    }

    /// Quiet at rest; a provisioning session takes the accent, a failed one red. No animation.
    static func tint(_ badge: WireSessionCloud.Badge) -> AnyShapeStyle {
        switch badge {
        case .ready: AnyShapeStyle(.secondary)
        case .busy: AnyShapeStyle(.tint)
        case .failed: AnyShapeStyle(Color.red)
        }
    }
}

// MARK: - Popover

/// Re-renders once a second while open; closed, nothing here exists, so nothing ticks.
struct SessionCloudPopover: View {
    let cloud: WireSessionCloud
    @ObservedObject var controls: SessionCloudControls

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            SessionCloudPopoverContent(cloud: cloud, controls: controls, now: timeline.date)
        }
    }
}

/// The popover as a pure function of the snapshot and `now`, so tests render it at a fixed time.
struct SessionCloudPopoverContent: View {
    let cloud: WireSessionCloud
    @ObservedObject var controls: SessionCloudControls
    let now: Date
    @Environment(\.sessionCloudActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            budget
            if let cap = cloud.monthCapUsd {
                Text("Month ~\(SessionCloudFormat.usd(cloud.monthUsd)) of \(SessionCloudFormat.usd(cap))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("session-cloud-month")
            }
            Divider()
            ForEach(cloud.machines) { machine in
                machineView(machine)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cloud Settings…") { actions.openSettings() }
                    .controlSize(.small)
                    .disabled(!actions.isAvailable)
                    .accessibilityIdentifier("session-cloud-settings")
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .accessibilityIdentifier("session-cloud-popover")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Cloud").font(.headline)
            Spacer()
            Text("\(SessionCloudFormat.usd(cloud.hourlyUsd))/h")
                .font(.subheadline.monospacedDigit())
            Text("\(SessionCloudFormat.usd(cloud.spent(at: now))) spent")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Budget

    @ViewBuilder
    private var budget: some View {
        if let cap = cloud.budgetCapUsd, let level = SessionCloudFormat.budgetLevel(cloud, at: now) {
            let spent = cloud.spent(at: now)
            let color: Color = level == .exhausted ? .red : level == .warning ? .orange : .accentColor
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Budget \(SessionCloudFormat.usd(cap))").font(.subheadline)
                    Spacer()
                    Text("\(SessionCloudFormat.usd(spent)) spent · \(SessionCloudFormat.usd(cloud.remaining(at: now) ?? 0)) left")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                // Drawn by hand: `ProgressView(value:)` ignores `.tint` while its window is
                // inactive (a hover popover's never is key), which greyed the warning colours.
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule().fill(color)
                                .frame(width: geo.size.width * SessionCloudFormat.budgetFraction(spent: spent, cap: cap))
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Budget used")
                    .accessibilityValue("\(Int((SessionCloudFormat.budgetFraction(spent: spent, cap: cap) * 100).rounded())) percent")
                    .accessibilityIdentifier("session-cloud-budget-bar")
                if let text = SessionCloudFormat.exhaustionText(cloud, at: now) {
                    Text(text.prefix(1).uppercased() + text.dropFirst())
                        .font(.caption)
                        .foregroundStyle(level == .exhausted ? Color.red : Color.secondary)
                }
            }
        } else {
            Text("No budget for this session — `/budget 20` sets one")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Machines

    private func machineView(_ machine: WireCloudMachine) -> some View {
        let inFlight = controls.busy.contains(machine.name)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(machine.name).fontWeight(.medium)
                Text(machine.state)
                    .font(.caption)
                    .foregroundStyle(machine.state == "failed" ? .red : .secondary)
                Spacer()
                Text(SessionCloudFormat.rateText(machine))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(SessionCloudFormat.detailLine(machine))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text([
                "\(SessionCloudFormat.usd(machine.spent(asOf: cloud.asOf, at: now))) spent",
                SessionCloudFormat.upText(machine, at: now),
                SessionCloudFormat.ttlText(machine, at: now),
            ].joined(separator: " · "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let failure = machine.failure {
                Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            if let error = controls.errors[machine.name] {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
                    .accessibilityIdentifier("session-cloud-error-\(machine.name)")
            }
            controlsRow(machine, inFlight: inFlight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-cloud-machine-\(machine.name)")
    }

    @ViewBuilder
    private func controlsRow(_ machine: WireCloudMachine, inFlight: Bool) -> some View {
        if controls.pendingDestroy == machine.name {
            // Inline rather than a `.confirmationDialog`: this lives in a transient popover,
            // and a dialog presented from inside one dismisses the popover under it.
            VStack(alignment: .leading, spacing: 4) {
                Text("Destroy “\(machine.name)”? The cloud machine and everything on it is deleted. Runs on \(machine.name) stop.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Destroy", role: .destructive) { controls.confirmDestroy(using: actions) }
                        .accessibilityIdentifier("session-cloud-destroy-confirm-\(machine.name)")
                    Button("Cancel", role: .cancel) { controls.pendingDestroy = nil }
                }
                .controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                Button("Extend 1h") { controls.extend(machine.name, using: actions) }
                    .disabled(!actions.isAvailable || inFlight || !SessionCloudFormat.canExtend(machine))
                    .help(SessionCloudFormat.extendHelp(machine))
                    .accessibilityIdentifier("session-cloud-extend-\(machine.name)")
                Button("Destroy…", role: .destructive) { controls.pendingDestroy = machine.name }
                    .disabled(!actions.isAvailable || inFlight || machine.state == "destroying")
                    .accessibilityIdentifier("session-cloud-destroy-\(machine.name)")
                if inFlight { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
        }
    }
}
