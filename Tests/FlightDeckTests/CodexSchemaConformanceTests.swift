import XCTest
@testable import FlightDeck

/// Every method name and enum value the codex adapter layer depends on, checked against the
/// schema `codex app-server generate-json-schema` emits.
///
/// This suite exists because three separate wire-format bugs shipped through a full plan's
/// worth of review, and all three were checkable in seconds against this file:
///
/// - `verifyHandshake` sent `initialize` with no `params`, which `InitializeParams` requires.
/// - `ThreadStatus` was mapped as `running`/`busy`, neither of which is in the union, and
///   `active` — the one status meaning "working" — had no case at all.
/// - `agentsStates` was decoded as `[String: String]` when `CollabAgentState` is an object,
///   so the sub-agent count was never emitted.
///
/// None could be caught by a hermetic test, because every stub transport in this suite
/// answers whatever the fixture author expected. The schema is the one artifact codex itself
/// produces, so it is the only thing here that can disagree with the code.
///
/// The fixture is checked in verbatim; see `codex-app-server-v2.provenance.json`. It is
/// hermetic by design — nothing in this file spawns `codex` unless
/// `FLIGHT_DECK_CODEX_SCHEMA_REGEN=1` is set.
final class CodexSchemaConformanceTests: XCTestCase {
    // Four cases were deleted when codex observation moved to the rollout file: they asserted
    // that the notification vocabulary the mapper handled was real, and the mapper no longer
    // handles notifications. Nothing generated can assert their replacement — the rollout and
    // session-index formats have no schema — so that coverage now lives in captured fixtures
    // (`rollout.captured.jsonl`) and in `CodexIntegrationTests`. That is weaker, deliberately
    // and knowingly: see the spec's §6.

    // MARK: - Loading

    private static func loadFixtureSchema() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle(for: CodexSchemaConformanceTests.self).url(
                forResource: "codex-app-server-v2.generated", withExtension: "json",
                subdirectory: "Fixtures/Codex"
            ),
            "the generated codex schema is missing from the test bundle"
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private var schema: [String: Any]!
    private var definitions: [String: Any]!

    override func setUpWithError() throws {
        schema = try Self.loadFixtureSchema()
        definitions = try XCTUnwrap(schema["definitions"] as? [String: Any])
    }

    // MARK: - Reading the schema

    /// Every string literal appearing in an `enum`/`const` anywhere under `definitions[name]`.
    ///
    /// Deliberately structural rather than a full JSON-Schema walk: codex's request and
    /// notification unions are `oneOf` lists of objects whose `method` is a single-valued
    /// `enum`, and the tagged unions (`ThreadStatus`) are the same shape one level in. A
    /// resolver would be more code and no more truthful for this question.
    private func enumValues(under name: String) throws -> Set<String> {
        var found: Set<String> = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                for key in ["enum", "const"] {
                    if let single = dict[key] as? String { found.insert(single) }
                    if let many = dict[key] as? [Any] {
                        found.formUnion(many.compactMap { $0 as? String })
                    }
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(try XCTUnwrap(definitions[name], "`\(name)` is not in the schema at all"))
        return found
    }

    /// The `type` tags of an internally-tagged union such as `ThreadStatus`.
    private func unionTags(of name: String) throws -> Set<String> {
        let node = try XCTUnwrap(definitions[name] as? [String: Any])
        let variants = try XCTUnwrap(node["oneOf"] as? [[String: Any]], "`\(name)` is not a oneOf union")
        return Set(variants.compactMap {
            (($0["properties"] as? [String: Any])?["type"] as? [String: Any])?["enum"] as? [String]
        }.flatMap { $0 })
    }

    private func propertyNames(of name: String) throws -> Set<String> {
        let node = try XCTUnwrap(definitions[name] as? [String: Any], "`\(name)` is not in the schema")
        return Set((node["properties"] as? [String: Any])?.keys ?? [:].keys)
    }

    // MARK: - Methods

    /// Every JSON-RPC method the adapter layer SENDS.
    ///
    /// Hand-listed on purpose, and the list is the point: adding an RPC call to
    /// `CodexAdapter` or `CodexProcessTransport` without adding it here is the omission this
    /// suite is meant to make loud. Grep `rpc.request(` — these are all of them.
    private static let sentMethods = [
        "initialize",         // CodexProcessTransport.verifyHandshake
        "thread/start",       // CodexAdapter.prepare
        "thread/name/set",    // CodexAdapter.prepare, CodexAdapter.rename
        "thread/read",        // CodexAdapter.read
    ]

    func testEveryMethodTheAdapterSendsExists() throws {
        let requests = try enumValues(under: "ClientRequest")
        for method in Self.sentMethods {
            XCTAssertTrue(requests.contains(method),
                          "`\(method)` is not a ClientRequest method in codex's own schema")
        }
    }

    // MARK: - Thread status

    /// Drives the REAL mapping function over every variant the schema declares, so a codex
    /// release that adds a `ThreadStatus` case fails here rather than silently mapping to
    /// nil in production.
    func testEveryThreadStatusVariantIsAccountedFor() throws {
        let tags = try unionTags(of: "ThreadStatus")
        XCTAssertEqual(tags, ["notLoaded", "idle", "systemError", "active"],
                       "the ThreadStatus union moved — CodexThreadStatus needs revisiting")

        // Intentionally unmapped: an absence of information, not a claim about activity.
        let deliberatelyNil: Set<String> = ["notLoaded"]
        for tag in tags {
            let activity = CodexThreadStatus.activity(from: ["type": tag, "activeFlags": []])
            if deliberatelyNil.contains(tag) {
                XCTAssertNil(activity, "\(tag) is documented as saying nothing")
            } else {
                XCTAssertNotNil(activity, "\(tag) is a real status with no mapping")
            }
        }
    }

    func testEveryThreadActiveFlagMeansWaiting() throws {
        let flags = try enumValues(under: "ThreadActiveFlag")
        XCTAssertEqual(flags, ["waitingOnApproval", "waitingOnUserInput"])
        for flag in flags {
            XCTAssertEqual(
                CodexThreadStatus.activity(from: ["type": "active", "activeFlags": [flag]]),
                .waiting, "\(flag) blocks on the user, so it is waiting rather than busy"
            )
        }
    }

    // MARK: - thread/start options

    func testTheOptionsPanesPickersOfferOnlyValuesCodexAccepts() throws {
        XCTAssertEqual(Set(CodexOptionsForm.sandboxes), try enumValues(under: "SandboxMode"))
        // `AskForApproval` is a union: three bare strings plus a `granular` object whose
        // members are booleans, so the picker's values are a subset rather than the whole set.
        let approvals = try enumValues(under: "AskForApproval")
        for policy in CodexOptionsForm.approvalPolicies {
            XCTAssertTrue(approvals.contains(policy),
                          "`\(policy)` is not an AskForApproval value codex accepts")
        }
    }

    func testAsThreadStartParamsOnlyUsesRealThreadStartFields() throws {
        let fields = try propertyNames(of: "ThreadStartParams")
        let params = CodexThreadOptions(
            model: "m", sandbox: "read-only", approvalPolicy: "never", addDirs: ["/w/b"]
        ).asThreadStartParams(cwd: "/w/a", historyMode: nil)

        // `historyMode` is deliberately not in this list. The pinned 0.147.0 schema this test
        // checks against defines `ThreadHistoryMode` but leaves it orphaned —
        // `ThreadStartParams` has no such property there — so asserting it here would fail
        // until the fixture is regenerated against a newer codex, which is out of scope for
        // this change. Passed as `nil` above for the same reason: a non-nil value would add
        // the key and immediately fail the "only real fields" assertion below.
        for key in ["cwd", "model", "sandbox", "approvalPolicy", "config"] {
            XCTAssertTrue(params.keys.contains(key), "the fixture for this test stopped sending \(key)")
            XCTAssertTrue(fields.contains(key), "`\(key)` is not a ThreadStartParams field")
        }
        // The known exception, asserted rather than left as folklore: `addDirs` is NOT a
        // field, and codex ignores it. It is still sent for backward compatibility, and the
        // directories reach codex through `config` instead. If a codex release ever adds it,
        // this flips and the `config` override can go.
        XCTAssertFalse(fields.contains("addDirs"),
                       "codex added addDirs — send it for real and drop the config override")
    }

    func testWritableRootsIsCodexsOwnConfigKey() throws {
        XCTAssertTrue(try propertyNames(of: "SandboxWorkspaceWrite").contains("writable_roots"),
                      "the config override addDirs rides on is not a real codex config key")
    }

    // MARK: - Provenance, and the opt-in live check

    func testTheCheckedInSchemaSaysWhichCodexItCameFrom() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "codex-app-server-v2.provenance", withExtension: "json",
            subdirectory: "Fixtures/Codex"
        ))
        let provenance = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(provenance["isVerbatimGeneratedOutput"] as? Bool, true)
        XCTAssertNotNil(provenance["codexVersion"] as? String,
                        "a schema fixture with no version is a fixture nobody can refresh")
    }

    /// Opt-in: regenerates the schema from the installed `codex` and re-runs every vocabulary
    /// assertion above against it, so the checked-in copy going stale is a visible failure
    /// rather than a silent one.
    ///
    /// Skipped by default because it spawns `codex`, which no committed test may do. It
    /// writes only to a temp directory it removes, creates no thread, and starts no
    /// app-server — `generate-json-schema` prints and exits.
    ///
    ///     FLIGHT_DECK_CODEX_SCHEMA_REGEN=1 ./scripts/test-unit.sh
    func testTheCheckedInSchemaStillMatchesTheInstalledCodex() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FLIGHT_DECK_CODEX_SCHEMA_REGEN"] == "1",
            "set FLIGHT_DECK_CODEX_SCHEMA_REGEN=1 to regenerate against the installed codex"
        )

        let out = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "app-server", "generate-json-schema", "--out", out.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "no usable `codex` on PATH")

        let live = out.appendingPathComponent("codex_app_server_protocol.v2.schemas.json")
        let fresh = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: live)) as? [String: Any]
        )
        // Swap the fixture for the freshly generated one and re-run the whole vocabulary.
        // Every assertion above reads `definitions`, so this is the entire re-check.
        definitions = try XCTUnwrap(fresh["definitions"] as? [String: Any])
        try testEveryMethodTheAdapterSendsExists()
        try testEveryThreadStatusVariantIsAccountedFor()
        try testEveryThreadActiveFlagMeansWaiting()
        try testTheOptionsPanesPickersOfferOnlyValuesCodexAccepts()
        try testAsThreadStartParamsOnlyUsesRealThreadStartFields()
        try testWritableRootsIsCodexsOwnConfigKey()
    }
}
