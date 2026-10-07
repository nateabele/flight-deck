# Cloud Infra Hosts (Sub-project E) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `flightdeck infra up <name>` creates a machine in the user's AWS or GCP account with OpenTofu, enrolls it as a paired host with nothing typed, enforces TTL/idle/budget, and destroys it with `infra down` — so every existing delegation feature works on it unchanged.

**Architecture:** Pure, cross-platform pieces (config, durations, cost model, enrollment payload, idle tracking) go in HostKit. The controller gains `Sources/FlightDeck/Infra/` (tool resolution, OpenTofu runner, cloud-init rendering, accounts, prices, tailnet, registry/ledger, `InfraService`, `Reaper`) and one wire family `infra.*`. hostd gains an `enroll` admin op and idle reporting. Presets are bundled OpenTofu modules.

**Tech Stack:** Swift 6 (HostKit, FleetKit), Swift 5 app target, OpenTofu ≥1.8 (`tofu test` with mock providers), cloud-init, AWS CLI v2 / Pricing / Service Quotas, gcloud / Cloud Billing Catalog, Tailscale API v2, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-07-cloud-infra-hosts-design.md` (approved). Parent: `docs/superpowers/specs/2026-10-03-remote-hosts-delegation-design.md`.

## Global Constraints

- **Public repo: never commit a real host name, IP, ssh login, account ID, project ID or tailnet name** — in code, tests, docs or commit messages. Tests use `192.0.2.x`, `198.51.100.x`, `100.64.0.x`, `example-tailnet.ts.net`, account `123456789012`, project `example-project`.
- HostKit stays Foundation-only Swift 6 and must pass `scripts/test-hostkit.sh` on macOS and Linux.
- FleetKit compiles for iOS: after touching `Sources/FleetKit`, run `./scripts/build-ios.sh`.
- Wire enum cases are atomic: a new `FleetRequest`/`ServerFrame` case and every exhaustive switch arm land in one commit.
- `./scripts/test-unit.sh` exits 0 on failure — always `rg -n "error:|failed \(" <log>`. Scope with `FD_TEST_FILTER=ClassA,ClassB`.
- TDD: each new test must be seen failing before the fix. Never weaken an assertion.
- Never launch an app bundle; never touch `/Applications`; never `git stash`; GUI end-to-end is Nate's.
- No cloud resource is ever created by any test except `scripts/test-infra-live.sh`, which refuses without `FD_INFRA_LIVE=1`.
- Commits: lowercase behavioral subject; body = mechanism, evidence, rejected alternatives; trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Tool compatibility (spec §4, verbatim): `tofu >= 1.8, < 2`; `aws` v2 `>= 2.15`; `gcloud >= 480`; `tailscale >= 1.70`. Tailscale is never installed by Flight Deck.
- Budget defaults (spec §8–9): monthly $50, per-machine $10, warning 80%; max concurrent 2; max TTL 12h; max idle 2h; default idle 30m.
- Ports: host 47410, pairing 47411 (unchanged).

**Deviations from the spec found while planning (record in the spec's as-built note, Task 19):**
1. Unknown keys in `[infra.<name>]` are **errors**, not warnings. The parser warns for recipes, but an infra typo spends money; erroring is the stricter reading of "as for recipes".
2. The TOML reader gains floats (`max_hourly = 1.50`); it rejected them before.
3. A `Duration` parser (`30m`, `4h`, `1d`) is added to HostKit; none existed.
4. `flightdeck-hostd enroll` hands the payload to the running `serve` through a new admin op, because `ControllerStore` is read once at start and a second process writing `controllers.json` would be ignored.
5. `auto_up` hooks into `DelegationService.start` (the app resolves `--on`), not the CLI.
6. `infra extend` cannot go past the TTL set at creation: the on-machine timer that guarantees success criterion 3 is fixed when the machine boots (Task 14).

## Review Focus

1. **The Mac sleeps or Flight Deck quits mid-`infra up`** — on relaunch the machine is either adopted (it enrolled) or destroyed; never forgotten. Test: Task 14 `testRelaunchMidProvisionResumesOrDestroys`.
2. **`tofu apply` fails halfway, leaving some resources** — state `failed`, and `infra down` still destroys what exists. Test: Task 14 `testFailedApplyIsStillDestroyable`.
3. **Two repos define the same infra name, or it clashes with a paired host** — refused before anything is created, naming the other owner. Test: Task 14 `testNameClashRefusedBeforeCreate`.
4. **A machine runs across midnight on the last day of the month** — the ledger splits its spend between the two months. Test: Task 10 `testSegmentSplitsAcrossMonths`.
5. **The Mac's public IP changes while a public-mode machine runs** — the firewall rule is re-applied and the link recovers. Test: Task 15 `testPublicIPChangeReappliesFirewall`.

---

## File structure

```
Packages/HostKit/Sources/HostKit/
  Delegation/DelegateConfigParser.swift   (modify: floats, [infra.*])
  Delegation/DelegateConfigTypes.swift    (modify: DelegateConfig.infra)
  Infra/Duration.swift                    parse/format 30m 4h 1d
  Infra/InfraConfig.swift                 [infra.<name>] value type
  Infra/CostModel.swift                   rates, worst case, cap decisions
  Infra/EnrollmentPayload.swift           one-time enroll file
  Infra/IdleTracker.swift                 host-side idle clock
  AdminWire.swift                         (modify: enroll op)
  HostInfo.swift                          (modify: idleSince, tolerant decode)
Packages/HostDaemonLinux/Sources/HostDaemonLinux/main.swift   (modify: enroll subcommand)
Packages/HostDaemonLinux/Sources/HostDaemonLinux/LinuxHostd.swift (modify: admin enroll, idle)
scripts/hostd-install.sh                  (modify: --no-pair)
Sources/FleetKit/InfraControlWire.swift   InfraRequest + wire structs
Sources/FleetKit/{TimelineFrames,Frames,FleetConnector,FleetSocketServer,Wire}.swift (modify)
Sources/FlightDeck/Infra/
  ToolPins.swift  ToolResolver.swift  ToolDownloader.swift
  TofuRunner.swift  InfraWorkdir.swift  CloudInitRenderer.swift
  InfraRegistry.swift  CostLedger.swift  PriceCatalog.swift
  CloudAccounts.swift  AWSAccount.swift  GCPAccount.swift
  TailnetIntegration.swift  HuJSONPatcher.swift
  InfraPreflight.swift  InfraService.swift  Reaper.swift  InfraNotifier.swift
Sources/FlightDeck/Hosts/HostService.swift  (modify: enroll(key:name:endpoints:))
Sources/FlightDeck/Delegation/DelegationService.swift (modify: auto_up + cost notice)
Sources/FlightDeck/Fleet/{FleetService,ControlScope}.swift (modify)
Sources/FlightDeck/Preferences/UI/{CloudSettingsTab,CloudSetupSheet}.swift
Sources/FlightDeckCLI/{CLIArguments,CLIRunner,InfraCommands}.swift
Resources/Infra/presets/{aws-linux,gcp-linux}/{main.tf,variables.tf,outputs.tf,.terraform.lock.hcl,tests/*.tftest.hcl}
scripts/test-infra-presets.sh  scripts/test-infra-live.sh
```

---

### Task 0: Probes P1–P4 (report only, no product code)

**Files:** Create: `docs/superpowers/specs/2026-10-07-cloud-infra-probes.md`

- [ ] **Step 1: P1 — Tailscale OAuth-client creation by API.** Read the Tailscale API v2 reference (`https://tailscale.com/api`) for `POST /api/v2/tailnet/{tailnet}/keys` with `keyType: "client"` (or any OAuth-client creation endpoint). Record: does it exist, which token kinds may call it, which scopes/tags it accepts. Do not call the API.
- [ ] **Step 2: P2 — GCP `max_run_duration` + `DELETE`.** Read the OpenTofu/Terraform `google_compute_instance` docs for `scheduling { max_run_duration, instance_termination_action }`; record provider version support, spot vs standard, GPU restrictions (`on_host_maintenance = "TERMINATE"` required with GPUs).
- [ ] **Step 3: P3 — per-user AWS CLI install.** Read AWS's "Install for current user" macOS instructions (`installer -pkg AWSCLIV2.pkg -target CurrentUserHomeDirectory -applyChoiceChangesXML choices.xml`); record the choices XML and the resulting binary path. Do not install.
- [ ] **Step 4: P4 — GCP SKU mapping.** From Cloud Billing Catalog docs, record the SKU description patterns for `e2/n2/g2` vCPU, RAM, and `nvidia-l4` GPU in `us-central1`, and the published on-demand prices for `e2-standard-2`, `n2-standard-4`, `g2-standard-4` from the public pricing page, to be used as Task 11 fixture expectations.
- [ ] **Step 5: Write the findings file** with one section per probe: question, answer, source URL, consequence for this plan (which task changes, if any). If P1 is "yes", Task 18's OAuth step becomes automatic; otherwise it stays a checklist (both are specified there).
- [ ] **Step 6: Commit** — `docs: record the cloud infra probes` with the trailer.

---

### Task 1: TOML floats and `Duration`

**Files:**
- Modify: `Packages/HostKit/Sources/HostKit/Delegation/DelegateConfigParser.swift` (`TOMLValue` at :318-323, value lexing at :554-556)
- Create: `Packages/HostKit/Sources/HostKit/Infra/Duration.swift`
- Test: `Packages/HostKit/Tests/HostKitTests/DurationTests.swift`, `DelegateConfigParserTests.swift`

**Interfaces:**
- Produces: `TOMLValue.float(Double)`; `public struct Duration: Codable, Sendable, Equatable, Comparable { public let seconds: Int; public init(seconds: Int); public static func parse(_ text: String) -> Duration?; public var formatted: String }`

- [ ] **Step 1: Write the failing tests**

```swift
// DurationTests.swift
import XCTest
@testable import HostKit

final class DurationTests: XCTestCase {
    func testParsesUnits() {
        XCTAssertEqual(Duration.parse("45s")?.seconds, 45)
        XCTAssertEqual(Duration.parse("30m")?.seconds, 1800)
        XCTAssertEqual(Duration.parse("4h")?.seconds, 14_400)
        XCTAssertEqual(Duration.parse("1d")?.seconds, 86_400)
        XCTAssertEqual(Duration.parse("1h30m")?.seconds, 5400)
    }

    func testRejectsGarbage() {
        for bad in ["", "4", "h", "-1h", "1.5h", "4 h", "1w", "0m"] {
            XCTAssertNil(Duration.parse(bad), bad)
        }
    }

    func testFormatsLargestUnitsFirst() {
        XCTAssertEqual(Duration(seconds: 5400).formatted, "1h30m")
        XCTAssertEqual(Duration(seconds: 172_800).formatted, "2d")
        XCTAssertEqual(Duration(seconds: 59).formatted, "59s")
    }
}

// DelegateConfigParserTests.swift — add
func testFloatValueParses() throws {
    let result = try DelegateConfigParser.parse("[recipe.x]\nrun = \"true\"\n[infra.g]\npreset = \"aws-linux\"\nregion = \"r\"\ninstance_type = \"t\"\nttl = \"1h\"\nmax_hourly = 1.50\n")
    XCTAssertEqual(result.config.infra["g"]?.maxHourly, 1.5)
}
```

(The second test also depends on Task 2; write it now and expect it to keep failing until Task 2 — note this in the commit body. The float lexing itself is pinned by `testFloatLexes` below.)

```swift
func testFloatLexes() throws {
    var warnings: [DelegateConfigIssue] = []
    let table = try TOMLReader.read("a = 1.25\nb = -0.5\nc = 3\n", warnings: &warnings)
    guard case .value(.float(let a), _) = table.entries["a"]!,
          case .value(.float(let b), _) = table.entries["b"]!,
          case .value(.int(3), _) = table.entries["c"]! else { return XCTFail("\(table.entries)") }
    XCTAssertEqual(a, 1.25); XCTAssertEqual(b, -0.5)
}
```

Check `TOMLReader`'s real read entry point name/signature at `DelegateConfigParser.swift:377` and adapt the call (it may be an instance with `parse()`); keep the assertions.

- [ ] **Step 2: Run** `cd Packages/HostKit && swift test --filter 'DurationTests|DelegateConfigParserTests'`. Expected: compile failure (`Duration`, `.float` missing).

- [ ] **Step 3: Implement**

```swift
// Infra/Duration.swift
import Foundation

/// A span written the way people write it in config: `45s`, `30m`, `4h`, `1d`, or a run of
/// them (`1h30m`). Whole units only, all positive — a TTL of `1.5h` or `0m` is a typo, not
/// a request, and a machine that bills by the hour must never get one silently.
public struct Duration: Codable, Sendable, Equatable, Comparable {
    public let seconds: Int
    public init(seconds: Int) { self.seconds = seconds }

    private static let units: [(Character, Int)] = [("d", 86_400), ("h", 3600), ("m", 60), ("s", 1)]

    public static func parse(_ text: String) -> Duration? {
        var total = 0, digits = "", sawUnit = false
        for ch in text {
            if ch.isASCII, ch.isNumber { digits.append(ch); continue }
            guard let unit = units.first(where: { $0.0 == ch }), let n = Int(digits), n > 0 else { return nil }
            total += n * unit.1; digits = ""; sawUnit = true
        }
        guard sawUnit, digits.isEmpty, total > 0 else { return nil }
        return Duration(seconds: total)
    }

    public var formatted: String {
        var rest = seconds, out = ""
        for (symbol, size) in Self.units where rest >= size {
            out += "\(rest / size)\(symbol)"; rest %= size
        }
        return out.isEmpty ? "0s" : out
    }

    public static func < (a: Duration, b: Duration) -> Bool { a.seconds < b.seconds }
}
```

In `DelegateConfigParser.swift`: add `case float(Double)` to `TOMLValue`; in the scalar lexer (where `unsupported value … floats and dates are not supported` is thrown at :554-556), accept `^-?[0-9]+\.[0-9]+$` as `.float(Double(text)!)` and keep the error for dates and exponents. Update the doc comment at :41-47 listing the supported subset. Any `switch` over `TOMLValue` gains a `.float` arm (type-mismatch errors name "a number").

- [ ] **Step 4: Run** `swift test --filter 'DurationTests|DelegateConfigParserTests/testFloatLexes'` → PASS; then `./scripts/test-hostkit.sh` → PASS on both platforms.
- [ ] **Step 5: Commit** — `feat: read decimal numbers and human durations in delegate.toml`.

---

### Task 2: `[infra.<name>]` parsing and validation

**Files:**
- Create: `Packages/HostKit/Sources/HostKit/Infra/InfraConfig.swift`
- Modify: `DelegateConfigTypes.swift:6-21` (add `infra`), `DelegateConfigParser.swift` (`map` switch :93-116, new `infra(_:name:)`, `validate(hosts:)` :265)
- Test: `Packages/HostKit/Tests/HostKitTests/InfraConfigTests.swift`

**Interfaces:**
- Consumes: `Duration` (Task 1), `TOMLValue.float`.
- Produces:

```swift
public struct InfraConfig: Codable, Sendable, Equatable {
    public enum Source: Codable, Sendable, Equatable { case preset(String); case module(String) }
    public var source: Source
    public var region: String?
    public var instanceType: String?
    public var arch: String?
    public var diskGB: Int?
    public var spot: Bool
    public var ttl: Duration
    public var idle: Duration
    public var autoUp: Bool
    public var vars: [String: String]
    public var maxHourly: Double?
    public static let knownPresets = ["aws-linux", "gcp-linux"]
    public static let defaultIdle = Duration(seconds: 1800)
}
// DelegateConfig gains: public var infra: [String: InfraConfig] (init param default [:])
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import HostKit

final class InfraConfigTests: XCTestCase {
    let full = """
    [infra.gpu]
    preset = "aws-linux"
    region = "us-east-1"
    instance_type = "g6.xlarge"
    arch = "x86_64"
    disk_gb = 100
    spot = true
    ttl = "4h"
    idle = "20m"
    auto_up = true
    vars = { team = "ml" }
    max_hourly = 1.5
    """

    func testParsesEveryField() throws {
        let c = try XCTUnwrap(DelegateConfigParser.parse(full).config.infra["gpu"])
        XCTAssertEqual(c.source, .preset("aws-linux"))
        XCTAssertEqual(c.region, "us-east-1"); XCTAssertEqual(c.instanceType, "g6.xlarge")
        XCTAssertEqual(c.arch, "x86_64"); XCTAssertEqual(c.diskGB, 100); XCTAssertTrue(c.spot)
        XCTAssertEqual(c.ttl.seconds, 14_400); XCTAssertEqual(c.idle.seconds, 1200)
        XCTAssertTrue(c.autoUp); XCTAssertEqual(c.vars, ["team": "ml"]); XCTAssertEqual(c.maxHourly, 1.5)
    }

    func testDefaults() throws {
        let c = try XCTUnwrap(DelegateConfigParser.parse("[infra.a]\npreset = \"gcp-linux\"\nregion = \"us-central1\"\ninstance_type = \"e2-standard-2\"\nttl = \"1h\"\n").config.infra["a"])
        XCTAssertEqual(c.idle, InfraConfig.defaultIdle); XCTAssertFalse(c.autoUp); XCTAssertFalse(c.spot)
    }

    func testTTLIsRequired() {
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\nregion = \"r\"\ninstance_type = \"t\"\n")) {
            XCTAssertTrue("\($0)".contains("infra.a.ttl"), "\($0)")
        }
    }

    func testExactlyOneSource() {
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\nttl = \"1h\"\n"))
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\nmodule = \"infra/x\"\nttl = \"1h\"\n"))
    }

    func testUnknownPresetAndUnknownKeyAreErrors() {
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"azure\"\nttl = \"1h\"\n"))
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\nregion = \"r\"\ninstance_type = \"t\"\nttl = \"1h\"\nttll = \"2h\"\n")) {
            XCTAssertTrue("\($0)".contains("ttll"))
        }
    }

    func testPresetNeedsRegionAndInstanceType() {
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\nttl = \"1h\"\n"))
    }

    func testModuleMustStayInsideRepo() {
        for path in ["../x", "/abs", "infra/../../x"] {
            XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\nmodule = \"\(path)\"\nttl = \"1h\"\n"), path)
        }
        XCTAssertNoThrow(try DelegateConfigParser.parse("[infra.a]\nmodule = \"infra/gpu\"\nttl = \"1h\"\n"))
    }

    func testBadDurationNamesTheKey() {
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\nregion = \"r\"\ninstance_type = \"t\"\nttl = \"forever\"\n")) {
            XCTAssertTrue("\($0)".contains("infra.a.ttl"))
        }
    }

    /// An infra name that is already a paired host would make `--on` ambiguous.
    func testValidateRefusesClashWithPairedHost() throws {
        let config = try DelegateConfigParser.parse("[infra.mini]\npreset = \"aws-linux\"\nregion = \"r\"\ninstance_type = \"t\"\nttl = \"1h\"\n").config
        let issues = config.validate(hosts: ["mini"])
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("mini") }, "\(issues)")
    }
}
```

Match `validate(hosts:)`'s real signature/return at `DelegateConfigParser.swift:265` (it may return `[DelegateConfigIssue]`); adapt the call, keep the assertion.

- [ ] **Step 2: Run** `swift test --filter InfraConfigTests` → compile failure.
- [ ] **Step 3: Implement.** In `map(_:warnings:)` add `case "infra":` shaped like `case "recipe":` (:98-107), calling a new `infra(_ table: TOMLTable, name: String) throws -> InfraConfig`. Labels are `"infra.<name>.<key>"`. Reuse the typed helpers `string`, `bool`, `int`, and `env` (for `vars`). Add a `double` helper accepting `.float` and `.int`. Rules: unknown key → **error** (deviation 1); `preset` ∈ `knownPresets`; exactly one of `preset`/`module`; `module` path: relative, no `..` component after standardizing, not absolute; preset requires `region` and `instance_type`; `ttl` required and parsed by `Duration.parse`; `idle` defaults to `InfraConfig.defaultIdle`. In `validate(hosts:)`, add an error per infra name present in `hosts`, and an error if an infra name equals a recipe name used as a host elsewhere is NOT needed (YAGNI). Add `infra` to `DelegateConfig`'s init with default `[:]` so all existing call sites compile.
- [ ] **Step 4: Run** `swift test --filter 'InfraConfigTests|DelegateConfigParserTests'` → PASS (including Task 1's `testFloatValueParses`); `./scripts/test-hostkit.sh` → PASS.
- [ ] **Step 5: Commit** — `feat: declare cloud machines as [infra.<name>] tables in delegate.toml`.

---

### Task 3: `CostModel` — rates, worst case, cap decisions

**Files:**
- Create: `Packages/HostKit/Sources/HostKit/Infra/CostModel.swift`
- Test: `Packages/HostKit/Tests/HostKitTests/CostModelTests.swift`

**Interfaces:**
- Produces:

```swift
public struct BudgetSettings: Codable, Sendable, Equatable {
    public var monthlyCapUSD: Double?      // nil = no cap
    public var perMachineCapUSD: Double?
    public var warnFraction: Double        // 0.8
    public var maxConcurrent: Int          // 2
    public var maxTTL: Duration            // 12h
    public var maxIdle: Duration           // 2h
    public var allowedTypes: [String: [String]]  // cloud ("aws"/"gcp") -> glob patterns
    public static let `default`: BudgetSettings
    public var hasDollarCap: Bool { get }
}
public enum BudgetVerdict: Equatable, Sendable {
    case allowed
    case refused(String)   // human sentence naming numbers and the setting to change
}
public enum CostModel {
    public static func worstCase(hourly: Double, ttl: Duration) -> Double
    public static func checkLaunch(hourly: Double?, ttl: Duration, idle: Duration, instanceType: String,
                                   cloud: String, running: Int, monthToDate: Double,
                                   settings: BudgetSettings) -> BudgetVerdict
    public enum RunningState: Equatable, Sendable { case ok; case warn(String); case destroy(String) }
    public static func checkRunning(spent: Double, monthToDate: Double, settings: BudgetSettings) -> RunningState
    public static func globMatches(_ pattern: String, _ value: String) -> Bool
}
```

`BudgetSettings.default`: monthly 50, per-machine 10, warn 0.8, maxConcurrent 2, maxTTL 12h, maxIdle 2h, allowed:
`aws: ["t3.*","t4g.*","m6i.*large","m7g.*large","c7g.*large","m6i.2xlarge","m6i.4xlarge","m7g.2xlarge","m7g.4xlarge","g6.xlarge","g6.2xlarge","g5.xlarge"]`,
`gcp: ["e2-*","n2-standard-2","n2-standard-4","n2-standard-8","n2-standard-16","t2a-standard-*","g2-standard-4","g2-standard-8"]`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import HostKit

final class CostModelTests: XCTestCase {
    var s = BudgetSettings.default

    func testWorstCaseIsRateTimesTTL() {
        XCTAssertEqual(CostModel.worstCase(hourly: 0.8, ttl: Duration(seconds: 4 * 3600)), 3.2, accuracy: 1e-9)
    }

    func testAllowsWithinEveryLimit() {
        XCTAssertEqual(CostModel.checkLaunch(hourly: 0.8, ttl: .init(seconds: 4*3600), idle: .init(seconds: 1800),
            instanceType: "g6.xlarge", cloud: "aws", running: 0, monthToDate: 10, settings: s), .allowed)
    }

    func testPerMachineCapBoundary() {
        // $10 cap: 12.5h at $0.80 = $10.00 exactly is allowed; one more minute is not.
        XCTAssertEqual(CostModel.checkLaunch(hourly: 0.8, ttl: .init(seconds: 45_000), idle: .init(seconds: 60),
            instanceType: "g6.xlarge", cloud: "aws", running: 0, monthToDate: 0, settings: { var x = s; x.maxTTL = .init(seconds: 86_400); return x }()), .allowed)
        guard case .refused(let why) = CostModel.checkLaunch(hourly: 0.8, ttl: .init(seconds: 45_060), idle: .init(seconds: 60),
            instanceType: "g6.xlarge", cloud: "aws", running: 0, monthToDate: 0, settings: { var x = s; x.maxTTL = .init(seconds: 86_400); return x }())
        else { return XCTFail() }
        XCTAssertTrue(why.contains("per-machine"), why)
    }

    func testMonthlyCapCountsMonthToDate() {
        guard case .refused(let why) = CostModel.checkLaunch(hourly: 1, ttl: .init(seconds: 3*3600), idle: .init(seconds: 60),
            instanceType: "g6.xlarge", cloud: "aws", running: 0, monthToDate: 48, settings: s) else { return XCTFail() }
        XCTAssertTrue(why.contains("monthly") && why.contains("48"), why)
    }

    func testUnpricedRefusedOnlyWhenADollarCapIsSet() {
        guard case .refused = CostModel.checkLaunch(hourly: nil, ttl: .init(seconds: 3600), idle: .init(seconds: 60),
            instanceType: "t3.small", cloud: "aws", running: 0, monthToDate: 0, settings: s) else { return XCTFail() }
        var noCaps = s; noCaps.monthlyCapUSD = nil; noCaps.perMachineCapUSD = nil
        XCTAssertEqual(CostModel.checkLaunch(hourly: nil, ttl: .init(seconds: 3600), idle: .init(seconds: 60),
            instanceType: "t3.small", cloud: "aws", running: 0, monthToDate: 0, settings: noCaps), .allowed)
    }

    func testGuardrails() {
        func refused(_ t: String, cloud: String = "aws", running: Int = 0, ttl: Int = 3600, idle: Int = 60) -> Bool {
            if case .refused = CostModel.checkLaunch(hourly: 0.1, ttl: .init(seconds: ttl), idle: .init(seconds: idle),
                instanceType: t, cloud: cloud, running: running, monthToDate: 0, settings: s) { return true }
            return false
        }
        XCTAssertTrue(refused("p5.48xlarge"))
        XCTAssertFalse(refused("t3.small"))
        XCTAssertTrue(refused("t3.small", running: 2))
        XCTAssertTrue(refused("t3.small", ttl: 13 * 3600))
        XCTAssertTrue(refused("t3.small", idle: 3 * 3600))
        XCTAssertFalse(refused("e2-standard-2", cloud: "gcp"))
        XCTAssertTrue(refused("a3-highgpu-8g", cloud: "gcp"))
    }

    func testRunningThresholds() {
        XCTAssertEqual(CostModel.checkRunning(spent: 5, monthToDate: 20, settings: s), .ok)
        guard case .warn = CostModel.checkRunning(spent: 8.1, monthToDate: 20, settings: s) else { return XCTFail() }
        guard case .destroy = CostModel.checkRunning(spent: 10, monthToDate: 20, settings: s) else { return XCTFail() }
        guard case .destroy = CostModel.checkRunning(spent: 1, monthToDate: 50, settings: s) else { return XCTFail() }
    }

    func testGlob() {
        XCTAssertTrue(CostModel.globMatches("t3.*", "t3.micro"))
        XCTAssertTrue(CostModel.globMatches("m6i.*large", "m6i.xlarge"))
        XCTAssertFalse(CostModel.globMatches("m6i.*large", "m6i.metal"))
        XCTAssertFalse(CostModel.globMatches("t3.*", "t3a.micro"))
    }
}
```

- [ ] **Step 2: Run** `swift test --filter CostModelTests` → compile failure.
- [ ] **Step 3: Implement.** `checkLaunch` order (first failure wins, each sentence names the setting in Settings → Cloud → Budget): instance-type allowlist (`globMatches` over `allowedTypes[cloud] ?? []`; `*` matches any run of characters, everything else literal) → `running >= maxConcurrent` → `ttl > maxTTL` → `idle > maxIdle` → if `hasDollarCap` and `hourly == nil`: refused "can't price this machine; set max_hourly" → per-machine: `worstCase > cap + 1e-9` → monthly: `monthToDate + worstCase > cap + 1e-9`. Money formatted `String(format: "$%.2f", x)`. `checkRunning`: destroy if `spent >= perMachine` or `monthToDate >= monthly`; warn if either ≥ `warnFraction × cap`; else ok.
- [ ] **Step 4: Run** → PASS; `./scripts/test-hostkit.sh` → PASS.
- [ ] **Step 5: Commit** — `feat: decide whether a cloud machine fits the budget before and while it runs`.

---

### Task 4: Enrollment — payload, hostd admin op, `enroll` subcommand, installer `--no-pair`

**Files:**
- Create: `Packages/HostKit/Sources/HostKit/Infra/EnrollmentPayload.swift`
- Modify: `Packages/HostKit/Sources/HostKit/AdminWire.swift:17-21` (new request case), `Packages/HostDaemonLinux/Sources/HostDaemonLinux/main.swift:90-131` (subcommand), `LinuxHostd.swift` (admin handler), `scripts/hostd-install.sh`
- Test: `Packages/HostKit/Tests/HostKitTests/EnrollmentPayloadTests.swift`, `AdminWireTests.swift`, HostDaemonLinux tests, `scripts/test-hostd-install.sh`

**Interfaces:**
- Produces:

```swift
public struct EnrollmentPayload: Codable, Sendable, Equatable {
    public let version: Int             // 1
    public let slot: UUID
    public let secretHex: String        // 64 hex chars
    public let controllerName: String
    public let idleSeconds: Int
    public let issuedAt: Date
    public static let maxAge: TimeInterval = 1800
    public func validate(now: Date) throws -> (slot: UUID, secret: Data)
}
public enum EnrollmentError: Error, Equatable { case expired, malformed, wrongVersion }
// AdminRequest gains: case enroll(EnrollmentPayload)   — tag "enroll"
```

- hostd CLI: `flightdeck-hostd enroll --file PATH [--root DIR]` → reads, validates, sends `AdminRequest.enroll` to the running `serve`, deletes the file on success or on `expired`; exit 0 enrolled, 1 refused, 2 hostd not running.
- Installer: `--no-pair` skips the final `exec "$BIN" pair` (and nothing else).

- [ ] **Step 1: Write the failing tests**

```swift
// EnrollmentPayloadTests.swift
import XCTest
@testable import HostKit

final class EnrollmentPayloadTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func payload(issued: Date? = nil, hex: String = String(repeating: "ab", count: 32), v: Int = 1) -> EnrollmentPayload {
        EnrollmentPayload(version: v, slot: UUID(), secretHex: hex, controllerName: "ctl", idleSeconds: 1800, issuedAt: issued ?? t0)
    }
    func testValidWithinMaxAge() throws {
        let (_, secret) = try payload().validate(now: t0.addingTimeInterval(1799))
        XCTAssertEqual(secret, Data(repeating: 0xAB, count: 32))
    }
    func testExpired() {
        XCTAssertThrowsError(try payload().validate(now: t0.addingTimeInterval(1801))) { XCTAssertEqual($0 as? EnrollmentError, .expired) }
    }
    func testMalformedSecretAndVersion() {
        XCTAssertThrowsError(try payload(hex: "zz").validate(now: t0)) { XCTAssertEqual($0 as? EnrollmentError, .malformed) }
        XCTAssertThrowsError(try payload(v: 2).validate(now: t0)) { XCTAssertEqual($0 as? EnrollmentError, .wrongVersion) }
    }
    func testRoundTripsAsJSON() throws {
        let p = payload()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(EnrollmentPayload.self, from: enc.encode(p)), p)
    }
}

// AdminWireTests.swift — add
func testEnrollRoundTrips() throws {
    let p = EnrollmentPayload(version: 1, slot: UUID(), secretHex: String(repeating: "00", count: 32),
                              controllerName: "c", idleSeconds: 60, issuedAt: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(try HostWire.decode(AdminRequest.self, from: HostWire.encode(AdminRequest.enroll(p))), .enroll(p))
}
```

hostd (in the HostDaemonLinux test target, run by `scripts/test-hostd-linux.sh`) — add to the existing admin-handler tests, against the in-process `LinuxHostd` admin handler:

```swift
func testAdminEnrollAddsControllerAndIsIdempotentlyRefusedOnReuse() throws {
    // Build LinuxHostd the way existing tests do (see LinuxHostd.swift:72-84 init) with a temp root.
    let hostd = try makeTestHostd()
    let p = EnrollmentPayload(version: 1, slot: UUID(), secretHex: String(repeating: "11", count: 32),
                              controllerName: "ctl", idleSeconds: 600, issuedAt: Date())
    XCTAssertEqual(hostd.handleAdmin(.enroll(p)), .ok)
    XCTAssertEqual(hostd.store.all().map(\.slot), [p.slot])
    guard case .failed(let why) = hostd.handleAdmin(.enroll(p)) else { return XCTFail() }
    XCTAssertTrue(why.contains("already"), why)
}
func testAdminEnrollRefusesExpired() throws {
    let hostd = try makeTestHostd()
    let p = EnrollmentPayload(version: 1, slot: UUID(), secretHex: String(repeating: "11", count: 32),
                              controllerName: "ctl", idleSeconds: 600, issuedAt: Date(timeIntervalSinceNow: -3600))
    guard case .failed = hostd.handleAdmin(.enroll(p)) else { return XCTFail() }
    XCTAssertTrue(hostd.store.all().isEmpty)
}
```

Use the real admin dispatch method name in `LinuxHostd.swift` (find the `AdminSocketServer` handle closure); if it is a closure, extract it to `func handleAdmin(_ r: AdminRequest) -> AdminReply` first (pure refactor) so it is callable from tests. `makeTestHostd()` mirrors the existing test helper for `LinuxHostd`; if none exists, build one with a temp `--root` and port 0.

Installer — extend `scripts/test-hostd-install.sh` with a run passing `--no-systemd --no-pair` that asserts the script exits 0 without printing `Pairing code:` (the `--no-systemd` path already returns before pairing; add a second assertion in the systemd-less path by grepping the script: `rg -q -- '--no-pair' scripts/hostd-install.sh`). The behavioral check of `--no-pair` with systemd lives in Task 19's live test.

- [ ] **Step 2: Run** `cd Packages/HostKit && swift test --filter 'EnrollmentPayloadTests|AdminWireTests'` and `./scripts/test-hostd-linux.sh` → compile failures.
- [ ] **Step 3: Implement.**
  - `EnrollmentPayload.validate`: version == 1 else `.wrongVersion`; `now - issuedAt` in `[−300, maxAge]` else `.expired` (300 s tolerance for clock skew); `secretHex` 64 lowercase/uppercase hex → 32 bytes else `.malformed`.
  - `AdminRequest.enroll(EnrollmentPayload)` with tag `"enroll"` in `AdminWire.swift`'s hand-rolled coding (follow `revoke`'s shape).
  - `LinuxHostd.handleAdmin(.enroll(p))`: `validate(now: Date())` → on error `.failed("enrollment <reason>")`; if `store.all()` contains the slot → `.failed("slot already enrolled")`; else `store.add(PairedController(slot:, name: p.controllerName, secret:, pairedAt: Date()))`, store `idleSeconds` for Task 5 (an `idleThreshold` property on `LinuxHostd`, persisted in `<root>/idle.json`), reply `.ok`.
  - `main.swift`: `case "enroll":` reads `--file`, decodes with ISO-8601 dates, calls `adminRequest(.enroll(p), root:)` (exits 2 when not running), deletes the file on `.ok` or when validation said expired, prints one line, exits 0/1. Add to usage text (:30-43).
  - `hostd-install.sh`: parse `--no-pair` → `PAIR=0`; guard the final `exec "$BIN" pair` with `[ "$PAIR" = 1 ]`; document the flag in the header comment (:10-17): "for machines enrolled by Flight Deck's cloud-init".
- [ ] **Step 4: Run** HostKit tests, `./scripts/test-hostd-linux.sh`, `./scripts/test-hostd-install.sh` → PASS (`INSTALL PASS`).
- [ ] **Step 5: Commit** — `feat: enroll a controller into a running hostd from a one-time file`.

---

### Task 5: Idle tracking and `HostInfo.idleSince`

**Files:**
- Create: `Packages/HostKit/Sources/HostKit/Infra/IdleTracker.swift`
- Modify: `HostKit/HostInfo.swift` (field + tolerant decode), `HostServerCore.swift:194-198` (fill it), `HostKit/Delegation/DelegationHost.swift:145` (activity hook), `LinuxHostd.swift:72-84` (wire), `Sources/FleetKit/Wire.swift:375` (`WireHostInfo.idleSince`), `Sources/FlightDeck/Fleet/HostProjection.swift:29`
- Test: `Packages/HostKit/Tests/HostKitTests/IdleTrackerTests.swift`, `HostWireTests.swift`, `HostServerCoreTests.swift`

**Interfaces:**
- Produces:

```swift
public final class IdleTracker: @unchecked Sendable {
    public init(now: @escaping @Sendable () -> Date = Date.init)
    public func begin() -> UUID          // an activity started (run, service, sync)
    public func end(_ token: UUID)
    public func touch()                   // a request arrived
    public var idleSince: Date? { get }   // nil while any activity is open
}
// HostInfo gains: public var idleSince: Date?   (absent in JSON from older hostds → nil)
// WireHostInfo gains: public let idleSince: Date?
```

- [ ] **Step 1: Write the failing tests**

```swift
final class IdleTrackerTests: XCTestCase {
    func testIdleSinceTracksLastActivity() {
        var now = Date(timeIntervalSince1970: 100)
        let t = IdleTracker(now: { now })
        XCTAssertEqual(t.idleSince, Date(timeIntervalSince1970: 100))
        now += 10; let a = t.begin()
        XCTAssertNil(t.idleSince)
        now += 50; let b = t.begin(); t.end(a)
        XCTAssertNil(t.idleSince, "one activity still open")
        now += 5; t.end(b)
        XCTAssertEqual(t.idleSince, Date(timeIntervalSince1970: 165))
        now += 20; t.touch()
        XCTAssertEqual(t.idleSince, Date(timeIntervalSince1970: 185))
    }
    func testEndingUnknownTokenIsHarmless() {
        let t = IdleTracker(); t.end(UUID()); XCTAssertNotNil(t.idleSince)
    }
}

// HostWireTests — add
func testHostInfoFromAnOlderHostdHasNoIdleSince() throws {
    let old = #"{"arch":"arm64","diskFreeBytes":1,"hostName":"h","hostdVersion":"0.1.0","osVersion":"x","platform":"Linux","xcode":[]}"#
    XCTAssertNil(try JSONDecoder().decode(HostInfo.self, from: Data(old.utf8)).idleSince)
}

// HostServerCoreTests — add
func testHostInfoCarriesIdleSince() throws {
    let tracker = IdleTracker(now: { Date(timeIntervalSince1970: 42) })
    let core = HostServerCore(/* existing args as in this file's helper */, idle: tracker)
    // hello then host.info, as testHelloThenHostInfo does; assert info.idleSince == Date(timeIntervalSince1970: 42)
}
```

Write the last test fully by copying `testHelloThenHostInfo` in `HostServerCoreTests.swift` and adding the `idle:` argument and the `idleSince` assertion.

- [ ] **Step 2: Run** `swift test --filter 'IdleTrackerTests|HostWireTests|HostServerCoreTests'` → compile failure.
- [ ] **Step 3: Implement.** `IdleTracker`: `NSLock`, `open: Set<UUID>`, `last: Date` (init = now()). `HostInfo`: add `idleSince` to `CodingKeys` and a custom `init(from:)` using `decodeIfPresent` for it (other fields as today). `HostServerCore.init` gains `idle: IdleTracker? = nil` (default keeps every call site compiling); `answerHostInfo` sets `info.idleSince = idle?.idleSince`. `DelegationHost`: accept an optional `IdleTracker`; in `handle(id:_:from:)` call `touch()`; wrap each run/service start→end and each `syncPush` in `begin()/end()` (find the run-end path in `Runner` via `liveRuns`; simplest correct hook: `begin()` when `handle` starts a run or service request and `end()` in the run-exit callback the host already sends to the controller). `LinuxHostd` creates one `IdleTracker` and passes it to both. FleetKit `WireHostInfo` gains `idleSince: Date?` (decodeIfPresent), `HostProjection.info` copies it. Run `./scripts/build-ios.sh`.
- [ ] **Step 4: Run** HostKit tests, `./scripts/test-hostd-linux.sh`, `FD_TEST_FILTER=HostCLITests,HostLinkTests ./scripts/test-unit.sh` (rg for errors), `./scripts/build-ios.sh` → PASS.
- [ ] **Step 5: Commit** — `feat: report how long a host has been idle in host.info`.

---

### Task 6: `ToolResolver`, pins and verified downloads

**Files:**
- Create: `Sources/FlightDeck/Infra/ToolPins.swift`, `ToolResolver.swift`, `ToolDownloader.swift`
- Test: `Tests/FlightDeckTests/ToolResolverTests.swift`

**Interfaces:**
- Consumes: `LoginShellPath.resolve()` (`Sources/FlightDeck/Agents/LoginShellPath.swift:36`), `IntakeKit.CommandRunner` (`Sources/IntakeKit/CommandRunner.swift:17`).
- Produces:

```swift
enum InfraTool: String, CaseIterable, Sendable { case tofu, aws, gcloud, tailscale }
struct SemVer: Comparable, Equatable, Sendable { let major, minor, patch: Int; static func parse(_ s: String) -> SemVer? }
struct ToolPin: Sendable { let tool: InfraTool; let minimum: SemVer; let belowMajor: Int?
    let managedVersion: String?; let assetURL: URL?; let sha256: String?; let versionArgs: [String] }
enum ToolPins { static let all: [InfraTool: ToolPin] }
enum ToolSource: Equatable, Sendable { case path, managed }
struct ResolvedTool: Equatable, Sendable { let tool: InfraTool; let url: URL; let version: SemVer; let source: ToolSource }
enum ToolError: Error, Equatable { case missing(InfraTool, String); case checksumMismatch(InfraTool); case downloadFailed(InfraTool, String) }
protocol ToolDownloading: Sendable { func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL }
final class ToolResolver: @unchecked Sendable {
    init(searchPath: [URL], managedRoot: URL, runner: CommandRunner, downloader: ToolDownloading,
         pins: [InfraTool: ToolPin] = ToolPins.all)
    func resolve(_ tool: InfraTool, provision: Bool, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ResolvedTool
    static func defaultSearchPath() -> [URL]   // login PATH, /opt/homebrew/bin, /usr/local/bin, Tailscale.app
}
```

Pins (fill real values in Step 3 from each project's release page, recording the URL and SHA-256 you verified by downloading once and running `shasum -a 256`; never invent a hash): `tofu` 1.8.x darwin_arm64 zip; `aws` AWSCLIV2.pkg; `gcloud` darwin-arm google-cloud-cli tarball; `tailscale` no managed copy.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlightDeck

final class ToolResolverTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A fake tool: a shell script printing `output` for any arguments.
    func fake(_ name: String, prints output: String, in sub: String = "bin") throws {
        let url = dir.appendingPathComponent(sub).appendingPathComponent(name)
        try "#!/bin/sh\necho '\(output)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    struct NoDownload: ToolDownloading { func fetch(_ u: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL { throw ToolError.downloadFailed(.tofu, "offline") } }

    func resolver(_ downloader: ToolDownloading = NoDownload()) -> ToolResolver {
        ToolResolver(searchPath: [dir.appendingPathComponent("bin")], managedRoot: dir.appendingPathComponent("managed"),
                     runner: SystemCommandRunner(), downloader: downloader)
    }

    func testUsesCompatibleCopyOnPath() async throws {
        try fake("tofu", prints: "OpenTofu v1.8.3\non darwin_arm64")
        let r = try await resolver().resolve(.tofu, provision: false)
        XCTAssertEqual(r.source, .path); XCTAssertEqual(r.version, SemVer(major: 1, minor: 8, patch: 3))
    }

    func testTooOldOnPathIsNotUsed() async throws {
        try fake("tofu", prints: "OpenTofu v1.6.0")
        do { _ = try await resolver().resolve(.tofu, provision: false); XCTFail() }
        catch ToolError.missing(.tofu, let why) { XCTAssertTrue(why.contains("1.6.0"), why) }
    }

    func testNextMajorIsNotUsed() async throws {
        try fake("tofu", prints: "OpenTofu v2.0.0")
        do { _ = try await resolver().resolve(.tofu, provision: false); XCTFail() } catch ToolError.missing {}
    }

    func testUnparseableVersionIsNotUsed() async throws {
        try fake("aws", prints: "something odd")
        do { _ = try await resolver().resolve(.aws, provision: false); XCTFail() } catch ToolError.missing {}
    }

    func testAWSAndGcloudVersionShapes() async throws {
        try fake("aws", prints: "aws-cli/2.17.4 Python/3.11 Darwin/25 exe/arm64")
        try fake("gcloud", prints: "Google Cloud SDK 495.0.0\nbq 2.1.8")
        let r = resolver()
        let aws = try await r.resolve(.aws, provision: false)
        let gc = try await r.resolve(.gcloud, provision: false)
        XCTAssertEqual(aws.version.minor, 17); XCTAssertEqual(gc.version.major, 495)
    }

    func testTailscaleIsNeverProvisioned() async throws {
        do { _ = try await resolver().resolve(.tailscale, provision: true); XCTFail() }
        catch ToolError.missing(.tailscale, _) {}
    }

    func testChecksumMismatchIsHardFailure() async throws {
        struct BadDownload: ToolDownloading {
            let file: URL
            func fetch(_ u: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL { file }
        }
        let junk = dir.appendingPathComponent("junk.zip"); try Data("nope".utf8).write(to: junk)
        do { _ = try await resolver(BadDownload(file: junk)).resolve(.tofu, provision: true); XCTFail() }
        catch ToolError.checksumMismatch(.tofu) {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("managed/tofu").path),
                       "nothing is unpacked from an unverified download")
    }

    func testPrefersPathOverManaged() async throws {
        try fake("tofu", prints: "OpenTofu v1.9.0")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("managed/tofu/1.8.3"), withIntermediateDirectories: true)
        try fake("tofu", prints: "OpenTofu v1.8.3", in: "managed/tofu/1.8.3")
        XCTAssertEqual(try await resolver().resolve(.tofu, provision: false).source, .path)
    }

    func testSemVerParse() {
        XCTAssertEqual(SemVer.parse("v1.8.3"), SemVer(major: 1, minor: 8, patch: 3))
        XCTAssertEqual(SemVer.parse("495.0.0"), SemVer(major: 495, minor: 0, patch: 0))
        XCTAssertEqual(SemVer.parse("1.70"), SemVer(major: 1, minor: 70, patch: 0))
        XCTAssertNil(SemVer.parse("x"))
    }
}
```

- [ ] **Step 2: Run** `FD_TEST_FILTER=ToolResolverTests ./scripts/test-unit.sh 2>&1 | tee /tmp/t.log; rg -n "error:|failed \(" /tmp/t.log` → compile errors.
- [ ] **Step 3: Implement.**
  - Version extraction per tool: run `<bin> <versionArgs>` with a 5 s timeout (wrap `CommandRunner.run` in `withThrowingTaskGroup` racing `Task.sleep`); regex the first `\d+\.\d+(\.\d+)?` after the tool-specific prefix (`OpenTofu v`, `aws-cli/`, `Google Cloud SDK `, tailscale prints the bare version on line 1).
  - Search: each dir in `searchPath`, executable named `tofu|aws|gcloud|tailscale`; for tailscale also `/Applications/Tailscale.app/Contents/MacOS/Tailscale` (reuse `TailscaleCLI.candidates` in `HostPairingAddresses.swift:109`). First compatible wins. Record the incompatible ones in the `.missing` message ("found 1.6.0 at …, need >= 1.8").
  - Managed: `<managedRoot>/<tool>/<version>/…`; if already unpacked and the version check passes → use. Else if `provision` and a pin has an asset: `downloader.fetch` → SHA-256 (CryptoKit) vs pin → mismatch: delete download, throw `.checksumMismatch`; else unpack to a temp dir then atomically rename into place (`ditto -x -k` for zip, `tar -xzf` for tarball, `installer -pkg … -target CurrentUserHomeDirectory -applyChoiceChangesXML` for the aws pkg per Task 0 P3). Re-run the version check on the unpacked binary.
  - `defaultSearchPath()`: `LoginShellPath.resolve()?.split(":")` + `/opt/homebrew/bin` + `/usr/local/bin`, de-duplicated.
  - `URLSessionToolDownloader: ToolDownloading` using `URLSession.download` with a delegate for progress.
  - Managed root in the app: `FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory()` + `/tools`.
- [ ] **Step 4: Run** the filter → PASS.
- [ ] **Step 5: Commit** — `feat: use a compatible tofu, aws or gcloud from PATH or fetch a verified copy`.

---

### Task 7: `TofuRunner` and the per-machine workdir

**Files:**
- Create: `Sources/FlightDeck/Infra/TofuRunner.swift`, `InfraWorkdir.swift`
- Test: `Tests/FlightDeckTests/TofuRunnerTests.swift`, `InfraWorkdirTests.swift`

**Interfaces:**
- Consumes: `ResolvedTool` (Task 6), `CommandRunner` streaming `onStdout`.
- Produces:

```swift
struct TofuProgress: Equatable, Sendable { let resource: String; let action: String; let done: Bool }
struct TofuOutputs: Equatable, Sendable { let address: String; let instanceID: String?; let hourlyUSD: Double? }
enum TofuError: Error, Equatable { case failed(step: String, message: String); case missingOutput(String) }
protocol TofuRunning: Sendable {
    func initialize(workdir: URL) async throws
    func apply(workdir: URL, progress: @escaping @Sendable (TofuProgress) -> Void) async throws
    func destroy(workdir: URL, progress: @escaping @Sendable (TofuProgress) -> Void) async throws
    func outputs(workdir: URL) async throws -> TofuOutputs
    func refreshShowsGone(workdir: URL) async throws -> Bool
}
struct LiveTofuRunner: TofuRunning { init(tofu: URL, pluginCache: URL, runner: CommandRunner, environment: [String: String]) }
enum InfraWorkdir {
    static func prepare(root: URL, name: String, moduleSource: URL, vars: [String: InfraVar]) throws -> URL
}
enum InfraVar: Encodable, Equatable { case string(String), number(Double), bool(Bool), map([String: String]) }
```

- [ ] **Step 1: Write the failing tests**

```swift
// TofuRunnerTests.swift — drives LiveTofuRunner against a fake `tofu` script
@MainActor final class TofuRunnerTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tofu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    func fakeTofu(_ body: String) throws -> URL {
        let u = dir.appendingPathComponent("tofu")
        try "#!/bin/sh\n\(body)\n".write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }

    func testApplyStreamsJSONProgress() async throws {
        let tofu = try fakeTofu("""
        echo '{"@level":"info","type":"apply_start","hook":{"resource":{"addr":"aws_instance.this"},"action":"create"}}'
        echo '{"@level":"info","type":"apply_complete","hook":{"resource":{"addr":"aws_instance.this"},"action":"create"}}'
        """)
        let r = LiveTofuRunner(tofu: tofu, pluginCache: dir, runner: SystemCommandRunner(), environment: [:])
        let seen = LockedBox<[TofuProgress]>([])
        try await r.apply(workdir: dir) { p in seen.mutate { $0.append(p) } }
        XCTAssertEqual(seen.value, [TofuProgress(resource: "aws_instance.this", action: "create", done: false),
                                    TofuProgress(resource: "aws_instance.this", action: "create", done: true)])
    }

    func testFailureCarriesTheDiagnostic() async throws {
        let tofu = try fakeTofu("""
        echo '{"@level":"error","type":"diagnostic","diagnostic":{"summary":"UnauthorizedOperation","detail":"not allowed"}}'
        exit 1
        """)
        let r = LiveTofuRunner(tofu: tofu, pluginCache: dir, runner: SystemCommandRunner(), environment: [:])
        do { try await r.apply(workdir: dir) { _ in }; XCTFail() }
        catch TofuError.failed(let step, let message) { XCTAssertEqual(step, "apply"); XCTAssertTrue(message.contains("UnauthorizedOperation")) }
    }

    func testOutputsParse() async throws {
        let tofu = try fakeTofu(#"echo '{"fd_address":{"value":"198.51.100.7"},"fd_instance_id":{"value":"i-0abc"},"fd_hourly_usd":{"value":0.8}}'"#)
        let r = LiveTofuRunner(tofu: tofu, pluginCache: dir, runner: SystemCommandRunner(), environment: [:])
        XCTAssertEqual(try await r.outputs(workdir: dir), TofuOutputs(address: "198.51.100.7", instanceID: "i-0abc", hourlyUSD: 0.8))
    }

    func testMissingAddressIsAnError() async throws {
        let tofu = try fakeTofu(#"echo '{}'"#)
        let r = LiveTofuRunner(tofu: tofu, pluginCache: dir, runner: SystemCommandRunner(), environment: [:])
        do { _ = try await r.outputs(workdir: dir); XCTFail() } catch TofuError.missingOutput("fd_address") {}
    }
}

// InfraWorkdirTests.swift
final class InfraWorkdirTests: XCTestCase {
    func testCopiesModuleAndWritesVars() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wd-\(UUID().uuidString)")
        let module = tmp.appendingPathComponent("src"); try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try "resource {}".write(to: module.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        let wd = try InfraWorkdir.prepare(root: tmp.appendingPathComponent("infra"), name: "gpu", moduleSource: module,
                                          vars: ["fd_name": .string("gpu"), "disk_gb": .number(100), "spot": .bool(false)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: wd.appendingPathComponent("module/main.tf").path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: wd.appendingPathComponent("module/fd.auto.tfvars.json"))) as! [String: Any]
        XCTAssertEqual(json["fd_name"] as? String, "gpu"); XCTAssertEqual(json["disk_gb"] as? Double, 100)
    }
    func testRecopyKeepsState() throws {
        // terraform.tfstate in the workdir survives a second prepare (a user module is re-copied each up).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wd-\(UUID().uuidString)")
        let module = tmp.appendingPathComponent("src"); try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try "a".write(to: module.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        let wd = try InfraWorkdir.prepare(root: tmp, name: "x", moduleSource: module, vars: [:])
        try "state".write(to: wd.appendingPathComponent("module/terraform.tfstate"), atomically: true, encoding: .utf8)
        _ = try InfraWorkdir.prepare(root: tmp, name: "x", moduleSource: module, vars: [:])
        XCTAssertEqual(try String(contentsOf: wd.appendingPathComponent("module/terraform.tfstate")), "state")
    }
}
```

`LockedBox` — use the existing test helper if the test target has one (`rg -n "final class LockedBox|struct Locked" Tests/`); otherwise add a 10-line `final class LockedBox<T>: @unchecked Sendable` with an `NSLock` in this test file.

- [ ] **Step 2: Run** `FD_TEST_FILTER=TofuRunnerTests,InfraWorkdirTests ./scripts/test-unit.sh` → compile errors.
- [ ] **Step 3: Implement.** Commands: `tofu -chdir=<wd>/module init -input=false -no-color` (env `TF_PLUGIN_CACHE_DIR=<pluginCache>`, `TF_IN_AUTOMATION=1`), `apply -auto-approve -input=false -json`, `destroy -auto-approve -input=false -json`, `output -json`, `plan -refresh-only -detailed-exitcode -json` (`refreshShowsGone` = the refresh found the instance resource deleted: parse `resource_drift` lines with `"action":"delete"` for the resource whose addr ends in the module's instance; exit 0 → false). Parse each stdout line as JSON; `apply_start`/`apply_complete` → `TofuProgress`; `diagnostic` with `@level == "error"` collected into the failure message. Non-zero exit → `.failed(step:, message: collected diagnostics or stderr tail)`. `InfraWorkdir.prepare`: `<root>/<name>/module/`; copy every file from `moduleSource` except `terraform.tfstate*`, `.terraform/`; write `fd.auto.tfvars.json` with sorted keys; never delete existing state.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat: drive OpenTofu with streamed progress from a per-machine workdir`.

---

### Task 8: `CloudInitRenderer`

**Files:**
- Create: `Sources/FlightDeck/Infra/CloudInitRenderer.swift`
- Test: `Tests/FlightDeckTests/CloudInitRendererTests.swift`, golden files in `Tests/FlightDeckTests/Fixtures/cloud-init/{public-aws,tailnet-gcp}.yaml`

**Interfaces:**
- Consumes: `EnrollmentPayload` (Task 4), `LinuxHostInstaller.command(info:)` values (`AddHostSheet.swift:12-23`: `FDHostdReleaseBaseURL`, `FDHostdInstallerSHA256`).
- Produces:

```swift
struct CloudInitOptions: Equatable, Sendable {
    var installerBaseURL: String; var installerSHA256: String
    var ttlSeconds: Int; var cloud: String            // "aws" | "gcp"
    var tailscaleAuthKey: String?; var tailscaleHostname: String?
}
enum CloudInitRenderer { static func render(_ p: EnrollmentPayload, _ o: CloudInitOptions) throws -> String }
```

- [ ] **Step 1: Write the failing tests** — golden comparisons plus invariants:

```swift
final class CloudInitRendererTests: XCTestCase {
    let payload = EnrollmentPayload(version: 1, slot: UUID(uuidString: "6F0B2C1E-8E37-4D7A-9D0A-3C5E2B1A9F00")!,
        secretHex: String(repeating: "5a", count: 32), controllerName: "controller", idleSeconds: 1800,
        issuedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let base = CloudInitOptions(installerBaseURL: "https://example.invalid/hostd", installerSHA256: String(repeating: "0", count: 64),
                                ttlSeconds: 14_400, cloud: "aws", tailscaleAuthKey: nil, tailscaleHostname: nil)

    func golden(_ name: String) throws -> String {
        try String(contentsOf: Bundle(for: Self.self).url(forResource: name, withExtension: "yaml", subdirectory: "cloud-init")!)
    }
    func testPublicAWSMatchesGolden() throws { XCTAssertEqual(try CloudInitRenderer.render(payload, base), try golden("public-aws")) }
    func testTailnetGCPMatchesGolden() throws {
        var o = base; o.cloud = "gcp"; o.tailscaleAuthKey = "tskey-auth-EXAMPLE"; o.tailscaleHostname = "fd-gpu"
        XCTAssertEqual(try CloudInitRenderer.render(payload, o), try golden("tailnet-gcp"))
    }
    func testInvariants() throws {
        let y = try CloudInitRenderer.render(payload, base)
        XCTAssertTrue(y.hasPrefix("#cloud-config\n"))
        XCTAssertTrue(y.contains("/run/flightdeck/enroll.json")); XCTAssertTrue(y.contains("permissions: '0600'"))
        XCTAssertTrue(y.contains("--no-pair")); XCTAssertTrue(y.contains("flightdeck-hostd enroll --file /run/flightdeck/enroll.json"))
        XCTAssertTrue(y.contains("shutdown -h +240"))
        XCTAssertFalse(y.contains("tailscale"))
    }
    func testRejectsUnsafeValues() {
        var o = base; o.tailscaleHostname = "x; rm -rf /"
        o.tailscaleAuthKey = "k"
        XCTAssertThrowsError(try CloudInitRenderer.render(payload, o))
    }
}
```

Write both golden files by hand in Step 3 from the template below (they are the reviewed contract), and add `Tests/FlightDeckTests/Fixtures/cloud-init` to the FlightDeckTests target as a folder resource (`project.yml`, pattern at :237-239).

- [ ] **Step 2: Run** `FD_TEST_FILTER=CloudInitRendererTests ./scripts/test-unit.sh` → fails.
- [ ] **Step 3: Implement.** Output (exact layout; user module via `runcmd` running as the default user `ubuntu`/first non-root user — use `cloud-init`'s `${USER}`-free approach: create user `flightdeck` with linger):

```yaml
#cloud-config
users:
  - default
  - name: flightdeck
    shell: /bin/bash
    lock_passwd: true
write_files:
  - path: /run/flightdeck/enroll.json
    owner: root:root
    permissions: '0600'
    content: |
      <single-line JSON of the payload, ISO-8601 dates, sorted keys>
runcmd:
  - [ chown, "flightdeck:flightdeck", /run/flightdeck/enroll.json ]
  - [ loginctl, enable-linger, flightdeck ]
  - [ su, "-", flightdeck, "-c", "curl -fsSL <base>/hostd-install.sh | sh -s -- --sha256 <sha> --no-pair" ]
  - [ su, "-", flightdeck, "-c", "~/.local/bin/flightdeck-hostd enroll --file /run/flightdeck/enroll.json" ]
  # tailnet mode only:
  - [ sh, -c, "curl -fsSL https://tailscale.com/install.sh | sh" ]
  - [ tailscale, up, "--auth-key=<key>", "--hostname=<host>", "--advertise-tags=tag:flightdeck-cloud" ]
  # aws only (gcp uses max_run_duration in the preset):
  - [ shutdown, -h, "+<ttl minutes>" ]
```

Validation: `tailscaleHostname` must match `^[a-z0-9-]{1,63}$`; auth key `^[A-Za-z0-9_-]+$`; installer base must be `https://`; sha 64 hex. Both modes on AWS include the shutdown line; on GCP it is omitted (the preset enforces TTL). Note: `/run/flightdeck` is created by `write_files` (tmpfs on Ubuntu).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat: render cloud-init that installs hostd, enrolls it and arms the TTL`.

---

### Task 9: OpenTofu presets `aws-linux` and `gcp-linux`

**Files:**
- Create: `Resources/Infra/presets/aws-linux/{versions.tf,variables.tf,main.tf,outputs.tf,.terraform.lock.hcl,tests/preset.tftest.hcl}`, same for `gcp-linux`
- Create: `scripts/test-infra-presets.sh`
- Modify: `project.yml` (FlightDeck target: `- path: Resources/Infra` `type: folder` `buildPhase: resources`, pattern at :91-93)

**Interfaces:**
- Produces (module contract, spec §5.3): inputs `fd_name` (string), `fd_user_data` (string), `fd_labels` (map(string)), `fd_allow_cidr` (string, default `""` = tailnet mode, no inbound rule), `region`, `instance_type`, `arch` (`"x86_64"|"arm64"`, default derived), `disk_gb` (default 50), `spot` (default false), `ttl_seconds` (number); GCP adds `project`, `zone` (default `"${region}-a"`). Outputs `fd_address`, `fd_instance_id`.

- [ ] **Step 1: Write the failing `tofu test`s** (mock providers, no credentials):

```hcl
# Resources/Infra/presets/aws-linux/tests/preset.tftest.hcl
mock_provider "aws" {
  mock_data "aws_ami" { defaults = { id = "ami-0123456789abcdef0" } }
}
variables {
  fd_name = "gpu"  fd_user_data = "#cloud-config\n"  fd_labels = { flightdeck = "1", flightdeck-owner = "ctl", flightdeck-name = "gpu" }
  region = "us-east-1"  instance_type = "g6.xlarge"  ttl_seconds = 3600
}
run "tailnet_mode_has_no_inbound_rule" {
  command = plan
  assert { condition = aws_instance.this.metadata_options[0].http_tokens == "required" error_message = "IMDSv2 must be required" }
  assert { condition = aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1 error_message = "hop limit 1" }
  assert { condition = aws_instance.this.instance_initiated_shutdown_behavior == "terminate" error_message = "shutdown must terminate" }
  assert { condition = aws_instance.this.tags["flightdeck"] == "1" error_message = "labels on the instance" }
  assert { condition = length(aws_vpc_security_group_ingress_rule.hostd) == 0 error_message = "no inbound in tailnet mode" }
}
run "public_mode_admits_only_the_controller" {
  command = plan
  variables { fd_allow_cidr = "198.51.100.7/32" }
  assert { condition = aws_vpc_security_group_ingress_rule.hostd[0].cidr_ipv4 == "198.51.100.7/32" error_message = "only /32" }
  assert { condition = aws_vpc_security_group_ingress_rule.hostd[0].from_port == 47410 && aws_vpc_security_group_ingress_rule.hostd[0].to_port == 47410 error_message = "only 47410" }
}
run "spot" {
  command = plan
  variables { spot = true }
  assert { condition = length(aws_instance.this.instance_market_options) == 1 error_message = "spot market options" }
}
```

```hcl
# Resources/Infra/presets/gcp-linux/tests/preset.tftest.hcl
mock_provider "google" {}
variables {
  fd_name = "gpu"  fd_user_data = "#cloud-config\n"  fd_labels = { flightdeck = "1", flightdeck-owner = "ctl", flightdeck-name = "gpu" }
  project = "example-project"  region = "us-central1"  instance_type = "g2-standard-4"  ttl_seconds = 3600
}
run "ttl_is_enforced_by_the_cloud" {
  command = plan
  assert { condition = google_compute_instance.this.scheduling[0].max_run_duration[0].seconds == 3600 error_message = "max_run_duration" }
  assert { condition = google_compute_instance.this.scheduling[0].instance_termination_action == "DELETE" error_message = "DELETE on TTL" }
  assert { condition = google_compute_instance.this.labels["flightdeck"] == "1" error_message = "labels" }
  assert { condition = google_compute_instance.this.metadata["user-data"] == "#cloud-config\n" error_message = "user-data" }
}
run "gpu_types_terminate_on_maintenance" {
  command = plan
  assert { condition = google_compute_instance.this.scheduling[0].on_host_maintenance == "TERMINATE" error_message = "GPU needs TERMINATE" }
}
run "public_mode_firewall" {
  command = plan
  variables { fd_allow_cidr = "198.51.100.7/32" }
  assert { condition = google_compute_firewall.hostd[0].source_ranges == toset(["198.51.100.7/32"]) error_message = "only /32" }
}
```

```bash
#!/usr/bin/env bash
# scripts/test-infra-presets.sh — `tofu test` for each bundled preset against mock providers.
# No credentials and no cloud calls: mock_provider replaces every provider.
set -euo pipefail
cd "$(dirname "$0")/.."
TOFU=${TOFU:-$(command -v tofu || true)}
[ -n "$TOFU" ] || { echo "tofu not found (brew install opentofu, or TOFU=/path)"; exit 2; }
for p in Resources/Infra/presets/*/; do
  echo "== $p"; (cd "$p" && "$TOFU" init -backend=false -input=false >/dev/null && "$TOFU" test)
done
echo "PRESETS PASS"
```

- [ ] **Step 2: Run** `./scripts/test-infra-presets.sh` → fails (no modules).
- [ ] **Step 3: Write the modules.**
  - **aws-linux:** `required_providers { aws = { source = "hashicorp/aws", version = "~> 5.70" } }`, `required_version = ">= 1.8"`. `data "aws_ami"` Ubuntu 24.04 (owner `099720109477`, name `ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${arch == "arm64" ? "arm64" : "amd64"}-server-*`, most_recent). Default VPC (`data "aws_vpc" default = true`), `aws_security_group.this` (egress all, tags = labels), `aws_vpc_security_group_ingress_rule.hostd` with `count = var.fd_allow_cidr == "" ? 0 : 1`, tcp 47410, `cidr_ipv4 = var.fd_allow_cidr`. `aws_instance.this`: `ami`, `instance_type`, `user_data = var.fd_user_data`, `user_data_replace_on_change = true`, `associate_public_ip_address = var.fd_allow_cidr != ""`, `metadata_options { http_tokens = "required" http_put_response_hop_limit = 1 }`, `instance_initiated_shutdown_behavior = "terminate"`, `root_block_device { volume_size = var.disk_gb volume_type = "gp3" tags = var.fd_labels }`, `dynamic "instance_market_options"` when `spot` (`market_type = "spot"`, `spot_options { instance_interruption_behavior = "terminate" }`), `tags = merge(var.fd_labels, { Name = "fd-${var.fd_name}" })`, `volume_tags` not used (conflicts with root_block_device tags). Outputs: `fd_address = var.fd_allow_cidr == "" ? aws_instance.this.private_ip : aws_instance.this.public_ip` (tailnet mode replaces it with the tailnet IP later, Task 14), `fd_instance_id = aws_instance.this.id`.
  - **gcp-linux:** `google` provider `~> 6.8`. `google_compute_instance.this`: `machine_type`, `zone`, boot disk `ubuntu-os-cloud/ubuntu-2404-lts-${arch == "arm64" ? "arm64" : "amd64"}` size `disk_gb`, `network_interface { network = "default" dynamic "access_config" { for_each = var.fd_allow_cidr == "" ? [] : [1] content {} } }`, `metadata = { user-data = var.fd_user_data }`, `labels = var.fd_labels`, `scheduling { provisioning_model = spot ? "SPOT" : "STANDARD" preemptible = spot automatic_restart = false on_host_maintenance = "TERMINATE" instance_termination_action = "DELETE" max_run_duration { seconds = var.ttl_seconds } }`, `shielded_instance_config { enable_secure_boot = true }`, `tags = ["fd-${var.fd_name}"]`. `google_compute_firewall.hostd` count by `fd_allow_cidr`, `allow { protocol = "tcp" ports = ["47410"] }`, `source_ranges = [var.fd_allow_cidr]`, `target_tags = ["fd-${var.fd_name}"]`. GPU attach: `dynamic "guest_accelerator"` only for non-`g2`/`a2` types where the GPU is not built into the machine type — YAGNI: g2/a2 machine types include GPUs, so no `guest_accelerator` block in v1. Outputs as AWS (`network_ip` / `access_config[0].nat_ip`).
  - Commit each `.terraform.lock.hcl` generated by `tofu providers lock -platform=darwin_arm64 -platform=darwin_amd64` so `init` is reproducible.
  - Adjust the test assertions only if a provider attribute name differs from the provider docs you read in Task 0 (record any change in the commit body); never remove an assertion.
- [ ] **Step 4: Run** `./scripts/test-infra-presets.sh` → `PRESETS PASS`; `./scripts/build.sh` succeeds and `ls "DerivedData/Build/Products/Debug/Flight Deck.app/Contents/Resources/Infra/presets"` lists both (do not launch the app).
- [ ] **Step 5: Commit** — `feat: bundle aws and gcp presets that label everything and cannot outlive their ttl`.

---

### Task 10: `InfraRegistry` and `CostLedger`

**Files:**
- Create: `Sources/FlightDeck/Infra/InfraRegistry.swift`, `CostLedger.swift`
- Test: `Tests/FlightDeckTests/InfraRegistryTests.swift`, `CostLedgerTests.swift`

**Interfaces:**
- Produces:

```swift
enum InfraState: String, Codable, Sendable { case planned, provisioning, enrolling, ready, idle, destroying, gone, failed, orphaned }
enum NetworkMode: String, Codable, Sendable { case tailnet, `public` }
struct InfraMachine: Codable, Equatable, Identifiable, Sendable {
    var name: String; var repoRoot: String; var cloud: String; var instanceType: String; var region: String
    var slot: UUID?; var state: InfraState; var failure: String?; var network: NetworkMode
    var createdAt: Date; var deadline: Date; var idle: Duration; var allowCIDR: String?
    var instanceID: String?; var address: String?; var hourlyUSD: Double?
    var id: String { name }
}
@MainActor final class InfraRegistry {
    init(fileURL: URL, workRoot: URL)
    private(set) var machines: [InfraMachine]
    func upsert(_ m: InfraMachine) throws
    func remove(name: String) throws
    func machine(named: String) -> InfraMachine?
    func workdir(for name: String) -> URL
}
struct CostSegment: Codable, Equatable, Sendable { let name: String; let start: Date; var end: Date?; let hourlyUSD: Double }
@MainActor final class CostLedger {
    init(fileURL: URL, calendar: Calendar = .current)
    func open(name: String, hourlyUSD: Double, at: Date) throws
    func close(name: String, at: Date) throws
    func spent(name: String, now: Date) -> Double
    func monthToDate(now: Date) -> Double
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor final class CostLedgerTests: XCTestCase {
    var url: URL!
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    override func setUp() { url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID()).json") }
    func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testSpentIsRateTimesElapsed() throws {
        let l = CostLedger(fileURL: url, calendar: cal)
        try l.open(name: "gpu", hourlyUSD: 0.8, at: d("2026-10-10T10:00:00Z"))
        XCTAssertEqual(l.spent(name: "gpu", now: d("2026-10-10T11:30:00Z")), 1.2, accuracy: 1e-9)
        try l.close(name: "gpu", at: d("2026-10-10T12:00:00Z"))
        XCTAssertEqual(l.spent(name: "gpu", now: d("2026-10-10T20:00:00Z")), 1.6, accuracy: 1e-9)
    }

    /// Review Focus 4.
    func testSegmentSplitsAcrossMonths() throws {
        let l = CostLedger(fileURL: url, calendar: cal)
        try l.open(name: "gpu", hourlyUSD: 1, at: d("2026-10-31T22:00:00Z"))
        XCTAssertEqual(l.monthToDate(now: d("2026-11-01T03:00:00Z")), 3, accuracy: 1e-9, "only November's 3 hours")
        XCTAssertEqual(l.monthToDate(now: d("2026-10-31T23:00:00Z")), 1, accuracy: 1e-9)
    }

    func testPersistsAcrossInstances() throws {
        try CostLedger(fileURL: url, calendar: cal).open(name: "a", hourlyUSD: 2, at: d("2026-10-10T00:00:00Z"))
        XCTAssertEqual(CostLedger(fileURL: url, calendar: cal).spent(name: "a", now: d("2026-10-10T01:00:00Z")), 2, accuracy: 1e-9)
    }
}

@MainActor final class InfraRegistryTests: XCTestCase {
    func testUpsertPersistsAndReloads() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ir-\(UUID())")
        let m = InfraMachine(name: "gpu", repoRoot: "/repo", cloud: "aws", instanceType: "g6.xlarge", region: "us-east-1",
            slot: UUID(), state: .provisioning, failure: nil, network: .public, createdAt: Date(timeIntervalSince1970: 1),
            deadline: Date(timeIntervalSince1970: 3601), idle: .init(seconds: 1800), allowCIDR: "198.51.100.7/32",
            instanceID: nil, address: nil, hourlyUSD: 0.8)
        try InfraRegistry(fileURL: tmp.appendingPathComponent("infra.json"), workRoot: tmp).upsert(m)
        XCTAssertEqual(InfraRegistry(fileURL: tmp.appendingPathComponent("infra.json"), workRoot: tmp).machine(named: "gpu"), m)
    }
}
```

- [ ] **Step 2: Run** → compile errors.
- [ ] **Step 3: Implement.** Both files: `{version: 1, …}` JSON, atomic write (`Data.write(options: .atomic)`), ISO-8601 dates. `monthToDate`: sum over segments of `rate × overlap(segment, [startOfMonth(now), now])` in hours. `close` closes the open segment for that name; `open` closes any open one first. Ledger lives inside `infra.json`? No — separate `infra-ledger.json` beside it (separate responsibility; ledger keeps history after a machine is removed).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat: persist cloud machines and their spend across relaunches and months`.

---

### Task 11: `PriceCatalog`

**Files:**
- Create: `Sources/FlightDeck/Infra/PriceCatalog.swift`
- Test: `Tests/FlightDeckTests/PriceCatalogTests.swift`, fixtures `Tests/FlightDeckTests/Fixtures/prices/{aws-getproducts-g6.json,aws-spot.json,gcp-skus-compute.json}`

**Interfaces:**
- Produces:

```swift
struct PriceQuery: Hashable, Sendable { let cloud: String; let region: String; let instanceType: String; let spot: Bool; let diskGB: Int }
protocol PriceSource: Sendable { func hourly(_ q: PriceQuery) async throws -> Double }
struct AWSPriceSource: PriceSource { init(aws: URL, runner: CommandRunner, profile: String?) }      // aws pricing get-products / ec2 describe-spot-price-history
struct GCPPriceSource: PriceSource { init(token: @Sendable () async throws -> String, http: HTTPFetching, machineTypes: GCPMachineTypes) }
protocol HTTPFetching: Sendable { func get(_ url: URL, headers: [String: String]) async throws -> Data }
final class PriceCatalog: @unchecked Sendable {
    init(sources: [String: PriceSource], cacheURL: URL, now: @escaping @Sendable () -> Date = Date.init, ttl: TimeInterval = 86_400)
    func hourly(_ q: PriceQuery) async -> Double?   // nil = unknown (no cache, lookup failed)
}
```

- [ ] **Step 1: Write the failing tests** — parse captured fixtures (record them in Step 3 by running the real CLI/API once by hand with your own credentials, then **scrub** account IDs and anything identifying; keep only the price structure):

```swift
final class PriceCatalogTests: XCTestCase {
    func testAWSOnDemandPlusDisk() throws {
        let json = try fixture("aws-getproducts-g6")
        // g6.xlarge us-east-1 on-demand from the fixture, plus 100 GB gp3 at $0.08/GB-month / 730 h
        XCTAssertEqual(try AWSPriceSource.parseOnDemand(json) + AWSPriceSource.diskHourly(gb: 100), 0.8048 + 100 * 0.08 / 730, accuracy: 1e-4)
    }
    func testGCPMachineFromSKUs() throws {
        let skus = try fixture("gcp-skus-compute")
        // Expected = P4 published price for e2-standard-2 in us-central1 (Task 0), within 1%.
        let price = try GCPPriceSource.price(machineType: "e2-standard-2", region: "us-central1", spot: false, skus: skus, shapes: .builtIn)
        XCTAssertEqual(price, P4.e2Standard2UsCentral1, accuracy: P4.e2Standard2UsCentral1 * 0.01)
    }
    func testCacheServesWithinTTLAndUnknownWithoutIt() async {
        struct Counting: PriceSource { let box: LockedBox<Int>; func hourly(_ q: PriceQuery) async throws -> Double { box.mutate { $0 += 1 }; return 1.5 } }
        struct Failing: PriceSource { func hourly(_ q: PriceQuery) async throws -> Double { throw URLError(.notConnectedToInternet) } }
        let box = LockedBox(0); var now = Date(timeIntervalSince1970: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID()).json")
        let q = PriceQuery(cloud: "aws", region: "r", instanceType: "t", spot: false, diskGB: 0)
        let c = PriceCatalog(sources: ["aws": Counting(box: box)], cacheURL: url, now: { now })
        _ = await c.hourly(q); _ = await c.hourly(q)
        XCTAssertEqual(box.value, 1)
        let offline = PriceCatalog(sources: ["aws": Failing()], cacheURL: url, now: { now })
        let cached = await offline.hourly(q)
        XCTAssertEqual(cached, 1.5)
        now = Date(timeIntervalSince1970: 90_000)
        let stale = await offline.hourly(q)
        XCTAssertNil(stale, "expired cache and failed lookup is unknown, never a guess")
    }
}
```

`P4` is a tiny enum in the test file holding the published prices recorded by Task 0 Step 4 (copy the numbers from the probes file). `fixture(_:)` loads `Fixtures/prices/<name>.json` from the test bundle (add the folder to FlightDeckTests as in Task 8).

- [ ] **Step 2: Run** → compile errors.
- [ ] **Step 3: Implement.**
  - AWS on-demand: `aws pricing get-products --region us-east-1 --service-code AmazonEC2 --filters Type=TERM_MATCH,Field=instanceType,Value=<t> Type=TERM_MATCH,Field=regionCode,Value=<r> Type=TERM_MATCH,Field=operatingSystem,Value=Linux Type=TERM_MATCH,Field=tenancy,Value=Shared Type=TERM_MATCH,Field=preInstalledSw,Value=NA Type=TERM_MATCH,Field=capacitystatus,Value=Used --output json`; `PriceList[0]` is a JSON string → `terms.OnDemand.*.priceDimensions.*.pricePerUnit.USD`. Spot: `aws ec2 describe-spot-price-history --region <r> --instance-types <t> --product-descriptions Linux/UNIX --start-time <now> --output json` → max over AZs of `SpotPrice`. Disk gp3 $0.08/GB-month constant in v1 (document the "est.").
  - GCP: `GET https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?currencyCode=USD` (paged, bearer token from `gcloud auth application-default print-access-token`); `GCPMachineTypes.builtIn` maps family → (vCPU, GB RAM, GPU count/type) for the allowlisted families; match SKUs by description patterns from P4 and `serviceRegions` containing the region; price = vCPU×cpuSKU + GB×ramSKU (+ GPU SKU) using `pricingInfo[0].pricingExpression.tieredRates.last.unitPrice` (`units + nanos/1e9`).
  - Cache: JSON keyed by `cloud|region|type|spot|disk` with `fetchedAt`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat: price cloud machines from each cloud's own price list, cached for a day`.

---

### Task 12: `CloudAccounts` — AWS and GCP

**Files:**
- Create: `Sources/FlightDeck/Infra/CloudAccounts.swift`, `AWSAccount.swift`, `GCPAccount.swift`
- Test: `Tests/FlightDeckTests/CloudAccountsTests.swift`

**Interfaces:**
- Produces:

```swift
enum AccountStatus: Equatable, Sendable { case ready(identity: String); case signedOut(fix: String); case unavailable(String) }
struct QuotaCheck: Equatable, Sendable { let ok: Bool; let have: Double; let need: Double; let increaseURL: URL? }
protocol CloudAccount: Sendable {
    var cloud: String { get }
    func status() async -> AccountStatus
    func signIn() async throws                       // opens the browser via the CLI's own flow
    func quota(region: String, instanceType: String) async throws -> QuotaCheck
    func providerEnvironment() -> [String: String]   // AWS_PROFILE / GOOGLE_CLOUD_PROJECT etc. for tofu
}
struct AWSAccount: CloudAccount { init(aws: URL, profile: String?, runner: CommandRunner)
    static func profiles(configText: String) -> [String] }
struct GCPAccount: CloudAccount { init(gcloud: URL, project: String?, runner: CommandRunner) }
```

- [ ] **Step 1: Write the failing tests** — against a fake CLI script (same helper as Task 6, extracted into `Tests/FlightDeckTests/FakeExecutable.swift` in this task):

```swift
final class CloudAccountsTests: XCTestCase {
    func testAWSProfilesFromConfig() {
        let text = "[default]\nregion = us-east-1\n[profile dev]\nsso_session = s\n[sso-session s]\nsso_start_url = https://example.invalid\n"
        XCTAssertEqual(AWSAccount.profiles(configText: text), ["default", "dev"])
    }
    func testAWSReadyFromCallerIdentity() async throws {
        let aws = try FakeExecutable.make("aws", script: #"echo '{"Account":"123456789012","Arn":"arn:aws:sts::123456789012:assumed-role/x/y"}'"#)
        let s = await AWSAccount(aws: aws, profile: "dev", runner: SystemCommandRunner()).status()
        XCTAssertEqual(s, .ready(identity: "123456789012"))
    }
    func testAWSExpiredSSOSaysHowToFix() async throws {
        let aws = try FakeExecutable.make("aws", script: "echo 'Error when retrieving token from sso: Token has expired and refresh failed' >&2; exit 255")
        guard case .signedOut(let fix) = await AWSAccount(aws: aws, profile: "dev", runner: SystemCommandRunner()).status() else { return XCTFail() }
        XCTAssertTrue(fix.contains("aws sso login --profile dev"), fix)
    }
    func testAWSQuotaForGPUFamily() async throws {
        // G and VT on-demand vCPU quota L-DB2E81BA; g6.xlarge needs 4 vCPU.
        let aws = try FakeExecutable.make("aws", script: #"echo '{"Quota":{"Value":0.0}}'"#)
        let q = try await AWSAccount(aws: aws, profile: nil, runner: SystemCommandRunner()).quota(region: "us-east-1", instanceType: "g6.xlarge")
        XCTAssertFalse(q.ok); XCTAssertEqual(q.need, 4); XCTAssertNotNil(q.increaseURL)
    }
    func testGCPSignedOutWhenNoADC() async throws {
        let gc = try FakeExecutable.make("gcloud", script: "echo 'ERROR: (gcloud.auth.application-default.print-access-token) Your default credentials were not found.' >&2; exit 1")
        guard case .signedOut(let fix) = await GCPAccount(gcloud: gc, project: "example-project", runner: SystemCommandRunner()).status() else { return XCTFail() }
        XCTAssertTrue(fix.contains("gcloud auth application-default login"), fix)
    }
}
```

- [ ] **Step 2: Run** → compile errors.
- [ ] **Step 3: Implement.**
  - AWS status: `aws sts get-caller-identity --output json [--profile p]` → `.ready(Account)`; stderr containing `sso`/`expired`/`Unable to locate credentials` → `.signedOut("aws sso login --profile <p>")` (or `aws configure sso` when no profile). `signIn`: run `aws sso login --profile p` (it opens the browser; await exit). Quota: map instance family → quota code (`L-1216C47A` standard A/C/D/H/I/M/R/T/Z, `L-DB2E81BA` G/VT, `L-417A185B` P; spot equivalents `L-34B43A08`, `L-3819A6DF`, `L-7212CCBC`); vCPUs from `aws ec2 describe-instance-types --instance-types t --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus'`; quota from `aws service-quotas get-service-quota --service-code ec2 --quota-code … --region r`; `increaseURL = https://<region>.console.aws.amazon.com/servicequotas/home/services/ec2/quotas/<code>`. (Running usage is ignored in v1: `need` = this machine's vCPUs; note it as a limitation in FOLLOWUPS.)
  - GCP status: `gcloud auth application-default print-access-token` → ok; `identity` = project. `signIn`: `gcloud auth application-default login`. Quota: `gcloud compute regions describe r --project p --format json` → `quotas[]` metric `CPUS` (or `N2_CPUS` etc. by family) and `NVIDIA_L4_GPUS` for g2; `increaseURL = https://console.cloud.google.com/iam-admin/quotas?project=<p>&pageState=…` (link to the quotas page filtered by metric).
  - Env: AWS `AWS_PROFILE`; GCP `GOOGLE_CLOUD_PROJECT`, `CLOUDSDK_CORE_PROJECT`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat: check aws and gcp sign-in and quota with each cloud's own cli`.

---

### Task 13: `TailnetIntegration` and `HuJSONPatcher`

**Files:**
- Create: `Sources/FlightDeck/Infra/TailnetIntegration.swift`, `HuJSONPatcher.swift`
- Test: `Tests/FlightDeckTests/HuJSONPatcherTests.swift`, `TailnetIntegrationTests.swift`

**Interfaces:**
- Consumes: `TailscaleCLI` (`Sources/FlightDeck/Hosts/HostPairingAddresses.swift:109`), `HTTPFetching` (Task 11; add `post` here).
- Produces:

```swift
struct LocalTailnet: Equatable, Sendable { let running: Bool; let tailnet: String?; let selfIP: String?; let lockEnabled: Bool; let lockSigner: Bool }
struct TailscaleOAuthClient: Codable, Equatable, Sendable { let id: String; let secret: String; let tailnet: String }
enum TailnetMode: Equatable, Sendable { case available(TailscaleOAuthClient); case notRunning; case notConfigured(tailnet: String); case mismatch(local: String, client: String) }
final class TailnetIntegration: @unchecked Sendable {
    init(cli: URL?, http: HTTPFetching, secrets: TailnetSecretStoring)
    func local() async -> LocalTailnet
    func mode() async -> TailnetMode
    func mintAuthKey(client: TailscaleOAuthClient, tag: String, expiry: Duration) async throws -> String
    func nodeAddress(client: TailscaleOAuthClient, hostname: String) async throws -> String?
    func deleteNode(client: TailscaleOAuthClient, hostname: String) async throws
    func signIfSigner(nodeKey: String) async throws -> Bool
}
protocol TailnetSecretStoring: Sendable { func load() -> TailscaleOAuthClient?; func save(_ c: TailscaleOAuthClient) throws; func clear() }
enum HuJSONPatcher {
    struct Patch: Equatable { let original: String; let patched: String; let diff: String }
    static func addFlightDeckRules(to policy: String, tag: String, ownerAutogroup: String) -> Patch?   // nil = cannot place safely
}
```

The rules added (spec §6.1): `"tagOwners": { "tag:flightdeck-cloud": ["autogroup:admin"] }` (merged into an existing `tagOwners`), and one `grants` entry `{ "src": ["autogroup:member"], "dst": ["tag:flightdeck-cloud"], "ip": ["tcp:47410-47411"] }`. Use `"autogroup:member"` (the user's devices) as the source; it grants the tag nothing.

- [ ] **Step 1: Write the failing tests**

```swift
final class HuJSONPatcherTests: XCTestCase {
    let commented = """
    // Our policy
    {
      // owners
      "tagOwners": {
        "tag:ci": ["autogroup:admin"], // trailing comma below
      },
      "grants": [
        {"src": ["*"], "dst": ["*"], "ip": ["*"]},
      ],
    }
    """
    func testInsertsIntoExistingSectionsKeepingComments() throws {
        let p = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: commented, tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        XCTAssertTrue(p.patched.contains("// Our policy")); XCTAssertTrue(p.patched.contains("// trailing comma below"))
        XCTAssertTrue(p.patched.contains(#""tag:flightdeck-cloud": ["autogroup:admin"]"#))
        XCTAssertTrue(p.patched.contains(#""dst": ["tag:flightdeck-cloud"]"#))
        XCTAssertTrue(p.patched.contains("tcp:47410-47411"))
        XCTAssertTrue(p.diff.contains("+"))
    }
    func testCreatesMissingSections() throws {
        let p = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: "{\n  \"acls\": []\n}\n", tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        XCTAssertTrue(p.patched.contains("\"tagOwners\"")); XCTAssertTrue(p.patched.contains("\"grants\""))
    }
    func testIdempotent() throws {
        let once = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: commented, tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        let twice = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: once.patched, tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        XCTAssertEqual(twice.patched, once.patched); XCTAssertTrue(twice.diff.isEmpty)
    }
    func testRefusesWhatItCannotParse() {
        XCTAssertNil(HuJSONPatcher.addFlightDeckRules(to: "{ \"tagOwners\": /* unterminated", tag: "tag:x", ownerAutogroup: "autogroup:admin"))
        XCTAssertNil(HuJSONPatcher.addFlightDeckRules(to: "[1,2]", tag: "tag:x", ownerAutogroup: "autogroup:admin"))
    }
    func testStringsContainingBracesAreNotStructure() throws {
        let tricky = "{ \"note\": \"} { not structure\", \"grants\": [] }"
        let p = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: tricky, tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        XCTAssertTrue(p.patched.contains("\"} { not structure\""))
    }
}

final class TailnetIntegrationTests: XCTestCase {
    func testModeNotRunningWithoutCLI() async {
        let t = TailnetIntegration(cli: nil, http: FakeHTTP(), secrets: MemoryTailnetSecrets())
        let m = await t.mode()
        XCTAssertEqual(m, .notRunning)
    }
    func testModeMismatchRefuses() async throws {
        let cli = try FakeExecutable.make("tailscale", script: #"echo '{"BackendState":"Running","CurrentTailnet":{"Name":"example-tailnet.ts.net"},"Self":{"TailscaleIPs":["100.64.0.2"]}}'"#)
        let secrets = MemoryTailnetSecrets(TailscaleOAuthClient(id: "k", secret: "s", tailnet: "other.ts.net"))
        let m = await TailnetIntegration(cli: cli, http: FakeHTTP(), secrets: secrets).mode()
        XCTAssertEqual(m, .mismatch(local: "example-tailnet.ts.net", client: "other.ts.net"))
    }
    func testMintRequestsEphemeralPreauthorizedSingleUseTaggedKey() async throws {
        let http = FakeHTTP(responses: [
            "https://api.tailscale.com/api/v2/oauth/token": #"{"access_token":"tok","expires_in":3600}"#,
            "https://api.tailscale.com/api/v2/tailnet/-/keys": #"{"key":"tskey-auth-EXAMPLE"}"#])
        let t = TailnetIntegration(cli: nil, http: http, secrets: MemoryTailnetSecrets())
        let key = try await t.mintAuthKey(client: .init(id: "k", secret: "s", tailnet: "example-tailnet.ts.net"), tag: "tag:flightdeck-cloud", expiry: .init(seconds: 900))
        XCTAssertEqual(key, "tskey-auth-EXAMPLE")
        let body = try XCTUnwrap(http.lastBody(for: "https://api.tailscale.com/api/v2/tailnet/-/keys"))
        let caps = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let create = ((caps["capabilities"] as! [String: Any])["devices"] as! [String: Any])["create"] as! [String: Any]
        XCTAssertEqual(create["ephemeral"] as? Bool, true); XCTAssertEqual(create["preauthorized"] as? Bool, true)
        XCTAssertEqual(create["reusable"] as? Bool, false); XCTAssertEqual(create["tags"] as? [String], ["tag:flightdeck-cloud"])
        XCTAssertEqual(caps["expirySeconds"] as? Int, 900)
    }
}
```

`FakeHTTP` (records requests, returns canned bodies by URL) and `MemoryTailnetSecrets` live in `Tests/FlightDeckTests/InfraFakes.swift`, created in this task.

- [ ] **Step 2: Run** → compile errors.
- [ ] **Step 3: Implement.**
  - `HuJSONPatcher`: a tokenizer over HuJSON (strings with escapes, `//` and `/* */` comments, trailing commas). Find the top-level object; locate the `tagOwners` object value and the `grants` array value by key at depth 1. Insert text before each container's closing bracket, matching the indentation of the last member (or 4 spaces), adding a trailing comma per HuJSON style. Missing section → insert `"tagOwners": {…},` / `"grants": […],` before the top-level `}`. Already contains `"tag:flightdeck-cloud"` in tagOwners and a grant whose dst contains it → return unchanged with empty diff. Any tokenizer error, non-object top level, or duplicate key → `nil`. `diff` = unified diff of lines (`+`/`-` prefixes, no context needed beyond 2 lines).
  - Tailscale API: OAuth token `POST https://api.tailscale.com/api/v2/oauth/token` (form `client_id`, `client_secret`); keys `POST /api/v2/tailnet/-/keys` with `{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":true,"preauthorized":true,"tags":[tag]}}},"expirySeconds":N}`; devices `GET /api/v2/tailnet/-/devices` → match `hostname` → first `addresses` IPv4; delete `DELETE /api/v2/device/{id}`. Policy (setup only): `GET /api/v2/tailnet/-/acl` with `Accept: application/hujson` (returns `ETag`), `POST` with `If-Match`.
  - `local()`: `tailscale status --json` (reuse `TailscaleCLI.status(timeout:)`) → `BackendState`, `CurrentTailnet.Name`, `Self.TailscaleIPs[0]`; `tailscale lock status --json` → `Enabled`, and whether this node's key is in `TrustedKeys` → `lockSigner`.
  - `signIfSigner`: when `lockEnabled && lockSigner`, `tailscale lock sign <nodekey>`.
  - `KeychainTailnetSecrets` (service `dev.flightdeck.tailscale-oauth`, same Keychain attributes as `KeychainHostSecretStore`).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat: join cloud machines to the local tailnet with single-use ephemeral keys`.

---

### Task 14: `HostService.enroll`, `InfraPreflight` and `InfraService`

**Files:**
- Modify: `Sources/FlightDeck/Hosts/HostService.swift` (new `enroll(key:name:endpoints:)` reusing private `adopt` :223)
- Create: `Sources/FlightDeck/Infra/InfraPreflight.swift`, `InfraService.swift`
- Test: `Tests/FlightDeckTests/InfraServiceTests.swift`, `HostServiceEnrollTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–13. `HostService.statuses` (`@Published`), `FleetDeviceKey.mint()`.
- Produces:

```swift
// HostService
@discardableResult func enroll(key: FleetDeviceKey, name: String, endpoints: [String]) throws -> HostRecord   // refuses an existing name (no -2 rename)
func setEndpoints(slot: UUID, _ endpoints: [String])     // update + restart the link
struct InfraEnvironment: Sendable {   // the seams InfraService needs, all fakeable
    var tofu: (URL) -> TofuRunning; var resolver: ToolResolver; var accounts: [String: CloudAccount]
    var prices: PriceCatalog; var tailnet: TailnetIntegration; var publicIP: () async throws -> String
    var presetsRoot: URL; var installer: (base: String, sha256: String); var controllerName: String
    var now: () -> Date; var budget: () -> BudgetSettings
}
enum InfraEvent: Equatable, Sendable { case progress(String); case cost(String); case ready(InfraMachine); case failed(String) }
@MainActor final class InfraService {
    init(registry: InfraRegistry, ledger: CostLedger, hosts: HostService, env: InfraEnvironment)
    func up(name: String, config: InfraConfig, repoRoot: URL, events: @escaping (InfraEvent) -> Void) async throws -> InfraMachine
    func down(name: String, events: @escaping (InfraEvent) -> Void) async throws
    func extend(name: String, by: Duration) async throws -> InfraMachine
    func list(now: Date) -> [InfraMachine]
    func doctor() async -> [PreflightCheck]
    func resumeAfterLaunch() async          // Review Focus 1
    func costLine(for: InfraMachine, now: Date) -> String
}
struct PreflightCheck: Equatable, Sendable { let name: String; let ok: Bool; let detail: String; let fix: String? }
enum InfraError: Error, Equatable { case preflight([PreflightCheck]); case nameInUse(String); case enrollTimeout(console: String?); case notFound(String) }
```

- [ ] **Step 1: Write the failing tests** (all with fakes: `FakeTofu` scripted per step, `FakeAccount`, a `PriceCatalog` over a constant source, `TailnetIntegration` with `cli: nil`, `HostService` over `InMemoryHostSecretStore` and a fake dialer that reports online when told):

```swift
@MainActor final class InfraServiceTests: XCTestCase {
    var h: InfraHarness!   // builds registry, ledger, HostService, env with fakes; in InfraFakes.swift
    override func setUp() async throws { h = try InfraHarness() }

    let gpu = InfraConfig(source: .preset("aws-linux"), region: "us-east-1", instanceType: "t3.small", arch: nil, diskGB: nil,
                          spot: false, ttl: .init(seconds: 3600), idle: .init(seconds: 1800), autoUp: false, vars: [:], maxHourly: nil)

    func testUpCreatesEnrollsAndBecomesReady() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        let m = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { h.events.append($0) }
        XCTAssertEqual(m.state, .ready); XCTAssertEqual(m.network, .public)
        XCTAssertEqual(m.allowCIDR, "203.0.113.9/32")                 // from env.publicIP fake
        XCTAssertEqual(h.hosts.registry.hosts.map(\.name), ["gpu"])
        XCTAssertEqual(h.hosts.registry.hosts[0].endpoints, ["198.51.100.7:47410"])
        let vars = try h.tfvars("gpu")
        XCTAssertEqual(vars["fd_allow_cidr"] as? String, "203.0.113.9/32")
        XCTAssertTrue((vars["fd_user_data"] as? String)?.contains("enroll --file") == true)
        XCTAssertEqual((vars["fd_labels"] as? [String: String])?["flightdeck-name"], "gpu")
        XCTAssertTrue(h.events.contains { if case .cost = $0 { return true }; return false })
    }

    func testPreflightRefusesBeforeAnyTofuCall() async throws {
        h.budget.allowedTypes["aws"] = []                      // nothing allowed
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }; XCTFail() }
        catch InfraError.preflight(let checks) { XCTAssertTrue(checks.contains { !$0.ok && $0.name == "budget" }) }
        XCTAssertEqual(h.tofu.calls, [], "nothing created")
        XCTAssertTrue(h.hosts.registry.hosts.isEmpty)
    }

    /// Review Focus 3.
    func testNameClashRefusedBeforeCreate() async throws {
        try h.hosts.enroll(key: .mint(), name: "gpu", endpoints: [])
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }; XCTFail() }
        catch InfraError.nameInUse(let why) { XCTAssertTrue(why.contains("paired host")) }
        try h.registry.upsert(.fixture(name: "db", repoRoot: "/other/repo"))
        do { _ = try await h.service.up(name: "db", config: gpu, repoRoot: h.repo) { _ in }; XCTFail() }
        catch InfraError.nameInUse(let why) { XCTAssertTrue(why.contains("/other/repo")) }
        XCTAssertEqual(h.tofu.calls, [])
    }

    /// Review Focus 2.
    func testFailedApplyIsStillDestroyable() async throws {
        h.tofu.failApply = TofuError.failed(step: "apply", message: "InsufficientInstanceCapacity")
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }; XCTFail() } catch {}
        XCTAssertEqual(h.registry.machine(named: "gpu")?.state, .failed)
        XCTAssertTrue(h.registry.machine(named: "gpu")?.failure?.contains("InsufficientInstanceCapacity") == true)
        try await h.service.down(name: "gpu") { _ in }
        XCTAssertEqual(h.tofu.calls.last, "destroy")
        XCTAssertNil(h.registry.machine(named: "gpu")); XCTAssertTrue(h.hosts.registry.hosts.isEmpty)
    }

    /// Review Focus 1.
    func testRelaunchMidProvisionResumesOrDestroys() async throws {
        // Enrolled-but-never-confirmed: host comes online after relaunch → adopted as ready.
        try h.registry.upsert(.fixture(name: "a", state: .enrolling, slot: try h.hosts.enroll(key: .mint(), name: "a", endpoints: ["198.51.100.7:47410"]).slot))
        // Provisioning with a deadline already passed → destroyed.
        try h.registry.upsert(.fixture(name: "b", state: .provisioning, deadline: h.now.addingTimeInterval(-1)))
        h.hostOnline("a")
        await h.service.resumeAfterLaunch()
        XCTAssertEqual(h.registry.machine(named: "a")?.state, .ready)
        XCTAssertNil(h.registry.machine(named: "b")); XCTAssertTrue(h.tofu.destroyed.contains("b"))
    }

    func testEnrollTimeoutFailsWithConsoleOutput() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.consoleOutput = "cloud-init: curl: (6) Could not resolve host"
        h.enrollTimeout = 0.05
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }; XCTFail() }
        catch InfraError.enrollTimeout(let console) { XCTAssertTrue(console?.contains("Could not resolve") == true) }
        XCTAssertEqual(h.registry.machine(named: "gpu")?.state, .failed)
    }

    func testTailnetModeUsesTailnetAddressAndNoInboundRule() async throws {
        h.tailnetAvailable(nodeIP: "100.64.0.9")
        h.tofu.outputs = TofuOutputs(address: "10.0.0.4", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        let m = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }
        XCTAssertEqual(m.network, .tailnet); XCTAssertNil(m.allowCIDR)
        XCTAssertEqual(h.hosts.registry.hosts[0].endpoints, ["100.64.0.9:47410"])
        XCTAssertEqual(try h.tfvars("gpu")["fd_allow_cidr"] as? String, "")
    }

    func testCostLineFormat() {
        let m = InfraMachine.fixture(name: "gpu", instanceType: "g6.xlarge", hourlyUSD: 0.8,
                                     createdAt: h.now.addingTimeInterval(-4320), deadline: h.now.addingTimeInterval(10_080))
        XCTAssertEqual(h.service.costLine(for: m, now: h.now), "gpu · g6.xlarge · $0.80/h est. · up 1h12m · ~$0.96 · TTL 2h48m · month ~$0.96 of $50")
    }
}

@MainActor final class HostServiceEnrollTests: XCTestCase {
    func testEnrollRefusesExistingName() throws {
        let s = HostService(registry: HostRegistry(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID()).json"),
                                                   secrets: InMemoryHostSecretStore()), controllerName: "t")
        try s.enroll(key: .mint(), name: "gpu", endpoints: [])
        XCTAssertThrowsError(try s.enroll(key: .mint(), name: "gpu", endpoints: []))
        XCTAssertEqual(s.registry.hosts.map(\.name), ["gpu"])
    }
}
```

`InfraHarness`, `InfraMachine.fixture(...)` (all fields defaulted), `FakeTofu` (records `calls` as `"init"`, `"apply"`, `"destroy"`; `destroyed: Set<String>`; `failApply`; `outputs`), `FakeAccount`, and the dial fake live in `InfraFakes.swift`. `h.now` is fixed; `costLine`'s month total comes from the ledger opened in `testCostLineFormat`'s fixture (open a segment at `createdAt` in the fixture helper).

- [ ] **Step 2: Run** `FD_TEST_FILTER=InfraServiceTests,HostServiceEnrollTests ./scripts/test-unit.sh` → compile errors.
- [ ] **Step 3: Implement.**
  - `HostService.enroll`: if `registry.resolve(name:)` succeeds → throw `HostLookupError`-style error ("name in use"); else the `adopt` path with `serviceName: "fd-\(name)"`. `setEndpoints` updates the record and calls `link.stop()` + `open(record, key:)`.
  - `InfraPreflight.run(...) -> [PreflightCheck]` in spec §10 order: tools (`resolver.resolve(.tofu, provision: true)`), config (preset exists in `presetsRoot`/module dir exists), budget (`CostModel.checkLaunch` with `ledger.monthToDate`, running count of non-gone machines, price from `prices.hourly` or `config.maxHourly`), account (`status()`), quota, name (clash with `hosts.registry` or another repo's machine → `InfraError.nameInUse`, thrown before the other checks), network mode (`tailnet.mode()`).
  - `up`: preflight → registry `.planned` → mint key → `hosts.enroll(key:name:endpoints: [])` → `.provisioning` → network: tailnet (`mintAuthKey`, `fd_allow_cidr = ""`) or public (`publicIP()` → `/32`) → render user-data (`CloudInitRenderer`) → `InfraWorkdir.prepare` with vars (`fd_name`, `fd_user_data`, `fd_labels` = `flightdeck=1`, `flightdeck-owner=<controller slot hash>`, `flightdeck-name=<name>`, `fd_allow_cidr`, preset vars `region`, `instance_type`, `arch`, `disk_gb`, `spot`, `ttl_seconds`, GCP `project` from the account) → `initialize`/`apply` (progress → `.progress("<action> <resource>")`) → `outputs` → address: tailnet → poll `nodeAddress` (2 s, up to 5 min) and `signIfSigner`; public → `outputs.address` → `hosts.setEndpoints(["\(addr):47410"])` → `.enrolling` → await `hosts.statuses[slot]` `.online` with `enrollTimeout` (default 600 s; on timeout fetch console via `CloudAccount` — add `func consoleOutput(instanceID: String, region: String) async -> String?` to the protocol: AWS `ec2 get-console-output --latest`, GCP `compute instances get-serial-port-output`) → `.ready`, `ledger.open(rate)`, emit `.cost(costLine)`. Any throw after `.planned` → state `.failed` with message; re-throw.
  - `down`: `.destroying` → `destroy` (if workdir exists) → tailnet `deleteNode` (best effort) → `hosts.forget(slot:)` → `ledger.close` → `registry.remove`. A destroy failure leaves `.failed` and rethrows (never removes the record while resources may exist).
  - `extend` (deviation 6): the on-machine timer (AWS `shutdown -h`, GCP `max_run_duration`) is fixed at creation, so `extend` can never move the deadline past `createdAt + config.ttl`. It moves the controller deadline later only up to that bound (after an earlier reduction or a Reaper warning), re-running the budget check for the new span; beyond it, it refuses with "the machine's own timer was set at creation; run `flightdeck infra down` and `up` again to run longer". Spec §7.2's "pushes a new deadline to the machine" is recorded as deviation 6 in Task 19.
  - `resumeAfterLaunch`: for each machine: `.ready/.idle/.enrolling` with an online host → `.ready`; `.enrolling` offline past `createdAt + enrollTimeout` → `down`; `.planned/.provisioning` → if `now > deadline` → `down`, else `refreshShowsGone` → gone → remove, else leave for the Reaper; `.destroying` → `down` again.
  - `costLine`: exactly the spec §8.4 format; `up` uses `createdAt`; month from `ledger.monthToDate(now:)`; omit "of $N" when no monthly cap.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat: create, enroll and destroy cloud machines as hosts`.

---

### Task 15: `Reaper` and notifications

**Files:**
- Create: `Sources/FlightDeck/Infra/Reaper.swift`, `InfraNotifier.swift`
- Test: `Tests/FlightDeckTests/ReaperTests.swift`

**Interfaces:**
- Consumes: `InfraService`, `HostLinkClock` (`HostLink.swift:39`), `ManualHostLinkClock` (`Tests/FlightDeckTests/HostLinkTests.swift:26-55`), `CostModel.checkRunning`, `HostService.info(name:)` for `idleSince`.
- Produces:

```swift
protocol InfraNotifying: Sendable { func notify(id: String, title: String, body: String) }
struct UserNotificationInfraNotifier: InfraNotifying {}       // UNUserNotificationCenter, like SessionNotifier
@MainActor final class Reaper {
    init(service: InfraService, hosts: HostService, clock: HostLinkClock, notifier: InfraNotifying,
         budget: @escaping () -> BudgetSettings, interval: TimeInterval = 60)
    func start(); func stop()
    func tick() async                       // one pass; tests call it directly
    func linkLost(name: String) async       // public-IP check, Review Focus 5
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor final class ReaperTests: XCTestCase {
    var h: InfraHarness!; var spy: SpyInfraNotifier!; var reaper: Reaper!
    override func setUp() async throws {
        h = try InfraHarness(); spy = SpyInfraNotifier()
        reaper = Reaper(service: h.service, hosts: h.hosts, clock: h.clock, notifier: spy, budget: { self.h.budget })
    }
    func testWarnsTenMinutesBeforeTTLThenDestroys() async throws {
        try h.readyMachine("gpu", deadline: h.now.addingTimeInterval(9 * 60))
        await reaper.tick()
        XCTAssertTrue(spy.sent.contains { $0.body.contains("10 minutes") || $0.body.contains("9 minutes") })
        h.clock.advance(by: 9 * 60 + 1); await reaper.tick()
        XCTAssertTrue(h.tofu.destroyed.contains("gpu"))
    }
    func testIdleDestroys() async throws {
        try h.readyMachine("gpu", idle: .init(seconds: 1800))
        h.hostInfo("gpu", idleSince: h.now.addingTimeInterval(-1801))
        await reaper.tick()
        XCTAssertTrue(h.tofu.destroyed.contains("gpu"))
    }
    func testBusyMachineIsNotIdle() async throws {
        try h.readyMachine("gpu", idle: .init(seconds: 1800))
        h.hostInfo("gpu", idleSince: nil)
        await reaper.tick()
        XCTAssertFalse(h.tofu.destroyed.contains("gpu"))
    }
    func testBudgetDestroyAfterFiveMinuteWarning() async throws {
        h.budget.perMachineCapUSD = 1
        try h.readyMachine("gpu", hourlyUSD: 1, createdAt: h.now.addingTimeInterval(-3600))
        await reaper.tick()
        XCTAssertFalse(h.tofu.destroyed.contains("gpu")); XCTAssertTrue(spy.sent.contains { $0.title.contains("budget") })
        h.clock.advance(by: 301); await reaper.tick()
        XCTAssertTrue(h.tofu.destroyed.contains("gpu"))
    }
    func testDriftMarksGone() async throws {
        try h.readyMachine("gpu"); h.tofu.goneOnRefresh.insert("gpu")
        await reaper.tick()
        XCTAssertNil(h.registry.machine(named: "gpu")); XCTAssertTrue(h.hosts.registry.hosts.isEmpty)
    }
    /// Review Focus 5.
    func testPublicIPChangeReappliesFirewall() async throws {
        try h.readyMachine("gpu", network: .public, allowCIDR: "203.0.113.9/32")
        h.publicIP = "203.0.113.77"
        await reaper.linkLost(name: "gpu")
        XCTAssertEqual(try h.tfvars("gpu")["fd_allow_cidr"] as? String, "203.0.113.77/32")
        XCTAssertEqual(h.tofu.calls.last, "apply")
        XCTAssertEqual(h.registry.machine(named: "gpu")?.allowCIDR, "203.0.113.77/32")
    }
    func testSameIPDoesNotReapply() async throws {
        try h.readyMachine("gpu", network: .public, allowCIDR: "203.0.113.9/32")
        h.publicIP = "203.0.113.9"; let before = h.tofu.calls
        await reaper.linkLost(name: "gpu")
        XCTAssertEqual(h.tofu.calls, before)
    }
}
```

- [ ] **Step 2: Run** → compile errors.
- [ ] **Step 3: Implement.** `tick` per machine in `.ready/.idle`: drift (`refreshShowsGone` at most every 10 min per machine) → TTL (warn once at ≤ 10 min, destroy at deadline) → idle (`hosts.info(name:)` → `idleSince`; nil = busy; `now - idleSince >= idle` → `down`; set `.idle` state when idle > 0 for the UI) → budget (`checkRunning` with `ledger.spent`/`monthToDate`; `.warn` notify once per threshold; `.destroy` notify, record `destroyAt = now + 300`, destroy when reached; raising the cap clears it on the next tick). `linkLost`: public mode only; `publicIP()` → if differs, rewrite `fd_allow_cidr` in tfvars, `apply`, update registry. Wire `linkLost` from `HostService` link `.offline` transitions for infra-owned slots (in `InfraService.init`, sink `hosts.$statuses`; debounce 30 s). `UserNotificationInfraNotifier` mirrors `SessionNotifier` (`Sources/FlightDeck/SessionNotifier.swift:23`).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat: destroy cloud machines at ttl, when idle or over budget, and follow a moving mac`.

---

### Task 16: `infra.*` on the wire

**Files:**
- Create: `Sources/FleetKit/InfraControlWire.swift`
- Modify: `Sources/FleetKit/TimelineFrames.swift` (case + encode :282 + `init(from:)` :303), `Frames.swift` (replies, tags, encode/decode, `cid` :1033), `FleetSocketServer.swift:1090-1097` (`continuesStream`), `FleetConnector.swift:762-772`, `Sources/FlightDeck/Fleet/ControlScope.swift:120-145`, `FleetService.swift:~712` (route; `var infra: InfraService?`), `Sources/FlightDeckCLI/CLIRunner.swift:613-619` (exhaustive switch)
- Test: `Tests/FlightDeckTests/InfraControlWireTests.swift`, `ControlScope` tests

**Interfaces:**
- Produces:

```swift
public enum InfraRequest: Codable, Sendable, Equatable {
    case up(name: String, cwd: String)          // op "infra.up"
    case down(name: String, orphanID: String?)  // "infra.down"
    case list(orphans: Bool)                    // "infra.ls"
    case doctor                                 // "infra.doctor"
    case extend(name: String, seconds: Int)     // "infra.extend"
    public var isReadOnly: Bool                 // list, doctor
}
public struct WireInfraMachine: Codable, Sendable, Equatable {
    public let name, cloud, instanceType, region, state, network: String
    public let hourlyUsd: Double?; public let spentUsd: Double; public let ttlRemaining: Int
    public let monthUsd: Double; public let monthCapUsd: Double?; public let failure: String?; public let costLine: String
}
public struct WireInfraCheck: Codable, Sendable, Equatable { public let name: String; public let ok: Bool; public let detail: String; public let fix: String? }
// FleetRequest: case infra(InfraRequest)
// ServerFrame: case infraProgress(cid: Int, line: String)          — continues the stream
//              case infraMachine(cid: Int, WireInfraMachine)        — ends it (up/extend)
//              case infraList(cid: Int, [WireInfraMachine], orphans: [String])
//              case infraDoctor(cid: Int, [WireInfraCheck])
//              case infraDone(cid: Int)                              — ends it (down)
```

- [ ] **Step 1: Write the failing tests** — round-trip every request and frame (pattern: `DelegationControlWireTests.swift:34,163,188`), pin op strings, and pin scope:

```swift
final class InfraControlWireTests: XCTestCase {
    func testRequestsRoundTripWithPinnedOps() throws {
        let cases: [(FleetRequest, String)] = [
            (.infra(.up(name: "gpu", cwd: "/r")), "infra.up"), (.infra(.down(name: "gpu", orphanID: nil)), "infra.down"),
            (.infra(.list(orphans: true)), "infra.ls"), (.infra(.doctor), "infra.doctor"), (.infra(.extend(name: "gpu", seconds: 600)), "infra.extend")]
        for (r, op) in cases {
            let data = try JSONEncoder().encode(r)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"\(op)\""))
            XCTAssertEqual(try JSONDecoder().decode(FleetRequest.self, from: data), r)
        }
    }
    func testFramesRoundTrip() throws {
        let m = WireInfraMachine(name: "gpu", cloud: "aws", instanceType: "t3.small", region: "us-east-1", state: "ready", network: "public",
                                 hourlyUsd: 0.02, spentUsd: 0.01, ttlRemaining: 3000, monthUsd: 1, monthCapUsd: 50, failure: nil, costLine: "x")
        for f: ServerFrame in [.infraProgress(cid: 1, line: "creating aws_instance.this"), .infraMachine(cid: 1, m),
                               .infraList(cid: 2, [m], orphans: ["i-0dead"]), .infraDoctor(cid: 3, [.init(name: "tofu", ok: true, detail: "1.8.3 (PATH)", fix: nil)]),
                               .infraDone(cid: 4)] {
            XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(f)), f)
        }
    }
    func testOnlyProgressContinuesTheStream() {
        XCTAssertTrue(FleetSocketServer.continuesStream(.infraProgress(cid: 1, line: "")))
        XCTAssertFalse(FleetSocketServer.continuesStream(.infraDone(cid: 1)))
    }
}
// ControlScope test: list/doctor permitted at the read-only level; up/down/extend only for the
// fleet-wide write level, like hostPrune (copy the existing hostPrune scope test and adapt).
```

Use the real `continuesStream` signature (it may be an instance method or take a frame plus request); adapt the call, keep the assertions.

- [ ] **Step 2: Run** `FD_TEST_FILTER=InfraControlWireTests,ControlScopeTests ./scripts/test-unit.sh` → compile errors.
- [ ] **Step 3: Implement** all switch arms in one commit (wire atomicity). `FleetService`: `.infra` refused unless `client.isLocal`; `up` resolves `[infra.<name>]` by loading `delegate.toml` from `cwd`'s repo root (`LiveConfigLoader`), streams `InfraEvent.progress` as `.infraProgress` and `.cost` as `.infraProgress("cost: …")`, ends with `.infraMachine`; errors map to the existing error frame with codes `infra_preflight` (message = failing checks, one per line, each with its fix), `infra_name_in_use`, `infra_enroll_timeout`, `infra_not_found`, `infra_failed`. `FleetConnector`: drop as strays. Update the wire header comment in `DelegationControlWire.swift:1-72` style at the top of `InfraControlWire.swift`. Run `./scripts/build-ios.sh` and `./scripts/test-ios.sh` (the phone decodes `ServerFrame`).
- [ ] **Step 4: Run** the filter, then the full `./scripts/test-unit.sh` (rg errors), `build-ios.sh`, `test-ios.sh` → PASS.
- [ ] **Step 5: Commit** — `feat: carry infra up, down, ls, doctor and extend over the control socket`.

---

### Task 17: CLI `infra` verbs, auto-up and cost lines on runs

**Files:**
- Create: `Sources/FlightDeckCLI/InfraCommands.swift`
- Modify: `CLIArguments.swift` (`CLICommand.infra(InfraCommand)`, `parseVerb` :129, `valueFlags` :435-441), `CLIRunner.swift:297-303`, `Sources/FlightDeckTool/main.swift:14-57` (usage) and :188-197 (SIGINT for `infra up`), `Sources/FlightDeck/Delegation/DelegationService.swift` (auto-up between :440 and :455; cost notice)
- Test: `Tests/FlightDeckTests/CLIArgumentsTests.swift`, `InfraCommandsTests.swift`, `DelegationServiceTests.swift`

**Interfaces:**
- Produces:

```swift
enum InfraCommand: Equatable { case up(name: String); case down(name: String?, orphan: String?); case ls(orphans: Bool); case doctor; case extend(name: String, by: String) }
// DelegationService.Dependencies gains: var infra: InfraUpProviding?
protocol InfraUpProviding: AnyObject { @MainActor func ensureUp(name: String, config: InfraConfig, repoRoot: URL, notice: @escaping (String) -> Void) async throws
                                       @MainActor func costLine(host: String) -> String? }
```

- [ ] **Step 1: Write the failing tests**

```swift
// CLIArgumentsTests — add
func testInfraVerbs() {
    XCTAssertEqual(CLIArguments.parse(["infra", "up", "gpu"]).command, .infra(.up(name: "gpu")))
    XCTAssertEqual(CLIArguments.parse(["infra", "down", "gpu"]).command, .infra(.down(name: "gpu", orphan: nil)))
    XCTAssertEqual(CLIArguments.parse(["infra", "down", "--orphan", "i-0dead"]).command, .infra(.down(name: nil, orphan: "i-0dead")))
    XCTAssertEqual(CLIArguments.parse(["infra", "ls", "--orphans"]).command, .infra(.ls(orphans: true)))
    XCTAssertEqual(CLIArguments.parse(["infra", "doctor"]).command, .infra(.doctor))
    XCTAssertEqual(CLIArguments.parse(["infra", "extend", "gpu", "1h"]).command, .infra(.extend(name: "gpu", by: "1h")))
    XCTAssertNotNil(CLIArguments.parse(["infra", "extend", "gpu", "forever"]).error)
    XCTAssertNotNil(CLIArguments.parse(["infra", "up"]).error)
    XCTAssertTrue(CLIArguments.parse(["infra", "ls", "--json"]).json)
}

// InfraCommandsTests — drive the runner with scripted frames (pattern: DelegateRunnerHooks, DelegateCommands.swift:7)
func testUpPrintsProgressToStderrAndCostLine() async throws {
    let hooks = RecordingHooks(frames: [.infraProgress(cid: 1, line: "create aws_instance.this"),
                                       .infraMachine(cid: 1, .fixture(costLine: "gpu · t3.small · $0.02/h est. · up 0m · ~$0.00 · TTL 1h · month ~$1.00 of $50"))])
    let rc = await InfraCommandRunner(hooks: hooks.hooks, wantsJSON: false).run(.up(name: "gpu"), cwd: "/r")
    XCTAssertEqual(rc, 0)
    XCTAssertTrue(hooks.stderr.contains("flightdeck: create aws_instance.this"))
    XCTAssertTrue(hooks.stderr.contains("gpu · t3.small"))
}
func testPreflightErrorExitsWithItsOwnCode() async {
    let hooks = RecordingHooks(frames: [.err(cid: 1, code: "infra_preflight", message: "budget: … (Settings → Cloud → Budget)")])
    let rc = await InfraCommandRunner(hooks: hooks.hooks, wantsJSON: false).run(.up(name: "gpu"), cwd: "/r")
    XCTAssertEqual(rc, 125); XCTAssertTrue(hooks.stderr.contains("Settings → Cloud → Budget"))
}
func testLsTableHasTotalRow() async {
    let hooks = RecordingHooks(frames: [.infraList(cid: 1, [.fixture(name: "a", spentUsd: 1.5), .fixture(name: "b", spentUsd: 0.5)], orphans: [])])
    _ = await InfraCommandRunner(hooks: hooks.hooks, wantsJSON: false).run(.ls(orphans: false), cwd: "/r")
    XCTAssertTrue(hooks.stdout.contains("TOTAL")); XCTAssertTrue(hooks.stdout.contains("~$2.00"))
}

// DelegationServiceTests — add
func testRunOnAutoUpInfraCreatesItFirst() async throws {
    // FakeConfig returns a config with infra["gpu"] autoUp = true; FakeHosts has no "gpu" until ensureUp is called.
    let infra = FakeInfraUp(); deps.infra = infra
    // start a run with run.host = "gpu" (copy an existing start test's setup)
    // assert infra.ensured == ["gpu"], a notice "creating gpu (aws-linux, t3.small)…" was sent, and the run proceeded on the new link.
}
func testRunOnInfraWithoutAutoUpSaysHowToCreateIt() async throws {
    // infra["gpu"] autoUp = false, host absent → error message contains "flightdeck infra up gpu"
}
func testRunOnCloudHostSendsCostNotice() async throws {
    // host "gpu" exists and infra.costLine(host:) returns "gpu · …" → a delegateNotice with that line is sent before output.
}
```

Write the three `DelegationServiceTests` bodies fully by copying the nearest existing `start` test in `DelegationServiceTests.swift` (its setup of `FakeHosts`, `FakeConfig`, `FakeHostLink`) and adding the infra fake and assertions above; `RecordingHooks` and `.fixture` helpers go in `InfraCommandsTests.swift`.

- [ ] **Step 2: Run** `FD_TEST_FILTER=CLIArgumentsTests,InfraCommandsTests,DelegationServiceTests ./scripts/test-unit.sh` → compile errors.
- [ ] **Step 3: Implement.**
  - Parsing: `case "infra":` → `parseInfra` (`up NAME`, `down NAME | --orphan ID`, `ls [--orphans]`, `doctor`, `extend NAME DURATION` validated with `Duration.parse`); add `--orphan` to `valueFlags`.
  - `InfraCommandRunner` (mirrors `DelegateCommandRunner`): progress → `flightdeck: <line>` on stderr; `infraMachine` → stderr cost line, stdout table row or JSON; `ls` table columns `NAME CLOUD TYPE STATE NET $/H SPENT TTL` plus `TOTAL` row and orphans section; `doctor` prints `✓/✗ name — detail` and `  fix: …`; exit 0 ok, 125 for any `infra_*` error, 1 otherwise. Usage lines:
    `flightdeck infra up <name>` · `flightdeck infra down <name> | --orphan <id>` · `flightdeck infra ls [--orphans]` · `flightdeck infra doctor` · `flightdeck infra extend <name> <duration>`.
  - SIGINT during `infra up`: print "flightdeck: still creating gpu in Flight Deck; `flightdeck infra down gpu` to cancel" and exit 130 (the app keeps going — a half-created machine must not be abandoned by a ^C).
  - `DelegationService.start`: after `let host = try resolveHost(...)` — if `config.infra[host]` exists and the host is not in the directory: `autoUp` → `deps.infra?.ensureUp(...)` with notices forwarded as `delegateNotice`; else throw the existing user error with "run `flightdeck infra up \(host)` first". Then, if `deps.infra?.costLine(host:)` is non-nil, send it as a `delegateNotice` before streaming. `InfraService` conforms to `InfraUpProviding`.
- [ ] **Step 4: Run** the filter → PASS; full `./scripts/test-unit.sh` → no errors.
- [ ] **Step 5: Commit** — `feat: add the infra cli and create cloud hosts on demand for run --on`.

---

### Task 18: Settings → Cloud tab and the setup sheet

**Files:**
- Create: `Sources/FlightDeck/Preferences/UI/CloudSettingsTab.swift`, `CloudSetupSheet.swift`, `Sources/FlightDeck/Infra/CloudSetupModel.swift`
- Modify: `PreferencesTab.swift:12` (`.cloud`), `PreferencesView.swift` (tab after Hosting; `.accessibilityIdentifier("prefs-cloud")`), `FlightDeckApp.swift` (build `InfraService`, `Reaper`, pass to `PreferencesView` :490 and `FleetService.infra`), `HostsSettingsTab.swift` (cloud badge + rate/spend for infra-owned hosts), preferences storage for `BudgetSettings`, AWS profile, GCP project
- Test: `Tests/FlightDeckTests/CloudSetupModelTests.swift`

**Interfaces:**
- Produces:

```swift
@MainActor final class CloudSetupModel: ObservableObject {
    enum StepID: String, CaseIterable { case tools, aws, gcp, quota, tailnet, policy, oauth, lock, budget, test }
    struct Step: Equatable { let id: StepID; var state: State; var detail: String; var action: String?; var skipped: Bool
        enum State: Equatable { case pending, running, ok, failed } }
    @Published private(set) var steps: [Step]
    init(service: InfraService, tailnet: TailnetIntegration, accounts: [String: CloudAccount], open: @escaping (URL) -> Void,
         clipboard: @escaping () -> String?)
    func refresh() async                                    // re-runs every check
    func perform(_ id: StepID) async                        // the step's automation
    func skip(_ id: StepID)
    func applyPolicy(token: String) async -> HuJSONPatcher.Patch?   // fetch + diff; nil = fell back to copy-and-open
    func confirmPolicy(_ patch: HuJSONPatcher.Patch, token: String) async throws
    func captureOAuthClientFromClipboard() throws -> Bool
    func runTest() async                                    // cheapest preset, 15m TTL, uname -a, destroy
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor final class CloudSetupModelTests: XCTestCase {
    func testTailscaleStepsSkipWhenNotRunning() async throws {
        let m = try CloudSetupHarness(tailnet: .notRunning).model
        await m.refresh()
        for id in [CloudSetupModel.StepID.policy, .oauth, .lock] { XCTAssertTrue(m.steps.first { $0.id == id }!.skipped, "\(id)") }
    }
    func testSignedOutAWSOffersSignIn() async throws {
        let m = try CloudSetupHarness(aws: .signedOut(fix: "aws sso login --profile dev")).model
        await m.refresh()
        let s = m.steps.first { $0.id == .aws }!
        XCTAssertEqual(s.state, .failed); XCTAssertEqual(s.action, "Sign in")
    }
    func testQuotaTooLowOpensIncreasePage() async throws {
        let h = try CloudSetupHarness(quota: QuotaCheck(ok: false, have: 0, need: 4, increaseURL: URL(string: "https://example.invalid/quota")!))
        await h.model.perform(.quota)
        XCTAssertEqual(h.opened, [URL(string: "https://example.invalid/quota")!])
    }
    func testPolicyFallsBackToCopyAndOpenWhenUnpatchable() async throws {
        let h = try CloudSetupHarness(policy: "[not, an, object]")
        let patch = await h.model.applyPolicy(token: "tskey-api-EXAMPLE")
        XCTAssertNil(patch)
        XCTAssertTrue(h.copied?.contains("tag:flightdeck-cloud") == true)
        XCTAssertEqual(h.opened.last?.host, "login.tailscale.com")
    }
    func testClipboardOAuthCaptureNeedsBothParts() throws {
        let h = try CloudSetupHarness(clipboard: "client id: kExample\nclient secret: tskey-client-kExample-SECRET")
        XCTAssertTrue(try h.model.captureOAuthClientFromClipboard())
        XCTAssertEqual(h.savedOAuth?.id, "kExample")
        let h2 = try CloudSetupHarness(clipboard: "just some text")
        XCTAssertFalse(try h2.model.captureOAuthClientFromClipboard())
    }
}
```

`CloudSetupHarness` lives in `InfraFakes.swift` (fake accounts, tailnet mode, HTTP for policy GET/POST with `ETag`, `open`/clipboard spies, an `InfraHarness` underneath).

- [ ] **Step 2: Run** → compile errors.
- [ ] **Step 3: Implement.**
  - Model per spec §9 table. URLs: Tailscale keys page `https://login.tailscale.com/admin/settings/keys`, OAuth clients `https://login.tailscale.com/admin/settings/oauth`, policy editor `https://login.tailscale.com/admin/acls/file`. If Task 0 P1 said the API can create OAuth clients, `perform(.oauth)` creates one with the policy-step token (`scopes: ["auth_keys"]`, `tags: ["tag:flightdeck-cloud"]`) and saves it; otherwise opens the page and shows the two-item checklist (“Keys → Auth Keys: Write”, “Tags: tag:flightdeck-cloud”) with **Paste from clipboard**. Clipboard parse: an id token `k[A-Za-z0-9]+` and a secret `tskey-client-[A-Za-z0-9-]+`.
  - `runTest`: `up` a synthetic `InfraConfig` (cheapest allowlisted preset type per configured cloud: `t4g.nano`/`e2-micro`, `ttl 15m`, name `fd-setup-test`), then `flightdeck run`-equivalent `uname -a` via `DelegationService` (or `HostService.info` as the cheaper proof if a run is awkward from the model — the spec says `uname -a`; use the run), report elapsed and `costLine`, then `down`.
  - Views: `CloudSettingsTab` sections Accounts (AWS profile picker from `AWSAccount.profiles`, GCP project field), Tailscale (mode line from `TailnetIntegration.mode()`), Budget (monthly, per-machine, warn %, max concurrent, max TTL, max idle, allowlist editor per cloud), Machines (list with cost line and Down button), and **Set up…** button. `CloudSetupSheet`: the checklist with state icons, detail, action button, Skip; policy step shows the diff in a monospaced scroll view with **Apply**.
  - Persist `BudgetSettings` and account choices in the preferences blob used by other tabs (follow how `HostsSettingsTab`/preferences store values; JSON-coded under one key).
  - Render both views offscreen with the house `layer.render(in:)` technique and check layout; do not launch the app.
- [ ] **Step 4: Run** `FD_TEST_FILTER=CloudSetupModelTests ./scripts/test-unit.sh` → PASS; `./scripts/build.sh` → succeeds.
- [ ] **Step 5: Commit** — `feat: set up cloud accounts, tailscale and budgets from one guided sheet`.

---

### Task 19: Live test script, docs and as-built notes

**Files:**
- Create: `scripts/test-infra-live.sh`
- Modify: `AGENTS.md` (Commands block, Layout table), `docs/ARCHITECTURE.md` (new "Cloud infra hosts" section), `docs/BUILD.md` (presets test, live test), `docs/HANDOFF.md`, `docs/FOLLOWUPS.md`, `docs/AGENT-OPERATIONS.md` (never run the live test unasked; how to find and destroy orphans), the spec (as-built deviations 1–6), `Resources/ClaudePlugin` delegate skill (mention `infra` and the cost line)

- [ ] **Step 1: Write `scripts/test-infra-live.sh`**

```bash
#!/usr/bin/env bash
# The cloud end to end, against the user's real account. Costs cents; creates real resources.
# Never part of any suite: refuses without FD_INFRA_LIVE=1. Uses the installed Flight Deck's CLI
# (`flightdeck`), so it tests what the user runs.
#   FD_INFRA_LIVE=1 ./scripts/test-infra-live.sh aws|gcp
set -euo pipefail
[ "${FD_INFRA_LIVE:-}" = 1 ] || { echo "refusing: set FD_INFRA_LIVE=1 (creates real cloud resources)"; exit 2; }
CLOUD=${1:?aws|gcp}
FD=${FLIGHTDECK:-flightdeck}
WORK=$(mktemp -d); trap 'cd /; "$FD" infra down fd-live-test >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
cd "$WORK" && git init -q && git commit -q --allow-empty -m init
mkdir -p .flightdeck
case "$CLOUD" in
  aws) printf '[infra.fd-live-test]\npreset = "aws-linux"\nregion = "us-east-1"\ninstance_type = "t4g.nano"\narch = "arm64"\nttl = "15m"\nauto_up = true\n' ;;
  gcp) printf '[infra.fd-live-test]\npreset = "gcp-linux"\nregion = "us-central1"\ninstance_type = "e2-micro"\nttl = "15m"\nauto_up = true\n' ;;
esac > .flightdeck/delegate.toml
git add -A && git commit -q -m cfg
start=$(date +%s)
"$FD" run --on fd-live-test -- uname -a | tee run.out
grep -q Linux run.out
"$FD" host ls | grep -q '"name":"fd-live-test"'
"$FD" infra down fd-live-test
"$FD" infra ls --orphans --json | grep -q '"orphans":\[\]'
echo "INFRA LIVE PASS ($CLOUD, $(( $(date +%s) - start ))s)"
```

- [ ] **Step 2: Docs.** AGENTS.md Commands: `./scripts/test-infra-presets.sh` and the live script with its refusal note; Layout rows for `Sources/FlightDeck/Infra/` and `Resources/Infra/presets/`. ARCHITECTURE: units, data flow, trust boundaries, the double TTL, tailnet vs public mode. FOLLOWUPS: AWS quota ignores running usage; disk price constant; `extend` limited to the creation TTL (deviation 6); native cloud budgets; SkyPilot/Packer/remote state/Mac presets; GUI checklist (setup sheet, Cloud tab) is Nate's; the live test has not run until Nate runs it. Spec as-built note listing deviations 1–6.
- [ ] **Step 3: Verify** `bash -n scripts/test-infra-live.sh`; `FD_INFRA_LIVE= ./scripts/test-infra-live.sh aws` prints the refusal and exits 2; `rg -n "\]\((docs/)?[A-Za-z].*\.md" docs AGENTS.md` links resolve; `rg -n '100\.(9[0-9]|1[01][0-9])\.|nate@|\.ts\.net' -g '!*example*' docs scripts Sources Resources Tests | rg -v example-tailnet` finds nothing.
- [ ] **Step 4: Full gates** — `./scripts/test-unit.sh` (rg errors), `./scripts/test-hostkit.sh`, `./scripts/test-hostd-linux.sh`, `./scripts/test-hostd-install.sh`, `./scripts/test-infra-presets.sh`, `./scripts/build-ios.sh`, `./scripts/test-ios.sh`, `./scripts/build.sh` → all pass.
- [ ] **Step 5: Commit** — `docs: describe cloud infra hosts, their safety nets and the live test`.

---

## Manual checks (Nate's)

1. Settings → Cloud → Set up…: sign in to AWS and/or GCP, optionally Tailscale (token + OAuth client), run **Test** — it should report pairing time and a cost of a cent or less.
2. `FD_INFRA_LIVE=1 ./scripts/test-infra-live.sh aws` (and `gcp`) → `INFRA LIVE PASS`.
3. In a repo with an `[infra.gpu]` table, `flightdeck run --on gpu -- nvidia-smi` creates the machine, prints the cost line, and the Reaper destroys it after the idle period.
4. Close the laptop lid for longer than a test machine's TTL; on reopening, `flightdeck infra ls --orphans` shows nothing left running.
