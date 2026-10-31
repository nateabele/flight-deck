import IntakeKit
import SwiftUI

/// The controls for answering one clarifying question: radio rows, checkbox rows, a switch, or
/// a text field, by `question.kind`. The question's own text is left to the caller so each
/// surface (the intake form here, the P1 thread panel later) can number and style it itself.
struct StructuredQuestionView: View {
    let question: StructuredQuestion
    @Binding var answer: StructuredAnswer
    /// Lets a dropped file become a project-relative path in a free-text answer.
    var projectPath: String?

    init(question: StructuredQuestion, answer: Binding<StructuredAnswer>, projectPath: String? = nil) {
        self.question = question
        self._answer = answer
        self.projectPath = projectPath
    }

    /// The caption beside a recommended option, nil for every other. Static so tests can pin
    /// it without reading pixels.
    static func caption(for option: StructuredQuestion.Option, in question: StructuredQuestion) -> String? {
        question.recommended.contains(option.id) ? "recommended" : nil
    }

    /// "Other" is chosen exactly when `other` is non-nil. An empty string counts: the row must
    /// stay open while the human has picked it but not yet typed.
    private var otherChosen: Bool { answer.other != nil }

    var body: some View {
        switch question.kind {
        case .single: choices(multi: false)
        case .multi: choices(multi: true)
        case .toggle: toggle
        case .text: textField
        }
    }

    private func choices(multi: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(question.options, id: \.id) { option in
                row(selected: answer.selected.contains(option.id), multi: multi, label: option.label,
                    detail: option.detail, caption: Self.caption(for: option, in: question)) {
                    pick(option.id, multi: multi)
                }
            }
            if question.allowOther {
                row(selected: otherChosen, multi: multi, label: "Other…", detail: nil, caption: nil) {
                    toggleOther(multi: multi)
                }
                if otherChosen {
                    TextField("Other", text: otherText, prompt: Text("Your answer"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        // Every answer field took dropped files as paths before choices existed;
                        // Other is typed text too, and losing it here dropped nothing at all.
                        .dropsFilePaths(into: otherText, projectPath: projectPath)
                        .padding(.leading, 24)
                }
            }
        }
    }

    /// One row: the glyph carries the kind (round for radio, square for checkbox), so the two
    /// read differently at a glance even when the labels are alike.
    private func row(selected: Bool, multi: Bool, label: String, detail: String?, caption: String?,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.glyph(selected: selected, multi: multi))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(label).fixedSize(horizontal: false, vertical: true)
                        if let caption {
                            Text(caption).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static func glyph(selected: Bool, multi: Bool) -> String {
        switch (multi, selected) {
        case (false, false): "circle"
        case (false, true): "largecircle.fill.circle"
        case (true, false): "square"
        case (true, true): "checkmark.square.fill"
        }
    }

    private func pick(_ id: String, multi: Bool) {
        if multi {
            if let i = answer.selected.firstIndex(of: id) { answer.selected.remove(at: i) } else { answer.selected.append(id) }
        } else {
            // A named option and "Other" are alternatives for a single choice.
            answer.selected = [id]
            answer.other = nil
        }
    }

    private func toggleOther(multi: Bool) {
        if otherChosen {
            answer.other = nil
        } else {
            answer.other = ""
            if !multi { answer.selected = [] }
        }
    }

    private var otherText: Binding<String> {
        Binding(get: { answer.other ?? "" }, set: { answer.other = $0 })
    }

    /// A toggle's one option id being selected is Yes. The Yes/No caption keeps the state
    /// readable where a switch draws grey (an inactive window), and carries the recommendation.
    private var toggle: some View {
        let option = question.options.first
        let isOn = option.map { answer.selected.contains($0.id) } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(option?.label ?? "Yes", isOn: Binding(
                get: { isOn },
                set: { on in answer.selected = on ? (option.map { [$0.id] } ?? []) : [] }
            ))
            .toggleStyle(.switch)
            Text(isOn ? "Yes" : "No").foregroundStyle(.secondary)
            if let option, let caption = Self.caption(for: option, in: question) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var textField: some View {
        TextField("Answer", text: otherText, prompt: Text("Your answer"), axis: .vertical)
            .labelsHidden()
            .lineLimit(2...6)
            .textFieldStyle(.roundedBorder)
            .dropsFilePaths(into: otherText, projectPath: projectPath)
    }
}
