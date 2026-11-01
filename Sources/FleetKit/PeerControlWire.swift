import Foundation

/// Local peer commands share the control socket's caller attribution and sandbox grant.
/// The sender is taken from its authenticated caller token, never a model-supplied name.
public struct WirePeerRequest: Codable, Equatable, Sendable {
    public var operation: String
    public var target: String?
    public var message: String?
    public var notifyWhenIdle: Bool
    public var after: Int
    public var source: UUID?
    public init(operation: String, target: String? = nil, message: String? = nil,
                notifyWhenIdle: Bool = false, after: Int = 0, source: UUID? = nil) {
        self.operation = operation; self.target = target; self.message = message
        self.notifyWhenIdle = notifyWhenIdle; self.after = after; self.source = source
    }
}
