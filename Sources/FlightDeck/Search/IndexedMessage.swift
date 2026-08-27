import Foundation

/// One searchable thing somebody said, ready to go into the index.
///
/// Deliberately carries no file path or project: those are properties of *where* the
/// message was found, and `SearchIndexBuilder` knows them. Keeping them off this type is
/// what lets the extractor stay pure and be tested against a bare string.
struct IndexedMessage: Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }

    let conversationID: String
    let role: Role
    let text: String
    /// The record's own ISO-8601 stamp. nil for records that carry none, in which case the
    /// builder substitutes the transcript file's mtime — a whole-file approximation, which
    /// is why the per-record value is preferred whenever it exists.
    let timestamp: Date?
}
