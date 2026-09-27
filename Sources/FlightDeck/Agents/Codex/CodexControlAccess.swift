import Foundation

/// Grants a codex tab's own sandbox exactly one extra permission — reach into
/// `flightdeck`'s control socket — by injecting flags onto the `codex`/`codex resume` command
/// line Flight Deck types at the pty. Nothing here talks to codex directly; this is a pure
/// builder from `(socket, options)` to the argv that does the granting.
///
/// **Why this goes through `network_proxy`, not a sandbox override.** Probed against a live
/// `codex app-server` (codex-cli 0.155.1):
///
/// | Approach tried | Result |
/// |---|---|
/// | `--sandbox danger-full-access` | works, but throws away the whole sandbox — too broad |
/// | `--sandbox workspace-write` + `--add-dir` | `add-dir` only ever widens the filesystem view; codex's seatbelt profile has no notion of an allowlisted *socket path* at all outside the proxy |
/// | a custom `permissions.<profile>` extending `workspace-write`, granting only `network.unix_sockets` | works, and is the narrowest grant that reaches the socket without opening general network access |
///
/// The allowlist exists **only** through the experimental network-proxy path: codex-rs's own
/// seatbelt profile builder (`sandboxing/src/seatbelt.rs`, `proxy_policy_inputs`) is what turns a
/// `permissions.<profile>.network.unix_sockets` map into an actual per-path exception in the
/// generated sandbox profile — there is no non-proxy seatbelt knob for a unix socket at all, so
/// there is no narrower route to grant than this one.
///
/// **`network_proxy` is experimental in codex-cli 0.155.1.** `--enable network_proxy` is required
/// to turn the feature on at all; Task 3's live test (`test-codex-live.sh`) pins behavior against
/// that exact version, since an experimental feature can change shape release to release.
///
/// **Why an explicit sandbox skips injection entirely.** codex-rs `core/src/config/mod.rs`
/// refuses to start at all once both `sandbox_mode` and `default_permissions` overrides are set
/// — literally, "sandbox_mode and default_permissions overrides cannot both be set" — so a user
/// who picked an explicit sandbox in Preferences must never also receive this override: it would
/// not narrow their choice, it would crash their launch. Checking `options.sandbox == nil` here,
/// before codex ever sees either flag, is what keeps that user's tab launching at all.
enum CodexControlAccess {
    /// One `-c` override, as an unquoted `key=value` TOML assignment (codex's own `-c` syntax).
    /// Kept private and typed rather than inlined as bare strings so `launchArguments` and
    /// `launchFlags` can never drift out of sync with each other — both build from this same list.
    private struct Override {
        let key: String
        let value: String
        var argument: String { "\(key)=\(value)" }
    }

    /// The permission profile name granted this override — arbitrary (codex only requires it be
    /// a valid TOML key), chosen to read clearly in a `ps`/pty transcript as "this is Flight
    /// Deck's own grant", not a name the user is expected to type or configure themselves.
    private static let profileName = "flightdeck"

    /// Raw, unquoted argv — one element per flag/value, exactly as `Process`'s `arguments` wants
    /// it (Task 3's shape: spawned via `Process`, never re-parsed by a shell, so quoting here
    /// would be actively wrong). Returns `[]` when there is nothing to grant: no socket to reach,
    /// or a user-chosen sandbox that must not be joined by a conflicting override (see the type's
    /// doc comment).
    static func launchArguments(socket: URL?, options: CodexThreadOptions) -> [String] {
        guard let socket, options.sandbox == nil else { return [] }

        // codex allowlists the DIRECTORY a unix socket lives in, not the socket path itself —
        // the seatbelt exception `proxy_policy_inputs` emits is a path prefix, and the socket
        // file's own leaf name plays no part in it.
        let socketDirectory = socket.deletingLastPathComponent().path

        let overrides = [
            Override(key: "default_permissions", value: quotedTOMLString(profileName)),
            Override(key: "permissions.\(profileName).extends", value: quotedTOMLString(":workspace")),
            Override(key: "permissions.\(profileName).network.enabled", value: "true"),
            Override(
                key: "permissions.\(profileName).network.unix_sockets",
                value: "{\(quotedTOMLString(socketDirectory))=\"allow\"}"
            ),
        ]

        var arguments = ["--enable", "network_proxy"]
        for override in overrides {
            arguments.append("-c")
            arguments.append(override.argument)
        }
        return arguments
    }

    /// The shell-quoted form of `launchArguments`, for the text Flight Deck types at a pty
    /// (`launchCommand`/`resumeCommand`/`coldCreateCommand`'s fresh branch) rather than passes to
    /// `Process`. Only the `-c` *values* need quoting — `--enable` and `network_proxy` contain no
    /// shell metacharacters — but every value goes through `ClaudeSession.shellQuoted` uniformly
    /// so this can never silently miss one if the override list grows.
    static func launchFlags(socket: URL?, options: CodexThreadOptions) -> [String] {
        let raw = launchArguments(socket: socket, options: options)
        guard !raw.isEmpty else { return [] }

        var flags: [String] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let flag = raw[index]
            if flag == "-c", raw.index(after: index) < raw.endIndex {
                flags.append(flag)
                flags.append(ClaudeSession.shellQuoted(raw[raw.index(after: index)]))
                index = raw.index(index, offsetBy: 2)
            } else {
                flags.append(flag)
                index = raw.index(after: index)
            }
        }
        return flags
    }

    /// TOML basic-string escaping for a value that will sit inside `"..."` — codex parses each
    /// `-c` argument's value with its own TOML parser, independent of the shell that already
    /// unquoted it, so this is a second, distinct escaping pass with its own rules. Order matters:
    /// backslash must be escaped FIRST, or a `\` introduced while escaping a `"` would itself be
    /// re-escaped on a hypothetical second pass — there is only one pass here, but doing `"`
    /// first would still be wrong the moment a value ever carries both.
    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func quotedTOMLString(_ value: String) -> String {
        "\"\(tomlEscaped(value))\""
    }
}
