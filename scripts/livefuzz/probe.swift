// scripts/livefuzz/probe.swift
//
// A thin CLI over the real `ChoiceDialog` (`Sources/FlightDeck/ChoiceDialog.swift`), compiled
// alongside it so the fuzz harness in this directory checks a live claude against the exact
// parser the answer path uses — not a Python reimplementation of it.
//
//   probe focused                 < screen   prints the focused row, or -1
//   probe reads <N> <label...>    < screen   prints true or false
//
// The screen is read from stdin; the operation and its arguments come from argv. Always
// `ChoiceDialog.claudeMarker` — the harness only ever drives claude.
import Foundation

@main
struct Probe {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        guard let op = args.first else {
            FileHandle.standardError.write(Data("usage: probe focused|reads <N> <label...>\n".utf8))
            exit(2)
        }

        let viewport = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""

        switch op {
        case "focused":
            let row = ChoiceDialog.focusedRow(inViewport: viewport, marker: ChoiceDialog.claudeMarker)
            print(row ?? -1)

        case "reads":
            let rest = args.dropFirst()
            guard let indexArg = rest.first, let index = Int(indexArg) else {
                FileHandle.standardError.write(Data("usage: probe reads <N> <label...>\n".utf8))
                exit(2)
            }
            let label = rest.dropFirst().joined(separator: " ")
            let result = ChoiceDialog.row(
                index, reads: label, inViewport: viewport, marker: ChoiceDialog.claudeMarker
            )
            print(result)

        default:
            FileHandle.standardError.write(Data("unknown op: \(op)\n".utf8))
            exit(2)
        }
    }
}
