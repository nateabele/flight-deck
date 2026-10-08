import HostKit
import SwiftUI

/// What the Cloud tab needs beyond preferences: the app's one `InfraService`, its tailnet, and
/// a way to build a fresh setup model each time the sheet opens.
@MainActor
struct CloudSettingsContext {
    let service: InfraService
    let tailnet: TailnetIntegration
    let makeSetup: @MainActor () -> CloudSetupModel
}

/// Settings → Cloud (spec §3.2, §8): the account each cloud uses, the network mode, the budget
/// and guardrails, the machines running now, and Set Up…. Shaped like `HostsSettingsTab`: a
/// grouped `Form`, captions under each section.
struct CloudSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    let context: CloudSettingsContext

    @State private var awsProfiles: [String] = []
    @State private var tailnetLine = "Checking Tailscale…"
    @State private var setup: CloudSetupModel?
    @State private var pendingDown: InfraMachine?
    @State private var downError: String?

    var body: some View {
        Form {
            accounts
            tailscale
            budget
            machines
        }
        .formStyle(.grouped)
        .task {
            awsProfiles = Self.readAWSProfiles()
            tailnetLine = Self.describe(await context.tailnet.mode())
        }
        .sheet(item: Binding(get: { setup.map(SetupBox.init) }, set: { setup = $0?.model })) { box in
            CloudSetupSheet(model: box.model)
        }
        .confirmationDialog("Destroy “\(pendingDown?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDown != nil }, set: { if !$0 { pendingDown = nil } }),
                            presenting: pendingDown) { machine in
            Button("Destroy", role: .destructive) { down(machine) }
            Button("Cancel", role: .cancel) { pendingDown = nil }
        } message: { machine in
            Text("The cloud machine and everything on it is deleted. Runs on \(machine.name) stop.")
        }
    }

    // MARK: - Accounts

    private var accounts: some View {
        Section("Accounts") {
            Picker("AWS profile", selection: cloudBinding(\.awsProfile)) {
                Text("Default credentials").tag(String?.none)
                ForEach(awsProfiles, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .accessibilityIdentifier("cloud-aws-profile")
            TextField("AWS region", text: cloudBinding(\.awsRegion))
                .accessibilityIdentifier("cloud-aws-region")
            TextField("GCP project", text: Binding(
                get: { preferences.cloud.gcpProject ?? "" },
                set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    preferences.updateCloud { $0.gcpProject = trimmed.isEmpty ? nil : trimmed }
                }), prompt: Text("gcloud's default project"))
                .accessibilityIdentifier("cloud-gcp-project")
            TextField("GCP region", text: cloudBinding(\.gcpRegion))
                .accessibilityIdentifier("cloud-gcp-region")
            HStack {
                Text("Profiles come from ~/.aws/config. The region is where Set Up… checks quota and runs its test machine; a repo's delegate.toml names its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Set Up…") { setup = context.makeSetup() }
                    .accessibilityIdentifier("cloud-setup-button")
            }
        }
    }

    // MARK: - Tailscale

    private var tailscale: some View {
        Section("Tailscale") {
            Text(tailnetLine)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cloud-tailnet-mode")
        }
    }

    // MARK: - Budget

    private var budget: some View {
        Section("Budget") {
            TextField("Monthly cap (USD)", value: budgetBinding(\.monthlyCapUSD), format: .number, prompt: Text("None"))
                .accessibilityIdentifier("cloud-budget-monthly")
            TextField("Per-machine cap (USD)", value: budgetBinding(\.perMachineCapUSD), format: .number, prompt: Text("None"))
                .accessibilityIdentifier("cloud-budget-per-machine")
            Stepper("Warn at \(Int((preferences.cloud.budget.warnFraction * 100).rounded()))% of a cap",
                    value: budgetBinding(\.warnFraction), in: 0.5...0.95, step: 0.05)
                .accessibilityIdentifier("cloud-budget-warn")
            Stepper("At most \(preferences.cloud.budget.maxConcurrent) machines at once",
                    value: budgetBinding(\.maxConcurrent), in: 1...20)
                .accessibilityIdentifier("cloud-budget-concurrent")
            Stepper("Longest TTL \(preferences.cloud.budget.maxTTL.formatted)", value: hoursBinding(\.maxTTL), in: 1...72)
                .accessibilityIdentifier("cloud-budget-max-ttl")
            Stepper("Longest idle \(preferences.cloud.budget.maxIdle.formatted)", value: hoursBinding(\.maxIdle), in: 1...24)
                .accessibilityIdentifier("cloud-budget-max-idle")
            ForEach(["aws", "gcp"], id: \.self) { cloud in
                TextField("Allowed \(cloud == "aws" ? "AWS" : "GCP") types", text: allowlistBinding(cloud), axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("cloud-budget-allow-\(cloud)")
            }
            Text("Every figure is an estimate: compute and the boot disk, not egress, taxes or discounts. Allowed types are glob patterns, comma-separated; a repo asking for anything else is refused.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Machines

    private var machines: some View {
        Section("Machines") {
            // The service is not observable; its list is in memory, so a short poll is cheap
            // and also keeps each line's running cost and TTL current.
            TimelineView(.periodic(from: .now, by: 5)) { timeline in
                let now = context.service.now
                let list = context.service.list(now: now)
                VStack(alignment: .leading, spacing: 8) {
                    if list.isEmpty {
                        Text("No cloud machines. `flightdeck infra up` starts one from a repo's delegate.toml.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("cloud-machines-empty")
                    }
                    ForEach(list) { machine in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(machine.name)
                                    Text(machine.state.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(machine.state == .failed ? .red : .secondary)
                                }
                                Text(context.service.costLine(for: machine, now: now))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let failure = machine.failure {
                                    Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2)
                                }
                            }
                            Spacer()
                            Button("Down") { pendingDown = machine }
                                .controlSize(.small)
                                .disabled(machine.state == .destroying)
                                .accessibilityIdentifier("cloud-machine-down-\(machine.name)")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("cloud-machine-\(machine.name)")
                    }
                    if let downError {
                        Text(downError).font(.caption).foregroundStyle(.red)
                    }
                }
                .id(timeline.date)
            }
            .accessibilityIdentifier("cloud-machines-list")
        }
    }

    private func down(_ machine: InfraMachine) {
        pendingDown = nil
        downError = nil
        Task {
            do { try await context.service.down(name: machine.name) { _ in } } catch {
                downError = "\(machine.name): \(CloudSetupModel.describe(error))"
            }
        }
    }

    // MARK: - Bindings

    private func cloudBinding<T>(_ key: WritableKeyPath<CloudPreferences, T>) -> Binding<T> {
        Binding(get: { preferences.cloud[keyPath: key] }, set: { value in preferences.updateCloud { $0[keyPath: key] = value } })
    }

    private func budgetBinding<T>(_ key: WritableKeyPath<BudgetSettings, T>) -> Binding<T> {
        cloudBinding((\CloudPreferences.budget).appending(path: key))
    }

    /// A whole-hour duration setting as a stepper's hours.
    private func hoursBinding(_ key: WritableKeyPath<BudgetSettings, HostKit.Duration>) -> Binding<Int> {
        Binding(get: { max(1, preferences.cloud.budget[keyPath: key].seconds / 3600) },
                set: { hours in preferences.updateCloud { $0.budget[keyPath: key] = HostKit.Duration(seconds: hours * 3600) } })
    }

    private func allowlistBinding(_ cloud: String) -> Binding<String> {
        Binding(get: { (preferences.cloud.budget.allowedTypes[cloud] ?? []).joined(separator: ", ") },
                set: { text in
                    let patterns = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    preferences.updateCloud { $0.budget.allowedTypes[cloud] = patterns }
                })
    }

    // MARK: - Pure

    static func describe(_ mode: TailnetMode) -> String {
        switch mode {
        case .available(let client): "Tailnet mode: machines join \(client.tailnet) and admit only your devices."
        case .notRunning: "Tailscale isn't running on this Mac, so machines use public mode: a public IP that admits only this Mac."
        case .notConfigured(let tailnet): "Tailscale is running on \(tailnet) but not set up for Flight Deck, so machines use public mode. Set Up… turns on tailnet mode."
        case .mismatch(let local, let client): "This Mac is on \(local) but the saved OAuth client is for \(client): cloud machines are refused until Set Up… replaces it."
        }
    }

    static func readAWSProfiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let config = home.appendingPathComponent(".aws/config")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return [] }
        return AWSAccount.profiles(configText: text)
    }
}

/// `sheet(item:)` wants an `Identifiable`; the model is a class, so its identity is its object.
private struct SetupBox: Identifiable {
    let model: CloudSetupModel
    var id: ObjectIdentifier { ObjectIdentifier(model) }
}
