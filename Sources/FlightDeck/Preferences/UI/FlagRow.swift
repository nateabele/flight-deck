import AppKit
import SwiftUI

/// One control, rendered from its `FlagSpec.Kind`. Six shapes cover all thirty-six
/// options, which is why the catalog is declarative — adding a flag is a table entry,
/// not a new view.
///
/// `value == nil` means the flag is unset. In the Projects tab that means "inherit", and
/// `inherited` supplies the de-emphasised value shown in its place.
struct FlagRow: View {
    let spec: FlagSpec
    @Binding var value: FlagValue?
    var inherited: FlagValue?
    var onRevert: (() -> Void)?

    /// Local draft for `.list` only — see `listDraft` below for why the model can't back
    /// the text field directly.
    @State private var listDraft: String = ""

    private var isOverridden: Bool { value != nil }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                control
                if isOverridden {
                    // Shown for every override, not only ones with something to diff
                    // against: in the Global tab `inherited` is always nil, but the flag
                    // can still be explicitly set (and, for `.string`/`.path`/`.list`,
                    // explicitly set-to-empty — see `isExplicitlyEmpty`) with no other way
                    // to clear it back to unset.
                    Button {
                        (onRevert ?? { value = nil })()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help(inherited != nil ? "Revert to the global default" : "Clear")
                }
            }
        } label: {
            Text(spec.label)
                .fontWeight(isOverridden && inherited != nil ? .semibold : .regular)
        }
        .help(spec.help)
    }

    @ViewBuilder
    private var control: some View {
        switch spec.kind {
        case .toggle:
            HStack(spacing: 6) {
                Toggle("", isOn: boolBinding).labelsHidden().accessibilityIdentifier(spec.label)
                // `.toggle`'s inherited value, when present, is always `.on` — the global
                // row for the same spec can only ever write `.on` or nil, never `.value`/
                // `.list` — but the `case .on` match keeps this an explicit check rather
                // than an assumption baked into the button state.
                if value == nil, let inherited, case .on = inherited {
                    Text("Inherited: on").font(.caption).foregroundStyle(.secondary)
                }
            }

        case .negatable:
            Picker("", selection: negatableBinding) {
                Text(defaultItemLabel("Default")).tag("")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
            .labelsHidden()
            .frame(width: 120)
            .accessibilityIdentifier(spec.label)

        case .choice(let options, let allowsCustom):
            HStack(spacing: 6) {
                Picker("", selection: choiceBinding(options, allowsCustom: allowsCustom)) {
                    Text(defaultItemLabel("Default")).tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                    if allowsCustom { Text("Custom…").tag(customTag) }
                    // `allowsCustom == false` specs (`--effort`, `--permission-mode`) have
                    // no "Custom…" entry, but a stored value outside `options` is still
                    // reachable — a typo hand-typed into the command field, or a value
                    // valid in a `claude` version ahead of this catalog snapshot. Without
                    // this row the Picker would resolve to no tag, render blank, and any
                    // touch would silently overwrite the value with whatever tag reads as
                    // selected. Surfacing it (still editable only by picking something
                    // else, not by typing) keeps it visible and prevents that clobber.
                    //
                    // `!raw.isEmpty` matters: `.value("")` (e.g. `--effort ''` typed into the
                    // command field) is not in `options` either, but `.tag("")` is already
                    // claimed by the Default item above. Without this guard the two items
                    // would collide on the same tag, leaving selection between them
                    // undefined. `.value("")` is functionally indistinguishable from unset
                    // for a picker anyway (nothing sensible to show as "the value"), so
                    // falling through to Default's tag/behavior for it is correct, not a gap.
                    if !allowsCustom, case .value(let raw)? = value, !raw.isEmpty, !options.contains(raw) {
                        Text("\(raw) — not a known value").tag(raw)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .accessibilityIdentifier(spec.label)

                if allowsCustom, isCustomValue(options) {
                    TextField("", text: stringBinding)
                        .frame(width: 160)
                        .accessibilityIdentifier("\(spec.label).text")
                }
            }

        case .optionalValue:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Toggle("", isOn: boolBinding).labelsHidden().accessibilityIdentifier(spec.label)
                    TextField(optionalPlaceholder, text: optionalValueBinding)
                        .frame(width: 200)
                        .disabled(value == nil)
                        .accessibilityIdentifier("\(spec.label).text")
                }
                if value == nil, inherited != nil {
                    Text(defaultItemLabel("")).font(.caption).foregroundStyle(.secondary)
                }
            }

        case .string:
            TextField(inheritedLabel(""), text: stringBinding)
                .frame(width: 240)
                .accessibilityIdentifier(spec.label)

        case .path:
            HStack(spacing: 6) {
                TextField(inheritedLabel(""), text: stringBinding)
                    .frame(width: 200)
                    .accessibilityIdentifier("\(spec.label).text")
                Button("Choose…") { chooseFile() }
                    .accessibilityIdentifier(spec.label)
            }

        case .multiline:
            VStack(alignment: .leading, spacing: 2) {
                TextEditor(text: stringBinding)
                    .font(.body.monospaced())
                    .frame(width: 320, height: 64)
                    .border(.separator)
                    .accessibilityIdentifier(spec.label)
                if value == nil, inherited != nil {
                    Text(defaultItemLabel("")).font(.caption).foregroundStyle(.secondary)
                }
            }

        case .list:
            TextField(listPlaceholder, text: $listDraft)
                .frame(width: 320)
                .accessibilityIdentifier(spec.label)
                .onAppear { listDraft = listTextFromModel }
                .onChange(of: listDraft) { _, newDraft in
                    let items = newDraft.split(whereSeparator: \.isWhitespace).map(String.init)
                    // Seeding and re-seeding both set `listDraft` programmatically, which
                    // re-enters this handler. Without this guard, appearing with (or being
                    // re-seeded to) a value this field cannot faithfully represent — an item
                    // containing whitespace, e.g. `.list(["/Users/nate/My Projects"])`, still
                    // fully valid and round-trippable through the model/serializer/parser —
                    // would get silently split into several bogus items purely from
                    // rendering the pane, with no user interaction at all. Editing such an
                    // item by hand still splits it on whitespace; that representational limit
                    // is real and stays, but merely displaying the row must not trigger it.
                    guard items.joined(separator: " ") != listTextFromModel else { return }
                    value = items.isEmpty ? (value == nil ? nil : .list([])) : .list(items)
                }
                .onChange(of: listTextFromModel) { _, fromModel in
                    // Re-seed only on a genuine external change (a revert, a switch to a
                    // different project's binding, …). Comparing against the draft's
                    // *parsed* form — not the raw draft — is what lets a trailing space
                    // survive: typing "Read " leaves the model at ["Read"], whose text form
                    // already equals the draft's parsed form, so we must not write back and
                    // eat the space the user just typed.
                    let draftParsed = listDraft.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if fromModel != draftParsed { listDraft = fromModel }
                }
        }
    }

    private var customTag: String { "\u{1}custom" }

    /// The "Default" Picker item's label, and the inherited-value caption on `.toggle`/
    /// `.multiline`/`.optionalValue`. Always describes what `inherited` actually is,
    /// regardless of whether this row is currently overridden — a user opening the menu (or
    /// reading the caption while unset) wants to know what selecting Default would produce,
    /// not a description of whatever is currently selected (the row's other controls already
    /// show that). Every call site that uses this already guards on `value == nil` itself
    /// where that distinction matters, so this function does not need to.
    private func defaultItemLabel(_ fallback: String) -> String {
        guard let inherited else { return fallback }
        switch inherited {
        case .on: return "Inherited: on"
        case .value(let raw): return "Inherited: \(raw)"
        case .list(let items): return "Inherited: \(items.joined(separator: " "))"
        }
    }

    /// A `TextField`/placeholder label for `.string`, `.path`, and `.list`. Unlike
    /// `defaultItemLabel`, this must NOT claim inheritance once the row is overridden — an
    /// overridden field showing "Inherited: X" as its (empty-field) placeholder would look
    /// exactly like an unset field inheriting that same value, which is the one thing this
    /// row exists to keep distinguishable. See `isExplicitlyEmpty`.
    private func inheritedLabel(_ fallback: String) -> String {
        guard value == nil else {
            // Overridden: never describe this row as inheriting. A present-but-empty
            // override (`.value("")` / `.list([])`) would otherwise render through an
            // empty `fallback` exactly like an unset field showing "Inherited: X" — the
            // one-way trap this exists to make visible instead of silently indistinguishable.
            return isExplicitlyEmpty ? "(explicitly empty)" : fallback
        }
        return defaultItemLabel(fallback)
    }

    /// True when `value` is present but renders as empty — `.value("")` or `.list([])`.
    /// Distinct from `value == nil` (unset/inheriting): this is an explicit override to
    /// nothing, reachable by clearing an already-set text/list field (see `stringBinding`
    /// and the `.list` `onChange` handler, both of which preserve rather than unset it).
    private var isExplicitlyEmpty: Bool {
        switch value {
        case .value(let raw)?: return raw.isEmpty
        case .list(let items)?: return items.isEmpty
        default: return false
        }
    }

    private func isCustomValue(_ options: [String]) -> Bool {
        if case .value(let raw)? = value { return !options.contains(raw) }
        return false
    }

    // MARK: Bindings

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { value = $0 ? .on : nil }
        )
    }

    private var negatableBinding: Binding<String> {
        Binding(
            get: { if case .value(let raw)? = value { return raw }; return "" },
            set: { value = $0.isEmpty ? nil : .value($0) }
        )
    }

    private func choiceBinding(_ options: [String], allowsCustom: Bool) -> Binding<String> {
        Binding(
            get: {
                guard case .value(let raw)? = value else { return "" }
                if options.contains(raw) { return raw }
                // Only render the "Custom…" tag when the Picker actually offers one.
                // Otherwise fall back to the raw value itself, which the `!allowsCustom`
                // branch above adds as its own tagged item — keeping an out-of-catalog
                // value visible (and its Picker selection resolvable) instead of blank.
                return allowsCustom ? customTag : raw
            },
            set: { selection in
                if selection.isEmpty {
                    value = nil
                } else if selection == customTag {
                    // Keep any existing custom text; otherwise start empty.
                    if case .value(let raw)? = value, !options.contains(raw) { return }
                    value = .value("")
                } else {
                    value = .value(selection)
                }
            }
        )
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: {
                if case .value(let raw)? = value { return raw }
                return ""
            },
            set: { value = $0.isEmpty ? (value == nil ? nil : .value("")) : .value($0) }
        )
    }

    /// The model's `.list` value rendered as text, for seeding and re-seeding `listDraft`.
    private var listTextFromModel: String {
        if case .list(let items)? = value { return items.joined(separator: " ") }
        return ""
    }

    private var listPlaceholder: String { inheritedLabel("space-separated") }

    /// For `.optionalValue` the toggle owns presence, so clearing the text means "bare
    /// flag" (`--debug`), not "flag with an empty argument" (`--debug ''`) — those
    /// round-trip to different, visually-indistinguishable command lines. Falling back to
    /// `.on` rather than `.value("")` keeps the toggle and the text in agreement.
    private var optionalValueBinding: Binding<String> {
        Binding(
            get: { if case .value(let raw)? = value { return raw }; return "" },
            set: { value = $0.isEmpty ? (value == nil ? nil : .on) : .value($0) }
        )
    }

    private var optionalPlaceholder: String {
        value == nil ? "" : "optional"
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            value = .value(url.path)
        }
    }
}
