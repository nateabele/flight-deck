import Foundation

/// Claude Code's select lists, read and driven.
///
/// `ChoiceDialog` is the grammar and stays where it is — it is a parser, tested against the
/// six verbatim captures in `Fixtures/Claude/` — and this is the two-line adapter that says
/// *which* agent's screens that grammar was derived from, plus the two answers that are not
/// shared between agents.
struct ClaudeDialogDriver: AgentDialogDriver {
    func focusedRow(inViewport viewport: String) -> Int? {
        ChoiceDialog.focusedRow(inViewport: viewport, marker: ChoiceDialog.claudeMarker)
    }

    func row(_ index: Int, reads label: String, inViewport viewport: String) -> Bool {
        ChoiceDialog.row(index, reads: label, inViewport: viewport,
                         marker: ChoiceDialog.claudeMarker)
    }

    /// **The first row, and only ever the first row.** Claude's permission dialog is ordered
    /// "Yes" / (sometimes) "Yes, and don't ask again for …" / "No, and tell Claude …", so row
    /// 0 is the plain approval and any middle row is a DURABLE GRANT. Checked against the six
    /// captures by `ChoiceDialogTests.testEveryRealDialogOpensWithTheCursorOnItsFirstRow`. If
    /// a future Claude Code reorders the dialog, those fixtures fail first — and this line
    /// must be rewritten, not the fixtures.
    let allowRow = 0

    /// Escape is a real denial and not a dismissal: the transcript closes the call
    /// `is_error=True "The user doesn't want to proceed with this tool use. The tool use was
    /// rejected"`, measured against claude 2.1.241.
    func deny(_ injector: TextInjecting) { injector.sendEscape() }
}
