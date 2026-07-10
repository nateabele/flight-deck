import XCTest
@testable import FlightDeck

final class ShellResolverTests: XCTestCase {
    func testUsesShellEnvWhenSet() {
        let shell = ShellResolver.resolve(environment: ["SHELL": "/bin/fish"])
        XCTAssertEqual(shell, "/bin/fish")
    }
    func testFallsBackToZshWhenUnset() {
        let shell = ShellResolver.resolve(environment: [:])
        XCTAssertEqual(shell, "/bin/zsh")
    }
    func testFallsBackToZshWhenEmpty() {
        let shell = ShellResolver.resolve(environment: ["SHELL": ""])
        XCTAssertEqual(shell, "/bin/zsh")
    }
}
