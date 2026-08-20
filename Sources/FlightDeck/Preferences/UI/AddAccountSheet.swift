import SwiftUI

/// What the "+" sheet is filling in: a name and the home it will create. `home` starts as
/// `defaultHome(for:name:)`'s derivation and is user-editable via the sheet's "Choose…" escape
/// (spec §8.2), so the two fields are tracked separately — typing a new name after picking a
/// custom location must not silently snap the location back onto the derived slug.
struct AccountDraft: Equatable {
    var name: String
    var home: URL

    /// What `AccountDraft.validate` answers. Not a `Bool`: the sheet's confirm button and its
    /// inline error text both read the *reason*, not just whether the draft is good.
    enum Validation: Equatable {
        case ok
        case homeAlreadyUsed
    }

    init(agent: AgentID) {
        name = ""
        home = Self.defaultHome(for: agent, name: "")
    }

    /// `~/.claude-field-wealth` for "Field Wealth". Lowercased, non-alphanumerics collapsed to
    /// single dashes, so a typed display name yields a path that is legal and predictable.
    static func defaultHome(for agent: AgentID, name: String) -> URL {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
        let base = agent.builtInHome.lastPathComponent
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(slug.isEmpty ? base : "\(base)-\(slug)", isDirectory: true)
    }

    /// Two accounts on one home would put two `CodexStack`s on one `session_index.jsonl`, so
    /// the Add sheet's confirm button and Relocate… both gate on this before anything is
    /// created or moved, rather than failing later at launch. `editing` is the account already
    /// occupying `home`, if any — nil for the Add sheet, the account's own id for Relocate, so
    /// relocating a home back onto itself is not mistaken for a collision.
    @MainActor
    static func validate(home: URL, editing id: UUID?, in store: PreferencesStore) -> Validation {
        store.homeIsTaken(home, excluding: id) ? .homeAlreadyUsed : .ok
    }
}

/// The "+" sheet under an agent's Accounts list: name a login, confirm or override where its
/// home lives, and file it. Creating the directory here (rather than leaving it to the first
/// launch) is what lets the row appear with a real, `Reveal in Finder`-able home immediately.
struct AddAccountSheet: View {
    @ObservedObject var preferences: PreferencesStore
    let agent: AgentID
    /// Fires after the account is created and inserted, so the caller can offer "Sign In Now"
    /// — the sheet itself has no opinion about what happens next.
    let onAdd: (AgentAccount) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AccountDraft
    /// Once the user has picked or typed a location by hand, further name edits stop
    /// re-deriving it — the same "don't clobber a deliberate choice" rule `newDir` fields
    /// elsewhere in this file follow.
    @State private var homeEditedByHand = false

    init(preferences: PreferencesStore, agent: AgentID, onAdd: @escaping (AgentAccount) -> Void) {
        self.preferences = preferences
        self.agent = agent
        self.onAdd = onAdd
        _draft = State(initialValue: AccountDraft(agent: agent))
    }

    private var validation: AccountDraft.Validation {
        AccountDraft.validate(home: draft.home, editing: nil, in: preferences)
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add \(agent.displayName) Account")
                .font(.headline)

            Form {
                TextField(
                    "Name",
                    text: Binding(
                        get: { draft.name },
                        set: { newValue in
                            draft.name = newValue
                            if !homeEditedByHand {
                                draft.home = AccountDraft.defaultHome(for: agent, name: newValue)
                            }
                        }
                    )
                )
                .accessibilityIdentifier("account-add-name")

                LabeledContent("Location") {
                    HStack(spacing: 6) {
                        TextField(
                            "",
                            text: Binding(
                                get: { draft.home.path },
                                set: {
                                    draft.home = URL(fileURLWithPath: $0, isDirectory: true)
                                    homeEditedByHand = true
                                }
                            )
                        )
                        .accessibilityIdentifier("account-add-location")

                        Button("Choose…") {
                            guard let chosen = FolderPicker.choose() else { return }
                            draft.home = chosen
                            homeEditedByHand = true
                        }
                    }
                }

                if validation == .homeAlreadyUsed {
                    Text("Another account already uses this location.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || validation != .ok)
                    .accessibilityIdentifier("account-add-confirm")
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func add() {
        // Best-effort: an account whose directory could not be created yet is still a valid
        // registry entry — the agent creates it itself on first launch, same as the built-in
        // home always has.
        try? FileManager.default.createDirectory(at: draft.home, withIntermediateDirectories: true)
        let account = AgentAccount(agent: agent, displayName: trimmedName, home: draft.home)
        preferences.addAccount(account)
        dismiss()
        onAdd(account)
    }
}
