import FleetKit
import Foundation

/// The answers chosen on the phone for an open clarifying round, kept until they are sent.
///
/// A person can pick five options, type an Other, and have the app killed before Send — by a
/// deploy, jetsam or a force quit — and the form came back at the recommended defaults. Handoff
/// §9.2: persist anything a person would miss after a relaunch.
///
/// Keyed by the intake and the round's digest (`WireQuestions.digest`), not its index: a retry
/// on the Mac reuses index 0 for different questions, and answers kept by index would come back
/// on them. One entry per intake: saving a new round's answers replaces the old round's, so
/// rounds the person never sent do not pile up.
///
/// UserDefaults, not a file: the entry is a few hundred bytes of option ids and short text,
/// written on every change, and `purgeAll()` takes it with the pairing.
final class AnswerDraftStore {
    private struct Entry: Codable {
        var digest: String
        var answers: [WireStructuredAnswer]
    }

    private static let prefix = "intakeAnswerDrafts."
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ intake: UUID) -> String { Self.prefix + intake.uuidString }

    private func entry(_ intake: UUID) -> Entry? {
        defaults.data(forKey: key(intake)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
    }

    /// The answers kept for this round of `intake`, or nil — for any other round's digest too.
    func drafts(intake: UUID, digest: String) -> [WireStructuredAnswer]? {
        entry(intake).flatMap { $0.digest == digest ? $0.answers : nil }
    }

    func save(_ answers: [WireStructuredAnswer], intake: UUID, digest: String) {
        guard let data = try? JSONEncoder().encode(Entry(digest: digest, answers: answers)) else { return }
        defaults.set(data, forKey: key(intake))
    }

    /// After a successful send. Only this round's entry: a send acked late must not wipe what
    /// is already being chosen for the next one.
    func clear(intake: UUID, digest: String) {
        guard entry(intake)?.digest == digest else { return }
        defaults.removeObject(forKey: key(intake))
    }

    /// Every entry: what was chosen goes with the pairing, like `DraftStore`.
    func purgeAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
