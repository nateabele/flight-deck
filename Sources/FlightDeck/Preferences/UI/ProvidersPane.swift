import SwiftUI

/// Settings → Flight Control → Providers: the visual providers Flight Control can draw with.
/// Rows follow `CapabilityIndexPane.sourcesSection`: a toggle, the name and a source caption,
/// with an orange line when the provider cannot run yet.
struct ProvidersPane: View {
    @StateObject private var model: ProvidersSettingsModel

    init(model: @autoclosure @escaping () -> ProvidersSettingsModel) {
        _model = StateObject(wrappedValue: model())
    }

    /// The registry the app uses: the person's folder in Application Support, and the providers
    /// shipped inside the app.
    static func defaultRegistry() -> ProviderRegistry {
        let support = ProviderTrustStore.defaultDirectory
        return ProviderRegistry(
            userRoot: support.appendingPathComponent("visual-providers", isDirectory: true),
            bundledRoot: Bundle.main.resourceURL?.appendingPathComponent("VisualProviders", isDirectory: true),
            trustStore: ProviderTrustStore())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Providers").font(.headline)
                    Text("A provider draws a kind of picture for Flight Control. \(model.repoCaption)")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("providers-repo-caption")
                }
                if let problem = model.trustProblem { trustProblem(problem) }
                if let error = model.approvalError {
                    Text(error).font(.caption).foregroundStyle(providerWarningColor)
                        .accessibilityIdentifier("providers-approval-error")
                }
                if model.rows.isEmpty {
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                            .accessibilityIdentifier("providers-loading")
                    } else {
                        Text("No providers found.").foregroundStyle(.secondary)
                            .accessibilityIdentifier("providers-empty")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.rows) { row in ProviderRow(row: row, model: model) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("providers-pane")
    }

    private func trustProblem(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Approvals cannot be read", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(providerWarningColor)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Button("Move damaged file aside") { model.moveTrustFileAside() }
                .accessibilityIdentifier("providers-trust-move-aside")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providers-trust-problem")
    }
}

/// System orange fails contrast as small text on a light window, so light mode gets a darker one.
let providerWarningColor = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? .systemOrange : NSColor(red: 0.72, green: 0.33, blue: 0, alpha: 1)
})

struct ProviderRow: View {
    let row: ProviderRowModel
    @ObservedObject var model: ProvidersSettingsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { row.isEnabled }, set: { model.setEnabled(row.id, $0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                    Text(row.sourceCaption)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let line = statusLine {
                        Text(line.text).font(.caption).foregroundStyle(line.color)
                            .accessibilityIdentifier("provider-status-\(row.id)")
                    }
                }
            }
            .disabled(!row.canToggle)
            Spacer()
            if row.canApprove {
                Button("Approve") { model.approve(row.id) }
                    .accessibilityLabel("Approve \(row.name)")
                    .accessibilityIdentifier("provider-approve-\(row.id)")
            }
        }
        .accessibilityIdentifier("provider-row-\(row.id)")
    }

    private var statusLine: (text: String, color: Color)? {
        switch row.status {
        case .none: nil
        case .approved: ("Approved to run on this Mac", .secondary)
        case .needsApproval(let command): ("Needs approval: it runs \(command) on this Mac", providerWarningColor)
        case .needsNewerFlightDeck: ("Needs a newer Flight Deck", providerWarningColor)
        case .broken(let reason): ("Cannot be used: \(reason)", .red)
        case .off: ("Off", .secondary)
        }
    }
}
