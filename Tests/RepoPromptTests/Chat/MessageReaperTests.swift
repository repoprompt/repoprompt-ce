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

    func testReaperDeinitInvalidatesItsRepeatingTimer() {
        let timerFactory = RecordingMessageReaperTimerFactory()
        var reaper: MessageReaper? = MessageReaper(timerFactory: timerFactory)
        var messages = [AIChatMessage(content: "pending", isUser: false)]

        reaper?.drain(&messages, chunkSize: 1, interval: 60)
        XCTAssertTrue(timerFactory.timer?.isValid == true)

        reaper = nil

        XCTAssertFalse(timerFactory.timer?.isValid == true)
    }
}

@MainActor
private final class RecordingMessageReaperTimerFactory: MessageReaperTimerFactory {
    private(set) var timer: Timer?

    func makeRepeatingTimer(
        interval: TimeInterval,
        block: @escaping (Timer) -> Void
    ) -> Timer {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true, block: block)
        self.timer = timer
        return timer
    }
}
