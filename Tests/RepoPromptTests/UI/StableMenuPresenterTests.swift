import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class StableMenuPresenterTests: XCTestCase {
    func testRepeatedProgrammaticRequestsPresentTwice() async {
        var openCount = 0
        var presentationCount = 0
        let presenter = StableMenuPresenter { _, _, _ in
            presentationCount += 1
        }
        let fixture = makeAttachedAnchor()
        presenter.update(
            anchorView: fixture.anchor,
            isEnabled: true,
            programmaticPresentationID: "current",
            isProgrammaticPresentationAllowed: true
        )

        enqueueProgrammaticPresentation(presenter, expectedID: "current") { openCount += 1 }
        enqueueProgrammaticPresentation(presenter, expectedID: "current") { openCount += 1 }
        await drainMainQueue()

        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(presentationCount, 2)
    }

    func testDeferredProgrammaticRequestDoesNotOpenAfterControlBecomesDisabled() async {
        var didOpen = false
        let presenter = StableMenuPresenter { _, _, _ in
            XCTFail("Disabled control must not present a menu")
        }
        let fixture = makeAttachedAnchor()
        presenter.update(
            anchorView: fixture.anchor,
            isEnabled: true,
            programmaticPresentationID: "current",
            isProgrammaticPresentationAllowed: true
        )

        enqueueProgrammaticPresentation(presenter, expectedID: "current") { didOpen = true }
        presenter.update(
            anchorView: fixture.anchor,
            isEnabled: false,
            programmaticPresentationID: "current",
            isProgrammaticPresentationAllowed: false
        )
        await drainMainQueue()

        XCTAssertFalse(didOpen)
    }

    func testDeferredProgrammaticRequestDoesNotOpenAfterAnchorDetaches() async {
        var didOpen = false
        let presenter = StableMenuPresenter { _, _, _ in
            XCTFail("Detached control must not present a menu")
        }
        let fixture = makeAttachedAnchor()
        presenter.update(
            anchorView: fixture.anchor,
            isEnabled: true,
            programmaticPresentationID: "current",
            isProgrammaticPresentationAllowed: true
        )

        enqueueProgrammaticPresentation(presenter, expectedID: "current") { didOpen = true }
        fixture.anchor.removeFromSuperview()
        await drainMainQueue()

        XCTAssertFalse(didOpen)
    }

    func testDeferredProgrammaticRequestDoesNotOpenForStalePresentationIdentity() async {
        var didOpen = false
        let presenter = StableMenuPresenter { _, _, _ in
            XCTFail("Stale request must not present a menu")
        }
        let fixture = makeAttachedAnchor()
        presenter.update(
            anchorView: fixture.anchor,
            isEnabled: true,
            programmaticPresentationID: "old-tab-or-provider",
            isProgrammaticPresentationAllowed: true
        )

        enqueueProgrammaticPresentation(presenter, expectedID: "old-tab-or-provider") { didOpen = true }
        presenter.update(
            anchorView: fixture.anchor,
            isEnabled: true,
            programmaticPresentationID: "new-tab-or-provider",
            isProgrammaticPresentationAllowed: true
        )
        await drainMainQueue()

        XCTAssertFalse(didOpen)
    }

    func testOrdinaryClickPresentationDoesNotRequireProgrammaticPermission() {
        var didOpen = false
        var didPresent = false
        let presenter = StableMenuPresenter { _, _, _ in
            didPresent = true
        }
        let fixture = makeAttachedAnchor()
        presenter.update(
            anchorView: fixture.anchor,
            isEnabled: true,
            programmaticPresentationID: "current",
            isProgrammaticPresentationAllowed: false
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

    private func enqueueProgrammaticPresentation(
        _ presenter: StableMenuPresenter,
        expectedID: AnyHashable,
        onOpen: @escaping () -> Void
    ) {
        presenter.enqueueProgrammaticPresentation(
            expectedPresentationID: expectedID,
            onOpen: onOpen,
            items: { [.action("Item") {}] }
        )
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
