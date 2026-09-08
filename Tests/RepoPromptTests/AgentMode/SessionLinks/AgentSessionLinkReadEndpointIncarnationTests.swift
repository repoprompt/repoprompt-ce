import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// The overseen-transcript read boundary must validate the **full** endpoint incarnation.
///
/// `read` authorizes its candidate, revalidates it, and then awaits its opaque cursor resolution
/// before the page is materialized. An in-place rebind that keeps the same session UUID lands inside
/// that await while leaving `(tabID, activeAgentSessionID)` equal, so anything weaker than a full
/// incarnation comparison would serve a page from the replacement binding.
@MainActor
final class AgentSessionLinkReadEndpointIncarnationTests: XCTestCase {
    private struct Fixture {
        let viewModel: AgentModeViewModel
        /// Retained: `AgentModeViewModel.workspaceManager` is a weak reference, and the lifecycle
        /// identity this whole test is about resolves through it.
        let manager: WorkspaceManagerViewModel
        let tabID: UUID
        let sessionID: UUID
        let session: AgentModeViewModel.TabSession
        let candidate: AgentSessionLinkEndpointCandidate
    }

    private var retainedViewModels: [AgentModeViewModel] = []

    override func tearDown() {
        retainedViewModels.removeAll()
        super.tearDown()
    }

    private func makeFixture() throws -> Fixture {
        let tabID = UUID()
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Cross-session read",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)],
            activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace

        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                // Never exercised: reads never touch a provider.
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retainedViewModels.append(viewModel)
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)

        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(session),
            "expected a durable persistent binding"
        )
        session.appendItem(AgentChatItem.user("first request", sequenceIndex: session.nextSequenceIndex))
        session.appendItem(
            AgentChatItem.assistant("first response", sequenceIndex: session.nextSequenceIndex)
        )
        let candidate = try XCTUnwrap(
            viewModel.agentSessionLinkCandidate(
                tabID: tabID,
                sessionID: sessionID,
                tabName: "Build API",
                isWindowClosing: false
            ),
            "expected a live oversight endpoint candidate"
        )
        return Fixture(
            viewModel: viewModel,
            manager: manager,
            tabID: tabID,
            sessionID: sessionID,
            session: session,
            candidate: candidate
        )
    }

    private func page(
        _ fixture: Fixture,
        candidate: AgentSessionLinkEndpointCandidate? = nil
    ) async -> Result<AgentSessionLinkTranscriptPage, AgentSessionLinkReadUnavailableReason> {
        await fixture.viewModel.agentSessionLinkTranscriptPage(
            for: candidate ?? fixture.candidate,
            anchor: nil,
            direction: .tail,
            maxItems: 30,
            maxOutputBytes: 8000,
            readerSessionID: UUID()
        )
    }

    // MARK: - Tests

    func testTheGrantedIncarnationStillReads() async throws {
        let fixture = try makeFixture()
        let result = await page(fixture)
        guard case let .success(value) = result else {
            return XCTFail("expected a page, got \(result)")
        }
        XCTAssertEqual(value.items.map(\.text), ["first request", "first response"])
    }

    /// Regression: an in-place rebind keeps `(tabID, activeAgentSessionID)` but advances the binding
    /// generations. The page must refuse rather than serve the replacement incarnation.
    func testReadRefusesAfterAnInPlaceRebindOfTheSameSessionUUID() async throws {
        let fixture = try makeFixture()

        let generation = fixture.session.beginPersistentBindingTransition()
        fixture.session.finishPersistentBindingTransition(generation: generation)

        XCTAssertEqual(
            fixture.session.activeAgentSessionID,
            fixture.candidate.sessionID,
            "The weaker (tabID, sessionID) pair is deliberately still equal in this scenario"
        )
        XCTAssertNotEqual(
            fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID),
            fixture.candidate.domainEndpoint,
            "...while the exact incarnation has changed"
        )

        let result = await page(fixture)
        guard case let .failure(reason) = result else {
            return XCTFail("expected the read to refuse, got \(result)")
        }
        XCTAssertEqual(reason, .endpointInvalidated)

        // The replacement incarnation reads on its own authority, so nothing is permanently broken.
        let rebound = try XCTUnwrap(
            fixture.viewModel.agentSessionLinkCandidate(
                tabID: fixture.tabID,
                sessionID: fixture.sessionID,
                tabName: "Build API",
                isWindowClosing: false
            )
        )
        guard case .success = await page(fixture, candidate: rebound) else {
            return XCTFail("the current incarnation must still be readable through its own candidate")
        }
    }

    /// Regression: the read materializes the canonical projection **off** the `@MainActor`, so an
    /// in-place rebind can land inside that suspension point rather than before it.
    ///
    /// The read proves the exact incarnation twice with one shared predicate — once to take the
    /// transcript snapshot and once before releasing the page — so a rebind concurrent with an
    /// in-flight read can never produce a page, whichever of the two proofs happens to catch it. This
    /// pins the second proof: the state it must refuse is an authorized read holding a *finished* page
    /// for an incarnation that no longer exists.
    ///
    /// Deterministic by construction, and deliberately not a race. The rebind is applied from the hook
    /// the read awaits after its page exists and before the gate decides, which is the exact state the
    /// gate would see had the rebind landed midway through the off-actor materialization — the snapshot
    /// and the pre-await proof are already behind it either way.
    ///
    /// The previous version drove this from the outside with a single `Task.yield()` and could not be
    /// made sound: under full-suite executor congestion the yielded continuation resumed only after the
    /// read had already, correctly, released its page, so the test failed on correct production
    /// behavior. A test that goes red for the right behavior is worse than no test, because the next
    /// reader assumes the gate broke and repairs the wrong thing.
    ///
    /// That the withheld page was real is proven by `testTheGrantedIncarnationStillReads`, which reads
    /// two rows out of this same fixture undisturbed — so the gate withholds a page rather than having
    /// broken `read`.
    func testReadRefusesWhenTheEndpointIsReboundWhileTheOffActorPageIsInFlight() async throws {
        let fixture = try makeFixture()
        fixture.viewModel.test_afterSessionLinkTranscriptPageMaterialized = {
            @MainActor [session = fixture.session] in
            let generation = session.beginPersistentBindingTransition()
            session.finishPersistentBindingTransition(generation: generation)
        }

        let result = await page(fixture)

        guard case let .failure(reason) = result else {
            return XCTFail("an authorized read must not resume against a replacement incarnation")
        }
        XCTAssertEqual(reason, .endpointInvalidated)
        // Non-vacuity: the hook is the only thing in this test that rebinds, and it is called from
        // exactly one place in the read. An unchanged endpoint here would mean the window was never
        // entered and the refusal came from somewhere else.
        XCTAssertNotEqual(
            fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID),
            fixture.candidate.domainEndpoint,
            "the rebind must have been applied while the read held its materialized page"
        )
    }

    /// The routing conversion used by tool advertisement and projection addressing must be exact.
    func testObserverEndpointRoutingIsExactAndFailsClosed() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID),
            fixture.candidate.domainEndpoint
        )
        XCTAssertNil(
            fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: UUID()),
            "An unrouted tab must yield no endpoint rather than an invented one"
        )
    }
}
