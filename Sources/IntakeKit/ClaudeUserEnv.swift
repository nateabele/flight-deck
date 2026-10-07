import Foundation

/// The `env` block of the operator's `~/.claude/settings.json`, re-applied by hand to every
/// headless claude child. `HarnessCommand.claudeIsolation`'s `--restricted` drops the user
/// settings file wholesale — its permission allows, which is the point, but also its
/// `env`, which on this machine carries `ANTHROPIC_BASE_URL` (a local proxy). A shell that
/// already exports it hides the loss; the app's launchd environment doesn't, so without this
/// a Finder-launched Flight Deck's claude seats would talk to the wrong endpoint.
public enum ClaudeUserEnv {
    /// `environment` with the settings `env` merged in underneath it: an explicit process
    /// variable wins on conflict, since the caller resolved it on purpose. A missing or
    /// malformed settings file (or a non-object `env`) contributes nothing — never a failed
    /// run. Called only through `ClaudeProfile.environment(base:account:)`, which scrubs the
    /// child-session variables AFTER this, so the settings file can never re-introduce
    /// `CLAUDE_CODE_CHILD_SESSION`/`CLAUDECODE`.
    static let excluded: Set<String> = ["PATH", "HOME"]

    public static func merged(into environment: [String: String],
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        merged(into: environment, configDirectory: home.appendingPathComponent(".claude", isDirectory: true))
    }

    /// The same merge from a config directory directly — what `CLAUDE_CONFIG_DIR` names. A seat
    /// bound to a non-default account reads THAT account's `settings.json`, since that is the
    /// file `--restricted` dropped for it (`ClaudeProfile.environment`).
    public static func merged(into environment: [String: String], configDirectory: URL) -> [String: String] {
        let file = configDirectory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any] else { return environment }
        var merged = environment
        // Never PATH or HOME, even when the caller left them unset: they decide which binary
        // runs and where it reads its own config and credentials from, and the one thing this
        // merge exists to restore is the proxy/endpoint config the settings file carries.
        for (key, value) in env where merged[key] == nil && !excluded.contains(key) {
            // claude itself stringifies scalar env values; anything nested isn't an env var.
            switch value {
            case let s as String: merged[key] = s
            case let n as NSNumber: merged[key] = n.stringValue
            default: continue
            }
        }
        return merged
    }
}
