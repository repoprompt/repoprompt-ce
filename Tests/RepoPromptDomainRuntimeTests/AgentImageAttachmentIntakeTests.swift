import Foundation
import RepoPromptDomainRuntime
import UniformTypeIdentifiers
import XCTest

final class AgentAttachmentDropClassifierTests: XCTestCase {
    func testFileURLsAreAcceptedWithoutAnExtensionAllowlistOrHoverRead() {
        for identifier in [UTType.pdf.identifier, UTType.swiftSource.identifier, UTType.data.identifier] {
            XCTAssertTrue(AgentAttachmentDropClassifier.accepts(typeIdentifiers: [UTType.fileURL.identifier, identifier]))
        }
        XCTAssertTrue(AgentAttachmentDropClassifier.accepts(typeIdentifiers: [UTType.fileURL.identifier]))
    }

    func testRawImagesIncludingLegacyPasteboardTypesAreAccepted() {
        for identifier in [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier,
                           UTType.image.identifier, "Apple PNG pasteboard type", "NeXT TIFF v4.0 pasteboard type"] {
            XCTAssertTrue(AgentAttachmentDropClassifier.accepts(typeIdentifiers: [identifier]), identifier)
        }
    }

    func testTextWebLinksAndUnaddressableBinaryDataRemainUnclaimed() {
        for identifier in [UTType.utf8PlainText.identifier, UTType.rtf.identifier, UTType.url.identifier, UTType.data.identifier] {
            XCTAssertFalse(AgentAttachmentDropClassifier.accepts(typeIdentifiers: [identifier]), identifier)
        }
    }
}

final class AgentAttachmentDropTrackerTests: XCTestCase {
    func testDropRoutesToTabCapturedAtDragStart() {
        let dragStartTab = UUID()
        var tracker = AgentAttachmentDropTracker()
        tracker.begin(tabID: dragStartTab, acceptsAttachments: true, dragID: "first-drag")
        XCTAssertTrue(tracker.isHighlighted)
        XCTAssertEqual(tracker.takeDropTarget(fallbackTabID: UUID()), dragStartTab)
        XCTAssertFalse(tracker.isActive)
        XCTAssertNil(tracker.capturedTabID)
    }

    func testCapturedTabSurvivesExitUntilTheNextDrag() {
        let first = UUID()
        let second = UUID()
        var tracker = AgentAttachmentDropTracker()
        tracker.begin(tabID: first, acceptsAttachments: true, dragID: "first-drag")
        tracker.exit()
        XCTAssertFalse(tracker.isHighlighted)
        XCTAssertEqual(tracker.capturedTabID, first)
        tracker.begin(tabID: second, acceptsAttachments: true, dragID: "second-drag")
        XCTAssertEqual(tracker.takeDropTarget(fallbackTabID: nil), second)
    }

    func testSameDragPreservesItsDestinationAcrossPaneEditorHandoffs() {
        let original = UUID()
        var tracker = AgentAttachmentDropTracker()
        tracker.begin(tabID: original, acceptsAttachments: true, dragID: "first-drag")
        tracker.exit()
        tracker.begin(tabID: UUID(), acceptsAttachments: true, dragID: "first-drag")
        XCTAssertEqual(tracker.takeDropTarget(fallbackTabID: nil), original)
    }

    func testFallbackTabIsUsedWhenNothingWasCaptured() {
        let fallback = UUID()
        var tracker = AgentAttachmentDropTracker()
        XCTAssertEqual(tracker.takeDropTarget(fallbackTabID: fallback), fallback)
    }

    func testUnsupportedDragDoesNotHighlightAndDropClearsItsState() {
        var tracker = AgentAttachmentDropTracker()
        tracker.begin(tabID: UUID(), acceptsAttachments: false, dragID: "first-drag")
        XCTAssertFalse(tracker.isHighlighted)
        XCTAssertEqual(tracker.acceptsAttachments, false)
        _ = tracker.takeDropTarget(fallbackTabID: nil)
        XCTAssertFalse(tracker.isActive)
    }
}

final class AgentImageAttachmentGuardTests: XCTestCase {
    func testGuardBlocksWithoutTabWhileBusyAndForUnsupportedProviders() {
        XCTAssertNil(AgentImageAttachmentGuard.blockReason(
            hasTab: true, isAgentBusy: false, providerSupportsImages: true, providerName: "Claude Code"
        ))
        XCTAssertEqual(
            AgentImageAttachmentGuard.blockReason(
                hasTab: false, isAgentBusy: false, providerSupportsImages: true, providerName: "Claude Code"
            ),
            .noActiveTab
        )
        XCTAssertEqual(
            AgentImageAttachmentGuard.blockReason(
                hasTab: true, isAgentBusy: true, providerSupportsImages: true, providerName: "Claude Code"
            ),
            .agentBusy
        )
        XCTAssertEqual(
            AgentImageAttachmentGuard.blockReason(
                hasTab: true, isAgentBusy: false, providerSupportsImages: false, providerName: "Grok Build"
            ),
            .providerUnsupported(providerName: "Grok Build")
        )
        XCTAssertTrue(
            AgentImageAttachmentBlockReason.providerUnsupported(providerName: "Grok Build").message.contains("Grok Build")
        )
    }
}

final class AgentImageAttachmentAvailabilityResolverTests: XCTestCase {
    func testPathLookupIsNilForRemoteSources() {
        XCTAssertNil(AgentImageAttachmentAvailabilityResolver.path(
            for: AgentFileAttachment(source: .url("https://example.com/a.png"))
        ))
        XCTAssertEqual(
            AgentImageAttachmentAvailabilityResolver.path(
                for: AgentFileAttachment(source: .localFile(path: "/tmp/a/../b.png"))
            ),
            "/tmp/b.png"
        )
    }

    func testMissingAndAvailableFilesResolveOnceAndAreCached() {
        let counter = CallCounter()
        let resolver = AgentImageAttachmentAvailabilityResolver(fileExists: { path in
            counter.increment()
            return path == "/present.png"
        })

        XCTAssertNil(resolver.cachedAvailability(forPath: "/missing.png"))
        XCTAssertEqual(resolve(resolver, "/missing.png"), .missing)
        XCTAssertEqual(resolve(resolver, "/missing.png"), .missing)
        XCTAssertEqual(resolve(resolver, "/present.png"), .available)
        XCTAssertEqual(counter.value, 2, "Each path hits the disk once; repeats come from the cache")
        XCTAssertEqual(resolver.cachedAvailability(forPath: "/missing.png"), .missing)
        XCTAssertEqual(resolver.cachedAvailability(forPath: "/present.png"), .available)
    }

    func testRecordedAvailabilityOverridesTheCache() {
        let resolver = AgentImageAttachmentAvailabilityResolver(fileExists: { _ in true })
        XCTAssertEqual(resolve(resolver, "/evicted.png"), .available)
        resolver.record(.missing, forPath: "/evicted.png")
        XCTAssertEqual(resolver.cachedAvailability(forPath: "/evicted.png"), .missing)
    }

    private func resolve(
        _ resolver: AgentImageAttachmentAvailabilityResolver,
        _ path: String
    ) -> AgentImageAttachmentAvailabilityResolver.Availability? {
        let expectation = expectation(description: "resolved \(path)")
        let box = AvailabilityBox()
        resolver.resolveAvailability(forPath: path) { availability in
            XCTAssertTrue(Thread.isMainThread)
            box.value = availability
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        return box.value
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class AvailabilityBox: @unchecked Sendable {
    var value: AgentImageAttachmentAvailabilityResolver.Availability?
}
