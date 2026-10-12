// scripts/livefuzz/screenprobe.swift
//
// A thin CLI over the real `ScreenPromptReader` and `ChoiceDialog`, for `loginfuzz.py`. Compiled
// against the actual sources (see `build_screenprobe()` there), so a live claude is checked
// against the parser the Mac ships and not a Python reimplementation of it.
//
//   screenprobe read               < screen   one JSON line: what the Mac would offer for it
//   screenprobe reads <N> <label…> < screen   true/false: `ChoiceDialog.row(N, reads:)`
//
// `read` prints `{"kind":"none"}`, `{"kind":"menu","call":…,"prompt":…,"labels":[…],"focused":N}`
// or `{"kind":"signin","call":…,"url":…}`. The sign-in's URL is printed so the harness can check
// it; it carries the attempt's `state`, so the harness never writes it to a file.
import FleetKit
import Foundation

@main
struct ScreenProbe {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        let viewport = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""

        switch args.first {
        case "read":
            var out: [String: Any] = ["kind": "none"]
            switch ScreenPromptReader.read(inViewport: viewport) {
            case .question(let call, let questions)?:
                out = [
                    "kind": "menu", "call": call,
                    "prompt": questions[0].question,
                    "labels": questions[0].options.map(\.label),
                    "focused": ChoiceDialog.focusedRow(
                        inViewport: viewport, marker: ChoiceDialog.claudeMarker) ?? -1,
                ]
            case .signIn(let call, let url)?:
                out = ["kind": "signin", "call": call, "url": url]
            default:
                break
            }
            let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
            print(String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}")

        case "reads":
            let rest = args.dropFirst()
            guard let indexArg = rest.first, let index = Int(indexArg) else {
                FileHandle.standardError.write(Data("usage: screenprobe reads <N> <label...>\n".utf8))
                exit(2)
            }
            print(ChoiceDialog.row(
                index, reads: rest.dropFirst().joined(separator: " "), inViewport: viewport,
                marker: ChoiceDialog.claudeMarker))

        default:
            FileHandle.standardError.write(Data("usage: screenprobe read | reads <N> <label...>\n".utf8))
            exit(2)
        }
    }
}
