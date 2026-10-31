# Planning v2 P0: Structured Questions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clarifying questions become choices (single, multi, toggle or text, with a recommended option and an "Other…" field) that can be answered on the Mac and, for the first time, on the phone.

**Architecture:** `TriageExchange` keeps its `questions: [String]` and `answers: [String]?` arrays, which are matched by position, and adds optional `structured` and `structuredAnswers` beside them. Every structured answer is also rendered into the matching plain `answers[i]` string. As a result, every existing reader (projections, board, progress, `qaTranscript`, `answersPrompt`) keeps working unchanged. Triage's schema asks for question objects, and the decoder still accepts plain strings. The phone gets a new `intake.answer` op behind a `structuredQuestions` capability flag.

**Tech Stack:** Swift 5 mode, SwiftUI (Mac and iOS), IntakeKit (Foundation only), FleetKit / FleetKitiOS wire types, XCTest.

**Spec:** [docs/superpowers/specs/2026-10-31-flight-control-planning-v2-design.md](../specs/2026-10-31-flight-control-planning-v2-design.md), §4, the `intake.answer` row in §10, §13 and §14.

## Global Constraints

- Words in UI and in agent prompts: *tasks* (never "beads"), *agent* (never "seat"), *Flight Control* (never "flywheel"). `TerminologyGuardTests` and `AgentVocabularyGuardTests` must stay green.
- Storage is additive. An `intake.json` written before this change must decode and render unchanged. New fields are optional, and no key is renamed.
- Wire enum cases are atomic. `FleetCommand.intakeAnswer`, its encode and decode arms and its `FleetService` handler land in **one commit**.
- An old Mac must never receive `intake.answer`. The phone sends it only when `WireIntakeDetail.structuredQuestions == true`.
- The triage schema stays strict: every property is in `required`, and every object has `additionalProperties: false` (`testSchemaIsValidJSONAndStrict`). It must also pass through `GeminiSchema.compatible` unchanged in meaning.
- `Sources/FlightDeckMobile/` stays flat, with no subdirectories.
- TDD: every test is seen failing before its fix. Assertions are never weakened.
- Nothing that opens a window, launches the app or runs XCUITest runs on this Mac. `./scripts/test-unit.sh` runs on the UI-test Mac. It always runs the whole suite (about 8 minutes) and exits 0 even when tests fail, so grep its output for `error:` and `failed`.
- Work in a worktree on branch `planning-v2-p0`, with the vendor artifacts and `scripts/local.env` symlinked from the main checkout (AGENT-OPERATIONS.md, "Worktrees"). Commit by path, and merge through `.superpowers/merge.lock` with `--ff-only`. No `git stash`, no push, no release swap.

## Review Focus

1. **An agent returns a malformed question.** Examples: `single` with fewer than 2 options, duplicate or empty option ids, `recommended` naming an option that doesn't exist. Expected: it still reaches the person as an answerable question, never as a decode failure that stalls triage. (Task 2: `testMalformedChoiceQuestionDegradesToText`, `testDuplicateIdsAreRenumbered`.)
2. **The phone answers questions that triage has since replaced.** The person answers on the Mac, triage asks a follow-up round, and then the phone's send arrives. Expected: it is refused with `stale_questions`, and the new round's answers are never overwritten. (Task 5: `testPhoneAnswerForAnEarlierRoundIsRefusedAsStale`.)
3. **"Other…" text with no option chosen** on a `single` question. Expected: this is a valid answer, rendered as `Other: <text>`. (Task 1: `testSingleAnsweredByOtherOnly`.)
4. **An intake saved before this change**, with string-only exchanges and an open round. Expected: it loads, shows its questions as text questions on the Mac and the phone, and can be answered from either. (Task 1: `testLegacyExchangeDecodesAndPresentsAsTextQuestions`; Task 5: `testLegacyOpenRoundProjectsAsTextQuestions`.)
5. **A multi question where the person clears everything**, including the preselected recommendation. Expected: valid, sent and rendered as `None`, not blocked as unanswered. (Task 1: `testMultiWithNothingSelectedIsCompleteAndRendersNone`.)

---

### Task 1: The structured question model

**Files:**
- Create: `Sources/IntakeKit/StructuredQuestion.swift`
- Modify: `Sources/IntakeKit/Intake.swift:59-65` (`TriageExchange`)
- Test: `Tests/FlightDeckTests/Intake/StructuredQuestionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct StructuredQuestion: Codable, Equatable, Sendable {
      public enum Kind: String, Codable, Sendable { case single, multi, toggle, text }
      public struct Option: Codable, Equatable, Sendable { public var id: String; public var label: String; public var detail: String? }
      public struct Cost: Codable, Equatable, Sendable { public var seconds: Int; public var tokens: Int }   // unused until P2a
      public var id: String; public var text: String; public var kind: Kind
      public var options: [Option]; public var recommended: [String]; public var allowOther: Bool; public var cost: Cost?
      public static func text(id: String, _ text: String) -> StructuredQuestion
      public func isComplete(_ a: StructuredAnswer) -> Bool
      public func render(_ a: StructuredAnswer) -> String
      public var initialAnswer: StructuredAnswer      // recommended preselected; toggle off unless recommended
  }
  public struct StructuredAnswer: Codable, Equatable, Sendable {
      public var questionID: String; public var selected: [String]; public var other: String?
  }
  extension TriageExchange {
      public var structured: [StructuredQuestion]?          // new stored, optional
      public var structuredAnswers: [StructuredAnswer]?     // new stored, optional
      public var presentedQuestions: [StructuredQuestion]   // structured ?? questions.enumerated().map { .text(id: "q\($0+1)", $1) }
  }
  ```
- Rules that the tests pin down:
  - `isComplete`:
    - text: `other` is non-blank;
    - single: exactly one selected, **or** no selection and a non-blank `other`;
    - multi and toggle: always complete.
  - `render`:
    - single: the label, or `Other: <text>`;
    - multi: the labels joined with `", "`, then `; Other: <text>` if present, or `None` when empty;
    - toggle: `Yes` or `No`;
    - text: the trimmed text.
  - A toggle has exactly one option. Selecting that option's id means Yes.

- [ ] **Step 1: Write the failing tests** in `StructuredQuestionTests`:
  - `testSingleAnsweredByOtherOnly`: single with options a and b, answer `selected: [], other: "Keep it"`. `isComplete` is true, and `render` gives `"Other: Keep it"`.
  - `testMultiWithNothingSelectedIsCompleteAndRendersNone`.
  - `testRenderFormsPerKind`: single gives `"Only this Mac"`. Multi with two options plus other gives `"A, B; Other: C"`. Toggle on gives `"Yes"` and off gives `"No"`. Text gives the trimmed text.
  - `testBlankTextAndUnchosenSingleAreIncomplete`.
  - `testInitialAnswerPreselectsRecommended`: single with `recommended: ["b"]` gives `selected == ["b"]`. Multi with `recommended: ["a","c"]` gives both. Toggle with recommended gives the option's id.
  - `testLegacyExchangeDecodesAndPresentsAsTextQuestions`: decode `{"questions":["Who?","When?"],"answers":null}`. `structured` is nil, and `presentedQuestions` gives ids `q1` and `q2`, kind `.text` and the original texts.
  - `testStructuredExchangeRoundTrips`: encode then decode keeps `structured` and `structuredAnswers`.
- [ ] **Step 2:** Run `./scripts/test-unit.sh 2>&1 | tee /tmp/p0-t1.log; rg -n 'error:|StructuredQuestionTests.*failed' /tmp/p0-t1.log`. Expected: a compile error, because `StructuredQuestion` is not defined.
- [ ] **Step 3:** Implement `StructuredQuestion.swift`, and add the two optional stored properties to `TriageExchange`. Its `init(questions:answers:)` keeps its signature, and the new fields default to nil. The memberwise decode needs no custom `init(from:)`, because the new fields are optional.
- [ ] **Step 4:** Run the suite again. Expected: `StructuredQuestionTests` pass, and `IntakeStoreTests` and `IntakeServiceTests` still pass.
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/IntakeKit/StructuredQuestion.swift Sources/IntakeKit/Intake.swift Tests/FlightDeckTests/Intake/StructuredQuestionTests.swift
  git commit -m "feat: model clarifying questions as choices beside the plain question strings"
  ```

### Task 2: Triage asks for structured questions

**Files:**
- Modify: `Sources/IntakeKit/Triage.swift`. Change `TriageResult` (:3-5), `schemaJSON` (:54-63), `Wire` and `decode` (:65-80), and the prompt text (:207-211).
- Modify: `Sources/FlightDeck/Intake/IntakeService.swift:2329`, where the exchange is appended.
- Modify: `Tests/FlightDeckTests/Fixtures/Intake/triage-schema.json`, regenerated on purpose.
- Test: `Tests/FlightDeckTests/Intake/TriageTests.swift`, and `RoundPromptsTests.testTriageSchemaJSONUnchangedByTheRefactor`, which now compares against the new fixture.

**Interfaces:**
- Consumes: `StructuredQuestion` and `StructuredQuestion.text(id:_:)` from Task 1.
- Produces:
  - `TriageResult.questions([StructuredQuestion])`, which replaces `[String]`.
  - `Triage.normalize(_ raw: [StructuredQuestion]) -> [StructuredQuestion]`.
  - The appended exchange is `TriageExchange(questions: qs.map(\.text), answers: nil)` with `structured = qs`.

**Schema:** each `questions` item becomes:

`{"type":"object","additionalProperties":false,"required":["id","text","kind","options","recommended","allowOther"],"properties":{"id":{"type":"string"},"text":{"type":"string"},"kind":{"type":"string","enum":["single","multi","toggle","text"]},"options":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","label","detail"],"properties":{"id":{"type":"string"},"label":{"type":"string"},"detail":{"type":["string","null"]}}}},"recommended":{"type":"array","items":{"type":"string"}},"allowOther":{"type":"boolean"}}}`

`cost` is not part of the triage schema in P0.

**Normalization rules:**
- **Ids:** empty or duplicate question ids become `q<n>` by position. Empty or duplicate option ids become `o<n>` within the question.
- **Recommended:** entries that don't name an existing option are dropped.
- **Malformed choices:** `single` or `multi` with fewer than 2 options, or `toggle` with a number of options other than 1, becomes `text`. Its option labels are appended to `text` as `" (e.g. A, B)"` when there are any, and its options are cleared.
- **Other:** `allowOther` is forced to true for `single` and `multi`.

**Decoding:** the decoder accepts an item that is a plain JSON string, as live output from an older prompt and the existing fixtures do, and maps it to `.text(id:)`.

**Prompt (:207-211):** ask the agent to prefer `single` or `multi` with 2 to 5 short options and a `recommended` pick when there is a sensible default. `toggle` is for a yes/no about one thing. `text` is only for answers no list could cover. Ids are `q1`, `q2` and so on, and option ids are short slugs.

- [ ] **Step 1: Write the failing tests** in `TriageTests`:
  - `testDecodesStructuredQuestions`: a single question with 3 options and `recommended: ["b"]` decodes with its kind, options and recommendation unchanged.
  - `testDecodesLegacyStringQuestions`: `"questions":["Who?"]` gives `.text`, id `q1`.
  - `testMalformedChoiceQuestionDegradesToText`: single with 1 option `"Mac"` becomes kind `.text`, with text `"Which? (e.g. Mac)"` and no options.
  - `testDuplicateIdsAreRenumbered`: questions `x,x` become `q1,q2`. Options `a,a` become `o1,o2`. `recommended: ["zz"]` is dropped.
  - `testExistingLiveFixturesStillDecode`: `triage-codex-live.jsonl` and `triage-claude-live.json` still give `.questions`, all `.text`.
  - Keep `testSchemaIsValidJSONAndStrict` passing.
  - Add `testSchemaSurvivesGeminiCompatible`: `GeminiSchema.compatible(Triage.schemaJSON)` parses, and the question kind is still an enum of 4 values.
- [ ] **Step 2:** Run the suite. Expected: the new tests fail, and `testTriageSchemaJSONUnchangedByTheRefactor` still passes against the old fixture.
- [ ] **Step 3:** Implement the schema, `Wire` (questions decoded through a custom `Decodable` item that accepts a string or an object), `normalize`, the prompt text, and the exchange append at `IntakeService.swift:2329`. Regenerate `triage-schema.json` from `Triage.schemaJSON`.
- [ ] **Step 4:** Run the suite. Expected: everything is green, including the updated schema fixture test and `IntakeServiceTests.testCaptureRunsTriageAndStoresQuestions`. Update that test's expectation from strings to `structured` if it compares question values.
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/IntakeKit/Triage.swift Sources/FlightDeck/Intake/IntakeService.swift Tests/FlightDeckTests/Intake/TriageTests.swift Tests/FlightDeckTests/Fixtures/Intake/triage-schema.json
  git commit -m "feat: triage asks clarifying questions as choices, and still reads plain ones"
  ```

### Task 3: Answering with structured answers on the Mac service

**Files:**
- Modify: `Sources/FlightDeck/Intake/IntakeService.swift`. Change `answer` (:968), `AnswerDrafts`, `saveAnswerDrafts` and `answerDrafts` (:984-1012).
- Test: `Tests/FlightDeckTests/Intake/IntakeServiceTests.swift`.

**Interfaces:**
- Consumes: `presentedQuestions`, `isComplete`, `render` and `initialAnswer` from Task 1.
- Produces:
  - `@discardableResult func answer(_ id: UUID, structured: [StructuredAnswer]) -> AnswerRefusal?`, with `enum AnswerRefusal: String { case notAwaitingAnswers = "not_awaiting_answers", unknownQuestion = "unknown_question", incomplete = "invalid_answer" }`.
  - `func answer(_ id: UUID, answers: [String])` stays as a wrapper that maps each string to a text answer, `StructuredAnswer(questionID: q.id, selected: [], other: s)`.
  - `func saveAnswerDrafts(_ id: UUID, round: Int, answers: [StructuredAnswer])`.
  - `func answerDrafts(_ id: UUID, round: Int) -> [StructuredAnswer]?`, where `round` is the index of the open exchange.
- **Behaviour:** check that every presented question has exactly one answer with a matching id, and that each is complete. Then write `structuredAnswers` and `answers = zip(questions, answers).map(render)`, and pass the rendered strings to `runTriage(.answers(questions:answers:))`, which is unchanged.
- **Drafts file:** it gains `round: Int?` and `structured: [StructuredAnswer]?`. An old drafts file, with strings only, loads as text answers when its `questions` still equal the open round's question texts.

- [ ] **Step 1: Write the failing tests:**
  - `testStructuredAnswerRendersIntoPlainAnswersForRounds`: an open round with a single question (options mac and any) and a text question, answered `[mac]` and `"soon"`. Then `exchanges.last.answers == ["Only this Mac", "soon"]`, `structuredAnswers` is stored, and the triage turn receives those strings.
  - `testIncompleteOrUnknownAnswersAreRefused`: a blank text answer gives `.incomplete`, an answer for id `q9` gives `.unknownQuestion`, and nothing is saved.
  - `testLegacyStringAnswerStillWorks`: the old `answer(_:answers:)` on a legacy round stores both arrays.
  - `testStructuredDraftsSurviveAFreshService`: modelled on `testAnswerDraftsSurviveAFreshServiceOnlyForTheSameQuestions`.
  - `testOldStringDraftsFileStillLoads`.
- [ ] **Step 2:** Run the suite. Expected: compile failures, because `answer(_:structured:)` doesn't exist yet.
- [ ] **Step 3:** Implement as described in the Interfaces block.
- [ ] **Step 4:** Run the suite. Expected: green, including the existing answer and draft tests.
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/FlightDeck/Intake/IntakeService.swift Tests/FlightDeckTests/Intake/IntakeServiceTests.swift
  git commit -m "feat: the Mac takes structured answers and hands rounds the same plain answers as before"
  ```

### Task 4: StructuredQuestionView on the Mac

**Files:**
- Create: `Sources/FlightDeck/Intake/Planning/StructuredQuestionView.swift`.
- Modify: `Sources/FlightDeck/Intake/IntakeDetailView.swift`. Change `@State answers` (:47), `needsAnswersBody` (:628-670), `canSendAnswers` (:685) and `performPrimary` (:1117-1121).
- Test: `Tests/FlightDeckTests/Intake/IntakeDetailViewTests.swift` and `IntakeDetailViewRenderTests.swift`.

**Interfaces:**
- Consumes: Task 1 (`presentedQuestions`, `initialAnswer`, `isComplete`) and Task 3 (`answer(_:structured:)`, the structured drafts).
- Produces: `struct StructuredQuestionView: View { let question: StructuredQuestion; @Binding var answer: StructuredAnswer }`. The P1 thread panel will reuse it.
- **Layout:**
  - single: radio rows (`Picker(.radioGroup)` or a custom row style), each showing its label and its `detail` as a secondary line;
  - multi: checkbox rows;
  - toggle: a `Toggle` with the option's label;
  - text: a multi-line `TextField(axis: .vertical)`.

  Single and multi end with an "Other…" row that shows a text field when chosen. The recommended option has a trailing "recommended" caption in the secondary colour. A choice question starts from `initialAnswer`, which means the recommendation is already selected.
- `IntakeDetailView` replaces `@State answers: [String]` with `@State structuredAnswers: [StructuredAnswer]`. `canSendAnswers` becomes "every question `isComplete`". ⌘↩ and the "Send Answers" button are unchanged.

- [ ] **Step 1: Write the failing tests:**
  - `IntakeDetailViewTests.testAnyIncompleteAnswerBlocksSending`, replacing `testAnyBlankAnswerBlocksSending`. A blank text question blocks sending. A multi question with nothing selected doesn't. A single question with nothing selected and no "Other" text blocks.
  - `IntakeDetailViewRenderTests.testRenderStructuredQuestions`: render a round with one single, one multi, one toggle and one text question offscreen with `layer.render(in:)`, using the existing harness, and save the PNG under `.superpowers/renders/p0/`. Assert the view's size is non-zero and that it shows a "recommended" label.
- [ ] **Step 2:** Run the suite. Expected: compile failure, because `StructuredQuestionView` doesn't exist.
- [ ] **Step 3:** Implement the view and its wiring.
- [ ] **Step 4:** Run the suite. Expected: green. **Open the PNG and look at it.** Radio, checkbox, toggle and text are each visibly distinct, and the recommendation is marked. Attach the path in the task report.
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/FlightDeck/Intake/Planning/StructuredQuestionView.swift Sources/FlightDeck/Intake/IntakeDetailView.swift Tests/FlightDeckTests/Intake/IntakeDetailViewTests.swift Tests/FlightDeckTests/Intake/IntakeDetailViewRenderTests.swift
  git commit -m "feat: answer clarifying questions on the Mac by choosing, with Other for anything else"
  ```

### Task 5: The wire: projection, capability flag and the `intake.answer` op

**Files:**
- Modify: `Sources/FleetKit/IntakeWire.swift`. Change `WireQuestions` (:342), and add `structuredQuestions: Bool?` to `WireIntakeDetail` (:75-112).
- Modify: `Sources/FleetKit/Frames.swift`. Add `case intakeAnswer` beside `intakeSetNoteKind` (:308), with its raw name, encode and decode arms.
- Modify: `Sources/FlightDeck/Fleet/IntakeDetailProjection.swift:121-149`.
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift:1438-1450` (dispatch).
- Modify: `Sources/FlightDeck/Intake/IntakeService.swift`, adding `phoneAnswer` beside `phoneSetNoteKind` (:1415).
- Test: `Tests/FlightDeckTests/IntakeWireCodingTests.swift`, `IntakeDetailProjectionTests.swift`, and `Tests/FlightDeckTests/Intake/IntakePhoneCommandTests.swift`.

**Interfaces:**
- Consumes: Task 3 (`answer(_:structured:) -> AnswerRefusal?`).
- Produces, all in FleetKit:
  ```swift
  public struct WireStructuredQuestion: Codable, Equatable, Sendable { public var id, text, kind: String; public var options: [WireOption]; public var recommended: [String]; public var allowOther: Bool }
  public struct WireOption: Codable, Equatable, Sendable { public var id, label: String; public var detail: String? }
  public struct WireStructuredAnswer: Codable, Equatable, Sendable { public var questionID: String; public var selected: [String]; public var other: String? }
  // WireQuestions gains: public var round: Int?; public var structured: [WireStructuredQuestion]?   (round = index of the open exchange)
  // WireIntakeDetail gains: public var structuredQuestions: Bool?
  // FleetCommand: case intakeAnswer(intakeID: UUID, round: Int, answers: [WireStructuredAnswer], token: String)   raw "intake.answer"
  ```
  `kind` is a `String` on the wire, so a later kind never breaks an old phone's decode. On the Mac, `func phoneAnswer(_ id: UUID, round: Int, answers: [WireStructuredAnswer], token: String) -> String?` returns an error code or nil. It uses the existing `alreadyAccepted` / `accept` token de-duplication.
  - It returns `stale_questions` when `round` is not the open exchange's index, or the intake isn't `.needsAnswers`.
  - Otherwise it passes on `AnswerRefusal.rawValue`.
- **Projection:** for the open round, `structured` is always filled from `presentedQuestions`, so legacy string rounds arrive as text questions. `round` is `exchanges.count - 1`. The Mac sets `structuredQuestions: true`.

- [ ] **Step 1: Write the failing tests:**
  - `IntakeWireCodingTests.testADetailRoundTripsEveryNestedType`: extend it to cover `structured`, `round` and `structuredQuestions`.
  - Add `testAnOldPhonePayloadWithoutStructuredFieldsDecodes`.
  - Add `testIntakeAnswerCommandRoundTrips`.
  - `IntakeDetailProjectionTests.testNeedsAnswersCarriesStructuredOpenRound` and `testLegacyOpenRoundProjectsAsTextQuestions`.
  - `IntakePhoneCommandTests.testPhoneAnswerAnswersTheOpenRound`.
  - Add `testPhoneAnswerForAnEarlierRoundIsRefusedAsStale`: answer on the Mac, append a second open round, then send a phone answer for `round: 0`. The result is `"stale_questions"`, and round 1 is still unanswered.
  - Add `testPhoneAnswerTokenIsIdempotent`.
- [ ] **Step 2:** Run the suite. Expected: compile failures.
- [ ] **Step 3:** Implement the wire types, the command case with **all** its arms, the dispatch, `phoneAnswer` and the projection, in one commit.
- [ ] **Step 4:** Run the suite. Expected: green. Also run `./scripts/build-ios.sh`. Expected: FleetKitiOS and FlightDeckMobile build. The phone doesn't send the op yet.
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/FleetKit/IntakeWire.swift Sources/FleetKit/Frames.swift Sources/FlightDeck/Fleet/IntakeDetailProjection.swift Sources/FlightDeck/Fleet/FleetService.swift Sources/FlightDeck/Intake/IntakeService.swift Tests/FlightDeckTests/IntakeWireCodingTests.swift Tests/FlightDeckTests/IntakeDetailProjectionTests.swift Tests/FlightDeckTests/Intake/IntakePhoneCommandTests.swift
  git commit -m "feat: the phone can answer clarifying questions over a capability-gated intake.answer"
  ```

### Task 6: Answering on the phone, plus docs

**Files:**
- Create: `Sources/FlightDeckMobile/StructuredQuestionForm.swift`, flat.
- Create: `Sources/FleetKit/StructuredAnswerRules.swift`. It holds the pure completeness and initial-answer rules over wire types, mirroring Task 1, so the phone's Send button agrees with the Mac. The Mac stays authoritative.
- Modify: `Sources/FlightDeckMobile/IntakeScreen.swift:176-189`, which currently reads "Answer on your Mac for now", and `IntakeCommands.swift:17`.
- Modify docs: `docs/ARCHITECTURE.md` (the triage Q&A paragraph and the `intake.answer` op), `docs/HANDOFF-plan-notes.md` (the Question note kind is unchanged in P0; mention that structured questions exist), and a new `docs/FLIGHT-CONTROL-PLANNING-V2-CHECKLIST.md` with a "P0" section.
- Test: `Tests/FlightDeckMobileTests/StructuredAnswerRulesTests.swift`, plus `IntakeRenderHarness` gets `testDrawStructuredQuestions`.

**Interfaces:**
- Consumes: Task 5's wire types and `intakeAnswer`.
- Produces:
  - `extension WireStructuredQuestion { public var initialAnswer: WireStructuredAnswer; public func isComplete(_ a: WireStructuredAnswer) -> Bool }`, with the same rules as Task 1.
  - `struct StructuredQuestionForm: View` (questions, bindings, `onSend`).
- **Behaviour:**
  - When `detail.structuredQuestions == true` and the intake needs answers, `IntakeScreen` shows the form instead of the read-only list. Otherwise it keeps today's "Answer on your Mac for now".
  - Send issues `intakeAnswer` with a fresh token. The form shows "Sending…" and is disabled until the projection leaves `.needsAnswers` or its `round` changes. An error code shows inline: `stale_questions` reads "These questions changed. Here are the new ones." and reloads the form.

- [ ] **Step 1: Write the failing tests:**
  - `StructuredAnswerRulesTests`: the same cases as Task 1's completeness and initial-answer tests, over wire types.
  - `testDrawStructuredQuestions`: render the form and save the PNG under `.superpowers/renders/p0/`.
- [ ] **Step 2:** Run `./scripts/test-ios.sh`. Expected: compile failure.
- [ ] **Step 3:** Implement the rules, the form and the `IntakeScreen` wiring, then update the docs and add the checklist. The checklist's P0 entries:
  - **Mac:** a new intake asks choice questions; the recommendation is preselected; Other works; ⌘↩ sends; a legacy intake's open round is answerable.
  - **Phone:** the form appears for the intake; Send gives "Sending…" and then the next stage; answering on the Mac first, then sending from the phone, shows "These questions changed."
- [ ] **Step 4:** Run `./scripts/test-ios.sh` and `./scripts/test-unit.sh`. Expected: both green. **Open the phone PNG and look at it.** Run `./scripts/build.sh`. Expected: the Debug app builds. Do not launch it.
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/FleetKit/StructuredAnswerRules.swift Sources/FlightDeckMobile/StructuredQuestionForm.swift Sources/FlightDeckMobile/IntakeScreen.swift Sources/FlightDeckMobile/IntakeCommands.swift Tests/FlightDeckMobileTests/StructuredAnswerRulesTests.swift Tests/FlightDeckMobileTests/IntakeRenderHarness.swift docs/ARCHITECTURE.md docs/HANDOFF-plan-notes.md docs/FLIGHT-CONTROL-PLANNING-V2-CHECKLIST.md
  git commit -m "feat: answer clarifying questions from the phone"
  ```

**After Task 6:** a whole-branch review, then merge `planning-v2-p0` into master through `.superpowers/merge.lock` with `--ff-only`. Report the checklist's P0 GUI entries as unverified until the maintainer runs them.
