import Foundation
import IntakeKit

/// Fixtures and builders for the capability index tests. Fixture files come from the test
/// bundle's `Fixtures/FlightControlL3/Index` folder reference (subfolders survive, see
/// project.yml). Builders are here, not per test file, so every test speaks about the same
/// three models and the same catalog.
enum IndexFixtures {
    private final class Token {}
    static let subdirectory = "Fixtures/FlightControlL3/Index"

    static func data(_ name: String, ext: String = "json") throws -> Data {
        guard let url = Bundle(for: Token.self).url(forResource: name, withExtension: ext, subdirectory: subdirectory) else {
            throw NSError(domain: "IndexFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name).\(ext)"])
        }
        return try Data(contentsOf: url)
    }

    static func payload(_ name: String) throws -> ExtractionPayload {
        try JSONDecoder().decode(ExtractionPayload.self, from: data(name))
    }

    /// The UI test's snapshot folder, as the unit-test bundle carries it.
    static func uiDirectory() throws -> URL {
        guard let root = Bundle(for: Token.self).resourceURL?
                .appendingPathComponent("\(subdirectory)/ui", isDirectory: true),
              FileManager.default.fileExists(atPath: root.path) else {
            throw NSError(domain: "IndexFixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing fixture folder ui"])
        }
        return root
    }

    /// A path under the temporary directory that does not exist yet. Callers remove it.
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fd-index-\(UUID().uuidString)", isDirectory: true)
    }

    static func catalogs() -> AdapterCatalogs {
        AdapterCatalogs([
            AdapterCatalog(agent: .codex, models: [ModelEntry(id: "gpt-6-sol", displayName: "GPT-6 Sol", knobs: ["effort"])],
                           knobSchema: ["effort": ["low", "medium", "high"]], defaultModel: "gpt-6-sol", enabled: true),
            AdapterCatalog(agent: .claude, models: [ModelEntry(id: "opus", displayName: "Opus 5", knobs: ["effort"]),
                                                       ModelEntry(id: "sonnet", displayName: "Sonnet 5", knobs: ["effort"])],
                           knobSchema: ["effort": ["low", "medium", "high"]], defaultModel: "opus", enabled: true),
        ])
    }

    static let sol = ModelRef(agent: .codex, model: "gpt-6-sol", knobs: ["effort": "high"])
    static let opus = ModelRef(agent: .claude, model: "opus", knobs: ["effort": "high"])
    static let sonnet = ModelRef(agent: .claude, model: "sonnet")

    /// The catalog's view of a model: no knobs.
    static func bare(_ ref: ModelRef) -> ModelRef { ModelRef(agent: ref.agent, model: ref.model) }

    static func source(_ id: String, _ dims: [String: Double] = ["agentic-coding": 1], unit: IndexUnit = .percent,
                       enabled: Bool = true) -> IndexSource {
        IndexSource(id: id, name: id, url: "https://\(id).test", dimensions: dims, howToRead: "the table",
                    unit: unit, machineReadable: false, enabled: enabled)
    }

    /// An agent answer for source `id`, one valid percent row per `(name, score)`.
    static func payloadJSON(_ id: String, _ rows: [(String, Double)]) -> String {
        let body = rows.map {
            #"{"benchmarkModel":"\#($0.0)","score":\#($0.1),"unit":"percent","url":"https://\#(id).test","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"\#($0.1)%"}"#
        }.joined(separator: ",")
        return #"{"source":"\#(id)","rows":[\#(body)]}"#
    }

    /// A `claude -p --output-format stream-json` transcript: the init line, then a `result`
    /// carrying `payloadJSON` as `structured_output` and the given usage (what the token meter
    /// counts).
    static func stream(_ payloadJSON: String, input: Int = 1000, output: Int = 200, isError: Bool = false) -> Data {
        let result = isError
            ? #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s1","result":"boom","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}"#
            : #"{"type":"result","subtype":"success","is_error":false,"session_id":"s1","usage":{"input_tokens":\#(input),"output_tokens":\#(output)},"structured_output":\#(payloadJSON)}"#
        return Data((#"{"type":"system","subtype":"init","session_id":"s1"}"# + "\n" + result + "\n").utf8)
    }
}
