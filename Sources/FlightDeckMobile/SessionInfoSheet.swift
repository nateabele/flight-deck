import FleetKit
import SwiftUI

/// One tab's context fill, the account it runs as with that account's usage windows and reset
/// times, and the accounts it can move to. Opened from the session screen's toolbar.
///
/// **It moves a tab by typing `/switch-account <id>` into it**, through the same prompt path as
/// the composer, rather than with a phone-side `account.switch`. The command runs in the tab,
/// as the tab, so the Mac's refusals (asleep, swarm agent, outside the project's pool) apply
/// exactly as at the keyboard, and the phone needs no write path of its own. The id is the
/// account's UUID (or the pool's id), which the Mac matches exactly.
///
/// The choices are the Mac's: a project that assigns a pool is offered that pool alone.
struct SessionInfoSheet: View {
    let session: WireSession?
    let load: () async -> Result<WireAccountChoices, FleetRequestError>
    /// Types `/switch-account <target>` into the tab.
    let switchTo: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var confirming: Target?

    enum Phase: Equatable {
        case loading
        case loaded(WireAccountChoices)
        case failed(String)
    }

    struct Target: Identifiable, Equatable {
        let id: String
        let label: String
    }

    var body: some View {
        NavigationStack {
            List {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView(); Spacer() }
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                case .loaded(let choices):
                    contextSection(choices.context)
                    accountSection(choices.currentAccount)
                    if SessionInfoStyle.canSwitch(agent: session?.agent) {
                        switchSections(choices)
                    }
                }
            }
            .navigationTitle(session?.title ?? "Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await reload() }
            .task { await reload() }
            .confirmationDialog(
                confirming.map { "Move this conversation to \($0.label)?" } ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { target in
                Button("Move to \(target.label)") {
                    switchTo(target.id)
                    dismiss()
                }
            } message: { _ in
                Text("Anything still running stops first and picks up again there.")
            }
        }
        .accessibilityIdentifier("session-info-sheet")
    }

    private func reload() async {
        switch await load() {
        case .success(let choices): phase = .loaded(choices)
        case .failure(let error): phase = .failed(SessionInfoStyle.failureText(error))
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func contextSection(_ context: WireContextUsage?) -> some View {
        Section("Context") {
            if let context {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(context.usedPercent, 100), total: 100)
                        .tint(SessionInfoStyle.tint(fraction: context.usedPercent / 100))
                    Text(SessionInfoStyle.contextText(context))
                        .font(.subheadline.monospacedDigit())
                }
                .accessibilityIdentifier("session-info-context")
            } else {
                Text("No reading yet").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func accountSection(_ account: WireAccountChoice?) -> some View {
        Section("Account") {
            if let account {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName).font(.headline)
                    if let email = account.email {
                        Text(email).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("session-info-account")
                let windows = account.windows ?? []
                if windows.isEmpty {
                    Text("No usage reading yet").foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(windows, id: \.name) { window in
                            windowRow(window, now: context.date)
                        }
                    }
                }
            } else {
                Text("No account on file").foregroundStyle(.secondary)
            }
        }
    }

    private func windowRow(_ window: WireUsageWindow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(SessionInfoStyle.windowLabel(window.name))
                Spacer()
                Text(SessionInfoStyle.percentText(window.utilization)).monospacedDigit()
            }
            .font(.subheadline)
            ProgressView(value: min(max(window.utilization, 0), 1))
                .tint(SessionInfoStyle.tint(fraction: window.utilization))
            if let reset = SessionInfoStyle.resetText(window.resetsAt, now: now) {
                Text(reset).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func switchSections(_ choices: WireAccountChoices) -> some View {
        ForEach(choices.pools, id: \.id) { pool in
            Section {
                Button {
                    confirming = Target(id: pool.id, label: "pool \(pool.label)")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Any account in \(pool.label)")
                        Text("The first one under its limit").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(pool.members, id: \.id) { accountRow($0) }
            } header: {
                Text(pool.isAssigned ? "Pool \(pool.label) · this project" : "Pool \(pool.label)")
            } footer: {
                if pool.isAssigned, choices.pools.count == 1, choices.accounts.isEmpty {
                    Text("This project uses this pool, so its conversations move only within it.")
                }
            }
        }
        if !choices.accounts.isEmpty {
            Section(choices.pools.isEmpty ? "Move to" : "No pool") {
                ForEach(choices.accounts, id: \.id) { accountRow($0) }
            }
        }
    }

    private func accountRow(_ account: WireAccountChoice) -> some View {
        Button {
            confirming = Target(id: account.id, label: account.displayName)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName).foregroundStyle(account.isCurrent ? .secondary : .primary)
                    Text(SessionInfoStyle.choiceDetail(account))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(SessionInfoStyle.isOver(account.state) ? .orange : .secondary)
                }
                Spacer()
                if account.isCurrent { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .disabled(account.isCurrent)
        .accessibilityIdentifier("session-info-choice")
    }
}

/// The sheet's words and numbers, apart from the view so they can be tested.
enum SessionInfoStyle {
    /// `/switch-account` is the Flight Deck plugin's, which only claude runs.
    static func canSwitch(agent: String?) -> Bool { agent == "claude" }

    /// The command the sheet types into the tab.
    static func switchCommand(_ target: String) -> String { "/switch-account \(target)" }

    /// The same short names the Mac's meters use (`MeterFormatter.windowLabel`, which the phone
    /// target cannot reach): "<limitId>:<base>" is base's label, "<n>m" is hours when it divides
    /// evenly, and a leading "<vendor>-" is dropped ("gemini-weekly" is "wk").
    static func windowLabel(_ name: String) -> String {
        if let colon = name.lastIndex(of: ":") { return windowLabel(String(name[name.index(after: colon)...])) }
        switch name {
        case "five_hour": return "5h"
        case "seven_day", "weekly": return "wk"
        case "seven_day_opus": return "Opus wk"
        case "seven_day_sonnet": return "Sonnet wk"
        case "rejected": return "Refused"
        case "retry-after": return "Retry"
        default: break
        }
        if name.hasSuffix("m"), let minutes = Int(name.dropLast()), minutes > 0, minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        if let dash = name.firstIndex(of: "-") { return windowLabel(String(name[name.index(after: dash)...])) }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    static func percentText(_ utilization: Double) -> String { "\(Int((utilization * 100).rounded()))%" }

    /// "resets in 2h 14m" within a day, "resets Tue 3:00 PM" beyond; nil with no reset time.
    static func resetText(_ resetsAt: Date?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        if seconds <= 0 { return "reset" }
        if seconds < 24 * 3600 {
            let minutes = Int((seconds / 60).rounded(.up))
            let hours = minutes / 60
            return hours > 0 ? "resets in \(hours)h \(minutes % 60)m" : "resets in \(minutes)m"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE j:mm")
        return "resets \(formatter.string(from: resetsAt))"
    }

    /// "37% used of 200K tokens".
    static func contextText(_ context: WireContextUsage) -> String {
        let percent = "\(Int(context.usedPercent.rounded()))% used"
        guard let size = context.windowSize, size > 0 else { return percent }
        let tokens = size >= 1_000_000 && size % 1_000_000 == 0 ? "\(size / 1_000_000)M"
            : size >= 1_000 ? "\(size / 1_000)K" : "\(size)"
        return "\(percent) of \(tokens) tokens"
    }

    /// One choice's usage on one line: each window's percent, or its headroom state.
    static func choiceDetail(_ account: WireAccountChoice) -> String {
        let windows = account.windows ?? []
        let state = ["underSoft": "under limit", "overSoft": "near limit", "overHard": "over limit"][account.state]
        guard !windows.isEmpty else { return state ?? "no usage reading" }
        let usage = windows.map { "\(windowLabel($0.name)) \(percentText($0.utilization))" }.joined(separator: " · ")
        return state.map { "\(usage) · \($0)" } ?? usage
    }

    static func isOver(_ state: String) -> Bool { state == "overSoft" || state == "overHard" }

    static func tint(fraction: Double) -> Color {
        fraction >= 0.9 ? .red : fraction >= 0.75 ? .orange : .accentColor
    }

    static func failureText(_ error: FleetRequestError) -> String {
        switch error {
        case .disconnected: "Not connected to your Mac."
        case .server(code: "out_of_scope"), .server(code: "unsupported"):
            "Update Flight Deck on your Mac to see accounts here."
        case .server(code: "unknown_session"): "This tab has no account information."
        default: "Your Mac could not answer."
        }
    }
}
