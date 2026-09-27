import Foundation

public enum TriageResult: Equatable, Sendable {
    case questions([String])
    case recommendation(preset: Preset, reason: String, changeSet: ChangeSet?)
}

/// The triage prompt, its strict JSON output schema, and the decoder for that schema
/// (pipeline step 2, spec §4). Triage reads the live bead graph read-only and returns
/// either clarifying questions or a fidelity recommendation — at Bead fidelity, with the
/// full change set already encoded, since Bead has no later encode step.
public enum Triage {
    public struct Malformed: Error, Equatable { public let why: String }

    private static let nullableString = #"{"type":["string","null"]}"#
    private static let pre = #"{"type":["object","null"],"additionalProperties":false,"required":["status","assignee"],"properties":{"status":{"type":"string"},"assignee":{"type":["string","null"]}}}"#
    private static let op = """
    {"type":"object","additionalProperties":false,
     "required":["op","tempId","title","type","priority","description","acceptance","labels","from","to","kind","id","set","pre","delivery","reason","of"],
     "properties":{
      "op":{"type":"string","enum":["createBead","addEdge","editBead","reopen","followUp"]},
      "tempId":\(nullableString),"title":\(nullableString),"type":\(nullableString),
      "priority":{"type":["integer","null"]},"description":\(nullableString),"acceptance":\(nullableString),
      "labels":{"type":["array","null"],"items":{"type":"string"}},
      "from":\(nullableString),"to":\(nullableString),
      "kind":{"type":["string","null"],"enum":["blocks","related","parent-child",null]},
      "id":\(nullableString),
      "set":{"type":["object","null"],"additionalProperties":false,"required":["title","description","acceptance","priority"],
             "properties":{"title":\(nullableString),"description":\(nullableString),"acceptance":\(nullableString),"priority":{"type":["integer","null"]}}},
      "pre":\(pre),
      "delivery":{"type":["object","null"],"additionalProperties":false,"required":["rating","reason"],
                  "properties":{"rating":{"type":"string","enum":["clarifying","scopeChange","invalidating"]},"reason":{"type":"string"}}},
      "reason":\(nullableString),"of":\(nullableString)}}
    """

    /// Strict-mode schema for both `codex exec --output-schema` and `claude --json-schema`:
    /// every object declares `additionalProperties: false` and lists every property in
    /// `required`, with optional values typed `[<type>, "null"]` instead of simply omitted —
    /// omitting a key from `required` is what both CLIs reject as non-strict.
    public static let schemaJSON = """
    {"type":"object","additionalProperties":false,
     "required":["kind","questions","preset","reason","changeSet"],
     "properties":{
      "kind":{"type":"string","enum":["questions","recommendation"]},
      "questions":{"type":["array","null"],"items":{"type":"string"}},
      "preset":{"type":["string","null"],"enum":["bead","sketch","featurePlan","fullPlan",null]},
      "reason":\(nullableString),
      "changeSet":{"type":["object","null"],"additionalProperties":false,"required":["graphObservedAt","ops"],
                   "properties":{"graphObservedAt":{"type":"string"},"ops":{"type":"array","items":\(op)}}}}}
    """

    private struct Wire: Decodable {
        let kind: String
        let questions: [String]?
        let preset: Preset?
        let reason: String?
        let changeSet: ChangeSet?
    }

    public static func decode(_ data: Data) throws -> TriageResult {
        let w: Wire
        do { w = try IntakeJSON.decoder.decode(Wire.self, from: data) }
        catch { throw Malformed(why: "not triage JSON: \(error)") }
        switch w.kind {
        case "questions":
            guard let q = w.questions, !q.isEmpty else { throw Malformed(why: "questions kind with no questions") }
            return .questions(q)
        case "recommendation":
            guard let p = w.preset, let r = w.reason else { throw Malformed(why: "recommendation without preset/reason") }
            return .recommendation(preset: p, reason: r, changeSet: w.changeSet)
        default:
            throw Malformed(why: "unknown kind \(w.kind)")
        }
    }

    /// The opening triage turn: intent plus the read-only files to consult, the fidelity
    /// presets to choose among, and the change-set rules to follow if it encodes now.
    /// `observedAt` is FD's own clock, not the agent's — it owns `graphObservedAt` because
    /// that timestamp is what release drift-checks against, and an agent's clock can be
    /// off or absent in a sandboxed harness.
    public static func initialPrompt(
        intent: String, graphFile: String, triageFile: String, agentsFile: String, readmeFile: String?,
        observedAt: Date
    ) -> String {
        var files = """
        - Live bead graph: \(graphFile)
        - Current triage view: \(triageFile)
        - Project agent instructions: \(agentsFile)
        """
        if let readmeFile {
            files += "\n- Project README: \(readmeFile)"
        }
        return """
        You are triaging one intent against this project's live bead graph. Decide whether \
        you need more information, and if not, recommend a fidelity preset.

        Intent:
        \(intent)

        Read-only files:
        \(files)

        \(graphFile) is a JSON snapshot shaped:
        `{"beads": {"<id>": {"id","title","status","assignee"?,"updatedAt"?,"labels"}}, \
        "edges": [{"dependent": "<id>", "dependency": "<id>"}]}`. An edge's `dependent` \
        depends on its `dependency` — that is, `dependent` is `from` and `dependency` is \
        `to`. A bead with no `assignee` key has no assignee; when you copy its `pre` \
        precondition, use `"assignee": null` for it — never an empty string, and never
        omit the key.

        Rules:
        - You are read-only. Never run a `br` command that writes (create, update, dep, or
          any other mutating verb) — FD is the only writer. You may run `br list`, `br show`,
          `br graph`, `br ready`, and `bv`.
        - Ask a clarifying question only when its answer would change the change set you
          would produce. If the intent is already unambiguous, do not ask anything.

        Choose one of four fidelity presets:
        - Bead: no drafting or refinement — you encode the change set yourself in one pass.
        - Sketch: one drafter, then up to two reviewer refinement rounds.
        - Feature plan: two drafters synthesize, then up to three refinement rounds and up to
          two polish rounds.
        - Full plan: four drafters (arbiter, realist, coverage, stress-test) synthesize, then
          up to five refinement rounds, then up to six polish rounds plus a fresh-eyes round
          and a dedup round.

        If you recommend Bead fidelity, also return the full change set now — Bead has no
        later encode step, so this is the only chance to produce it.

        Change-set rules, whenever you return a change set:
        - Set `changeSet.graphObservedAt` to exactly "\(IntakeJSON.string(from: observedAt))"
          — the moment FD read the graph, not your own clock.
        - Reference a bead you are creating in this same change set as `new:<tempId>` (never
          a bare tempId), everywhere another op needs to point at it.
        - Edge direction is `from` depends on `to`: `{"from": A, "to": B}` means A cannot
          proceed until B is done.
        - For every existing bead an op touches, copy its `pre` precondition (status and
          assignee) exactly as read from the graph — FD uses it to detect drift before
          release.
        - Rate every edit to a bead that is `in_progress`: `clarifying` if it only affects
          understanding, `scopeChange` if it changes what is being delivered, or
          `invalidating` if it makes the bead's current work moot — and give a reason for
          the rating.
        - For new work on a bead that is already closed, use `op=followUp` — it creates a
          new bead with a `related` edge to the closed one; never emit `createBead` plus a
          separate `addEdge` instead. Use `op=reopen` only when the closed work was itself
          wrong, and say why in its reason.
        - Before creating a bead, check for duplicates against both open and closed beads,
          not just open ones.

        Each op must fill in exactly the fields its kind needs, and set every other field
        to null:
        - `createBead`: `tempId`, `title`, `description` are required; `type`, `priority`,
          `acceptance`, and `labels` are optional (null falls back to `task` priority 2
          with no acceptance or labels).
        - `addEdge`: `from`, `to`, and `kind` — `kind` is required, one of `blocks`,
          `related`, or `parent-child`.
        - `editBead`: `id`, `set` (a non-null object of the fields you are changing), and
          `pre`; also `delivery` when the bead you are editing is `in_progress`.
        - `reopen`: `id`, `reason`, and `pre`.
        - `followUp`: `tempId`, `of`, `title`, `description`, and `pre`.

        Return only JSON matching the provided schema. Do not write prose.
        """
    }

    /// The follow-up turn once the human has answered triage's clarifying questions:
    /// restates the Q&A and asks for the recommendation triage withheld the first time.
    public static func answersPrompt(questions: [String], answers: [String]) -> String {
        let qa = zip(questions, answers)
            .map { "Q: \($0)\nA: \($1)" }
            .joined(separator: "\n\n")
        return """
        Here are your questions and the answers you asked for:

        \(qa)

        Using these answers, return your recommendation now: a preset, a one-sentence
        reason, and — if you recommend Bead fidelity — the full change set. Follow the
        same change-set rules as before.
        """
    }

    /// The single automatic retry after a change set fails validation (spec §11): resumes
    /// the same session, lists what was wrong, and asks for the whole change set again —
    /// not a patch, since FD re-validates the reply from scratch. Re-states
    /// `graphObservedAt` because the graph file may have been re-read since the first turn.
    public static func correctionPrompt(errors: [ValidationError], observedAt: Date) -> String {
        let list = errors.map { "- \($0.message)" }.joined(separator: "\n")
        return """
        Your change set failed validation:
        \(list)

        Return your recommendation again as JSON matching the schema, with a corrected, \
        complete change set that fixes every error above. Follow the same change-set rules \
        as before. Set changeSet.graphObservedAt to exactly "\(IntakeJSON.string(from: observedAt))".
        """
    }

    /// Forces a Bead-fidelity encode regardless of what triage would otherwise recommend —
    /// used when the human picks Bead over triage's own recommendation. Carries its own
    /// `graphObservedAt` instruction because it can start a fresh session (unlike
    /// `answersPrompt`, which resumes the session `initialPrompt` already gave it to).
    public static func encodeNowPrompt(observedAt: Date) -> String {
        """
        Encode this intent now at Bead fidelity as a single pass, regardless of your \
        recommended preset; return kind=recommendation, preset=bead with the full changeSet. \
        Set changeSet.graphObservedAt to exactly "\(IntakeJSON.string(from: observedAt))".
        """
    }
}
