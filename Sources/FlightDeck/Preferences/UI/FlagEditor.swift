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
    /// Non-nil while the confirmation alert for a `requiresConfirmation` flag is up. Set by
    /// `binding(for:).set` when it intercepts an enabling write instead of applying it.
    @State private var pendingDangerousFlag: FlagSpec?

    /// Flags that silently widen what every future session may do without asking — gated by
    /// an extra confirmation in `binding(for:)` on top of `FlagDiagnostics.validate`'s
    /// persistent inline warning for the same flag. Deliberately does NOT gate the command
    /// field's text → controls path (`applyTextToControls`): that field is the explicit,
    /// expert entry point, and it round-trips whatever the controls hold, so intercepting a
    /// typed `--dangerously-skip-permissions` there would break the invariant that committing
    /// the field always reflects the model faithfully. Only a control-driven enable prompts.
    private static let requiresConfirmation: Set<String> = ["--dangerously-skip-permissions"]

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
                                    // A control action makes any earlier parse note stale —
                                    // unlike `.onChange(of: flags)`, which also lands here
                                    // indirectly but must NOT clear a commit's own warnings
                                    // (see `applyTextToControls`), this is a genuine control
                                    // edit and owns the right to clear them.
                                    parseDiagnostics = []
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
        .alert(
            "Skip all permission checks?",
            isPresented: Binding(
                get: { pendingDangerousFlag != nil },
                set: { if !$0 { pendingDangerousFlag = nil } }
            ),
            presenting: pendingDangerousFlag
        ) { spec in
            Button("Cancel", role: .cancel) { pendingDangerousFlag = nil }
            Button("Enable", role: .destructive) {
                // Same set/sync/clear sequence as a normal `binding(for:).set` — routed
                // through `apply(_:for:)` directly rather than back through `binding(for:)`
                // itself, which would re-enter the gate above and re-present this alert.
                apply(.on, for: spec)
                pendingDangerousFlag = nil
            }
        } message: { _ in
            Text("Every new session will bypass all permission checks and act without asking. Recommended only for sandboxes with no internet access.")
        }
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
                // Gate BEFORE any mutation: turning a `requiresConfirmation` flag on parks
                // the pending spec and returns without touching `flags`, so the model is
                // untouched until the alert's own Enable button applies it. Turning the flag
                // back off (`newValue == nil`) is never gated — only the enabling direction
                // silently widens what future sessions may do.
                if newValue != nil, Self.requiresConfirmation.contains(spec.canonical) {
                    pendingDangerousFlag = spec
                    return
                }
                apply(newValue, for: spec)
            }
        )
    }

    /// The set/sync/clear sequence `binding(for:).set` performs once past the confirmation
    /// gate above. Factored out so the alert's Enable button can apply the exact same
    /// mutation without calling back into `binding(for:)` itself, which would re-enter (and
    /// re-trigger) the gate.
    private func apply(_ newValue: FlagValue?, for spec: FlagSpec) {
        if let newValue {
            flags.values[spec.canonical] = newValue
        } else {
            flags.values.removeValue(forKey: spec.canonical)
        }
        syncTextFromControls()
        // Same reasoning as `onRevert`: a control edit genuinely makes any earlier
        // parse note stale, so this call site owns the clear explicitly rather than
        // relying on `syncTextFromControls` to do it as a side effect (that side
        // effect would also fire from `.onChange(of: flags)` and wipe a commit's own
        // warnings — see `applyTextToControls`).
        parseDiagnostics = []
    }

    /// controls → text, immediate. Serializes `effective`, not `flags` alone: in the Claude
    /// tab `inherited` is nil so the two are identical, but in the Projects tab this is what
    /// makes the field show the merged command that will actually launch (design spec §6)
    /// rather than just the override's own fragment.
    ///
    /// Deliberately free of `parseDiagnostics` side effects. `.onChange(of: flags)` /
    /// `.onChange(of: inherited)` also call this — and `applyTextToControls` assigns
    /// `flags` synchronously from the same AppKit callback that also sets `parseDiagnostics`,
    /// so if this cleared diagnostics as a side effect, the `onChange` triggered by that same
    /// `flags` write would run afterward and wipe the warnings a successful commit just
    /// produced (unknown flag, app-managed flag, duplicate, the Important-2 removal notes).
    /// Each control-driven call site (`binding(for:).set`, `onRevert`) clears
    /// `parseDiagnostics` explicitly right after calling this, since a control edit *does*
    /// make an old parse note stale — that's still Important 1's fix, just no longer bundled
    /// in here where it can't tell a control edit from a commit's own `flags` write apart.
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
    private func applyTextToControls(_ text: String) {
        let result = ClaudeFlagParser.parse(text)
        guard !result.diagnostics.contains(where: { $0.severity == .error }) else {
            parseDiagnostics = result.diagnostics
            return
        }

        // The user blurred (or hit ⌘↩) without changing anything — `textDidEndEditing`
        // fires unconditionally on any resign-first-responder, including clicking a
        // control, not only on an actual text edit. Without this guard that keystroke-free
        // commit would still re-diff below and can only lose information: a project
        // override whose value happens to equal the global's (the user deliberately picked
        // "opus" in a picker when the global is already "opus") would silently drop back to
        // inheriting the instant the field loses focus, even though the field's text never
        // changed and the row was showing as overridden a moment ago. A genuine edit that
        // happens to land back on the global's value (see below) is still a real edit and
        // must still act — this only short-circuits a no-op commit.
        guard text != ClaudeFlagSerializer.serialize(effective) else {
            // Nothing to apply to the model, but the text did parse successfully — adopt
            // its diagnostics as current. Without this a stale error from an earlier
            // attempt (fixed since, e.g. by ⌘Z back to the last-good canonical text) would
            // stand forever: every later blur re-hits this same no-op guard and returns
            // before ever reaching the assignment below.
            parseDiagnostics = result.diagnostics
            return
        }

        guard let inherited else {
            flags = result.flags
            syncTextFromControls()
            parseDiagnostics = result.diagnostics
            return
        }

        var overrides = FlagSet()
        for (key, value) in result.flags.values where inherited.values[key] != value {
            overrides.values[key] = value
        }
        overrides.passthrough = projectPassthrough(from: result.flags.passthrough, inherited: inherited.passthrough)

        // A key present in `inherited` but missing from the parsed result means the user
        // deleted that flag from the merged text outright rather than editing its value.
        // `FlagSet` cannot represent "override to absent" — only "override to a different
        // value" — so `syncTextFromControls()` below will re-serialize the token right back
        // into the field. Surface that as a warning instead of letting the edit silently
        // undo itself with no explanation. (A `.string`/`.path`/`.list` flag overridden to
        // *empty*, e.g. `--model ''` or a bare `--add-dir`, is unaffected: that is a real,
        // present `FlagValue`, not an absence, and round-trips normally.)
        let removalWarnings = inherited.values.keys
            .filter { result.flags.values[$0] == nil }
            .sorted()
            .map {
                Diagnostic.warning(
                    "\($0) is inherited from the global defaults and can't be removed here — "
                    + "change it in the Claude tab, or override it to a different value."
                )
            }

        flags = overrides
        syncTextFromControls()
        parseDiagnostics = result.diagnostics + removalWarnings
    }

    /// Recovers the project's own passthrough tokens from the merged passthrough shown in
    /// the field, as a multiset difference: each token in `merged` that can still be matched
    /// against an unconsumed copy in `inherited` is attributed to the global and dropped;
    /// everything left over is the project's own. This handles the common edit shape
    /// correctly — the serializer emits passthrough *first*, so "type a new unknown flag at
    /// the start of the field" is the natural way to add one, and a plain prefix-strip would
    /// see the inserted token break the prefix match and misattribute the whole run,
    /// duplicating the inherited tokens into the override every time. A multiset diff
    /// tolerates insertion, deletion, and reordering of individual tokens without ever
    /// duplicating one.
    private func projectPassthrough(from merged: [String], inherited: [String]) -> [String] {
        var remaining = inherited
        var project: [String] = []
        for token in merged {
            if let index = remaining.firstIndex(of: token) {
                remaining.remove(at: index)
            } else {
                project.append(token)
            }
        }
        return project
    }
}
