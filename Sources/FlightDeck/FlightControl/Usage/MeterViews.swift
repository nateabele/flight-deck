import SwiftUI
import IntakeKit

/// One account's bar, decided outside SwiftUI so `MeterFormatterTests` can pin every word.
struct AccountMeterModel: Identifiable, Equatable {
    let id: String
    let label: String
    /// Nil is unknown: the bar is drawn empty and grey.
    let fraction: Double?
    let state: HeadroomState
    let soft: Double
    let hard: Double
    let resetText: String?
    let sourceText: String?
    let detail: String?

    var percentText: String { fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

    /// What VoiceOver says, and what the UI test reads, so both describe the same state.
    var accessibilityValue: String {
        // A refusal is the one state a listener must not mistake for a measured number, so its
        // wording is spoken in the sentence's own case rather than as a capitalised label.
        let spokenDetail = detail.map { $0 == MeterFormatter.refusedDetail ? $0.lowercased() : $0 }
        guard let fraction else { return spokenDetail ?? "no reading" }
        var parts = ["\(Int((fraction * 100).rounded())) percent used"]
        switch state {
        case .underSoft: parts.append("has headroom")
        case .overSoft: parts.append("past its soft limit")
        case .overHard: parts.append("past its hard limit")
        case .unknown: break
        }
        if let resetText { parts.append(resetText) }
        if let spokenDetail { parts.append(spokenDetail) }
        return parts.joined(separator: ", ")
    }
}

extension AccountMeterModel {
    /// The one string the bar exposes: the account's name, then its reading.
    var spokenText: String { "\(label): \(accessibilityValue)" }
}

struct PoolMeterModel: Identifiable, Equatable {
    let id: PoolID
    let title: String
    let isLocal: Bool
    let accounts: [AccountMeterModel]
    let note: String?
}

enum MeterFormatter {
    static let refusedDetail = "Refused by the provider"

    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<86_400: return "\(Int(s / 3600)) h ago"
        default: return "\(Int(s / 86_400)) d ago"
        }
    }

    static func resetText(_ date: Date?, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let date, date > now else { return nil }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = date.timeIntervalSince(now) < 86_400 ? "h:mm a" : "EEE h:mm a"
        return "resets \(f.string(from: date))"
    }

    static func account(_ h: AccountHeadroom, pool: CapacityPool, reading: UsageReading?, error: String?, now: Date,
                        rejection: Rejection? = nil,
                        timeZone: TimeZone = .current, locale: Locale = .current) -> AccountMeterModel {
        // A local pool's bar is slots in use; soft/hard ticks mean nothing there, so they sit at
        // the end of the track.
        let isLocal = pool.kind == .local

        // Spec §3: a rejection marks the account over hard whatever the meter said, so the bar
        // must say refused and name what refused it. Drawing it as a plain measured 100% hides
        // that the provider, not our arithmetic, closed the account.
        if let rejection, now < rejection.expiry {
            let realUtilization = reading.flatMap { r in
                r.worstWindow.map { window in
                    HeadroomPolicy.effectiveUtilization(of: window, readAt: r.readAt, now: now)
                }
            }
            return AccountMeterModel(
                id: "\(pool.id.rawValue)|\(h.account.id?.uuidString ?? "slot")",
                label: h.account.label,
                fraction: realUtilization,
                state: .overHard,
                soft: isLocal ? 1 : pool.softThreshold,
                hard: isLocal ? 1 : pool.hardThreshold,
                resetText: resetText(rejection.expiry, now: now, timeZone: timeZone, locale: locale),
                sourceText: "\(rejection.source) · \(age(now.timeIntervalSince(rejection.at)))",
                detail: refusedDetail)
        }

        let detail: String?
        if let error { detail = error }
        else if h.state == .unknown { detail = reading == nil ? "no reading" : "reading is stale" }
        else { detail = nil }
        return AccountMeterModel(
            id: "\(pool.id.rawValue)|\(h.account.id?.uuidString ?? "slot")",
            label: h.account.label,
            fraction: h.state == .unknown ? nil : h.worstUtilization,
            state: h.state,
            soft: isLocal ? 1 : pool.softThreshold,
            hard: isLocal ? 1 : pool.hardThreshold,
            resetText: resetText(h.resetsAt, now: now, timeZone: timeZone, locale: locale),
            sourceText: reading.map { "\($0.source) · \(age(now.timeIntervalSince($0.readAt)))" },
            detail: detail)
    }

    static func pools(_ ledger: CapacityLedger, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> [PoolMeterModel] {
        ledger.allPools.map { pool in
            let rows = ledger.headroom(pool: pool.id).map { h in
                account(h, pool: pool,
                        reading: h.account.id.flatMap { ledger.latestReading(account: $0) },
                        error: h.account.id.flatMap { ledger.sourceError(account: $0) },
                        now: now, rejection: h.account.id.flatMap { ledger.rejection(account: $0) },
                        timeZone: timeZone, locale: locale)
            }
            // The spec's caveat, said where the number is: FD counts only its own agents.
            let note: String? = pool.kind == .local
                ? "\(ledger.activeLeases(pool: pool.id).count) of \(pool.concurrencyCap) agents running on \(pool.endpoint ?? "this endpoint"). Load from outside Flight Deck is not visible."
                : nil
            return PoolMeterModel(id: pool.id, title: pool.label, isLocal: pool.kind == .local, accounts: rows, note: note)
        }
    }

    /// The sidebar row's small meter (L3-U §6): only past soft, from whichever pool holding the
    /// account rates it worst — the row warns at the earliest threshold anyone set.
    static func rowMeter(account id: UUID, ledger: CapacityLedger, now: Date,
                         timeZone: TimeZone = .current, locale: Locale = .current) -> AccountMeterModel? {
        var best: AccountMeterModel?
        for pool in ledger.allPools where pool.kind == .hosted && pool.accounts.contains(id) {
            guard let h = ledger.headroom(pool: pool.id).first(where: { $0.account.id == id }),
                  h.state == .overSoft || h.state == .overHard else { continue }
            let m = account(h, pool: pool, reading: ledger.latestReading(account: id), error: ledger.sourceError(account: id),
                            now: now, rejection: ledger.rejection(account: id),
                            timeZone: timeZone, locale: locale)
            if best.map({ severity(m) > severity($0) }) ?? true { best = m }
        }
        return best
    }

    private static func severity(_ m: AccountMeterModel) -> Double { (m.state == .overHard ? 2 : 1) + (m.fraction ?? 0) }
}

/// The bar itself: fill by state, ticks at soft and hard.
struct MeterTrack: View {
    let fraction: Double?
    let soft: Double
    let hard: Double
    let state: HeadroomState

    static func color(for state: HeadroomState) -> Color {
        switch state {
        case .underSoft: return .green
        case .overSoft: return .orange
        case .overHard: return .red
        case .unknown: return .gray
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                if let fraction {
                    Capsule().fill(Self.color(for: state)).frame(width: max(2, width * min(max(fraction, 0), 1)))
                }
                tick(at: soft, width: width)
                tick(at: hard, width: width)
            }
        }
    }

    private func tick(at t: Double, width: CGFloat) -> some View {
        Rectangle().fill(Color.primary.opacity(0.55)).frame(width: 1).offset(x: width * min(max(t, 0), 1) - 0.5)
    }
}

/// One account in the project header's pool popover and in Settings → Capacity.
struct AccountMeterBar: View {
    let model: AccountMeterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.label).font(.callout).lineLimit(1)
                Spacer(minLength: 8)
                Text(model.percentText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            MeterTrack(fraction: model.fraction, soft: model.soft, hard: model.hard, state: model.state).frame(height: 6)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        // An AXGroup carries no AXValue on macOS (the first UI run read "" off every bar), and a
        // Text reports its string as `value` with an empty `label` (a label set on it was not
        // matchable either). So the name and the reading travel together in the one string a
        // Text exposes, which XCUITest reads as `value` and VoiceOver speaks. Visuals unchanged.
        .accessibilityRepresentation {
            Text(model.spokenText).accessibilityIdentifier("meter-bar")
        }
    }

    private var caption: String { [model.resetText, model.sourceText, model.detail].compactMap { $0 }.joined(separator: " · ") }
}

/// The project header's pool popover body (L3-S mounts it in the popover at integration).
struct PoolMeterList: View {
    let pools: [PoolMeterModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if pools.isEmpty {
                Text("No pools yet. Add an account in Settings → Accounts.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(pools) { pool in
                VStack(alignment: .leading, spacing: 8) {
                    Text(pool.title).font(.headline)
                    ForEach(pool.accounts) { AccountMeterBar(model: $0) }
                    if let note = pool.note {
                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pool-meter-\(pool.id.rawValue)")
            }
        }
    }
}

/// The sidebar row's small meter. Draws nothing for nil — an account under soft, or unknown,
/// is not the row's business.
struct RowMiniMeter: View {
    let model: AccountMeterModel?

    var body: some View {
        if let model {
            MeterTrack(fraction: model.fraction, soft: model.soft, hard: model.hard, state: model.state)
                .frame(width: 28, height: 4)
                .help("\(model.label): \(model.accessibilityValue)")
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("row-mini-meter")
                .accessibilityLabel("\(model.label) usage")
                .accessibilityValue(model.accessibilityValue)
        }
    }
}

#if DEBUG
enum MeterPreviewData {
    static let pools: [PoolMeterModel] = [
        PoolMeterModel(id: "claude-default", title: "Claude default", isLocal: false, accounts: [
            AccountMeterModel(id: "a", label: "Work", fraction: 0.82, state: .overSoft, soft: 0.8, hard: 0.95,
                              resetText: "resets 11:00 PM", sourceText: "claude status line · 3 min ago", detail: nil),
            AccountMeterModel(id: "b", label: "Spare", fraction: nil, state: .unknown, soft: 0.8, hard: 0.95,
                              resetText: nil, sourceText: nil, detail: "no reading"),
        ], note: nil),
        PoolMeterModel(id: "codex-default", title: "Codex default", isLocal: false, accounts: [
            AccountMeterModel(id: "c", label: "Codex", fraction: 0.97, state: .overHard, soft: 0.8, hard: 0.95,
                              resetText: "resets 10:00 PM", sourceText: "codex app-server · 1 min ago", detail: nil),
        ], note: nil),
    ]
}

#Preview("Pool meters") { PoolMeterList(pools: MeterPreviewData.pools).padding().frame(width: 320) }
#Preview("Row meter") { RowMiniMeter(model: MeterPreviewData.pools[1].accounts[0]).padding() }
#endif
