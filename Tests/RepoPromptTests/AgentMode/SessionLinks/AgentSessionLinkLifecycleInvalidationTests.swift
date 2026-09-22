import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Routing contract for the eager live-session teardown hook.
///
/// The hook fires from `sessions.didSet`, which covers tab close, stash, delete, and MCP control
/// teardown. What it may *say* is the security-relevant part: a session UUID can be live in more than
/// one window at once, so a removed tab may only ever invalidate its own `(window, tab)` incarnation.
@MainActor
final class AgentSessionLinkLifecycleInvalidationTests: XCTestCase {
    private var retained: [AgentModeViewModel] = []
    private var retainedManagers: [WorkspaceManagerViewModel] = []
    private var previousSink: ((Int, UUID, DomainAgentSessionLinkRevocationReason) -> Void)?

    override func setUp() {
        super.setUp()
        previousSink = AgentSessionLinkInvalidationSink.invalidateBinding
    }

    override func tearDown() {
        // The sink is process-wide; leaving a test recorder installed would leak into every later
        // suite that tears a compose tab down.
        AgentSessionLinkInvalidationSink.invalidateBinding = previousSink
        retained.removeAll()
        retainedManagers.removeAll()
        super.tearDown()
    }

    private struct Recorded: Equatable {
        let windowID: Int
        let tabID: UUID
        let reason: DomainAgentSessionLinkRevocationReason
    }

    private func makeViewModel(tabID: UUID) throws -> (AgentModeViewModel, UUID) {
        let viewModel = AgentModeViewModel(
            testWindowID: 41,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        retainedManagers.append(
            AgentSessionLinkEndpointTestSupport.installWorkspace(
                on: viewModel,
                tabID: tabID,
                name: "Oversee lifecycle"
            )
        )
        let session = viewModel.session(for: tabID)
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(session),
            "expected a durable persistent binding"
        )
        return (viewModel, sessionID)
    }

    /// Regression: a closed tab invalidates exactly its own incarnation, addressed by window and tab.
    ///
    /// This used to call a session-UUID-scoped `sessionEnded`, which the bridge forwarded to
    /// `invalidateSession` — revoking every process-wide incarnation of that UUID, including grants a
    /// different window still legitimately held.
    func testTabRemovalInvalidatesOnlyItsOwnWindowAndTabIncarnation() throws {
        var recorded: [Recorded] = []
        AgentSessionLinkInvalidationSink.invalidateBinding = { windowID, tabID, reason in
            recorded.append(Recorded(windowID: windowID, tabID: tabID, reason: reason))
        }

        let tabID = UUID()
        let (viewModel, _) = try makeViewModel(tabID: tabID)
        recorded.removeAll()

        viewModel.test_removeSession(tabID: tabID)

        XCTAssertEqual(
            recorded,
            [Recorded(windowID: viewModel.windowID, tabID: tabID, reason: .tabClosed)],
            "teardown must name the exact (window, tab) incarnation, never a session UUID"
        )
    }

    /// A tab that never held a durable binding has no incarnation to invalidate.
    func testRemovingAnUnboundTabInvalidatesNothing() {
        var recorded: [Recorded] = []
        AgentSessionLinkInvalidationSink.invalidateBinding = { windowID, tabID, reason in
            recorded.append(Recorded(windowID: windowID, tabID: tabID, reason: reason))
        }

        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 42,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        _ = viewModel.session(for: tabID)
        recorded.removeAll()

        viewModel.test_removeSession(tabID: tabID)

        XCTAssertTrue(recorded.isEmpty, "an unbound tab was never an oversight endpoint")
    }
}
