import XCTest
import IntakeKit
@testable import FlightDeck

@MainActor
final class BeadWriterFidelityTests: XCTestCase {
    private func descriptionArg(_ r: RecordingRunner) -> String? {
        guard let call = r.calls.first(where: { $0.dropFirst().first == "create" }),
              let i = call.firstIndex(of: "--description") else { return nil }
        return call[i + 1]
    }

    func testACitedVisualAddsTheFidelitySection() async {
        let r = RecordingRunner(replies: ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)])
        let w = BeadWriter(runner: r, actor: "a", planSlug: "my-plan")
        let bead = NewBead(tempId: "n1", title: "T", description: "Build it.",
                           visualRefs: [VisualRef(visualID: "pairing", states: ["default", "error"])])
        let out = await w.apply([.create(bead)], project: "/p")
        XCTAssertNil(out.error)
        XCTAssertEqual(descriptionArg(r), """
        Build it.

        Fidelity references (implement to match; don't redesign):
        - docs/plans/my-plan/visuals/pairing/ \u{2014} states: default, error
        """)
    }

    func testNoRefsOrNoSlugLeavesTheDescriptionAlone() async {
        for (slug, refs) in [(String?.none, [VisualRef(visualID: "a")]), ("s", nil), ("s", [])] as [(String?, [VisualRef]?)] {
            let r = RecordingRunner(replies: ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)])
            _ = await BeadWriter(runner: r, actor: "a", planSlug: slug)
                .apply([.create(NewBead(tempId: "n1", title: "T", description: "Build it.", visualRefs: refs))], project: "/p")
            XCTAssertEqual(descriptionArg(r), "Build it.")
        }
    }
}
