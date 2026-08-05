@testable import RepoPromptApp
import XCTest

@MainActor
final class MessageReaperTests: XCTestCase {
    func testReaperDeallocatesWhileMessagesRemainQueued() {
        var reaper: MessageReaper? = MessageReaper()
        weak var weakReaper: MessageReaper?
        var messages = [AIChatMessage(content: "pending", isUser: false)]
        weakReaper = reaper

        reaper?.drain(&messages, chunkSize: 1, interval: 60)

        XCTAssertTrue(messages.isEmpty)
        XCTAssertNotNil(weakReaper)
        reaper = nil
        XCTAssertNil(weakReaper)
    }
}
