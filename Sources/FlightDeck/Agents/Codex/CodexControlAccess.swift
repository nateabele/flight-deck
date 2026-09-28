import Foundation

/// Grants a codex tab's own sandbox exactly one extra permission — connecting to
/// `flightdeck`'s control socket — by adding flags to the `codex`/`codex resume` command line
/// Flight Deck types at the pty. Nothing here talks to codex; this is a pure builder from
/// `(socket, options)` to the argv that does the granting. Claude tabs need nothing like it:
/// Flight Deck does not run claude in a sandbox, so its `flightdeck` already reaches the socket.
///
/// **Why it goes through `network_proxy`.** A unix socket can be allowed inside codex's
/// seatbelt only through its managed network proxy: codex-rs `sandboxing/src/seatbelt.rs`
/// turns a permission profile's `network.unix_sockets` map into seatbelt rules only on that
/// path. What was actually probed, with `codex sandbox` on codex-cli 0.155.1 against an echo
/// server in `~/Library/Application Support/Flight Deck/`:
///
/// | Probe | Socket | Internet |
/// |---|---|---|
/// | default `:workspace` / `:read-only` | EPERM | blocked |
/// | `--enable network_proxy` + a profile with `network.enabled=true` and a `unix_sockets` allow | connects | blocked |
/// | the same without the `unix_sockets` entry (control) | EPERM | blocked |
/// | `features.network_proxy.unix_sockets` on a built-in profile | EPERM | — |
/// | one headless `codex exec` turn (`approval: never`) with these flags | connects | blocked |
///
/// And on codex-cli 0.157.1: the real `flightdeck` binary run under the default `:workspace`
/// seatbelt gets EPERM at connect and exits 77 with its sandbox message; a `config.toml`
/// `sandbox_mode = "workspace-write"` does not conflict with these flags (the command-line
/// `default_permissions` wins, and the grant is in force). The live guard
/// `CodexIntegrationTests.testControlSocketGrantConnectsWithoutOpeningTheInternet` pins the
/// grant: it connects to the control socket, a second socket in the same directory is refused
/// with EPERM, a direct TCP connect is refused by the seatbelt with EPERM, and an HTTP request
/// through codex's proxy is denied.
///
/// **The key is the socket file, not its directory.** codex writes each `unix_sockets` key into
/// the profile as `(subpath <key>)`. Keyed on the state directory, that allowed every socket
/// in it — including `answer-trigger.sock`, which is unauthenticated and can press Return in
/// any tab. A `subpath` of the socket's own path matches that one file and nothing beside it.
///
/// **What the proxy does with other traffic.** `network.enabled=true` makes codex start its
/// proxy and point the child's `http_proxy`/`https_proxy`/… at it, and the proxy denies every
/// host by default. In a `codex exec` run with `approval: never` that is the end of it. In a
/// `codex resume` TUI tab the approval policy is not `never`, and codex 0.157.1's source sends
/// a host the proxy does not allow to an approval decider — so a proxy-aware tool (curl, pip,
/// npm, git over https) should raise a per-host "not in the allowed_domains" /
/// `network-access <host>` approval dialog there. That is read from the source, NOT seen live;
/// see docs/FOLLOWUPS.md.
///
/// **`network_proxy` is experimental.** It needs `--enable network_proxy`, and an experimental
/// feature can change shape between releases. So the flags are only typed for a codex at or
/// above `CodexVersionProbe.controlAccessMinimumVersion` (see `CodexAdapter.controlAccessSupported`),
/// and the live guard above is the tripwire for a later release that breaks them.
///
/// **Why an explicit sandbox skips injection entirely.** codex-rs `core/src/config/mod.rs`
/// refuses to start once both `sandbox_mode` and `default_permissions` overrides are set
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
    /// it (`testControlSocketGrantConnectsWithoutOpeningTheInternet` spawns codex this way, never
    /// through a shell, so shell quoting here would reach codex's TOML parser and break it).
    /// Returns `[]` when there is nothing to grant: no socket to reach, or a user-chosen sandbox
    /// that must not be joined by a conflicting override (see the type's doc comment).
    static func launchArguments(socket: URL?, options: CodexThreadOptions) -> [String] {
        guard let socket, options.sandbox == nil else { return [] }

        // The socket FILE, never its directory: codex emits `(subpath <key>)`, so a directory
        // key would also allow every other socket in Flight Deck's state directory — including
        // the unauthenticated `answer-trigger.sock`. A subpath of the file matches only it.
        let socketPath = socket.path

        let overrides = [
            Override(key: "default_permissions", value: quotedTOMLString(profileName)),
            Override(key: "permissions.\(profileName).extends", value: quotedTOMLString(":workspace")),
            Override(key: "permissions.\(profileName).network.enabled", value: "true"),
            Override(
                key: "permissions.\(profileName).network.unix_sockets",
                value: "{\(quotedTOMLString(socketPath))=\"allow\"}"
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
    /// `\` is escaped before `"`, so the backslash the quote escape adds is not doubled by the
    /// backslash escape — `"` first would turn `"` into `\\"`, which TOML reads as a literal
    /// backslash followed by a string-ending quote. Control characters are NOT escaped here;
    /// see docs/FOLLOWUPS.md.
    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func quotedTOMLString(_ value: String) -> String {
        "\"\(tomlEscaped(value))\""
    }
}
