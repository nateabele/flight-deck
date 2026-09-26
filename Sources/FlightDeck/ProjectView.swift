import SwiftUI

/// The per-project detail view a project row opens. This plan gives it the Intakes list;
/// the Beads tab arrives with the next plan.
struct ProjectView: View {
    @ObservedObject var store: SessionStore
    let repo: Repo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(repo.displayName).font(.title3.weight(.semibold))
            Text("Intakes").font(.headline).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("project-view")
    }
}
