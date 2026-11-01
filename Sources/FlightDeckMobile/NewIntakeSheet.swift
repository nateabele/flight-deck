import FleetKit
import SwiftUI

/// The New Intake sheet (spec §4.10): a Project row, one large field, and Triage in the bar.
/// Leaving keeps the draft (`NewIntakeModel` saves it as it is typed), so Cancel loses nothing.
struct NewIntakeSheet: View {
    @Bindable var model: NewIntakeModel
    /// The projects that can start an intake, in the list's order.
    let projects: [WireProject]
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Project", selection: projectBinding) {
                        ForEach(projects) { Text($0.name).tag($0.id) }
                    }
                }
                Section {
                    TextEditor(text: $model.text)
                        .focused($focused)
                        .frame(minHeight: 220)
                        .overlay(alignment: .topLeading) {
                            if model.text.isEmpty {
                                Text("Describe the outcome…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let refusal = model.refusal {
                            Text(refusal).font(.footnote).foregroundStyle(.orange)
                        }
                        Text("Triage runs on the Mac, reads the repo and asks what it needs to know. Your draft is kept if you leave.")
                    }
                }
            }
            .navigationTitle("New Intake")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { model.triage() } label: { Text("Triage").bold() }
                        .disabled(!model.canTriage)
                }
            }
            .onAppear { focused = true }
        }
    }

    private var projectBinding: Binding<UUID> {
        Binding(get: { model.project ?? projects.first?.id ?? UUID() }, set: { model.select($0) })
    }
}
