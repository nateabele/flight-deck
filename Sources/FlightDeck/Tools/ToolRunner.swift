import Foundation

/// Expands a tool against the current selection and launches it. The single path both the
/// Tools menu and the floating overlay go through, so the two cannot drift.
@MainActor
enum ToolRunner {
    static func run(
        _ tool: ToolDefinition,
        store: SessionStore,
        launcher: ToolLaunching
    ) {
        // No selection means no working directory. The menu item and the overlay button are
        // both disabled in that state, so this is a backstop rather than the usual route.
        guard let context = store.toolContext() else { return }
        // The account overlay is applied HERE, not inside `ShellToolLauncher.configured(_:)`'s
        // `environment` closure — that closure is built once per launcher and takes no
        // session, so it has no way to know which account the *selected* session runs as. This
        // call site is the one place a `ToolContext` for that session already exists, which is
        // what makes it correct rather than merely convenient.
        launcher.launch(
            command: ToolTemplate.expand(tool.command, in: context),
            in: context.workingDirectory,
            named: tool.name,
            environmentOverrides: context.accountEnvironment
        )
    }
}
