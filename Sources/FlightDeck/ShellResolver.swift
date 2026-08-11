import Foundation

enum ShellResolver {
    /// `override` comes from Preferences and wins over `$SHELL`. An empty or
    /// whitespace-only override is treated as unset, so a cleared text field in the
    /// Shell tab reverts to `$SHELL` rather than launching nothing.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        override: String? = nil
    ) -> String {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        if let shell = environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }
}
