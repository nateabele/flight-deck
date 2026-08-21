import SwiftUI

/// What the "+" sheet is filling in: a name and the home it will create. `homePath` starts as
/// `defaultHome(for:name:)`'s derivation and is user-editable via the sheet's "Choose…" escape
/// (spec §8.2), so the two fields are tracked separately — typing a new name after picking a
/// custom location must not silently snap the location back onto the derived slug.
struct AccountDraft: Equatable {
    var name: String
    /// The Location field's *text*, not a URL, and that is load-bearing: `URL(fileURLWithPath: "")`
    /// silently resolves to the process working directory, so a cleared field would reach
    /// `validate` looking exactly like a deliberate choice of that directory — which "Also
    /// Delete Files…" would later offer to move to the Trash. Keeping the raw text is what
    /// lets an empty Location be refused *as* empty.
    var homePath: String

    /// The same value as the rest of the app names a home. Settable so `Choose…` and Relocate…
    /// can keep handing over a URL; `validate` and `add()` go through `trimmedHome`, never this.
    var home: URL {
        get { URL(fileURLWithPath: homePath, isDirectory: true) }
        set { homePath = newValue.path }
    }

    /// What Add actually files: the typed path with its stray whitespace removed, so the
    /// directory created is the one `validate` inspected and not `"~/.claude-work "`.
    var trimmedHome: URL {
        URL(fileURLWithPath: homePath.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
    }

    /// What `AccountDraft.validate` answers. Not a `Bool`: the sheet's confirm button and its
    /// inline error text both read the *reason*, not just whether the draft is good.
    enum Validation: Equatable {
        case ok
        case locationEmpty
        case homeAlreadyUsed
        case notAnAgentHome

        /// The inline caption under the Location field. nil for `.ok` — there is nothing to
        /// say about a good draft. Lives on the reason rather than in the view so the wording
        /// is testable, the same way every other rule in this pane is.
        func message(for agent: AgentID) -> String? {
            switch self {
            case .ok:
                return nil
            case .locationEmpty:
                return "Enter a location for this account's files."
            case .homeAlreadyUsed:
                // Deliberately not "another account already uses this location": the occupant
                // may be an account the user removed a moment ago, and telling them something
                // they can no longer see is using it reads as a lie. A removed account holds
                // its location until the next launch because its tombstone still keys the
                // tabs running as it — see `PreferencesStore.homeIsTaken`.
                return """
                    This location is already in use by another account, or by one that was \
                    removed — a removed account keeps its location until Flight Deck next \
                    starts.
                    """
            case .notAnAgentHome:
                return """
                    That folder already holds files, and they are not a \(agent.displayName) \
                    login. Choose an empty or new folder, or one \(agent.displayName) is \
                    already signed in to.
                    """
            }
        }
    }

    init(agent: AgentID) {
        name = ""
        homePath = Self.defaultHome(for: agent, name: "").path
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

    /// The whole sanity rule the Add sheet's confirm button and Relocate… both gate on, before
    /// anything is created or moved rather than failing later at launch.
    ///
    /// Three refusals, in the order that names the most specific problem first:
    ///
    /// 1. An empty Location. Taken from the text, because the URL cannot say — see `homePath`.
    /// 2. A home another account already occupies, a removed one included. Two accounts on one
    ///    home would put two `CodexStack`s on one `session_index.jsonl` — and a tombstone is
    ///    still an occupant, because it keys the tabs still running as it (see
    ///    `PreferencesStore.homeIsTaken`). `editing` is the account already sitting there, if
    ///    any — nil for the Add sheet, the account's own id for Relocate, so relocating a home
    ///    back onto itself is not mistaken for a collision.
    /// 3. A path that is neither one of this agent's homes nor vacant. Nothing else checked
    ///    plausibility, so any typed path was accepted and filed — and "Also Delete Files…"
    ///    would later offer to move that tree to the Trash. Both halves of the rule are needed:
    ///    an existing login has files (so it is not vacant) and a brand-new home has no marker
    ///    yet (so it does not look like one).
    @MainActor
    static func validate(
        home path: String, agent: AgentID, editing id: UUID?, in store: PreferencesStore
    ) -> Validation {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .locationEmpty }
        let home = URL(fileURLWithPath: trimmed, isDirectory: true)
        guard !store.homeIsTaken(home, excluding: id) else { return .homeAlreadyUsed }
        guard AccountDirectory.looksLikeHome(home, agent: agent) || AccountDirectory.isVacant(home)
        else { return .notAnAgentHome }
        return .ok
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
        AccountDraft.validate(home: draft.homePath, agent: agent, editing: nil, in: preferences)
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
                                get: { draft.homePath },
                                set: {
                                    draft.homePath = $0
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

                if let message = validation.message(for: agent) {
                    Text(message)
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
        // Re-checked here, not only in `.disabled` above: this is the call that creates a
        // directory and files an account whose home "Also Delete Files…" will later offer to
        // trash, and a guard that lives only in a view modifier is one refactor from gone.
        guard !trimmedName.isEmpty, validation == .ok else { return }
        let home = draft.trimmedHome
        // Best-effort: an account whose directory could not be created yet is still a valid
        // registry entry — the agent creates it itself on first launch, same as the built-in
        // home always has.
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let account = AgentAccount(agent: agent, displayName: trimmedName, home: home)
        preferences.addAccount(account)
        dismiss()
        onAdd(account)
    }
}
