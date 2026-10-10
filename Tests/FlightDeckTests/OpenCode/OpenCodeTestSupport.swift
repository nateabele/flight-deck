import Foundation
import IntakeKit
import SQLite3
import XCTest
@testable import FlightDeck

/// Answers OpenCode requests from a script and records every one, so a test asserts on exactly
/// what would have gone over the wire. Unscripted requests answer 404, which is also what a
/// real server says about a request id it does not hold.
final class ScriptedOpenCodeHTTP: OpenCodeHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (Int, Any?)] = [:]
    private var _requests: [OpenCodeRequest] = []

    var requests: [OpenCodeRequest] { lock.withLock { _requests } }

    func on(_ method: String, _ path: String, status: Int = 200, json: Any? = nil) {
        lock.withLock { responses["\(method) \(path)"] = (status, json) }
    }

    func send(_ request: OpenCodeRequest) async throws -> (status: Int, body: Data) {
        let response: (Int, Any?)? = lock.withLock {
            _requests.append(request)
            return responses["\(request.method) \(request.path)"]
        }
        guard let (status, json) = response else {
            return (404, Data(#"{"name":"NotFoundError","data":{"message":"not scripted"}}"#.utf8))
        }
        guard let json else { return (status, Data()) }
        return (status, try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]))
    }

    func body(of request: OpenCodeRequest) -> [String: Any]? {
        request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

/// The server half with nothing behind it: an endpoint the test chooses, a stable password,
/// and a database path the test may point at a fixture.
@MainActor
final class FakeOpenCodeServer: OpenCodeServing {
    var endpoint: OpenCodeEndpoint?
    let password = "test-password"
    var databaseURL: URL?
    private(set) var starts = 0
    private(set) var stops = 0
    var startError: Error?

    init(running: Bool = true, databaseURL: URL? = nil) {
        if running { endpoint = OpenCodeEndpoint(url: URL(string: "http://127.0.0.1:45555")!, password: password) }
        self.databaseURL = databaseURL
    }

    func start() async throws {
        starts += 1
        if let startError { throw startError }
        if endpoint == nil {
            endpoint = OpenCodeEndpoint(url: URL(string: "http://127.0.0.1:45555")!, password: password)
        }
    }

    func stop() {
        stops += 1
        endpoint = nil
    }
}

enum OpenCodeFixtures {
    static func url(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(
            Bundle(for: TimelineFixtureTests.self).url(
                forResource: name, withExtension: ext, subdirectory: "Fixtures/OpenCode"
            ),
            "Fixtures/OpenCode/\(name).\(ext) not found in the test bundle"
        )
    }

    static func screen(_ name: String) throws -> String {
        try TimelineFixtureTests.text("\(name).captured", in: "OpenCode")
    }

    /// A writable copy of the captured database, so a test can never mutate the fixture.
    static func capturedDatabaseCopy() throws -> URL {
        let source = try url("opencode.captured", "db")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-db-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("opencode.db")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A minimal database with OpenCode's own column names for the three tables the mirror reads,
/// for tests that need rows in a precise state (a message still streaming, say) the captured
/// database does not happen to hold.
final class SyntheticOpenCodeDatabase {
    let url: URL
    private var db: OpaquePointer?

    init() throws {
        let directory = OpenCodeFixtures.temporaryDirectory().appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("opencode.db")
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw OpenCodeError.unreachable("open") }
        try exec("""
            CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, parent_id text,
              slug text NOT NULL, directory text NOT NULL, title text NOT NULL, version text NOT NULL,
              time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer);
            CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL,
              time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
            CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL,
              time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
            """)
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeError.malformed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func session(_ id: String, directory: String, title: String, parent: String? = nil,
                 updated: Int = 1_000, archived: Bool = false) throws {
        try exec("""
            INSERT INTO session VALUES ('\(id)', 'global', \(parent.map { "'\($0)'" } ?? "NULL"),
              'slug', '\(directory)', '\(title)', '1.18.34', 1, \(updated), \(archived ? "5" : "NULL"));
            """)
    }

    func message(_ id: String, session: String, created: Int, data: [String: Any]) throws {
        try exec("INSERT INTO message VALUES ('\(id)', '\(session)', \(created), \(created), '\(json(data))');")
    }

    func part(_ id: String, message: String, session: String, data: [String: Any]) throws {
        try exec("INSERT INTO part VALUES ('\(id)', '\(message)', '\(session)', 1, 1, '\(json(data))');")
    }

    func update(message id: String, data: [String: Any]) throws {
        try exec("UPDATE message SET data = '\(json(data))' WHERE id = '\(id)';")
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    }
}
