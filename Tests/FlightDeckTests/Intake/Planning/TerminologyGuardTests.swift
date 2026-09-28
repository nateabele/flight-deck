import XCTest
import IntakeKit
@testable import FlightDeck

/// A lightweight, comment-and-interpolation-aware scanner over every `"…"` literal in
/// `Sources/FlightDeck/**/*.swift` — the guard behind spec §2's "tasks, never beads", the
/// Flight Control rename, and the "agent, never seat" rename. Deliberately not a real Swift
/// lexer: it tracks just enough state (quotes, `\"` escapes, `\(…)` interpolation depth, `"""`
/// blocks, and `//` comments) to find every literal without one.
enum TerminologyScan {
    /// `\bbeads?\b`, `\bflywheel\b` or `\bseats?\b`, case-insensitive. `agent-flywheel` (the
    /// external methodology's proper name) and any URL are masked out before this runs — see
    /// `offense`. `seat`/`seats` is the user-facing word for one model run doing one role in a
    /// round; the type/property names (`SeatRow`, `seatActivities`…), file names, persisted
    /// paths (`runs/<run>`), accessibility IDENTIFIERS, test names and IntakeKit's agent-facing
    /// prompts all keep "seat" on purpose and never appear as a scanned string literal, so they
    /// need no allow-list entry — see `isExempt(line:)`'s `accessibilityIdentifier(` skip and
    /// `codeLineOffenses`'s `\(…)` interpolation collapse, which already erase both.
    private static let bannedWord = try! NSRegularExpression(
        pattern: "\\b(beads?|flywheel|seats?)\\b", options: [.caseInsensitive]
    )
    private static let agentFlywheel = try! NSRegularExpression(
        pattern: "agent[- ]flywheel(\\.com)?", options: [.caseInsensitive]
    )
    private static let url = try! NSRegularExpression(pattern: "https?://\\S+")

    /// True internals that legitimately say "bead"/"beads"/"flywheel" in a string literal —
    /// argv, on-disk paths, thread ids, and agent-facing prompt text. Spec §2 names `br`,
    /// `.beads/`, `BeadWriter`, schemas, agent prompts and logs as internals that keep the
    /// word; these are the literals that say it but land somewhere the line-level skips in
    /// `isExempt(line:)` don't reach (mainly: a continuation line of a multi-line array/`+`
    /// concatenation, where the line itself never mentions `argv`/`args`/a path call).
    ///
    /// Each key is the literal's *template*: every `\(…)` interpolation collapsed to a single
    /// `$`, so an entry matches regardless of the interpolated expression's exact spelling.
    static let internalAllowList: Set<String> = [
        // SessionStore.observeWatchPaths: the on-disk `.beads` store the file watcher polls —
        // a path, never rendered. (Also caught by `isExempt(line:)`'s path-component rule;
        // kept here too since the brief calls these out as the allow list's first entries.)
        ".beads",
        "beads.db",
        "beads.db-wal",

        // IntakeDelivery.deliver: the Agent-Mail `--thread-id` value groups a bead's mail
        // thread by its internal id — a wire key, never rendered as prose. It's a standalone
        // array element, so the same-line `argv` skip (the array's `var argv = [...]` is a
        // different physical line) never reaches it.
        "bead:$",
        // IntakeDelivery.reclaimFailedInjectText: text injected into an AGENT's own session
        // (`inject(...)`), never shown to the human user — spec §2 exempts agent prompts.
        "or reply on the Agent Mail thread bead:$.",

    ]

    /// Literals exempt in ONE file only. A bare `"beads"` anywhere else is exactly the kind of
    /// literal the guard exists to catch; allowing it app-wide exempted every future one too.
    static let fileAllowList: [String: Set<String>] = [
        // ObserveDrawer's lane keys and FlywheelProjection's `lanesUnavailable` both use
        // "beads" as the snapshot-field key the two correlate on — never displayed.
        "ObserveDrawer.swift": ["beads"],
        "FlywheelProjection.swift": ["beads"],
    ]

    /// IntakeKit files whose literals are all agent- or `br`-facing: prompts and schemas an agent
    /// reads, mail and injected text sent to an agent, and `br` argv/paths (spec §2 keeps the
    /// word there). Every other IntakeKit file is scanned — its strings reach the human as a
    /// failure, a diagnosis or a summary, and the app-side sweep can't see them.
    static let agentFacingIntakeKitFiles: Set<String> = [
        "Triage.swift", "RoundPrompts.swift", "DeliveryPlanner.swift", "ShadowGraph.swift",
    ]

    static func offenders(under root: URL, allow: Set<String>, skipping skipped: Set<String> = []) throws -> [String] {
        var offenses: [String] = []
        for file in try swiftFiles(under: root) where !skipped.contains(file.lastPathComponent) {
            offenses += try scan(file: file, allow: allow.union(fileAllowList[file.lastPathComponent] ?? []))
        }
        return offenses
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    /// A line-level reason to skip every literal on it entirely, before even extracting them —
    /// the brief's own skip list: `Logger`/`logger.` calls, accessibility identifiers, argv
    /// construction, and the `br` executable name. Deliberately does NOT include `.beads`/
    /// `beads.db` here: those are path fragments that belong to one specific literal, not the
    /// whole line, and a whole-line substring check on them false-positives on unrelated code
    /// that merely mentions a `beads`-prefixed property (e.g. `status.beadsSyncHooksInstalled`)
    /// while a genuine, renamable literal sits right next to it on the same line — see
    /// `isPathFragment(_:)`, which checks the literal itself instead.
    private static func isExempt(line: String) -> Bool {
        let needles = ["Logger", "logger.", "accessibilityIdentifier(", "\"br\""]
        let lowered = line.lowercased()
        return needles.contains { lowered.contains($0.lowercased()) }
            || argvWord.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// `argv`/`args` as whole words: a bare substring match exempted any line that merely said
    /// "targets" or "largest", along with whatever user-visible literal sat on it.
    private static let argvWord = try! NSRegularExpression(pattern: "\\b(argv|args)\\b")

    /// True for a literal that IS an on-disk path fragment (SessionStore's `.beads` watch path,
    /// `beads.db`/`beads.db-wal`, or anything built via `.appendingPathComponent(`) — checked
    /// against the literal's own text, not the surrounding line, so it can't be tripped by an
    /// unrelated identifier elsewhere on the same line.
    private static func isPathFragment(_ normalized: String, line: String) -> Bool {
        if line.contains(".appendingPathComponent(") { return true }
        return normalized.contains(".beads") || normalized.contains("beads.db")
    }

    private static func scan(file: URL, allow: Set<String>) throws -> [String] {
        let contents = try String(contentsOf: file, encoding: .utf8)
        var offenses: [String] = []
        var inTripleQuote = false

        for (index, rawLine) in contents.components(separatedBy: "\n").enumerated() {
            let lineNumber = index + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if inTripleQuote {
                // A `"""` block's own lines are all literal text (no further `\(…)` handling
                // needed here — none of this codebase's multi-line strings interpolate), so
                // just look for the closer and otherwise scan the whole line as one literal.
                if let range = rawLine.range(of: "\"\"\"") {
                    inTripleQuote = false
                    offenses += codeLineOffenses(String(rawLine[range.upperBound...]),
                                                  file: file, lineNumber: lineNumber, allow: allow)
                } else {
                    offenses += offense(rawLiteral: rawLine, normalized: rawLine, line: rawLine,
                                         file: file, lineNumber: lineNumber, allow: allow)
                }
                continue
            }

            if trimmed.hasPrefix("//") { continue } // a whole-line (or `///`) comment

            if let start = rawLine.range(of: "\"\"\"") {
                inTripleQuote = true
                offenses += codeLineOffenses(String(rawLine[..<start.lowerBound]),
                                              file: file, lineNumber: lineNumber, allow: allow)
                continue
            }

            offenses += codeLineOffenses(rawLine, file: file, lineNumber: lineNumber, allow: allow)
        }
        return offenses
    }

    /// Extracts every `"…"` literal from one line of ordinary code, honoring `\"`/`\\` escapes
    /// and `\(…)` interpolation (walked with a paren counter, since an interpolation can itself
    /// contain nested parens or strings — e.g. `\(Int(x))`), and stops at an un-quoted `//`
    /// trailing comment.
    private static func codeLineOffenses(_ line: String, file: URL, lineNumber: Int, allow: Set<String>) -> [String] {
        var offenses: [String] = []
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if chars[i] == "/" && i + 1 < chars.count && chars[i + 1] == "/" { break }
            guard chars[i] == "\"" else { i += 1; continue }
            var raw = "", normalized = ""
            i += 1
            while i < chars.count && chars[i] != "\"" {
                if chars[i] == "\\" && i + 1 < chars.count {
                    if chars[i + 1] == "(" {
                        i += 2
                        var depth = 1
                        while i < chars.count && depth > 0 {
                            if chars[i] == "(" { depth += 1 } else if chars[i] == ")" { depth -= 1 }
                            i += 1
                        }
                        normalized += "$"
                        continue
                    }
                    let decoded: Character = chars[i + 1] == "\"" ? "\"" : (chars[i + 1] == "\\" ? "\\" : chars[i + 1])
                    raw.append(decoded); normalized.append(decoded)
                    i += 2
                    continue
                }
                raw.append(chars[i]); normalized.append(chars[i])
                i += 1
            }
            i += 1 // closing quote
            offenses += offense(rawLiteral: raw, normalized: normalized, line: line,
                                 file: file, lineNumber: lineNumber, allow: allow)
        }
        return offenses
    }

    private static func offense(
        rawLiteral: String, normalized: String, line: String,
        file: URL, lineNumber: Int, allow: Set<String>
    ) -> [String] {
        guard !isExempt(line: line), !isPathFragment(normalized, line: line), !allow.contains(normalized) else { return [] }
        var masked = normalized as NSString
        for pattern in [agentFlywheel, url] {
            masked = pattern.stringByReplacingMatches(in: masked as String, range: NSRange(location: 0, length: masked.length),
                                                        withTemplate: "") as NSString
        }
        guard bannedWord.firstMatch(in: masked as String, range: NSRange(location: 0, length: masked.length)) != nil else {
            return []
        }
        return ["\(file.lastPathComponent):\(lineNumber): \"\(rawLiteral)\""]
    }
}

final class TerminologyGuardTests: XCTestCase {
    func testNoUserVisibleStringSaysBead() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // …/Tests/FlightDeckTests/Intake/Planning
            .appendingPathComponent("../../../../Sources/FlightDeck").standardized
        let offenders = try TerminologyScan.offenders(under: root, allow: TerminologyScan.internalAllowList)
        XCTAssertEqual(offenders, [], offenders.joined(separator: "\n"))
    }

    /// IntakeKit's own user-facing strings — validation failures, round diagnoses, summaries —
    /// reach the sheet, the board and the failed seat row, and the app-side sweep above never
    /// read them: "is not a bead in the graph" and "Could not read the bead graph" both shipped.
    func testNoUserVisibleIntakeKitStringSaysBead() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Sources/IntakeKit").standardized
        let offenders = try TerminologyScan.offenders(under: root, allow: TerminologyScan.internalAllowList,
                                                      skipping: TerminologyScan.agentFacingIntakeKitFiles)
        XCTAssertEqual(offenders, [], offenders.joined(separator: "\n"))
    }

    /// The validator's words are two: `message` goes back to the agent verbatim (its own schema
    /// says createBead/tempId), `userMessage` is what a twice-failed change set shows the human.
    func testValidationFailuresShownToTheHumanSayTask() {
        let all: [ValidationError] = [.unknownBead("fd-1"), .undefinedTempId("t1"), .duplicateTempId("t1"),
                                      .selfEdge("fd-1"), .cycle, .missingDelivery("fd-1"), .preconditionMismatch("fd-1")]
        for error in all {
            let text = error.userMessage.lowercased()
            for word in ["bead", "tempid", "createbead", "followup", "addedge", "editbead", "new:"] {
                XCTAssertFalse(text.contains(word), "\(error): \(error.userMessage)")
            }
        }
    }

    /// The `\bargs\b` exemption is a word, not a substring.
    func testArgsExemptionIsAWholeWord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TerminologyScan-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        let largest = "the largest bead"
        let args = ["bead"]
        let copy = "beads"
        """.write(to: dir.appendingPathComponent("Probe.swift"), atomically: true, encoding: .utf8)
        let offenders = try TerminologyScan.offenders(under: dir, allow: TerminologyScan.internalAllowList)
        XCTAssertEqual(offenders.count, 2, offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders[0].contains("largest bead"))
        XCTAssertTrue(offenders[1].contains("\"beads\""), "a bare \"beads\" is allowed in its two files only")
    }

    func testUIText() {
        XCTAssertEqual(UIText.presetName(.bead), "Single task")
        XCTAssertEqual(UIText.releaseButton(ReleaseCounts([.createBead(NewBead(tempId: "a", title: "A", description: ""))])),
                       "Release 1 New Task")
    }

    /// The release review sheet's title, sections, and the button it defaults to (spec §10).
    func testReleaseButtonTitle() {
        XCTAssertEqual(UIText.releaseSheetTitle, "Release plan as tasks")
        XCTAssertEqual(UIText.newTasksSection, "New tasks")
        XCTAssertEqual(UIText.editsSection, "Edits")
        XCTAssertEqual(UIText.dependenciesSection, "Dependencies")
        XCTAssertEqual(UIText.droppedCount(2), "2 dropped")
        XCTAssertEqual(UIText.notesCarried(1), "1 note carried into task notes")
        XCTAssertEqual(UIText.notesCarried(2), "2 notes carried into task notes")
    }

    /// Guards the exact defect T14 found: `ReleaseSummary` lives in `Sources/IntakeKit`, outside
    /// `TerminologyScan`'s `Sources/FlightDeck` sweep, so its footer text once said "bead" with
    /// nothing to catch it — this pins the sheet's actual runtime string, not just `UIText`'s.
    func testReleaseSheetHasNoBeadWording() {
        let ops: [ChangeOp] = [.createBead(NewBead(tempId: "n1", title: "n", description: "d"))]
        let footer = ReleaseSummary.text(
            ops, drift: [.holds], dropped: [], ratings: [:], hasSession: { _ in true })
        XCTAssertFalse(footer.lowercased().contains("bead"), "release footer must say task, not bead: \(footer)")

        for s in [UIText.releaseSheetTitle, UIText.newTasksSection, UIText.editsSection,
                  UIText.dependenciesSection, UIText.notesCarried(1)] {
            XCTAssertFalse(s.lowercased().contains("bead"), "\(s) must say task, not bead")
        }
    }
}
