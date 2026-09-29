import Foundation

/// How long an agent may look idle before its row says quiet, then stalled (planning-UI spec
/// §6). Shared so the Mac's rows and the phone's say the same thing about the same agent at the
/// same moment — named constants, not tuned against real runs yet.
public enum AgentActivityRules {
    public static let quiet: TimeInterval = 30
    public static let stalled: TimeInterval = 90
}
