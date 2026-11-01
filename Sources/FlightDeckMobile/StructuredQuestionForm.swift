import FleetKit
import SwiftUI

/// The open round of clarifying questions as sections of a `List`: choose, then Send. Recommended
/// options start selected. The Mac decides what it accepts; `isComplete` only keeps Send honest.
struct StructuredQuestionForm: View {
    let title: String
    let questions: [WireStructuredQuestion]
    let sending: Bool
    let enabled: Bool
    /// Hears every change, so what was chosen can be kept across a relaunch.
    let onChange: ([WireStructuredAnswer]) -> Void
    let onSend: ([WireStructuredAnswer]) -> Void
    @State private var answers: [WireStructuredAnswer]

    /// `initial` must hold one answer per question, in order; anything else starts from the
    /// recommended options.
    init(title: String, questions: [WireStructuredQuestion], initial: [WireStructuredAnswer]? = nil,
         sending: Bool, enabled: Bool = true, onChange: @escaping ([WireStructuredAnswer]) -> Void = { _ in },
         onSend: @escaping ([WireStructuredAnswer]) -> Void) {
        self.title = title
        self.questions = questions
        self.sending = sending
        self.enabled = enabled
        self.onChange = onChange
        self.onSend = onSend
        let fits = initial?.map(\.questionID) == questions.map(\.id)
        _answers = State(initialValue: fits ? initial! : questions.map(\.initialAnswer))
    }

    private var complete: Bool {
        zip(questions, answers).allSatisfy { $0.isComplete($1) }
    }

    var body: some View {
        ForEach(Array(questions.enumerated()), id: \.offset) { i, question in
            Section {
                if answers.indices.contains(i) { control(question, index: i) }
            } header: {
                if i == 0 { Text(title).font(.footnote) }
            } footer: {
                EmptyView()
            }
            .headerProminence(.standard)
        }
        Section {
            Button {
                onSend(answers.map(Self.cleaned))
            } label: {
                Text(sending ? "Sending…" : "Send").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(sending || !enabled || !complete)
        }
        .onChange(of: answers) { _, now in onChange(now) }
    }

    /// Blank `other` is no `other`, so the Mac never reads whitespace as an answer.
    static func cleaned(_ a: WireStructuredAnswer) -> WireStructuredAnswer {
        var a = a
        if a.other?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { a.other = nil }
        return a
    }

    @ViewBuilder private func control(_ q: WireStructuredQuestion, index i: Int) -> some View {
        Text(q.text).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        switch q.kind {
        case "single", "multi":
            let multi = q.kind == "multi"
            ForEach(q.options, id: \.id) { option in
                optionRow(q, option, multi: multi, index: i)
            }
            if q.allowOther { otherRow(multi: multi, index: i) }
        case "toggle":
            if let option = q.options.first {
                Toggle(isOn: Binding(
                    get: { answers[i].selected.contains(option.id) },
                    set: { answers[i].selected = $0 ? [option.id] : [] })
                ) {
                    optionLabel(q, option)
                }
                .disabled(sending)
            }
        default:
            TextField("Your answer", text: Binding(get: { answers[i].other ?? "" }, set: { answers[i].other = $0 }),
                      axis: .vertical)
                .font(.subheadline)
                .disabled(sending)
        }
    }

    private func optionLabel(_ q: WireStructuredQuestion, _ option: WireOption) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(option.label).font(.subheadline)
                if q.recommended.contains(option.id) {
                    Text("Recommended").font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func optionRow(_ q: WireStructuredQuestion, _ option: WireOption, multi: Bool, index i: Int) -> some View {
        let on = answers[i].selected.contains(option.id)
        return Button {
            answers[i] = Self.picking(option.id, in: answers[i], multi: multi)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: Self.symbol(multi: multi, on: on)).foregroundStyle(on ? Color.accentColor : .secondary)
                optionLabel(q, option)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sending)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// What an option tap does: it only picks, and never sends — not even for a lone single-select
    /// question, where one tap would be a whole answer. The options sit under the keyboard, and a
    /// thumb reaching for the Other field kept landing on one and sending an answer nobody meant
    /// (the prompt card's rule since e2b55cb0). Send is the only commit.
    static func picking(_ option: String, in a: WireStructuredAnswer, multi: Bool) -> WireStructuredAnswer {
        var a = a
        if multi {
            if a.selected.contains(option) { a.selected.removeAll { $0 == option } } else { a.selected.append(option) }
        } else {
            a.selected = [option]
            a.other = nil
        }
        return a
    }

    /// "Other…" is a choice of its own: in a single question it clears the pick, so what is sent
    /// is one thing or the other.
    @ViewBuilder private func otherRow(multi: Bool, index i: Int) -> some View {
        let on = answers[i].other != nil
        Button {
            if on { answers[i].other = nil } else {
                answers[i].other = ""
                if !multi { answers[i].selected = [] }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: Self.symbol(multi: multi, on: on)).foregroundStyle(on ? Color.accentColor : .secondary)
                Text("Other…").font(.subheadline)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sending)
        .accessibilityAddTraits(on ? .isSelected : [])
        if on {
            TextField("Your answer", text: Binding(get: { answers[i].other ?? "" }, set: { answers[i].other = $0 }),
                      axis: .vertical)
                .font(.subheadline)
                .disabled(sending)
        }
    }

    static func symbol(multi: Bool, on: Bool) -> String {
        multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")
    }
}
