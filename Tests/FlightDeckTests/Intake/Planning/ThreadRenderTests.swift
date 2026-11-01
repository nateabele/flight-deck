import AppKit
import IntakeKit
import SwiftUI
import Vision
import XCTest
@testable import FlightDeck

/// Renders the Ask threads' Mac surfaces for design review against the approved renders
/// (`thread-ux-v1.html`, `diff-slim-v2.html`): the rail with Ask cards, the thread panel, and a
/// proposed edit at rest and under the pointer. Written to `FD_INTAKE_RENDER_DIR`; skipped
/// without it. The plan sits beside the rail in an HStack rather than through `.inspector`, as
/// `NotesRailRenderTests` does: an offscreen render can't draw the inspector's AppKit split pane.
@MainActor
final class ThreadRenderTests: XCTestCase {
    private static let plan = """
    # Phone pairing v2

    ## 2. Session lifetime

    Paired phones keep a session token in the Keychain. Tokens never expire; the Mac revokes them explicitly from Settings → Phones. This keeps the phone usable after weeks offline.

    Reconnects are ranked by Tailscale CGNAT first, then Bonjour, so an off-LAN phone still finds the Mac.

    ## 3. Revocation

    Revoked tokens keep working until the phone next connects, then stop.

    Revoking a phone removes its key from `controllers.json` and closes any live socket within one second.

    ## 4. Failure modes

    If the exchange fails, for example from a mistyped code, the phone shows the code entry again and the pairing window stays open until it times out.
    """

    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    static let sessionSentence = "Tokens never expire; the Mac revokes them explicitly from Settings → Phones."
    /// §3's sentence, and what the diff would make of it: each unique in the plan, so a render can
    /// be read for whether the old words are on screen.
    static let oldSentence = "Revoked tokens keep working until the phone next connects, then stop."
    static let newSentence = "Revoked tokens stop working within one second, and the Mac closes the phone's socket."

    private func dir() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FD_INTAKE_RENDER_DIR"] else {
            throw XCTSkip("set FD_INTAKE_RENDER_DIR to render the thread PNGs")
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return URL(fileURLWithPath: path)
    }

    private func anchor(_ quote: String, checkpoint: Int = 2) -> NoteAnchor {
        NoteAnchor(checkpoint: checkpoint, selecting: Self.plan.range(of: quote)!, in: Self.plan)
    }

    private struct Scene {
        let store: FakeThreadStore
        let controller: PlanNotesController
        let tape: Tape
        let load: (Int, String) -> Data?
        let why: ThreadRecord
        let stale: ThreadRecord
        let diff: ThreadDiff
    }

    private func scene() -> Scene {
        let store = FakeThreadStore()
        let why = store.add("Why do tokens never expire?", section: "## 2. Session lifetime",
                            quote: Self.sessionSentence, status: .answering)
        store.records[0].anchor = ThreadAnchor(note: anchor(Self.sessionSentence))
        store.addTurn(why.id, you: "Why do tokens never expire? That feels risky for a lost phone.",
                      reply: "Because the intake requires the phone to \"keep working after weeks offline\" [cite:intake]. The Draft · R0 codex agent proposed a 7-day expiry [cite:ckpt:1], and Synthesis dropped expiry entirely. Revocation already exists: `ControllerStore.revoke` [cite:HostKit/ControllerStore.swift:88].",
                      actions: [.askQuestion(StructuredQuestion(
                          id: "q1", text: "What should happen to an idle phone?", kind: .single,
                          options: [.init(id: "30", label: "Expire after N days without a connection, then re-pair"),
                                    .init(id: "face", label: "Keep no expiry, but require Face ID to open the app"),
                                    .init(id: "keep", label: "Keep as is")],
                          recommended: ["30"], allowOther: true))])
        store.addTurn(why.id, answers: [StructuredAnswer(questionID: "q1", selected: ["30"])])
        store.addTurn(why.id, you: "First option, 30 days. Also log revocations.",
                      reply: "Done. I've proposed one edit and left one note for the next round.",
                      actions: [.proposeDiff(ProposedThreadDiff(checkpoint: 2, quote: "x", replacement: "y")),
                                .addNote(PlanNote(kind: .mustChange, note: "Log every revocation so support can see it.",
                                                  source: .thread(why.id)))])
        store.diffsByThread[why.id] = [ThreadDiff(thread: why.id, turn: 3, checkpoint: 2, anchor: anchor(Self.oldSentence),
                                                  old: Self.oldSentence, new: Self.newSentence)]
        store.live[why.id] = "reading §3 Revocation"

        let stale = store.add("Is CGNAT-first right for a home LAN?", section: "## 2. Session lifetime",
                              quote: "Tailscale CGNAT first, then Bonjour", status: .stale)
        store.records[1].anchor = ThreadAnchor(note: anchor("Tailscale CGNAT first, then Bonjour"))
        store.addTurn(stale.id, you: "Is CGNAT-first right for a home LAN?")
        store.addDiff(stale.id, state: .stale)
        let asked = store.add("Pairing failure copy", section: "## 4. Failure modes", quote: "the phone shows the code entry again")
        store.records[2].anchor = ThreadAnchor(note: anchor("the phone shows the code entry again"))
        store.addTurn(asked.id, you: "What should the failure copy say?", reply: "Two options; I need your call.",
                      actions: [.askQuestion(StructuredQuestion(id: "q2", text: "Tone?", kind: .single, options: [.init(id: "a", label: "Plain")]))])
        let done = store.add("Why SPAKE2 not QR-only?", section: "## 1. Pairing", status: .resolved)
        store.addTurn(done.id, you: "Why SPAKE2?", reply: "It resists offline guessing.")

        let notes = [PlanNote(kind: .mustChange, note: "Log every revocation so support can see it.",
                              anchor: anchor("closes any live socket within one second"), source: .thread(why.id))]
        var tape = Tape(checkpoints: [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: date),
            Checkpoint(id: 2, parent: 1, stage: .refine, round: 2, major: false, createdAt: date),
        ], target: .none, status: .paused)
        tape.pendingNotes = notes
        let plan = Self.plan
        let load: (Int, String) -> Data? = { id, file in
            (id == 1 && file == "drafts/0.md") || (id == 2 && file == "plan.md") ? Data(plan.utf8) : nil
        }
        let controller = PlanNotesController()
        controller.versionLabel = { $0 == 2 ? "Refine 2" : "Draft · R0" }
        controller.tapeNotes = TapeStore(intakeDirectory: FileManager.default.temporaryDirectory).notes(in: tape)
        controller.checkpoint = 2
        controller.threads = IntakeThreadBinding(intakeID: UUID(), reader: store, service: nil)
        return Scene(store: store, controller: controller, tape: tape, load: load, why: why, stale: stale,
                     diff: store.diffsByThread[why.id]![0])
    }

    private func layout(_ s: Scene, width: CGFloat, rail: some View) -> some View {
        HStack(alignment: .top, spacing: 0) {
            PlanSection(intakeID: UUID(), tape: s.tape, loadFile: s.load, onSend: { _ in }, notes: s.controller)
                .padding(20)
            Divider()
            rail.frame(width: width)
        }
    }

    // MARK: Rail

    func testRenderTheRailWithAskCards() throws {
        let out = try dir()
        ThreadPanelModel.forgetSession()
        let s = scene()
        let view = layout(s, width: 340, rail: NotesRail(controller: s.controller, roundName: { _ in "Refine 2" }, focusesDraft: false))
        try PlanningRender.write(view, size: NSSize(width: 1100, height: 760), to: out.appendingPathComponent("threads-rail.png"), appearance: .aqua) { host in
            XCTAssertNotNil(Self.find(PlanNSTextView.self, in: host))
        }
        try PlanningRender.write(view, size: NSSize(width: 1100, height: 760), to: out.appendingPathComponent("threads-rail-dark.png"))
        XCTAssertEqual(s.controller.threadPanel?.liveCount, 3)
    }

    // MARK: Panel

    func testRenderTheThreadPanel() throws {
        let out = try dir()
        ThreadPanelModel.forgetSession()
        let s = scene()
        let model = try XCTUnwrap(s.controller.threadPanel)
        model.open(s.why.id)
        let view = layout(s, width: 560, rail: NotesRail(controller: s.controller, roundName: { _ in "Refine 2" }, focusesDraft: false))
        try PlanningRender.write(view, size: NSSize(width: 1240, height: 780), to: out.appendingPathComponent("threads-panel.png"), appearance: .aqua)
        try PlanningRender.write(view, size: NSSize(width: 1240, height: 780), to: out.appendingPathComponent("threads-panel-dark.png"))
        // The narrow inspector (its 300 pt minimum): the conversation has the column, the index is a page.
        let narrow = layout(s, width: 340, rail: NotesRail(controller: s.controller, roundName: { _ in "Refine 2" }, focusesDraft: false))
        try PlanningRender.write(narrow, size: NSSize(width: 1100, height: 760), to: out.appendingPathComponent("threads-panel-narrow.png"), appearance: .aqua)
        XCTAssertEqual(model.selected, s.why.id)
    }

    /// The header of a thread whose agent has no shell (grok): "reads files only" beside the agent.
    func testRenderTheThreadPanelForAnAgentThatReadsFilesOnly() throws {
        let out = try dir()
        ThreadPanelModel.forgetSession()
        let s = scene()
        s.store.records[0].agent = .grok
        let model = try XCTUnwrap(s.controller.threadPanel)
        model.open(s.why.id)
        model.refresh()
        let view = layout(s, width: 560, rail: NotesRail(controller: s.controller, roundName: { _ in "Refine 2" }, focusesDraft: false))
        try PlanningRender.write(view, size: NSSize(width: 1240, height: 780), to: out.appendingPathComponent("threads-panel-grok.png"), appearance: .aqua)
        XCTAssertEqual(model.header(for: s.why.id)?.readsFilesOnly, true)
    }

    // MARK: Diff

    private func editorView(_ s: Scene) -> some View {
        PlanSection(intakeID: UUID(), tape: s.tape, loadFile: s.load, onSend: { _ in }, notes: s.controller)
            .padding(.horizontal, 30).padding(.vertical, 20)
    }

    /// Reads the words in a rendered PNG (Vision), lower-cased: the way to say "the old words are not
    /// on screen" about a drawing, where the text storage still holds them.
    static func words(in png: URL) throws -> String {
        let image = try XCTUnwrap(NSImage(contentsOf: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
    }

    func testRenderAProposedEditAtRestAndUnderThePointer() throws {
        let out = try dir()
        ThreadPanelModel.forgetSession()
        let s = scene()
        // The rail is not drawn here, so the model is told to read (its polling starts with the rail).
        s.controller.threadPanel?.refresh()
        let size = NSSize(width: 820, height: 560)
        var point: NSPoint?
        let rest = out.appendingPathComponent("diff-rest.png")
        try PlanningRender.write(editorView(s), size: size, to: rest, appearance: .aqua) { host in
            guard let textView = Self.find(PlanNSTextView.self, in: host) else { return XCTFail("no editor") }
            let range = (textView.string as NSString).range(of: Self.oldSentence)
            var actual = NSRange()
            let screen = textView.firstRect(forCharacterRange: range, actualRange: &actual)
            let inWindow = textView.window!.convertFromScreen(screen)
            point = textView.convert(NSPoint(x: inWindow.midX, y: inWindow.midY), from: nil)
            // D17: the editor still holds the old words, and has hidden them.
            XCTAssertNotNil(textView.string.range(of: Self.oldSentence))
            let at = range.location
            XCTAssertNotNil(textView.textStorage?.attribute(.planProposal, at: at, effectiveRange: nil), "the paragraph is drawn as the proposal")
        }
        let atRest = try Self.words(in: rest)
        XCTAssertTrue(atRest.contains("one second"), "the proposed words are on screen at rest: \(atRest)")
        XCTAssertFalse(atRest.contains("keep working"), "the old words are NOT on screen at rest: \(atRest)")
        let hover = try XCTUnwrap(point)
        let hovered = out.appendingPathComponent("diff-hover.png")
        try PlanningRender.write(editorView(s), size: size, to: hovered, appearance: .aqua) { host in
            guard let textView = Self.find(PlanNSTextView.self, in: host) else { return XCTFail("no editor") }
            textView.onHover?(hover)
        }
        let underPointer = try Self.words(in: hovered)
        XCTAssertTrue(underPointer.contains("keep working"), "the old text shows struck through under the pointer: \(underPointer)")
        XCTAssertTrue(underPointer.contains("one second"))
        try PlanningRender.write(editorView(s), size: size, to: out.appendingPathComponent("diff-hover-dark.png")) { host in
            guard let textView = Self.find(PlanNSTextView.self, in: host) else { return XCTFail("no editor") }
            textView.onHover?(hover)
        }
    }

    /// Real TextKit layout, not only the style attributes: the proposal's paragraph is laid out
    /// exactly as tall as the room the styler reserved for what is drawn there.
    func testTheProposalsLaidOutLineIsAsTallAsItsReservedHeight() throws {
        ThreadPanelModel.forgetSession()
        let s = scene()
        s.controller.threadPanel?.refresh()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proposal-height-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var checked = false
        try PlanningRender.write(editorView(s), size: NSSize(width: 820, height: 560), to: tmp, appearance: .aqua) { host in
            guard let textView = Self.find(PlanNSTextView.self, in: host), let layout = textView.textLayoutManager,
                  let storage = textView.textStorage else { return XCTFail("no editor") }
            let at = (storage.string as NSString).range(of: Self.oldSentence).location
            guard let ref = storage.attribute(.planProposal, at: at, effectiveRange: nil) as? PlanProposalRef else {
                return XCTFail("the sentence is not drawn as a proposal")
            }
            layout.ensureLayout(for: layout.documentRange)
            var found: NSTextLayoutFragment?
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                let start = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
                if start == at { found = fragment; return false }
                return true
            }
            let fragment = try? XCTUnwrap(found, "no layout fragment starts at the paragraph")
            guard let line = fragment?.textLineFragments.first else { return XCTFail("no line") }
            XCTAssertEqual(line.typographicBounds.height, ref.layout.restHeight, accuracy: 0.5,
                           "the laid-out line is as tall as the proposal the editor draws in it")
            checked = true
        }
        XCTAssertTrue(checked)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }
}
