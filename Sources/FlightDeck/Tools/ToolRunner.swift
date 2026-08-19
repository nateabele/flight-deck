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
        launcher.launch(
            command: ToolTemplate.expand(tool.command, in: context),
            in: context.workingDirectory,
            named: tool.name
        )
    }
}
