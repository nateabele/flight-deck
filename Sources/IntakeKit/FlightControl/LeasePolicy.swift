import Foundation

/// L3-U §4: the first account in pool order under soft; else the first unknown one (an idle
/// account has no reading, which is normal, and must still be usable); else nothing.
public enum LeasePolicy {
    public static func pick(_ headroom: [AccountHeadroom]) -> AccountRef? {
        headroom.first { $0.state == .underSoft }?.account
            ?? headroom.first { $0.state == .unknown }?.account
    }
}
