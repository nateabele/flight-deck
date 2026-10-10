import FleetKit
import Foundation
import IntakeKit

/// One thing an OpenCode server event says, before it is routed to a tab.
///
/// Keyed by OpenCode's own session id, never by a tab, because routing is not this type's
/// job: a subagent runs in a CHILD session (`parentID` set), and its permission and question
/// requests are raised on that child while the dialog is drawn in the parent's TUI — captured
/// live, an `@explore` subagent's `permission.asked` named `ses_ef8790…` while the tab was
/// attached to `ses_ef918c…`. `OpenCodeRuntime` folds children onto their root session.
enum OpenCodeSignal: Equatable, Sendable {
    case activity(session: String, SessionActivity)
    /// `session.idle` — the turn is over. Always accompanies the idle activity.
    case turnEnded(session: String)
    /// `session.error` named `MessageAbortedError`. Both an HTTP abort and Esc-Esc in the TUI
    /// produce exactly this, live-probed, so one mapping covers a phone's stop and a person's.
    ///
    /// **Only once the model has started answering.** An abort that lands after the turn went
    /// busy but before the first output chunk ends the turn with no error at all — measured in
    /// `OpenCodeLiveTests`, where it appeared as a plain `session.idle`. Nothing is lost by
    /// that: the turn still ends, and an interrupt that early cannot have left an API error
    /// behind for the retry ladder to act on.
    case turnAborted(session: String)
    case apiError(session: String, SessionAPIError)
    case title(session: String, String)
    /// A session appeared. `parent` is nil for a top-level one.
    case created(session: String, parent: String?)
    /// A message finished — the mirror has something new to append.
    case messageSettled(session: String)
    /// A permission or question request opened or closed. `line` is the mirror record that
    /// says so, already encoded; see `OpenCodeMirror` for why prompts are logged there.
    case prompt(session: String, line: String)
}

enum OpenCodeEventMapper {
    /// One `data:` payload from `GET /global/event`. That stream wraps every event as
    /// `{"directory": …, "payload": {"type": …, "properties": …}}`; the per-directory `/event`
    /// stream sends the bare payload. Both shapes are accepted so a fixture captured from
    /// either still parses.
    static func signals(inEventJSON text: String, now: Date = Date()) -> [OpenCodeSignal] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return [] }
        let payload = object["payload"] as? [String: Any] ?? object
        guard let type = payload["type"] as? String,
              let properties = payload["properties"] as? [String: Any]
        else { return [] }
        return signals(type: type, properties: properties, now: now)
    }

    static func signals(
        type: String, properties p: [String: Any], now: Date = Date()
    ) -> [OpenCodeSignal] {
        let session = p["sessionID"] as? String
        switch type {
        case "session.status":
            guard let session, let status = p["status"] as? [String: Any],
                  let kind = status["type"] as? String
            else { return [] }
            switch kind {
            // `retry` is OpenCode retrying the provider ITSELF (`attempt`, `next`), so the turn
            // is still in flight and nothing about it is Flight Deck's to retry. Busy, not an
            // error: arming Flight Deck's own retry ladder on top would type "continue" into a
            // turn OpenCode is about to resume on its own.
            case "busy", "retry": return [.activity(session: session, .busy)]
            case "idle": return [.activity(session: session, .idle)]
            default: return []
            }

        case "session.idle":
            guard let session else { return [] }
            return [.activity(session: session, .idle), .turnEnded(session: session)]

        case "session.error":
            guard let session, let error = p["error"] as? [String: Any],
                  let name = error["name"] as? String
            else { return [] }
            if name == "MessageAbortedError" { return [.turnAborted(session: session)] }
            return [.apiError(session: session, apiError(name: name, data: error["data"]))]

        case "session.created", "session.updated":
            guard let info = p["info"] as? [String: Any], let id = info["id"] as? String
            else { return [] }
            var out: [OpenCodeSignal] = []
            if type == "session.created" {
                out.append(.created(session: id, parent: info["parentID"] as? String))
            }
            // OpenCode's placeholder title is "New session - <ISO date>". It is what a session
            // created WITHOUT a title carries until OpenCode summarises one, and forwarding it
            // would rename a tab to a timestamp. Flight Deck always creates with a title, so
            // this only filters sessions it did not create.
            if let title = info["title"] as? String, !title.isEmpty,
               !title.hasPrefix("New session - ") {
                out.append(.title(session: id, title))
            }
            return out

        case "message.updated":
            guard let info = p["info"] as? [String: Any],
                  let owner = (info["sessionID"] as? String) ?? session
            else { return [] }
            // A user message is settled the moment it exists. An assistant message is settled
            // when OpenCode stamps `time.completed`, or when it carries an error (an abort
            // stamps the error; whether it also stamps completion has varied).
            let role = info["role"] as? String
            let time = info["time"] as? [String: Any]
            if role == "user" || time?["completed"] != nil || info["error"] != nil {
                return [.messageSettled(session: owner)]
            }
            return []

        case "permission.asked":
            guard let session, let id = p["id"] as? String else { return [] }
            var record: [String: Any] = [
                "type": "prompt.asked", "kind": "permission", "id": id, "time": millis(now),
                "permission": p["permission"] as? String ?? "permission",
                "patterns": p["patterns"] as? [String] ?? [],
            ]
            if let metadata = p["metadata"] as? [String: Any] { record["metadata"] = metadata }
            return [
                .activity(session: session, .waiting),
                .prompt(session: session, line: encode(record)),
            ]

        case "question.asked":
            guard let session, let id = p["id"] as? String,
                  let questions = p["questions"] as? [[String: Any]]
            else { return [] }
            let record: [String: Any] = [
                "type": "prompt.asked", "kind": "question", "id": id, "time": millis(now),
                "questions": questions,
            ]
            return [
                .activity(session: session, .waiting),
                .prompt(session: session, line: encode(record)),
            ]

        case "permission.replied", "question.replied", "question.rejected":
            guard let session, let id = p["requestID"] as? String else { return [] }
            var record: [String: Any] = [
                "type": "prompt.resolved", "id": id, "time": millis(now),
            ]
            switch type {
            case "permission.replied": record["outcome"] = p["reply"] as? String ?? "replied"
            case "question.replied":
                record["outcome"] = "answered"
                if let answers = p["answers"] { record["answers"] = answers }
            default: record["outcome"] = "rejected"
            }
            // Busy, not idle: a reply releases the turn that was blocked on it. A REJECTED
            // permission usually ends that turn too, and `session.idle` will say so.
            return [
                .activity(session: session, .busy),
                .prompt(session: session, line: encode(record)),
            ]

        default:
            return []
        }
    }

    /// OpenCode's error union, onto Flight Deck's one error shape. `APIError` is the only member
    /// carrying an HTTP status and OpenCode's own retryability verdict; every other member
    /// (`ProviderAuthError`, `ContextOverflowError`, …) is a kind with no status, and is
    /// non-transient by construction.
    static func apiError(name: String, data: Any?) -> SessionAPIError {
        let data = data as? [String: Any] ?? [:]
        return SessionAPIError(
            status: data["statusCode"] as? Int,
            kind: name,
            isTransient: name == "APIError" && (data["isRetryable"] as? Bool ?? false)
        )
    }

    static func millis(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }

    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
