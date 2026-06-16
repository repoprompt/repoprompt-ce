import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class AgentModeViewModelDisposalTests: XCTestCase {
    func testDebugInitializerDoesNotUseOrOverwriteProductionAgentDefaults() {
        let defaults = UserDefaults.standard
        let key = "agentMode.lastUsedAgent"
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set(AgentProviderKind.codexExec.rawValue, forKey: key)
        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.selectedAgent, .claudeCode)
        viewModel.selectedAgent = .openCode
        XCTAssertEqual(defaults.string(forKey: key), AgentProviderKind.codexExec.rawValue)
    }

    func testApprovalSubscriptionDoesNotRetainViewModel() async {
        let fixture = await makeSubscribedWeakViewModel()

        for _ in 0 ..< 100 {
            let subscriptionCount = await fixture.approvalStore.test_subscriptionCount()
            if fixture.weakViewModel.value == nil, subscriptionCount == 0 {
                break
            }
            await Task.yield()
        }

        let subscriptionCount = await fixture.approvalStore.test_subscriptionCount()
        XCTAssertNil(fixture.weakViewModel.value)
        XCTAssertEqual(subscriptionCount, 0)
    }

    private func makeSubscribedWeakViewModel() async -> SubscribedViewModelFixture {
        let approvalStore = ApplyEditsApprovalStore()
        let viewModel = makeViewModel(applyEditsApprovalStore: approvalStore)
        let session = await viewModel.ensureSessionReady(tabID: UUID())

        for _ in 0 ..< 100 where session.applyEditsApprovalSubscriptionID == nil {
            await Task.yield()
        }
        XCTAssertNotNil(session.applyEditsApprovalSubscriptionID)

        return SubscribedViewModelFixture(
            weakViewModel: WeakBox(viewModel),
            approvalStore: approvalStore
        )
    }

    private func makeViewModel(
        applyEditsApprovalStore: ApplyEditsApprovalStore = .shared
    ) -> AgentModeViewModel {
        AgentModeViewModel(
            applyEditsApprovalStore: applyEditsApprovalStore,
            codexControllerFactory: { _, _, _, _, _, _ in DisposalFakeCodexController() }
        )
    }
}

private struct SubscribedViewModelFixture {
    let weakViewModel: WeakBox<AgentModeViewModel>
    let approvalStore: ApplyEditsApprovalStore
}

private final class WeakBox<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

private final class DisposalFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(
            conversationID: "disposal-test",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil
        )
    }

    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "disposal-test",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
