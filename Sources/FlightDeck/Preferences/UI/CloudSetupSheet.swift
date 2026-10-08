import SwiftUI

/// Settings → Cloud → Set Up… (spec §9): `CloudSetupModel`'s checklist, one row per step with
/// its state, what the check found, its automation and Skip. Shaped like `AddHostSheet`: a
/// title, the body, and the buttons along the bottom.
struct CloudSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: CloudSetupModel

    @State private var token = ""
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up cloud machines")
                .font(.title2.bold())
            Text("Each check turns green as it passes. Skip anything you don't use: Tailscale (machines then use public mode), either cloud, or the test.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.steps, id: \.id) { step in
                        row(step)
                        if step.id != CloudSetupModel.StepID.allCases.last { Divider() }
                    }
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("cloud-setup-steps")

            HStack {
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check Again") { recheck() }
                    .disabled(checking)
                    .accessibilityIdentifier("cloud-setup-refresh")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("cloud-setup-done")
            }
        }
        .padding(24)
        .frame(width: 560, height: 640)
        .task { recheck() }
    }

    private func recheck() {
        checking = true
        Task {
            await model.refresh()
            checking = false
        }
    }

    // MARK: - One step

    @ViewBuilder
    private func row(_ step: CloudSetupModel.Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon(step)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(CloudSetupModel.title(step.id))
                        .foregroundStyle(step.skipped ? .secondary : .primary)
                    Spacer()
                    if !step.skipped, let action = step.action {
                        Button(action) { Task { await model.perform(step.id) } }
                            .controlSize(.small)
                            .disabled(step.state == .running)
                            .accessibilityIdentifier("cloud-step-action-\(step.id.rawValue)")
                    }
                    Button(step.skipped ? "Undo Skip" : "Skip") {
                        step.skipped ? model.unskip(step.id) : model.skip(step.id)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .disabled(step.state == .running)
                    .accessibilityIdentifier("cloud-step-skip-\(step.id.rawValue)")
                }
                if step.skipped {
                    Text("Skipped.").font(.caption).foregroundStyle(.secondary)
                } else {
                    if !step.detail.isEmpty {
                        Text(step.detail)
                            .font(.caption)
                            .foregroundStyle(step.state == .failed ? .red : .secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    extras(step)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cloud-step-\(step.id.rawValue)")
    }

    @ViewBuilder
    private func icon(_ step: CloudSetupModel.Step) -> some View {
        if step.skipped {
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        } else {
            switch step.state {
            case .running: ProgressView().controlSize(.mini)
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .pending: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
        }
    }

    /// The policy step's token field and diff, and the OAuth step's clipboard capture.
    @ViewBuilder
    private func extras(_ step: CloudSetupModel.Step) -> some View {
        switch step.id {
        case .policy where step.state != .ok:
            HStack {
                SecureField("API access token", text: $token, prompt: Text("tskey-api-…"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("cloud-policy-token")
                Button("Check Policy") { Task { _ = await model.applyPolicy(token: token) } }
                    .controlSize(.small)
                    .disabled(token.isEmpty || step.state == .running)
                    .accessibilityIdentifier("cloud-policy-check")
            }
            if let patch = model.pendingPatch {
                ScrollView([.vertical, .horizontal]) {
                    Text(patch.diff)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 140)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("cloud-policy-diff")
                HStack {
                    Spacer()
                    Button("Apply") { Task { try? await model.confirmPolicy(patch, token: token) } }
                        .controlSize(.small)
                        .accessibilityIdentifier("cloud-policy-apply")
                }
            }
        case .oauth where step.state != .ok:
            // The step's detail says what was wrong with the clipboard.
            Button("Paste from Clipboard") { _ = try? model.captureOAuthClientFromClipboard() }
                .controlSize(.small)
                .accessibilityIdentifier("cloud-oauth-paste")
        default:
            EmptyView()
        }
    }
}
