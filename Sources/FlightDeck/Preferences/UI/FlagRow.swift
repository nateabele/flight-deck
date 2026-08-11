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

    private var isOverridden: Bool { value != nil }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                control
                    .accessibilityIdentifier(spec.label)
                if let onRevert, isOverridden, inherited != nil {
                    Button {
                        onRevert()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Revert to the global default")
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
            Toggle("", isOn: boolBinding).labelsHidden()

        case .negatable:
            Picker("", selection: negatableBinding) {
                Text(inheritedLabel("Default")).tag("")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
            .labelsHidden()
            .frame(width: 120)

        case .choice(let options, let allowsCustom):
            HStack(spacing: 6) {
                Picker("", selection: choiceBinding(options, allowsCustom: allowsCustom)) {
                    Text(inheritedLabel("Default")).tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                    if allowsCustom { Text("Custom…").tag(customTag) }
                }
                .labelsHidden()
                .frame(width: 160)

                if allowsCustom, isCustomValue(options) {
                    TextField("", text: stringBinding)
                        .frame(width: 160)
                }
            }

        case .optionalValue:
            HStack(spacing: 6) {
                Toggle("", isOn: boolBinding).labelsHidden()
                TextField(optionalPlaceholder, text: stringBinding)
                    .frame(width: 200)
                    .disabled(value == nil)
            }

        case .string:
            TextField(inheritedLabel(""), text: stringBinding).frame(width: 240)

        case .path:
            HStack(spacing: 6) {
                TextField(inheritedLabel(""), text: stringBinding).frame(width: 200)
                Button("Choose…") { chooseFile() }
            }

        case .multiline:
            TextEditor(text: stringBinding)
                .font(.body.monospaced())
                .frame(width: 320, height: 64)
                .border(.separator)

        case .list:
            TextField(inheritedLabel("space-separated"), text: listBinding).frame(width: 320)
        }
    }

    private var customTag: String { "\u{1}custom" }

    private func inheritedLabel(_ fallback: String) -> String {
        guard let inherited else { return fallback }
        switch inherited {
        case .on: return "Inherited: on"
        case .value(let raw): return "Inherited: \(raw)"
        case .list(let items): return "Inherited: \(items.joined(separator: " "))"
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
                return options.contains(raw) ? raw : customTag
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

    private var listBinding: Binding<String> {
        Binding(
            get: {
                if case .list(let items)? = value { return items.joined(separator: " ") }
                return ""
            },
            set: { raw in
                let items = raw.split(separator: " ").map(String.init)
                value = items.isEmpty ? (value == nil ? nil : .list([])) : .list(items)
            }
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
