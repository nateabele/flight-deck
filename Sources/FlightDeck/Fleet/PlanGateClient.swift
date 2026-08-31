import Foundation

/// Flight Deck's client for one Plannotator plan gate.
///
/// **Loopback only, and that is a security property rather than a default.** Plannotator's API
/// is unauthenticated by design — its own generated docs say so — which is safe exactly as
/// long as the only thing that can reach it is a process on this machine. The Mac is that
/// process; the phone talks to the Mac. Nothing here takes a host.
///
/// The contract was read off the `plannotator` binary (v0.27.8) and confirmed against a
/// running server on 2026-08-29:
///
/// - `GET  /api/plan` → `{plan, origin, permissionMode, previousPlan, versionInfo, …}`
/// - `POST /api/external-annotations` → `{source, type, text, originalText}`
/// - `POST /api/approve`  → `{feedback?}`, resolves the hook, decision `"approved"`
/// - `POST /api/feedback` → `{feedback}`,  resolves it too, decision `"annotated"` — **not**
///   `/api/deny`, which the served frontend bundle still references but the v0.27.8 server
///   answers with a 404. `/api/feedback` is what the real "Send Feedback" button calls, and
///   it is a plain stateless POST with no lease/SSE connection required, exactly like
///   `/api/approve`.
struct PlanGateClient {
    /// Test seam, in the shape `PromptService.tail` is one: the network is the thing a test
    /// must substitute. The `Int` is the HTTP status; `nil` is a transport failure, which is
    /// a different fact from a server that answered badly.
    typealias Transport = @Sendable (URLRequest) async -> (Data, Int)?

    let port: Int
    let transport: Transport

    /// The `source` every annotation carries, so `DELETE ?source=flight-deck` can retract
    /// exactly what this Mac posted and nothing a person typed in the browser.
    static let source = "flight-deck"

    init(port: Int, transport: @escaping Transport = PlanGateClient.urlSession) {
        self.port = port
        self.transport = transport
    }

    static let urlSession: Transport = { request in
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        return (data, http.statusCode)
    }

    private func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private func post(_ path: String, _ body: [String: Any]) async -> Bool {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, status) = await transport(request) else { return false }
        return (200..<300).contains(status)
    }

    func plan() async -> String? {
        var request = URLRequest(url: url("/api/plan"))
        request.httpMethod = "GET"
        guard let (data, status) = await transport(request), (200..<300).contains(status),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["plan"] as? String
    }

    /// Post one comment.
    ///
    /// **The return value means "sent", never "pinned".** Plannotator matches `originalText`
    /// as a substring and falls back to sidebar-only when it does not match — silently, and
    /// the POST succeeds either way. `PlanBlocks` guarantees a verbatim unique substring so
    /// this should not arise; the phone still says "sent", because claiming a pin this call
    /// cannot confirm would be a lie the reader has no way to check.
    ///
    /// **Step 1 finding (2026-08-29, live server, `plannotator` 0.27.8):** confirms the body
    /// carries no pin/fallback signal, so there is nothing richer to return.
    /// `POST /api/external-annotations` → `201 Created`, body `{"ids":["<uuid>"]}`. Identical
    /// shape — same status, same `{"ids":[...]}` — whether `originalText` matched a substring
    /// of the plan or matched nothing at all; a follow-up `GET /api/external-annotations`
    /// shows the mismatched one stored with the same fields as the matched one, no
    /// pinned/fallback flag anywhere. The response reports only that an annotation was
    /// created, never whether it landed inline or fell back to the sidebar.
    func annotate(text: String, originalText: String?) async -> Bool {
        var body: [String: Any] = [
            "source": Self.source,
            "text": text,
            "type": originalText == nil ? "GLOBAL_COMMENT" : "COMMENT",
        ]
        // Absent rather than empty: an empty string is a substring of everything and would
        // pin the comment to the first character of the plan.
        if let originalText { body["originalText"] = originalText }
        return await post("/api/external-annotations", body)
    }

    /// Resolve the gate. **Approve carries feedback too** — reading a plan, marking it up and
    /// saying yes anyway is a first-class outcome, not a workaround.
    ///
    /// **Step 3 finding (2026-08-29, live server, `plannotator` 0.27.8):** the deny path is
    /// `POST /api/feedback`, not `/api/deny`. `/api/deny` 404s every time against the real
    /// binary, on every request shape tried — it is dead code, still referenced in the served
    /// frontend bundle's minified JS but not wired to the UI's actual "Send Feedback" button,
    /// which was captured (via the browser's network panel) calling `/api/feedback` instead.
    /// `POST /api/feedback` with the same `{feedback}` body returns `200`, and the process
    /// exits printing the feedback text back verbatim in a decision JSON of
    /// `{"decision":"annotated","feedback":"…"}` — this client only checks the HTTP status,
    /// so the different decision label doesn't otherwise matter here.
    func resolve(approved: Bool, feedback: String?) async -> Bool {
        var body: [String: Any] = [:]
        if let feedback, !feedback.isEmpty { body["feedback"] = feedback }
        return await post(approved ? "/api/approve" : "/api/feedback", body)
    }
}
