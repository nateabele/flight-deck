# Planning v2 P3 (core): Visual Provider Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. This plan runs **alongside P1** in one worktree (`p3-core`), as sequential tasks K1–K5. It touches no P1 hotspot, so its tasks can merge whenever they are green.

**Goal:** Flight Deck can read, resolve, trust-gate and sandbox-run visual providers, and check one from the CLI. A bundled authoring skill writes them.

**Deferred to P3-integration** (needs P2a-integration):
- ProviderHost driving `makeVisual`
- the "sample visual per kind with a cheap model" step of `provider check`
- `fd.comp.canvas`

**Spec:** §9.

## Rulings (from the P3 code map)

| # | Spec assumed | Code has | Ruling | Cost if wrong |
|---|---|---|---|---|
| K-R1 | `provider.toml` is parsed like `delegate.toml` | The TOML reader is **internal** to HostKit, which IntakeKit cannot import | Add `ProviderManifestParser` **inside HostKit**, beside `DelegateConfigParser`, reusing `TOMLReader`. The app and the CLI already link HostKit. ThreadRunner reaches it through the CLI tool process it already runs in. | None |
| K-R2 | Trust is "SHA-256 of the provider folder" | HostKit bans CryptoKit, and nothing defines how a folder is hashed | New `Sources/ProviderKit/`, a source folder compiled into **both** the app target and the CLI target (`project.yml`). Its `ProviderTrust.digest(folder:)` is SHA-256 (CryptoKit) over sorted relative paths, each followed by a NUL, its length and its bytes. Symlinks are refused. Approvals live in `~/Library/Application Support/Flight Deck/provider-trust.json` as `{repoPath, providerID, digest, approvedAt}`. | None |
| K-R3 | Generators run under `sandbox-exec` with no network | There is no sandbox or network-blocking code anywhere | `ProviderSandbox` writes a `.sb` profile at run time: deny the network, deny file writes outside the draft folder and `$TMPDIR`, allow reads. It runs `/usr/bin/sandbox-exec -f <profile> <cmd>` through `CommandRunner` with a raced deadline that kills the process group. When `sandbox-exec` is missing, the generator is **refused**: a provider with a generator does not run unsandboxed. | Providers on a Mac without `sandbox-exec` cannot use generators |
| K-R4 | "Settings → Planning" | There is no Planning tab | Add a **Providers** section to the **Flight Control** settings tab. Rows follow `CapabilityIndexPane.sourcesSection`: a toggle, the name, a source caption, and an orange status line for "needs approval" or "needs a newer Flight Deck". The approve button records the digest. | Users look in the wrong tab |
| K-R5 | The Codex skill delivery follows `CodexDelegateSkill` | That installer copies one hard-wired `SKILL.md` | Generalize it to `CodexBundledSkill(name:)`, which copies a **folder** with the same `.flightdeck-managed` digest sidecar. Migrate `delegate` and `peer-messaging` to it, with their tests unchanged. | One more refactor in a working installer |
| K-R6 | `provider check` is a CLI command | `recipe check` goes over the socket | `flightdeck provider check <dir>` is **local**: it is intercepted in `FlightDeckTool/main.swift` before the transport, like `intake run`. In core it validates the manifest, the kinds, the instructions files and the assets. A declared generator is run in the sandbox against the provider's own `samples/<kind>/` input, if present. | None |

## Global Constraints
- The words, TDD, worktree and commit rules are the same as P1's.
- Contract-1 parsing is strict: an unknown top-level key is a warning, and a higher `contract` is "needs a newer Flight Deck". **A provider is never partly loaded.**
- Repo providers are untrusted input. Nesting is capped (`TOMLReader.maxDepth`). Paths in the manifest must resolve inside the provider folder.

## Review Focus
1. **A manifest path escapes the folder** (`instructions = "../../x"`, or a symlink). The provider is refused with its line number. (K1)
2. **A repo provider changes one byte after it was approved.** It reads "needs approval" again. (K2)
3. **A generator tries to reach the network, or to write outside its folder.** Both are blocked, and the visual fails with the sandbox's reason. (K3)
4. **A generator hangs.** It is killed when the timeout expires, together with its children. (K3)
5. **A repo provider and a bundled provider share an id.** The repo one wins in that repo only. (K2)

### K1: `ProviderManifestParser` in HostKit
- **Files:** `Packages/HostKit/Sources/HostKit/Providers/ProviderManifest.swift` and `ProviderManifestParser.swift`.
- **Tests:** `ProviderManifestParserTests`, run through `scripts/test-hostkit.sh` on macOS and in Linux Docker. They cover:
  - the spec's example manifest;
  - a missing required key;
  - a higher contract;
  - an escaping path;
  - a `"60s"` duration parsed through `Duration`;
  - a `[[kind]]` array.

### K2: `ProviderKit`, covering registry and trust
- **Files:**
  - `Sources/ProviderKit/ProviderRegistry.swift`: resolves sources in the order repo › user › bundled, keyed by id, and returns `ResolvedProvider{manifest, source, trust: .bundled|.user|.repoDataOnly|.repoApproved|.repoNeedsApproval, problems}`.
  - `ProviderTrust.swift`: K-R2.
  - `project.yml`: compiles ProviderKit into both targets.
- **Tests:**
  - `ProviderRegistryTests`: precedence, and Review Focus 5.
  - `ProviderTrustTests`: the digest is stable, ignores file order, refuses symlinks, and changes when one byte changes (Review Focus 2).

### K3: `ProviderSandbox`
- **Files:** `Sources/ProviderKit/ProviderSandbox.swift`.
- **Tests:** `ProviderSandboxTests`, using real `sandbox-exec` on this Mac. That is safe, because it opens no windows. They cover:
  - `curl` blocked;
  - a write outside the folder blocked;
  - a write inside allowed;
  - a hanging `sleep` child killed when the timeout expires;
  - refusal when the `sandbox-exec` path is absent (the path is injected).

### K4: `flightdeck provider check`
- **Files:** `CLIArguments` (a `provider` verb and its sub-parser), `CLIHelp` (a `provider` family), and the `main.swift` interception.
- **Tests:** `CLIArgumentsTests` and `ProviderCheckTests`. The tests check exit codes and output for:
  - a valid provider;
  - a broken manifest;
  - a generator sample.

### K5: Settings pane and the authoring skill
- **Settings:** the Flight Control tab gets a Providers section (K-R4), with a render that gets looked at.
- **Skill:**
  - `Resources/ClaudePlugin/skills/visual-provider/SKILL.md`, plus `templates/provider.toml` and `templates/kinds/example.md`. It writes a provider from a description, or by wrapping an existing skill, then runs `flightdeck provider check`.
  - The `CodexBundledSkill` generalization (K-R5), which installs `delegate`, `peer-messaging` and `visual-provider`.
- **Tests:** the existing `CodexDelegateSkill` and `PeerMessagingSkill` tests pass unchanged against the generalized installer. New tests cover the folder copy, user edits being kept, and an existing install being upgraded. A `ClaudePluginPayloadTests` case checks that the skill ships.
- **Docs:** the HANDOFF §5 entry, an ARCHITECTURE "Visual providers" section, spec errata K-R1–K-R6, and a CHECKLIST P3-core section marked unverified.

### Verification
- The full Mac suite runs once, at K5, together with `test-hostkit.sh`.
- Each task is reviewed, then one final review covers the whole branch.
- It merges independently of P1.
