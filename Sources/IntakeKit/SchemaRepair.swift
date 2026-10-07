import Foundation

/// The schema-repair seam (grok/gemini spec §3.4). A harness whose CLI cannot constrain its own
/// output to a schema (`AgentProfile.hasNativeSchema == false`, gemini today) gets the schema in
/// its prompt and, when the answer still fails to parse or validate, ONE retry: the same session
/// resumed with "Your reply did not validate: <first error>. Reply again with only the corrected
/// JSON." A second failure stands as `invalidOutput`. Keyed by the capability, not the harness,
/// so a later schema-less harness gets the retry for free.
///
/// `RoundExecutor.attempt` calls `retry` after every finished seat run and, when it returns a
/// value, runs exactly one more attempt with it (`isRepair: true`, so a repair never repairs).
/// Track M implements the decision below; everything around it is already wired.
public enum SchemaRepair {
    /// What the one repair attempt runs: the failed run's own session, resumed, with this prompt.
    public struct Retry: Sendable, Equatable {
        public var resumeSessionID: String
        public var prompt: String
        public init(resumeSessionID: String, prompt: String) {
            self.resumeSessionID = resumeSessionID; self.prompt = prompt
        }
    }

    /// The repair to run after a seat run that ended in `failure`, or nil to let it stand.
    /// `sessionID` is the failed run's session (nil when none was parsed); `isRepair` is true
    /// when that run was itself the repair.
    public static func retry(profile: any AgentProfile, failure: Diagnosis, sessionID: String?,
                             access: HarnessAccess, isRepair: Bool) -> Retry? {
        // A native-schema harness never retries: its CLI already enforced the schema, so a
        // mismatch is not something a "please fix your JSON" turn repairs — and claude/codex
        // rounds must behave exactly as before this seam existed.
        guard !profile.hasNativeSchema, !isRepair else { return nil }
        // Only an answer that came back and failed to parse or validate is repairable. A rate
        // limit, a sign-in or a crash is not fixed by asking again for JSON — retrying those
        // would just spend the one retry on the same failure.
        guard failure.category == .invalidOutput else { return nil }
        // The repair resumes the failed run's OWN conversation; with no id there is nothing to
        // resume, and a fresh run would not know what it was correcting.
        guard let sessionID, !sessionID.isEmpty else { return nil }
        // The integrator (write mode) always starts fresh — `HarnessCommand.validate` refuses a
        // write-mode resume — so it is never repaired.
        guard access == .readOnly else { return nil }
        return Retry(resumeSessionID: sessionID, prompt: prompt(firstError: failure.detail))
    }

    /// The repair turn's whole prompt (spec §3.4 step 4). Only the first error: a list invites
    /// the model to fix some and re-break others, and one is enough to say what went wrong.
    public static func prompt(firstError: String) -> String {
        let first = firstError.split(whereSeparator: \.isNewline).first.map(String.init) ?? firstError
        return "Your reply did not validate: \(first). Reply again with only the corrected JSON."
    }
}
