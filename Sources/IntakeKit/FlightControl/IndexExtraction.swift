import Foundation

/// One source's refresh as a headless claude run.
///
/// The isolation reuses `HeadlessCommand`'s, for the reasons documented there: `--restricted`
/// ignores the user's settings files (a standing `Bash(git add *)` allow would otherwise
/// apply), `--strict-mcp-config` loads no MCP server, `dontAsk` denies anything not
/// pre-approved because nobody can answer a prompt under `-p`. On top of that, `--tools` makes
/// WebSearch and WebFetch the ONLY tools that exist — claude 2.1.289's `--help` says
/// `--restricted` removes WebFetch "unless --tools names them", so naming them here is what
/// keeps them.
public enum IndexExtraction {
    public static let webTools = "WebSearch WebFetch"
    /// Defense in depth behind `--tools`: denied by name, since deny rules beat allow rules from
    /// any source.
    public static let deniedTools = "Bash Edit Write NotebookEdit Task"

    public static let schemaJSON = #"""
    {"type":"object","additionalProperties":false,"required":["source","rows"],"properties":{"source":{"type":"string"},"rows":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["benchmarkModel","score","unit","url","retrievedAt","quotedFigure"],"properties":{"benchmarkModel":{"type":"string"},"score":{"type":"number"},"unit":{"type":"string"},"url":{"type":"string"},"retrievedAt":{"type":"string"},"quotedFigure":{"type":"string"}}}}}}
    """#

    /// The agent gets the source entry and the catalog models (spec §4). It is told to report
    /// the benchmark's own names — mapping them is the alias table's job, and an agent asked to
    /// map would guess.
    public static func prompt(source: IndexSource, catalogs: AdapterCatalogs) -> String {
        let models = catalogs.order.compactMap { catalogs.byAgent[$0] }.flatMap { cat in
            cat.models.map { "- \(cat.agent.rawValue)/\($0.id) (\($0.displayName))" }
        }
        let list = models.isEmpty ? "- (none listed yet)" : models.joined(separator: "\n")
        return """
        You are reading one public benchmark for Flight Deck's capability index.

        Source: \(source.name) (id \(source.id))
        Address: \(source.url)
        What to read: \(source.howToRead)
        Unit: report every score in "\(source.unit)".

        Read the address with WebFetch. Use WebSearch only if the address has moved.
        Report one row per model in that table:
        - benchmarkModel: the model's name exactly as the source writes it, with any setting in brackets.
        - score: the figure as a number, in the unit above.
        - quotedFigure: the figure copied character for character from the source, for example "61.3%".
        - url: the address you read the figure on.
        - retrievedAt: the current time in ISO 8601.
        - unit: "\(source.unit)".
        Do not estimate, convert from another table, or fill a gap. Leave out any model you cannot read a figure for.
        Set "source" to "\(source.id)".

        Flight Deck can run these models. Report every row you can read, not only these:
        \(list)
        """
    }

    public static func command(prompt: String, settings: IndexAgentSettings)
        -> (executable: String, arguments: [String], unsetEnvironment: [String]) {
        let args = ["-p", prompt, "--model", settings.model, "--effort", settings.effort]
            + HeadlessCommand.claudeStreaming
            + ["--json-schema", schemaJSON, "--permission-mode", "dontAsk",
               "--tools", webTools, "--allowedTools", webTools, "--disallowedTools", deniedTools]
            + HeadlessCommand.claudeIsolation
        // Unset for the reason `HeadlessCommand.build` gives: a claude spawned from inside Claude
        // Code otherwise skips saving its transcript, and the live probe runs from inside one.
        return ("claude", args, ClaudeProfile.childSessionVariables)
    }

    /// The stream's final `result.structured_output`, decoded. Throws on an error result, a
    /// stream that never finished, or an answer that is not the row format.
    public static func parse(stdout: Data) throws -> ExtractionPayload {
        let parsed = try HeadlessOutput.parse(.claude, stdout: stdout)
        return try JSONDecoder().decode(ExtractionPayload.self, from: parsed.structured)
    }
}
