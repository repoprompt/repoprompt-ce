import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class InterceptingWindowDelegateProxyTests: XCTestCase {
    func testWindowDidOrderOffScreenUsesRuntimeSelectorSafely() throws {
        let selector = NSSelectorFromString("windowDidOrderOffScreen:")
        let notificationObject = NSObject()
        let notification = Notification(
            name: Notification.Name("InterceptingWindowDelegateProxyTests.windowDidOrderOffScreen"),
            object: notificationObject,
            userInfo: ["marker": "original"]
        )

        let supportedDelegate = RecordingWindowDelegate()
        let supportedProxy = InterceptingWindowDelegateProxy(
            windowState: nil,
            forwardedDelegate: supportedDelegate
        )

        XCTAssertTrue(supportedProxy.responds(to: selector))
        XCTAssertTrue(supportedDelegate.responds(to: selector))
        _ = supportedProxy.perform(selector, with: notification)

        XCTAssertEqual(supportedDelegate.receivedNotifications.count, 1)
        let receivedNotification = try XCTUnwrap(supportedDelegate.receivedNotifications.first)
        XCTAssertEqual(receivedNotification.name, notification.name)
        XCTAssertTrue((receivedNotification.object as? NSObject) === notificationObject)
        XCTAssertEqual(receivedNotification.userInfo?["marker"] as? String, "original")

        let releasedProxy: InterceptingWindowDelegateProxy
        weak var releasedDelegate: RecordingWindowDelegate?
        do {
            let delegate = RecordingWindowDelegate()
            releasedDelegate = delegate
            releasedProxy = InterceptingWindowDelegateProxy(
                windowState: nil,
                forwardedDelegate: delegate
            )
        }

        XCTAssertNil(releasedDelegate)
        _ = releasedProxy.perform(selector, with: notification)

        let unsupportedDelegate = UnsupportedWindowDelegate()
        let unsupportedProxy = InterceptingWindowDelegateProxy(
            windowState: nil,
            forwardedDelegate: unsupportedDelegate
        )

        XCTAssertTrue(unsupportedProxy.responds(to: selector))
        XCTAssertFalse(unsupportedDelegate.responds(to: selector))
        _ = unsupportedProxy.perform(selector, with: notification)
    }
}

private final class RecordingWindowDelegate: NSObject, NSWindowDelegate {
    private(set) var receivedNotifications: [Notification] = []

    @objc(windowDidOrderOffScreen:)
    func recordWindowDidOrderOffScreen(_ notification: Notification) {
        receivedNotifications.append(notification)
    }
}

private final class UnsupportedWindowDelegate: NSObject, NSWindowDelegate {}
