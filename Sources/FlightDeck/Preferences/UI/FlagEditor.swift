import SwiftUI

/// The controls, the command field, and the diagnostics beneath it — the whole two-way
/// sync in one place, used by both the Claude tab (global) and the Projects tab (override).
///
/// Sync is asymmetric (design spec §3.3):
/// - controls → text is immediate: any control change re-serializes the tail.
/// - text → controls happens on blur or ⌘↩, so the field is never rewritten mid-typing.
///
/// In the Projects tab the field shows the **merged** command (design spec §6) — that is
/// what actually launches — while `flags` itself stays the project's override alone. See
/// `applyTextToControls` for how those two facts are reconciled on commit.
struct FlagEditor: View {
    @Binding var flags: FlagSet
    /// Non-nil in the Projects tab: the globals this override inherits from.
    var inherited: FlagSet?
    let lockedPrefix: String

    @State private var tail: String = ""
    @State private var parseDiagnostics: [Diagnostic] = []

    private var effective: FlagSet {
        guard let inherited else { return flags }
        return FlagSetMerge.merge(global: inherited, project: flags)
    }

    private var diagnostics: [Diagnostic] {
        parseDiagnostics + FlagDiagnostics.validate(effective)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                ForEach(FlagSpec.Section.allCases, id: \.self) { section in
                    Section(section.rawValue) {
                        // Keyed by `spec.canonical`, not index/offset: `FlagRow` holds
                        // row-local `@State` (its `.list` draft), and if SwiftUI reused a
                        // row across a different spec under a positional key, that draft
                        // would migrate and write one flag's text into another's model.
                        ForEach(specs(in: section), id: \.canonical) { spec in
                            FlagRow(
                                spec: spec,
                                value: binding(for: spec),
                                inherited: inherited?.values[spec.canonical],
                                onRevert: inherited == nil ? nil : {
                                    flags.values.removeValue(forKey: spec.canonical)
                                    syncTextFromControls()
                                }
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Launch command")
                    .font(.subheadline.weight(.medium))
                LockedPrefixCommandField(
                    lockedPrefix: lockedPrefix,
                    tail: $tail,
                    onCommit: applyTextToControls
                )
                .frame(height: 60)

                ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Label {
                        Text(diagnostic.message)
                    } icon: {
                        Image(systemName: diagnostic.severity == .error
                              ? "exclamationmark.octagon.fill"
                              : "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                }

                Text("Applies to new sessions. Running sessions keep the command line they started with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .onAppear { syncTextFromControls() }
        // `flags`/`inherited` can change out from under this view without going through
        // `binding(for:)` or `applyTextToControls` — e.g. a master/detail Projects list
        // that re-points the same `FlagEditor` at a different project's `FlagSet`, or a
        // global-defaults edit made on the Claude tab while a Projects tab's merged text is
        // showing. Either changes what `effective` resolves to, so the tail must re-sync;
        // without this the field would keep showing a stale, previously-selected project's
        // command. Harmless (idempotent) when the change instead originated from this
        // view's own setters, which already call `syncTextFromControls()` themselves.
        .onChange(of: flags) { _, _ in syncTextFromControls() }
        .onChange(of: inherited) { _, _ in syncTextFromControls() }
    }

    private func specs(in section: FlagSpec.Section) -> [FlagSpec] {
        ClaudeFlagCatalog.all.filter { $0.section == section }
    }

    /// Passes `FlagValue`s straight through — no normalizing, defaulting, or coercing.
    /// `FlagRow` alone owns the mapping from a spec's `Kind` to a well-formed `FlagValue`;
    /// this binding must not second-guess it.
    private func binding(for spec: FlagSpec) -> Binding<FlagValue?> {
        Binding(
            get: { flags.values[spec.canonical] },
            set: { newValue in
                if let newValue {
                    flags.values[spec.canonical] = newValue
                } else {
                    flags.values.removeValue(forKey: spec.canonical)
                }
                syncTextFromControls()
            }
        )
    }

    /// controls → text, immediate. Serializes `effective`, not `flags` alone: in the Claude
    /// tab `inherited` is nil so the two are identical, but in the Projects tab this is what
    /// makes the field show the merged command that will actually launch (design spec §6)
    /// rather than just the override's own fragment.
    private func syncTextFromControls() {
        tail = ClaudeFlagSerializer.serialize(effective)
    }

    /// text → controls, on blur or ⌘↩. A parse *error* (unterminated quote) keeps the last
    /// good `FlagSet` and leaves the controls alone rather than clobbering them from garbage.
    ///
    /// In the Claude (global) tab `inherited` is nil, `effective == flags`, and the parsed
    /// result assigns straight through.
    ///
    /// In the Projects tab the text the user is editing is the *merged* command, not the
    /// override alone (see `syncTextFromControls`). Assigning `result.flags` straight to
    /// `flags` — as if the field held only the override — would silently promote every
    /// inherited value into an explicit project override just from focusing and blurring the
    /// field, since the merged text always contains the full inherited set too. Instead the
    /// parsed result is diffed against `inherited`: a key whose parsed value matches the
    /// global value is left out of `flags` entirely (still inheriting); only a key that is
    /// new, or genuinely differs from the global, becomes a real override. This is the same
    /// "leave it inherited" outcome `FlagRow`'s own revert button produces, so a user who
    /// edits a value back to match the global one gets the same reverted state either way.
    ///
    /// One case this cannot recover: deleting an inherited flag from the merged text
    /// *without* replacing it is indistinguishable from never having mentioned it, because
    /// `FlagSet` has no way to represent "override to absent" — only "override to a
    /// different value." That token reappears (from `inherited`) the next time the tail is
    /// re-synced. That is not a bug introduced here; it is the same limitation the row
    /// controls already have (a plain `.toggle` row has no "explicitly off" state to revert
    /// to either — only unset/inherit, or on). A `.string`/`.path`/`.list` flag *can* be
    /// overridden to empty (`--model ''`, bare `--add-dir`), and that still round-trips,
    /// because an explicit empty value is a real, present `FlagValue` distinguishable from
    /// the key being absent — the token just needs to survive the edit, not vanish.
    private func applyTextToControls(_ text: String) {
        let result = ClaudeFlagParser.parse(text)
        parseDiagnostics = result.diagnostics
        guard !result.diagnostics.contains(where: { $0.severity == .error }) else { return }

        guard let inherited else {
            flags = result.flags
            syncTextFromControls()
            return
        }

        var overrides = FlagSet()
        for (key, value) in result.flags.values where inherited.values[key] != value {
            overrides.values[key] = value
        }
        overrides.passthrough = projectPassthrough(from: result.flags.passthrough, inherited: inherited.passthrough)
        flags = overrides
        syncTextFromControls()
    }

    /// Recovers the project's own passthrough tokens from the merged passthrough shown in
    /// the field. `FlagSetMerge` concatenates `inherited.passthrough + flags.passthrough`,
    /// and the serializer emits passthrough first, so on an unedited merge the inherited
    /// tokens are a literal leading prefix of what comes back from the parser — strip it. If
    /// the user edited that region (reordered it, inserted a token ahead of an inherited
    /// one, deleted an inherited token), no prefix match survives; treat the whole run as
    /// the project's own in that case. That can duplicate an inherited token into the
    /// override, but it never silently drops passthrough text the user just typed.
    private func projectPassthrough(from merged: [String], inherited: [String]) -> [String] {
        guard merged.count >= inherited.count, Array(merged.prefix(inherited.count)) == inherited else {
            return merged
        }
        return Array(merged.dropFirst(inherited.count))
    }
}
