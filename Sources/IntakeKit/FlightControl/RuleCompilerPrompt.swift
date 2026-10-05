import Foundation

/// The compiler's prompt and its output schema (spec L3-R §3).
public enum RuleCompilerPrompt {
    /// Strict mode for both `claude --json-schema` and `codex exec --output-schema`: every object
    /// lists every property in `required`, optional values typed `[<type>, "null"]`.
    public static let schemaJSON = """
    {"type":"object","additionalProperties":false,
     "required":["ok","reason","mode","terms","harness","model","modelDefaulted","knobs","pool","fallbackPool"],
     "properties":{
      "ok":{"type":"boolean"},
      "reason":{"type":["string","null"]},
      "mode":{"type":"string","enum":["any","all"]},
      "terms":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["dimension","atLeast","kind"],
               "properties":{"dimension":{"type":["string","null"]},"atLeast":{"type":["number","null"]},"kind":{"type":["string","null"]}}}},
      "harness":{"type":["string","null"]},
      "model":{"type":["string","null"]},
      "modelDefaulted":{"type":"boolean"},
      "knobs":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["name","value"],
               "properties":{"name":{"type":"string"},"value":{"type":"string"}}}},
      "pool":{"type":["string","null"]},
      "fallbackPool":{"type":["string","null"]}}}
    """

    public static func text(_ input: RuleCompilerInput) -> String {
        let dimensions = Dimensions.all.map { "- \($0.id): \($0.summary)" }.joined(separator: "\n")
        // Merged kinds are left out (`isLive`): a new condition on a kind that no longer exists
        // would only ever match through its merge target, which the agent should name instead.
        let kinds = input.kinds.filter(\.isLive).map { k in
            "- \(k.id.rawValue) (\(k.name)): \(k.description). Weights: \(k.weightsText)"
        }.joined(separator: "\n")
        let agents = input.catalogs.order.compactMap { input.catalogs.byHarness[$0] }.map { c -> String in
            let models = c.models.map { "\($0.id) (\($0.displayName))" }.joined(separator: ", ")
            let knobs = c.knobSchema.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value.joined(separator: " | "))" }
            return "- \(c.harness.rawValue) (\(c.enabled ? "enabled" : "not enabled")). Default model: \(c.defaultModel ?? "none"). "
                + "Models: \(models.isEmpty ? "none" : models). Options: \(knobs.isEmpty ? "none" : knobs.joined(separator: "; "))"
        }.joined(separator: "\n")
        let pools = input.pools.map { "- \($0.id.rawValue) (\($0.harness.rawValue))" }.joined(separator: "\n")

        return """
        You compile one routing rule for Flight Deck. A routing rule says which coding agent, \
        model, options and capacity pool run some kind of task.

        Sentence:
        \(input.sentence)

        Capability dimensions (every task kind weighs each one from 0 to 1):
        \(dimensions)

        Task kinds:
        \(kinds.isEmpty ? "- none" : kinds)

        Agents:
        \(agents.isEmpty ? "- none" : agents)

        Pools:
        \(pools.isEmpty ? "- none" : pools)

        How to answer:
        - Turn what the sentence describes into conditions. A condition is either \
        {dimension, atLeast} — the task kind weighs at least atLeast on that dimension — or \
        {kind} — the task is that kind or a kind merged into it. Set the unused fields of a \
        condition to null.
        - Prefer dimension conditions for general descriptions ("tests", "complex algorithms"), \
        so kinds added later match too. Add a kind condition when the sentence names a listed kind.
        - mode is "any" when any one condition is enough, "all" when every condition must hold.
        - harness is the agent the sentence names. model is the model it names, matched to that \
        agent's list; if it names none, use that agent's default model and set modelDefaulted to true.
        - knobs: only options the agent lists, with a listed value. An empty list when the \
        sentence names none.
        - pool is the pool the sentence names, or null for the agent's default pool. fallbackPool \
        is a second pool the sentence names as an "else", or null.
        - If the sentence is not a routing rule, set ok to false and say why in reason. \
        Otherwise ok is true and reason is null.

        Return only JSON matching the provided schema.
        """
    }
}
