import Foundation
import RepoPromptDomainRuntime
import UniformTypeIdentifiers
import XCTest

final class AgentImageDropClassifierTests: XCTestCase {
    func testImageDataTypesClassifyAsImages() {
        for identifier in [
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType.tiff.identifier,
            UTType.image.identifier,
            AgentImageDropClassifier.legacyPNGPasteboardType,
            AgentImageDropClassifier.legacyTIFFPasteboardType
        ] {
            XCTAssertEqual(
                AgentImageDropClassifier.classify(typeIdentifiers: [identifier], fileURLs: []),
                .images,
                identifier
            )
        }
    }

    func testImageFileURLClassifiesAsImages() {
        let url = URL(fileURLWithPath: "/tmp/does-not-need-to-exist/screenshot.png")
        XCTAssertTrue(AgentImageDropClassifier.isImageFileURL(url))
        XCTAssertEqual(
            AgentImageDropClassifier.classify(
                typeIdentifiers: [UTType.fileURL.identifier],
                fileURLs: [URL(fileURLWithPath: "/tmp/notes.txt"), url]
            ),
            .images
        )
    }

    func testNonImageFilesAndTextAreNotImages() {
        XCTAssertEqual(
            AgentImageDropClassifier.classify(
                typeIdentifiers: [UTType.fileURL.identifier, UTType.swiftSource.identifier],
                fileURLs: [URL(fileURLWithPath: "/tmp/Main.swift")]
            ),
            .notImages
        )
        XCTAssertEqual(
            AgentImageDropClassifier.classify(
                typeIdentifiers: [UTType.utf8PlainText.identifier, UTType.rtf.identifier],
                fileURLs: nil
            ),
            .notImages
        )
        XCTAssertFalse(AgentImageDropClassifier.isImageFileURL(URL(string: "https://example.com/a.png")!))
    }

    func testUnreadFileURLsAreUndetermined() {
        XCTAssertEqual(
            AgentImageDropClassifier.classify(typeIdentifiers: [UTType.fileURL.identifier], fileURLs: nil),
            .undetermined
        )
    }
}

final class AgentImageDropTrackerTests: XCTestCase {
    func testDropRoutesToTabCapturedAtDragStart() {
        let dragStartTab = UUID()
        let laterTab = UUID()
        var tracker = AgentImageDropTracker()

        tracker.begin(tabID: dragStartTab, classification: .images)
        XCTAssertTrue(tracker.isHighlighted)

        XCTAssertEqual(tracker.takeDropTarget(fallbackTabID: laterTab), dragStartTab)
        XCTAssertFalse(tracker.isActive)
        XCTAssertNil(tracker.capturedTabID)
    }

    func testCapturedTabSurvivesExitUntilTheNextDrag() {
        let first = UUID()
        let second = UUID()
        var tracker = AgentImageDropTracker()

        tracker.begin(tabID: first, classification: .images)
        tracker.exit()
        XCTAssertFalse(tracker.isHighlighted)
        XCTAssertEqual(tracker.capturedTabID, first)

        tracker.begin(tabID: second, classification: .images)
        XCTAssertEqual(tracker.takeDropTarget(fallbackTabID: nil), second)
    }

    func testFallbackTabIsUsedWhenNothingWasCaptured() {
        let fallback = UUID()
        var tracker = AgentImageDropTracker()
        XCTAssertEqual(tracker.takeDropTarget(fallbackTabID: fallback), fallback)
    }

    func testStaleAsynchronousClassificationIsIgnored() {
        var tracker = AgentImageDropTracker()
        let firstGeneration = tracker.begin(tabID: UUID(), classification: .undetermined)
        tracker.exit()
        XCTAssertFalse(tracker.resolve(.images, generation: firstGeneration), "Resolution after exit must not relight")
        XCTAssertFalse(tracker.isHighlighted)

        let secondGeneration = tracker.begin(tabID: UUID(), classification: .undetermined)
        XCTAssertFalse(tracker.resolve(.images, generation: firstGeneration))
        XCTAssertEqual(tracker.classification, .undetermined)
        XCTAssertTrue(tracker.resolve(.images, generation: secondGeneration))
        XCTAssertTrue(tracker.isHighlighted)
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
            for: AgentImageAttachment(source: .url("https://example.com/a.png"))
        ))
        XCTAssertEqual(
            AgentImageAttachmentAvailabilityResolver.path(
                for: AgentImageAttachment(source: .localFile(path: "/tmp/a/../b.png"))
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
