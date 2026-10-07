import XCTest
@testable import FleetKit

/// The splitting rule, run over a real plan.
///
/// **The fixture is a capture**, per the `*.captured.*` convention: it is the verbatim
/// `GET /api/plan` response from `plannotator` pid 18418 on 2026-08-29, taken while the gate
/// was open. A plan authored by whoever wrote the splitter agrees with the splitter by
/// construction and proves nothing.
final class PlanBlocksTests: XCTestCase {

    private func capturedPlan() throws -> String {
        let url = try XCTUnwrap(Bundle(for: PlanBlocksTests.self).url(
            forResource: "plan-gate.captured", withExtension: "json",
            subdirectory: "Fixtures/Plannotator"
        ), "Fixtures/Plannotator/plan-gate.captured.json not found in the test bundle")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(root["plan"] as? String)
    }

    /// **The property the whole feature rests on.** Plannotator pins a comment by matching
    /// `originalText` as a verbatim substring of the plan. A block that is not one cannot be
    /// pinned, and the comment would silently fall back to sidebar-only.
    func testEveryBlockIsAVerbatimSubstringOfThePlan() throws {
        let plan = try capturedPlan()
        for block in PlanBlocks.split(plan).blocks {
            XCTAssertTrue(plan.contains(block.text),
                          "block \(block.index) is not a substring: \(block.text.prefix(60))")
        }
    }

    /// A target must occur exactly once, or the highlight lands on whichever copy the
    /// matcher happened to reach first.
    func testEveryTargetOccursExactlyOnce() throws {
        let plan = try capturedPlan()
        for block in PlanBlocks.split(plan).blocks where block.isTarget {
            XCTAssertEqual(PlanBlocks.occurrences(of: block.text, in: plan, stoppingAt: 2), 1,
                           "target \(block.index) is ambiguous: \(block.text.prefix(60))")
        }
    }

    /// The measured shape of this exact capture. Pins the rule against drift.
    func testCapturedPlanSplitsIntoTheMeasuredShape() throws {
        let plan = try capturedPlan()
        let split = PlanBlocks.split(plan)
        XCTAssertEqual(plan.count, 6342)
        XCTAssertEqual(split.blocks.count, 39)
        XCTAssertEqual(split.blocks.filter(\.isTarget).count, 38)
        XCTAssertEqual(split.blocks.first?.text, "# Surface Failure and Respawn — Plan 1 of 2")
    }

    /// A fence's own blank lines are not block separators. Splitting inside one would produce
    /// two halves of a code block, neither of which reads as code.
    func testFencedCodeSurvivesItsBlankLines() {
        let plan = """
        Intro paragraph.

        ```swift
        let a = 1

        let b = 2
        ```

        Outro paragraph.
        """
        let blocks = PlanBlocks.split(plan).blocks
        XCTAssertEqual(blocks.count, 3)
        XCTAssertTrue(blocks[1].text.contains("let a = 1"))
        XCTAssertTrue(blocks[1].text.contains("let b = 2"))
    }

    /// List items split individually. Measured better on real plans than keeping a list whole:
    /// 4.9% non-unique versus 6.5%, at finer granularity.
    func testListItemsAreSeparateBlocks() {
        let plan = """
        Preamble here.

        - first item
        - second item
        - third item
        """
        let blocks = PlanBlocks.split(plan).blocks
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[1].text, "- first item")
        XCTAssertEqual(blocks[3].text, "- third item")
    }

    /// 229 of 6,442 blocks across 120 real plans were thematic breaks. There is no prose on
    /// one to comment about, and `---` is the single most common non-unique block by far.
    func testThematicBreakIsNeverATarget() {
        let plan = "One paragraph.\n\n---\n\nAnother paragraph.\n\n---\n\nA third."
        let blocks = PlanBlocks.split(plan).blocks
        for block in blocks where block.text.trimmingCharacters(in: .whitespaces) == "---" {
            XCTAssertFalse(block.isTarget)
        }
        XCTAssertEqual(blocks.filter(\.isTarget).count, 3)
    }

    /// A repeated block is refused rather than pinned to an arbitrary copy — the same
    /// "refuse rather than improvise" ruling `AnswerPlan.plan(for:answers:)` makes.
    func testARepeatedBlockIsNotATarget() {
        let plan = "**Assertions:**\n\nSomething unique.\n\n**Assertions:**\n\nSomething else."
        let blocks = PlanBlocks.split(plan).blocks
        let repeated = blocks.filter { $0.text == "**Assertions:**" }
        XCTAssertEqual(repeated.count, 2)
        XCTAssertTrue(repeated.allSatisfy { !$0.isTarget })
        XCTAssertEqual(blocks.filter(\.isTarget).count, 2)
    }

    /// **A 300 KB plan splits without freezing the phone.** The phone builds a review on the
    /// tap, on the main thread, and a real plan of this size — 6,727 lines, 931 blocks — froze
    /// it: each block's "occurs exactly once" check scanned the whole plan with
    /// `String.range(of:)`, 3.9s optimised on an M-series Mac (0.16s after). This synthetic one
    /// has 5,540 blocks and took 25s unoptimised before the fix, 0.8s after; the bound is loose
    /// because this suite runs unoptimised on a machine that is often busy. Synthetic rather
    /// than the plan that hit it, which belongs to another project.
    func testAPlanOfThreeHundredKilobytesSplitsWithoutFreezing() {
        var sections: [String] = []
        var i = 0
        while sections.joined(separator: "\n\n").utf8.count < 300_000 {
            sections.append("""
            ## Task \(i): wire the lane \(i) adapter

            Step \(i) moves the encapsulation boundary for group \(i) and keeps its tests green.

            - [ ] Write the failing test for lane \(i)
            - [ ] Make it pass without touching lane \(i + 1)

            ```swift
            func lane\(i)() -> Int {
                return \(i) * 2
            }
            ```
            """)
            i += 1
        }
        let plan = sections.joined(separator: "\n\n")
        let started = Date()
        let blocks = PlanBlocks.split(plan).blocks
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(blocks.count, 3_000)
        XCTAssertLessThan(elapsed, 3.0, "split took \(elapsed)s")
    }

    /// The count the targets rest on: matches do not overlap, it stops at the limit, and a
    /// non-ASCII needle is found where it is.
    func testOccurrencesCountsNonOverlappingMatchesAndStopsAtTheLimit() {
        XCTAssertEqual(PlanBlocks.occurrences(of: "aa", in: "aaa", stoppingAt: 2), 1)
        XCTAssertEqual(PlanBlocks.occurrences(of: "aa", in: "aaaa", stoppingAt: 5), 2)
        XCTAssertEqual(PlanBlocks.occurrences(of: "ab", in: "ab ab ab", stoppingAt: 2), 2)
        XCTAssertEqual(PlanBlocks.occurrences(of: "", in: "abc", stoppingAt: 2), 0)
        XCTAssertEqual(PlanBlocks.occurrences(of: "abcd", in: "abc", stoppingAt: 2), 0)
        XCTAssertEqual(PlanBlocks.occurrences(of: "→ é 👩‍💻", in: "x → é 👩‍💻 y", stoppingAt: 2), 1)
    }

    /// Index lookup is bounds-checked, because it is reached from a wire command.
    func testBlockAtIndexRefusesOutOfRange() {
        let split = PlanBlocks.split("Only one block.")
        XCTAssertEqual(split.block(at: 0)?.text, "Only one block.")
        XCTAssertNil(split.block(at: 1))
        XCTAssertNil(split.block(at: -1))
    }
}
