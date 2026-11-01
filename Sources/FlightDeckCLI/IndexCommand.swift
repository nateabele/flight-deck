import Foundation

/// `flightdeck index …`: the command surface of the machine-wide code index (spec §2.12). It is
/// `fdindex` under another name, so everything after `index` goes to that binary untouched,
/// flags included (`--json` and `--help` are `fdindex`'s here, not `flightdeck`'s), and
/// the process becomes `fdindex`: its stdio, signals and exit status are the caller's.
///
/// Local like `provider check`: the index daemon is its own process with its own socket, so this
/// never asks Flight Deck anything and works with the app closed (requirement 4).
public enum IndexCommand {
    /// Names the `fdindex` to run; wins over everything else.
    public static let environmentOverride = "FLIGHTDECK_FDINDEX"
    public static let binaryName = "fdindex"
    /// Exit status when there is no `fdindex` to run, as a shell's "command not found".
    public static let notFoundStatus: Int32 = 127

    /// Where `fdindex` is looked for, in order: `$FLIGHTDECK_FDINDEX`, the folder of the running
    /// `flightdeck` (the app bundle's `Contents/MacOS`, where it ships), then `$PATH`.
    /// - Returns: the first executable file, or the reason there is none.
    public static func locate(
        environment: [String: String],
        executable: URL?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Result<String, CLIUsageError> {
        if let override = environment[environmentOverride], !override.isEmpty {
            // An override that points nowhere is an error, not a cue to look elsewhere: it was
            // set to pick a specific build, and silently running another would hide the mistake.
            return isExecutable(override)
                ? .success(override)
                : .failure(CLIUsageError("index: \(environmentOverride)=\(override) is not an executable file"))
        }
        var candidates: [String] = []
        if let executable {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent(binaryName).path)
        }
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(binaryName)" }
        if let found = candidates.first(where: isExecutable) { return .success(found) }
        return .failure(CLIUsageError(
            "index: cannot find \(binaryName). Looked next to flightdeck and on PATH; "
                + "set \(environmentOverride) to its path, or reinstall Flight Deck."))
    }

    /// Replaces this process with `fdindex args…`. Returns only on failure, with the status to exit with.
    public static func run(
        _ args: [String],
        environment: [String: String],
        executable: URL?,
        report: (String) -> Void,
        exec: (String, [String]) -> Int32 = { path, argv in
            // An ignored signal stays ignored across exec; `main.swift` ignores SIGPIPE for itself.
            signal(SIGPIPE, SIG_DFL)
            var cArgs = argv.map { strdup($0) } + [nil]
            defer { cArgs.forEach { free($0) } }
            execv(path, &cArgs)
            return errno
        }
    ) -> Int32 {
        switch locate(environment: environment, executable: executable) {
        case .failure(let error):
            report("flightdeck: \(error.message)")
            return notFoundStatus
        case .success(let path):
            let code = exec(path, [binaryName] + args)
            report("flightdeck: index: cannot run \(path): \(String(cString: strerror(code)))")
            return notFoundStatus
        }
    }
}
