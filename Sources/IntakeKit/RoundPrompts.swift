import Foundation

/// Draft round's structured output: the whole plan as markdown, nothing else — there is
/// nothing yet to diff a first draft against.
public struct DraftOutput: Codable, Sendable {
    public var plan: String
    public init(plan: String) { self.plan = plan }
}

/// One proposed edit to a plan file. Synthesis and refinement-review both emit these instead
/// of writing the plan themselves — only Integrate is allowed to touch it — so `edit` has to
/// be precise enough for another agent to apply blind: a git-diff-style hunk, or exact
/// replacement instructions.
public struct ProposedChange: Codable, Equatable, Sendable {
    public var section: String
    public var rationale: String
    public var edit: String
    public init(section: String, rationale: String, edit: String) {
        self.section = section
        self.rationale = rationale
        self.edit = edit
    }
}

/// Synthesis and refinement-review's shared shape: the edits being proposed, plus a
/// one-line summary of what changed and why.
public struct ReviewOutput: Codable, Sendable {
    public var changes: [ProposedChange]
    public var summary: String
    public init(changes: [ProposedChange], summary: String) {
        self.changes = changes
        self.summary = summary
    }
}

/// Integrate's report of what it did with the reviewer's proposed changes. `disagree`
/// changes are NOT applied — this is also the signal `TapePlanner`'s caller uses to decide
/// whether another refinement round is worth running.
public struct IntegrateOutput: Codable, Sendable {
    public var agree: Int
    public var somewhat: Int
    public var disagree: Int
    public var notes: String
    public init(agree: Int, somewhat: Int, disagree: Int, notes: String) {
        self.agree = agree
        self.somewhat = somewhat
        self.disagree = disagree
        self.notes = notes
    }
}

/// Encode, polish, fresh-eyes, and dedup all hand back a complete change set — never a
/// diff, so a later round never has to reconstruct state from a chain of partial edits —
/// plus a one-line summary of what it did.
public struct ChangeSetOutput: Codable, Sendable {
    public var changeSet: ChangeSet
    public var summary: String
    public init(changeSet: ChangeSet, summary: String) {
        self.changeSet = changeSet
        self.summary = summary
    }
}

/// Strict-mode schemas for every round's output shape, built the same way `Triage.schemaJSON`
/// is: every object declares `additionalProperties: false` and lists every property in
/// `required`. Only four shapes exist across all eight rounds — synthesis reuses `review`
/// (both hand back `changes[]` + `summary`), and polish/fresh-eyes/dedup all reuse
/// `changeSet` (all four hand back a complete change set + `summary`).
public enum RoundSchemas {
    public static let draft = """
    {"type":"object","additionalProperties":false,"required":["plan"],
     "properties":{"plan":{"type":"string"}}}
    """

    private static let proposedChange = """
    {"type":"object","additionalProperties":false,"required":["section","rationale","edit"],
     "properties":{"section":{"type":"string"},"rationale":{"type":"string"},"edit":{"type":"string"}}}
    """

    public static let review = """
    {"type":"object","additionalProperties":false,"required":["changes","summary"],
     "properties":{"changes":{"type":"array","items":\(proposedChange)},"summary":{"type":"string"}}}
    """

    public static let integrate = """
    {"type":"object","additionalProperties":false,
     "required":["agree","somewhat","disagree","notes"],
     "properties":{"agree":{"type":"integer"},"somewhat":{"type":"integer"},
                   "disagree":{"type":"integer"},"notes":{"type":"string"}}}
    """

    /// Embeds `Triage.changeSetSchemaFragment` exactly, rather than a hand-copied twin that
    /// could drift from it — encode, polish, fresh-eyes, and dedup all hand back the same
    /// `{graphObservedAt, ops}` shape triage does at Bead fidelity.
    public static let changeSet = """
    {"type":"object","additionalProperties":false,"required":["changeSet","summary"],
     "properties":{"changeSet":\(Triage.changeSetSchemaFragment),"summary":{"type":"string"}}}
    """
}

/// Everything every round prompt needs about the intake itself. Seat-specific pieces —
/// persona, which files to reference, the round number — are separate function parameters
/// on `RoundPrompts`, since which of them apply differs stage to stage (Integrate, for
/// instance, needs no intent or graph at all).
public struct RoundContext: Sendable {
    public var intent: String
    public var qa: [TriageExchange]
    public var graphFile: String
    public var agentsFile: String?
    public var readmeFile: String?
    public var annotations: [String]
    public var observedAt: Date
    public init(intent: String, qa: [TriageExchange], graphFile: String, agentsFile: String?,
                readmeFile: String?, annotations: [String], observedAt: Date) {
        self.intent = intent
        self.qa = qa
        self.graphFile = graphFile
        self.agentsFile = agentsFile
        self.readmeFile = readmeFile
        self.annotations = annotations
        self.observedAt = observedAt
    }
}

/// The round engine's prompts (spec §6): one function per stage, each returning plain words
/// plus the schema its stage's `RoundSchemas` member matches. Adapted from the methodology's
/// original prompts, not copied verbatim, except for the pieces `Triage` itself owns — the
/// graph shape and the change-set rules — which are built from `Triage.graphShapeText` /
/// `Triage.changeSetRulesText` rather than a hand copy, so the wording can't drift.
public enum RoundPrompts {
    public struct Malformed: Error, Equatable { public let why: String }

    // MARK: - Shared fragments

    private static func inputFiles(_ c: RoundContext) -> String {
        var files = "- Live bead graph: \(c.graphFile)"
        if let agentsFile = c.agentsFile { files += "\n- Project agent instructions: \(agentsFile)" }
        if let readmeFile = c.readmeFile { files += "\n- Project README: \(readmeFile)" }
        return files
    }

    /// Flattens every exchange's parallel `questions`/`answers` arrays into `Q:`/`A:` pairs.
    /// nil when there is nothing to show — a fresh intake with no prior triage turn should
    /// not get an empty "Here is the Q&A transcript" header.
    private static func qaTranscript(_ qa: [TriageExchange]) -> String? {
        let pairs = qa.flatMap { exchange -> [String] in
            let answers = exchange.answers ?? []
            return exchange.questions.enumerated().map { i, q in
                i < answers.count ? "Q: \(q)\nA: \(answers[i])" : "Q: \(q)\nA: (unanswered)"
            }
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "\n\n")
    }

    /// The extra clause every polish-family round gets once a shadow-beads database exists
    /// (Task 7b wires the path in): `bv`'s robot reports re-read the graph AS IF the current
    /// change set had already landed, so the model sees the shape its own beads would
    /// actually produce before committing to it — nil when no shadow database has been
    /// built yet, e.g. the first polish round of a fresh intake.
    private static func shadowBeadsClause(_ shadowBeads: String?) -> String {
        guard let shadowBeads else { return "" }
        return """


        `bv --db \(shadowBeads) --robot-insights` / `--robot-plan` / `--robot-priority` \
        analyse the graph AS IF your current change set were applied: use them to find \
        bottlenecks, long serial chains, and narrow ready fronts, and restructure \
        dependencies for parallel work where it doesn't lose correctness.
        """
    }

    /// The read-only inputs every change-set round (encode, polish, fresh-eyes, dedup) is
    /// pointed at. The graph is the one that matters: every existing-bead op must copy its
    /// `pre` out of it, and a prompt that never names the file leaves the model guessing at
    /// statuses and assignees — which then fail validation and burn the one correction turn.
    private static func changeSetInputs(_ c: RoundContext) -> String {
        """
        Read-only files:
        \(inputFiles(c))

        \(Triage.graphShapeText(graphFile: c.graphFile))
        """
    }

    private static func lens(for persona: DrafterPersona) -> String {
        switch persona {
        case .general:
            // The only persona a single-drafter round (Sketch) ever uses — no lens to bias
            // toward, since there is no competing draft to spread disagreement against.
            return ""
        case .arbiter:
            return "\n\nYour lens: global coherence — make sure the plan holds together " +
                   "as one coherent whole, with no section contradicting another."
        case .realist:
            return "\n\nYour lens: implementability and sequencing — make sure every step " +
                   "is concretely doable, in an order that actually works."
        case .coverage:
            return "\n\nYour lens: coverage — make sure every feature, edge case and " +
                   "workflow the intent implies is accounted for."
        case .stressTest:
            return "\n\nYour lens: stress-test — challenge every assumption behind the " +
                   "intent and the plan, and call out where the plan would break."
        }
    }

    // MARK: - Rounds

    public static func draft(_ c: RoundContext, persona: DrafterPersona) -> String {
        var s = """
        You are drafting a plan for this project intake. Write a complete, detailed, \
        granular markdown plan — not an outline, not a summary.

        Intent:
        \(c.intent)
        """
        if let qa = qaTranscript(c.qa) {
            s += """


            Here is the Q&A transcript so far:
            \(qa)
            """
        }
        s += """


        Read-only files:
        \(inputFiles(c))

        \(Triage.graphShapeText(graphFile: c.graphFile))
        """
        s += lens(for: persona)
        s += """


        You are read-only: never run a `br` command that writes, and never edit any file.
        Return only JSON matching the provided schema: `{"plan": "<the plan, as markdown>"}`.
        """
        return s
    }

    public static func synthesis(_ c: RoundContext, ownDraft: String, otherDrafts: [String]) -> String {
        let others = otherDrafts.map { "- Competing draft: \($0)" }.joined(separator: "\n")
        return """
        I asked competing models to independently do the same drafting task you were just \
        given; be intellectually honest about what they did better than your own plan, and \
        fold it in.

        Read-only files:
        - Your draft: \(ownDraft)
        \(others)

        Read your own draft again alongside the competing drafts, and return the edits you \
        would make to YOUR OWN draft (\(ownDraft)) — not a rewrite of theirs — as \
        `changes[]`. Each change names the `section` it touches, the `rationale` (what a \
        competing draft got right that yours didn't), and `edit`: a git-diff-style hunk or \
        exact replacement instructions precise enough that another agent could apply it \
        without guessing.

        Return only JSON matching the provided schema: `{"changes": [...], "summary": "..."}`.
        """
    }

    public static func review(_ c: RoundContext, planFile: String, round: Int) -> String {
        var s = """
        This is refinement round \(round). Carefully review this entire plan and come up \
        with your best revisions to it: \(planFile). I am positive you missed or got wrong \
        at least 40 elements — find them.
        """
        if !c.annotations.isEmpty {
            let notes = c.annotations.map { "- \($0)" }.joined(separator: "\n")
            s += """


            The human steering this plan says:
            \(notes)
            """
        }
        s += """


        Return your proposed revisions as `changes[]` — each with `section`, `rationale`, \
        and `edit` (a git-diff-style hunk or exact replacement instructions) — plus a \
        one-line `summary` of what you found. Do not edit \(planFile) yourself; Integrate \
        applies these.

        Return only JSON matching the provided schema.
        """
        return s
    }

    public static func integrate(planFile: String, changesFile: String) -> String {
        """
        Integrate these revisions into `\(planFile)` in place; be meticulous; edit only \
        that file. The proposed changes are in \(changesFile).

        For each proposed change, decide whether you wholeheartedly agree with it, somewhat \
        agree (and apply a modified version of it), or disagree (and leave it out — a \
        disagreed-with change is NOT applied). Report the counts, and a one-line `notes` on \
        what you did and why anything was left out.

        Return only JSON matching the provided schema: `{"agree": N, "somewhat": N, \
        "disagree": N, "notes": "..."}`.
        """
    }

    public static func encode(_ c: RoundContext, planFile: String) -> String {
        """
        Turn ALL of the plan at \(planFile) into a comprehensive and granular set of beads: \
        each bead self-contained and self-documenting, so someone who has never read the \
        plan can pick it up and work it. Include unit and end-to-end test obligations in \
        every bead's acceptance criteria. Never lose a feature the plan describes.

        \(changeSetInputs(c))

        \(Triage.changeSetRulesText(observedAt: c.observedAt))

        Return only JSON matching the provided schema: `{"changeSet": {...}, "summary": "..."}`.
        """
    }

    public static func polish(_ c: RoundContext, planFile: String, changeSetFile: String, round: Int,
                               shadowBeads: String? = nil) -> String {
        """
        This is polish round \(round). Reread AGENTS.md. Check over each proposed bead in \
        \(changeSetFile) super carefully against the plan at \(planFile): does it make \
        sense, is it optimal, could it be better? Revise it. DO NOT OVERSIMPLIFY. DO NOT \
        LOSE FEATURES. Merge duplicates, fill empty descriptions, fix dependencies, and \
        cross-check every bead against the plan.\(shadowBeadsClause(shadowBeads))

        Return the complete revised change set — not a diff — under the same rules encode \
        followed. Existing-bead ops (`editBead`, `reopen`, `followUp`) may be revised, but \
        their `pre` must stay exactly what it was; it is not yours to change.

        \(changeSetInputs(c))

        \(Triage.changeSetRulesText(observedAt: c.observedAt))

        Return only JSON matching the provided schema: `{"changeSet": {...}, "summary": "..."}`.
        """
    }

    public static func freshEyes(_ c: RoundContext, planFile: String, changeSetFile: String,
                                  shadowBeads: String? = nil) -> String {
        """
        You are seeing this plan and its beads for the first time — a fresh-eyes reviewer, \
        not someone who has been polishing them for rounds. Read the plan at \(planFile) \
        and the proposed beads at \(changeSetFile) fresh: does the change set make sense, is \
        it optimal, could it be better? Revise it. DO NOT OVERSIMPLIFY. DO NOT LOSE \
        FEATURES. Merge duplicates, fill empty descriptions, fix dependencies, and \
        cross-check every bead against the plan.\(shadowBeadsClause(shadowBeads))

        Return the complete revised change set — not a diff — under the same rules encode \
        followed. Existing-bead ops (`editBead`, `reopen`, `followUp`) may be revised, but \
        their `pre` must stay exactly what it was; it is not yours to change.

        \(changeSetInputs(c))

        \(Triage.changeSetRulesText(observedAt: c.observedAt))

        Return only JSON matching the provided schema: `{"changeSet": {...}, "summary": "..."}`.
        """
    }

    public static func dedup(_ c: RoundContext, changeSetFile: String, shadowBeads: String? = nil) -> String {
        """
        Check over ALL proposed beads at \(changeSetFile); none may be duplicative or \
        excessively overlapping. Merge into canonical beads, keeping the richer tests and \
        dependencies of whichever duplicate had them.\(shadowBeadsClause(shadowBeads))

        Return the complete revised change set — not a diff — under the same rules encode \
        followed. Existing-bead ops (`editBead`, `reopen`, `followUp`) may be revised, but \
        their `pre` must stay exactly what it was; it is not yours to change.

        \(changeSetInputs(c))

        \(Triage.changeSetRulesText(observedAt: c.observedAt))

        Return only JSON matching the provided schema: `{"changeSet": {...}, "summary": "..."}`.
        """
    }

    /// The single automatic retry after an encode/polish/fresh-eyes/dedup change set fails
    /// validation — resumed in the same session. Not `Triage.correctionPrompt`: that one asks
    /// for a "recommendation", which a change-set seat never gave, and a model told to return
    /// something it doesn't recognise is one more way to spend the only retry on confusion.
    public static func changeSetCorrection(errors: [ValidationError], observedAt: Date) -> String {
        let list = errors.map { "- \($0.message)" }.joined(separator: "\n")
        return """
        Your change set failed validation:
        \(list)

        Return the complete corrected change set — every op, not just the ones you fixed — \
        that fixes every error above, under the same change-set rules as before. Set \
        changeSet.graphObservedAt to exactly "\(IntakeJSON.string(from: observedAt))".

        Return only JSON matching the provided schema: `{"changeSet": {...}, "summary": "..."}`.
        """
    }

    /// Decodes one round's structured output. `IntakeJSON.decoder` handles both ISO8601
    /// date forms `ChangeSetOutput` needs; wrapping the failure in `Malformed` (rather than
    /// letting `DecodingError` surface raw) mirrors `Triage.decode`, since callers on both
    /// sides of the pipeline treat "not JSON matching the schema" the same way.
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try IntakeJSON.decoder.decode(T.self, from: data)
        } catch {
            throw Malformed(why: "not \(T.self) JSON: \(error)")
        }
    }
}
