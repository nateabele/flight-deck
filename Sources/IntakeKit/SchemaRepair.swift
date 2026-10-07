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
        // Track M: decide here (invalidOutput only, a session to resume, read-only access —
        // write mode refuses a resume) and build the repair prompt from `failure.detail`.
        return nil
    }
}
