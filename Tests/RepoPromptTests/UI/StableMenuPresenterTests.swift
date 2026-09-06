import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class StableMenuPresenterTests: XCTestCase {
    func testRepeatedProgrammaticRequestsPresentTwice() async {
        var openCount = 0
        var itemCount = 0
        var presentationCount = 0
        let presenter = StableMenuPresenter { _, _, _ in
            presentationCount += 1
        }
        let fixture = makeAttachedAnchor()
        update(
            presenter,
            anchor: fixture.anchor,
            onOpen: { openCount += 1 },
            items: {
                itemCount += 1
                return [.action("Item") {}]
            }
        )

        presenter.enqueueProgrammaticPresentation(expectedPresentationID: "current")
        presenter.enqueueProgrammaticPresentation(expectedPresentationID: "current")
        await drainMainQueue()

        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(itemCount, 2)
        XCTAssertEqual(presentationCount, 2)
    }

    func testDeferredProgrammaticRequestUsesLatestPreparationClosures() async {
        var oldOpenCount = 0
        var oldItemCount = 0
        var newOpenCount = 0
        var newItemCount = 0
        var presentedTitle: String?
        let presenter = StableMenuPresenter { menu, _, _ in
            presentedTitle = menu.items.first?.title
        }
        let fixture = makeAttachedAnchor()
        update(
            presenter,
            anchor: fixture.anchor,
            onOpen: { oldOpenCount += 1 },
            items: {
                oldItemCount += 1
                return [.action("Old") {}]
            }
        )

        presenter.enqueueProgrammaticPresentation(expectedPresentationID: "current")
        update(
            presenter,
            anchor: fixture.anchor,
            onOpen: { newOpenCount += 1 },
            items: {
                newItemCount += 1
                return [.action("New") {}]
            }
        )
        await drainMainQueue()

        XCTAssertEqual(oldOpenCount, 0)
        XCTAssertEqual(oldItemCount, 0)
        XCTAssertEqual(newOpenCount, 1)
        XCTAssertEqual(newItemCount, 1)
        XCTAssertEqual(presentedTitle, "New")
    }

    func testDeferredProgrammaticRequestDoesNotOpenWhenSwiftUIControlBecomesDisabled() async {
        let counters = PreparationCounters()
        let presenter = rejectingPresenter(message: "Disabled control must not present a menu")
        let fixture = makeAttachedAnchor()
        update(presenter, anchor: fixture.anchor, counters: counters)

        presenter.enqueueProgrammaticPresentation(expectedPresentationID: "current")
        update(
            presenter,
            anchor: fixture.anchor,
            isEnabled: false,
            isProgrammaticPresentationAllowed: true,
            counters: counters
        )
        await drainMainQueue()

        assertPreparationWasSkipped(counters)
    }

    func testDeferredProgrammaticRequestDoesNotOpenWhenLiveApplicabilityBecomesFalse() async {
        let counters = PreparationCounters()
        let presenter = rejectingPresenter(message: "Inapplicable request must not present a menu")
        let fixture = makeAttachedAnchor()
        update(presenter, anchor: fixture.anchor, counters: counters)

        presenter.enqueueProgrammaticPresentation(expectedPresentationID: "current")
        update(
            presenter,
            anchor: fixture.anchor,
            isEnabled: true,
            isProgrammaticPresentationAllowed: false,
            counters: counters
        )
        await drainMainQueue()

        assertPreparationWasSkipped(counters)
    }

    func testDeferredProgrammaticRequestDoesNotOpenAfterAnchorDetaches() async {
        let counters = PreparationCounters()
        let presenter = rejectingPresenter(message: "Detached control must not present a menu")
        let fixture = makeAttachedAnchor()
        update(presenter, anchor: fixture.anchor, counters: counters)

        presenter.enqueueProgrammaticPresentation(expectedPresentationID: "current")
        fixture.anchor.removeFromSuperview()
        await drainMainQueue()

        assertPreparationWasSkipped(counters)
    }

    func testDeferredProgrammaticRequestDoesNotOpenForStalePresentationIdentity() async {
        let counters = PreparationCounters()
        let presenter = rejectingPresenter(message: "Stale request must not present a menu")
        let fixture = makeAttachedAnchor()
        update(
            presenter,
            anchor: fixture.anchor,
            programmaticPresentationID: "old-tab-or-provider",
            counters: counters
        )

        presenter.enqueueProgrammaticPresentation(expectedPresentationID: "old-tab-or-provider")
        update(
            presenter,
            anchor: fixture.anchor,
            programmaticPresentationID: "new-tab-or-provider",
            counters: counters
        )
        await drainMainQueue()

        assertPreparationWasSkipped(counters)
    }

    func testOrdinaryClickPresentationDoesNotRequireProgrammaticPermission() {
        var didOpen = false
        var didPresent = false
        let presenter = StableMenuPresenter { _, _, _ in
            didPresent = true
        }
        let fixture = makeAttachedAnchor()
        update(
            presenter,
            anchor: fixture.anchor,
            isProgrammaticPresentationAllowed: false,
            onOpen: {},
            items: { [.action("Current") {}] }
        )

        presenter.present(
            expectedProgrammaticPresentationID: nil,
            requiresProgrammaticPermission: false,
            onOpen: { didOpen = true },
            items: { [.action("Item") {}] }
        )

        XCTAssertTrue(didOpen)
        XCTAssertTrue(didPresent)
    }

    private func update(
        _ presenter: StableMenuPresenter,
        anchor: NSView,
        isEnabled: Bool = true,
        programmaticPresentationID: AnyHashable = "current",
        isProgrammaticPresentationAllowed: Bool = true,
        onOpen: @escaping () -> Void,
        items: @escaping () -> [StableMenuItem]
    ) {
        presenter.update(
            anchorView: anchor,
            isEnabled: isEnabled,
            programmaticPresentationID: programmaticPresentationID,
            isProgrammaticPresentationAllowed: isProgrammaticPresentationAllowed,
            onOpen: onOpen,
            items: items
        )
    }

    private func update(
        _ presenter: StableMenuPresenter,
        anchor: NSView,
        isEnabled: Bool = true,
        programmaticPresentationID: AnyHashable = "current",
        isProgrammaticPresentationAllowed: Bool = true,
        counters: PreparationCounters
    ) {
        update(
            presenter,
            anchor: anchor,
            isEnabled: isEnabled,
            programmaticPresentationID: programmaticPresentationID,
            isProgrammaticPresentationAllowed: isProgrammaticPresentationAllowed,
            onOpen: { counters.openCount += 1 },
            items: {
                counters.itemCount += 1
                return [.action("Item") {}]
            }
        )
    }

    private func rejectingPresenter(message: String) -> StableMenuPresenter {
        StableMenuPresenter { _, _, _ in
            XCTFail(message)
        }
    }

    private func assertPreparationWasSkipped(_ counters: PreparationCounters) {
        XCTAssertEqual(counters.openCount, 0)
        XCTAssertEqual(counters.itemCount, 0)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func makeAttachedAnchor() -> (window: NSWindow, anchor: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        window.contentView?.addSubview(anchor)
        return (window, anchor)
    }
}

@MainActor
private final class PreparationCounters {
    var openCount = 0
    var itemCount = 0
}
