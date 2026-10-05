import Foundation
import HostKit

/// `flightdeck-hostd controllers`: the paired controllers, so a Linux host's owner can find the
/// slot `revoke` takes. A Mac host lists them in its Hosting tab; without this a headless box
/// had no way to name the controller it wanted to cut off short of reading `controllers.json`,
/// which holds every controller's secret beside its slot.
///
/// The slot leads each line because it is the one field `revoke` needs, and a tab separates the
/// fields because a controller's name (a Mac's name) routinely contains spaces. Dates are
/// ISO 8601 in UTC, not the admin wire's reference-date doubles: this is for a person or a
/// script, not for a hostd of another build.
enum ControllersCommand {
    static func text(_ controllers: [AdminController]) -> String {
        let iso = ISO8601DateFormatter()
        return controllers
            .map { "\($0.slot.uuidString)\t\($0.name)\t\(iso.string(from: $0.pairedAt))" }
            .joined(separator: "\n")
    }

    static func json(_ controllers: [AdminController]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(controllers), as: UTF8.self)
    }
}
