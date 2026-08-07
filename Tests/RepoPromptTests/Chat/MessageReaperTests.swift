@testable import RepoPromptApp
import XCTest

@MainActor
final class MessageReaperTests: XCTestCase {
    func testReaperDeallocatesWhileMessagesRemainQueued() {
        let timerFactory = RecordingMessageReaperTimerFactory()
        var reaper: MessageReaper? = MessageReaper(timerFactory: timerFactory)
        weak var weakReaper: MessageReaper?
        var messages = [
            AIChatMessage(content: "pending 1", isUser: false),
            AIChatMessage(content: "pending 2", isUser: false),
            AIChatMessage(content: "pending 3", isUser: false)
        ]
        weakReaper = reaper

        reaper?.drain(&messages, chunkSize: 1, interval: 60)

        XCTAssertTrue(messages.isEmpty)
        XCTAssertNotNil(weakReaper)
        reaper = nil
        XCTAssertNil(weakReaper)
        XCTAssertTrue(timerFactory.timer?.isValid == true)

        timerFactory.timer?.fire()
        XCTAssertTrue(timerFactory.timer?.isValid == true)
        timerFactory.timer?.fire()
        XCTAssertTrue(timerFactory.timer?.isValid == true)
        timerFactory.timer?.fire()
        XCTAssertFalse(timerFactory.timer?.isValid == true)
    }

    func testReaperTimerInvalidatesAfterQueuedMessagesDrain() {
        let timerFactory = RecordingMessageReaperTimerFactory()
        var reaper: MessageReaper? = MessageReaper(timerFactory: timerFactory)
        var messages = [AIChatMessage(content: "pending", isUser: false)]

        reaper?.drain(&messages, chunkSize: 1, interval: 60)
        XCTAssertTrue(timerFactory.timer?.isValid == true)

        reaper = nil
        timerFactory.timer?.fire()

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
