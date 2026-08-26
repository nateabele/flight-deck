import XCTest
@testable import FlightDeck

@MainActor
final class SubscriberListTests: XCTestCase {
    private func token(_ conversation: UUID, _ tab: UUID) -> AttachmentToken {
        AttachmentToken(conversationID: conversation, tab: tab)
    }

    func testEmitReachesEverySubscriber() {
        let conversation = UUID()
        let list = SubscriberList()
        var a: [AgentEvent] = []
        var b: [AgentEvent] = []
        list.add(token(conversation, UUID())) { a.append($0) }
        list.add(token(conversation, UUID())) { b.append($0) }

        list.emit(.title("shared"))

        XCTAssertEqual(a, [.title("shared")])
        XCTAssertEqual(b, [.title("shared")], "a second subscriber must not replace the first")
    }

    func testRemovingOneSubscriberLeavesTheOther() {
        let conversation = UUID()
        let list = SubscriberList()
        let first = token(conversation, UUID())
        var a: [AgentEvent] = []
        var b: [AgentEvent] = []
        list.add(first) { a.append($0) }
        list.add(token(conversation, UUID())) { b.append($0) }

        XCTAssertTrue(list.remove(first))
        list.emit(.title("after"))

        XCTAssertTrue(a.isEmpty)
        XCTAssertEqual(b, [.title("after")])
        XCTAssertFalse(list.isEmpty)
    }

    func testRemovingTheLastSubscriberEmptiesTheList() {
        let only = token(UUID(), UUID())
        let list = SubscriberList()
        list.add(only) { _ in }
        XCTAssertTrue(list.remove(only))
        XCTAssertTrue(list.isEmpty)
    }
}
