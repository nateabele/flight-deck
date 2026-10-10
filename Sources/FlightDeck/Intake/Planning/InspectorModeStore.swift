import Combine
import Foundation

/// The inspector mode last chosen for each plan (`DetailLayout.InspectorMode`), persisted.
///
/// **Its own object, observed by the inspector alone.** It used to be a `@Published` on
/// `IntakeService`, and `SessionStore` forwards every `IntakeService` publish into its own: each
/// Notes/Rounds click re-evaluated `RootView`, `ProjectView`, the detail pane and the live card
/// (measured in `ProjectViewInspectorLiveTests`: root 1, project 1, detail 2 per switch), and
/// scheduled a fleet summary refresh, for a choice nothing but the inspector draws. Only
/// `InspectorModeReader` subscribes here.
///
/// Per plan, not per project: one plan is being annotated while another is being set up, and the
/// mode is the human's choice of which. Owned by `IntakeService`, not the pane's `@State`:
/// `ProjectView` keys the pane on the intake, so a trip to another plan and back reset it.
@MainActor
final class InspectorModeStore: ObservableObject {
    @Published private(set) var modes: [UUID: DetailLayout.InspectorMode] = [:]
    private let defaults: UserDefaults
    /// Persisted as `[uuidString: rawValue]`. The key predates this type; kept so a mode chosen
    /// before the move still reads back.
    static let defaultsKey = "IntakeInspectorModeByIntake"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let raw = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] {
            modes = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
                UUID(uuidString: key).flatMap { id in DetailLayout.InspectorMode(rawValue: value).map { (id, $0) } }
            })
        }
    }

    /// The mode last chosen for `id`; nil before the human chose one, which
    /// `DetailLayout.inspectorMode` turns into the plan's default.
    func mode(_ id: UUID) -> DetailLayout.InspectorMode? { modes[id] }

    /// Records the mode chosen for `id` and persists it. A write that changes nothing is dropped,
    /// so it never redraws the inspector for nothing.
    func set(_ mode: DetailLayout.InspectorMode, for id: UUID) {
        guard modes[id] != mode else { return }
        modes[id] = mode
        persist()
    }

    /// Forgets `id`'s mode: a discarded plan is never shown again, so its entry would only grow
    /// the key.
    func forget(_ id: UUID) {
        guard modes.removeValue(forKey: id) != nil else { return }
        persist()
    }

    private func persist() {
        defaults.set(Dictionary(uniqueKeysWithValues: modes.map { ($0.key.uuidString, $0.value.rawValue) }),
                     forKey: Self.defaultsKey)
    }
}
