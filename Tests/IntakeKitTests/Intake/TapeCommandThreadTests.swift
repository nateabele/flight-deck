import XCTest
import IntakeKit

/// What ask threads add to the tape's own `commands.jsonl` (R8): `applyThreadDiff` and the
/// note's optional `source`, and nothing else. The file is shared with runners already in the
/// field, so every line an old build wrote must still decode, and a line this build writes must
/// be one an old runner drops rather than misreads.
final class TapeCommandThreadTests: XCTestCase {
    private var root: URL!
    private let thread = ThreadID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TapeCommandThread-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: IntakeJSON.encoder.encode(value)) as? [String: Any])
    }

    /// The full edited plan, like `editPlan`, so the runner never has to rebuild it from a patch.
    func testApplyThreadDiffRoundTripsFlat() throws {
        let diff = UUID()
        let command = TapeCommand.applyThreadDiff(thread: thread, diff: diff, checkpoint: 6, markdown: "# Plan\nnew\n")
        let data = try IntakeJSON.encoder.encode(command)
        XCTAssertEqual(try IntakeJSON.decoder.decode(TapeCommand.self, from: data), command)
        let obj = try object(command)
        XCTAssertEqual(Set(obj.keys), ["kind", "thread", "diff", "checkpoint", "markdown"])
        XCTAssertEqual(obj["kind"] as? String, "applyThreadDiff")
        XCTAssertEqual(obj["thread"] as? String, thread.raw.uuidString)
        XCTAssertEqual(obj["diff"] as? String, diff.uuidString)
    }

    /// Lines exactly as builds before threads wrote them, `annotate` included.
    func testAnOldCommandsFileStillDecodes() throws {
        let note = UUID()
        let lines = [
            #"{"seq":1,"command":{"kind":"step"}}"#,
            #"{"seq":2,"command":{"kind":"annotate","text":"focus on auth"}}"#,
            #"{"seq":3,"command":{"kind":"note","note":{"id":"\#(note.uuidString)","kind":"mustChange","note":"n","anchor":{"checkpoint":1,"quote":"q","prefix":"","suffix":""}}}}"#,
            ##"{"seq":4,"command":{"kind":"editPlan","checkpoint":1,"markdown":"# P\n"}}"##,
            #"{"seq":5,"command":{"kind":"setNoteKind","id":"\#(note.uuidString)","noteKind":"comment"}}"#,
        ]
        let store = TapeStore(intakeDirectory: root)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: store.commandsURL)
        let read = store.commands(after: 0)
        XCTAssertEqual(read.map(\.seq), [1, 2, 3, 4, 5])
        XCTAssertEqual(read[0].command, .step)
        XCTAssertEqual(read[1].command, .annotate("focus on auth"))
        XCTAssertEqual(read[2].command, .note(PlanNote(id: note, kind: .mustChange, note: "n",
                                                       anchor: NoteAnchor(checkpoint: 1, quote: "q"))))
        guard case .note(let decoded) = read[2].command else { return XCTFail() }
        XCTAssertNil(decoded.source, "a note from before threads has no source")
        XCTAssertEqual(read[3].command, .editPlan(checkpoint: 1, markdown: "# P\n"))
        XCTAssertEqual(read[4].command, .setNoteKind(note, .comment))
    }

    /// What an old runner does with `applyThreadDiff`: its `TapeCommand` has no such kind, so the
    /// line fails to decode, `commands(after:)` drops it, and its seq still counts — the next
    /// command lands above it and is read. Reproduced here with a kind this build doesn't know
    /// either, which takes exactly the old runner's path.
    func testAnOldRunnerDropsTheLineAndKeepsCounting() throws {
        let store = TapeStore(intakeDirectory: root)
        let applied = try store.appendCommand(.applyThreadDiff(thread: thread, diff: UUID(), checkpoint: 2, markdown: "m"))
        XCTAssertEqual(applied, 1)
        let line = try String(contentsOf: store.commandsURL, encoding: .utf8)
        XCTAssertTrue(line.contains(#""kind":"applyThreadDiff""#), line)
        // The kinds a pre-threads runner knows — its decode of this line throws.
        XCTAssertThrowsError(try JSONDecoder().decode(PreThreadsKind.self, from: Data(line.utf8)))

        let future = #"{"seq":2,"command":{"kind":"applyVisualDiff","thread":"\#(thread.raw.uuidString)"}}"#
        let handle = try FileHandle(forWritingTo: store.commandsURL)
        handle.seekToEndOfFile()
        handle.write(Data((future + "\n").utf8))
        try handle.close()
        XCTAssertEqual(try store.appendCommand(.step), 3, "an unreadable line still holds its seq")
        XCTAssertEqual(store.commands(after: 0).map(\.seq), [1, 3])
    }

    func testNoteSourceRoundTripsAndIsAbsentWhenNil() throws {
        let sourced = PlanNote(kind: .comment, note: "from a thread", source: .thread(thread))
        let data = try IntakeJSON.encoder.encode(sourced)
        XCTAssertEqual(try IntakeJSON.decoder.decode(PlanNote.self, from: data), sourced)
        let obj = try object(sourced)
        XCTAssertEqual(obj["source"] as? [String: String], ["thread": thread.raw.uuidString])
        XCTAssertNil(try object(PlanNote(note: "plain"))["source"], "an unsourced note keeps its old bytes")
    }

    /// A source kind from a later build (a visual, say) must not make the note — and with it the
    /// whole tape — fail to load: the note keeps everything but the label.
    func testAnUnknownSourceDecodesAsNoSource() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","kind":"comment","note":"n","source":{"visual":"v1"}}"#
        let note = try IntakeJSON.decoder.decode(PlanNote.self, from: Data(json.utf8))
        XCTAssertEqual(note, PlanNote(id: id, kind: .comment, note: "n"))
    }

    func testANoteCommandCarriesItsSourceThroughTheFile() throws {
        let store = TapeStore(intakeDirectory: root)
        let note = PlanNote(kind: .mustChange, note: "n", source: .thread(thread))
        _ = try store.appendCommand(.note(note))
        XCTAssertEqual(store.commands(after: 0).map(\.command), [.note(note)])
    }
}

/// `TapeCommand.Kind` as it stood before ask threads, for the old-runner test.
private struct PreThreadsKind: Decodable {
    enum Kind: String, Decodable {
        case step, nextMajor, toReview, pause, stop, annotate, extend, trim, note, removeNote, editPlan, setNoteKind
    }
    struct Command: Decodable { let kind: Kind }
    let command: Command
}
