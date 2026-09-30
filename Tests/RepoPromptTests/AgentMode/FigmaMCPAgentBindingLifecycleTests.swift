import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class FigmaMCPAgentBindingLifecycleTests: XCTestCase {
    func testStaleBindingForRunACannotCancelReplacementRunInSameTab() async {
        let recorder = FigmaBindingLifecycleRecorder()
        let controller = FigmaBindingLifecycleController(recorder: recorder)
        let viewModel = makeViewModel(controller: controller)
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        let runA = UUID()
        let runB = UUID()

        session.selectedAgent = .codexExec
        session.codexController = controller
        session.runState = .running
        session.installRunID(runA)
        session.beginRunAttempt(source: "figma-binding-run-a")
        let bindingA = UUID()
        viewModel.test_recordFigmaEnabledBinding(tabID: tabID, controllerBindingID: bindingA)

        session.installRunID(runB)
        session.beginRunAttempt(source: "figma-binding-run-b")
        viewModel.test_revokeFigmaBoundAgentSessions()
        await Task.yield()

        XCTAssertEqual(session.runID, runB)
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(recorder.shutdownCount(), 0)
    }

    func testRetiringOldControllerDoesNotRemoveReplacementBinding() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        let runID = UUID()
        let oldControllerID = UUID()
        let replacementControllerID = UUID()

        session.installRunID(runID)
        viewModel.test_recordFigmaEnabledBinding(tabID: tabID, controllerBindingID: oldControllerID)
        viewModel.test_recordFigmaEnabledBinding(tabID: tabID, controllerBindingID: replacementControllerID)
        XCTAssertTrue(viewModel.test_hasFigmaBinding(tabID: tabID, runID: runID, controllerBindingID: oldControllerID))
        XCTAssertTrue(viewModel.test_hasFigmaBinding(tabID: tabID, runID: runID, controllerBindingID: replacementControllerID))

        viewModel.test_retireFigmaBinding(tabID: tabID, runID: runID, controllerBindingID: oldControllerID)

        XCTAssertFalse(viewModel.test_hasFigmaBinding(tabID: tabID, runID: runID, controllerBindingID: oldControllerID))
        XCTAssertTrue(viewModel.test_hasFigmaBinding(tabID: tabID, runID: runID, controllerBindingID: replacementControllerID))
    }

    func testMultipleControllerBindingsForOneRunProduceOneCancellation() async throws {
        let recorder = FigmaBindingLifecycleRecorder()
        let controller = FigmaBindingLifecycleController(recorder: recorder)
        let viewModel = makeViewModel(controller: controller)
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        let runID = UUID()

        session.selectedAgent = .codexExec
        session.codexController = controller
        session.runState = .running
        session.installRunID(runID)
        session.beginRunAttempt(source: "figma-binding-multiple-controllers")
        viewModel.test_recordFigmaEnabledBinding(tabID: tabID, controllerBindingID: UUID())
        viewModel.test_recordFigmaEnabledBinding(tabID: tabID, controllerBindingID: UUID())

        viewModel.test_revokeFigmaBoundAgentSessions()
        try await waitUntil { !session.runState.isActive }

        XCTAssertEqual(recorder.shutdownCount(), 1)
    }

    private func makeViewModel(controller: FigmaBindingLifecycleController? = nil) -> AgentModeViewModel {
        AgentModeViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(),
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                controller ?? FigmaBindingLifecycleController()
            }
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let step: UInt64 = 10_000_000
        var waited: UInt64 = 0
        while !condition(), waited < timeoutNanoseconds {
            try await Task.sleep(nanoseconds: step)
            waited += step
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }
}

private final class FigmaBindingLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func recordShutdown() {
        lock.withLock { count += 1 }
    }

    func shutdownCount() -> Int {
        lock.withLock { count }
    }
}

private final class FigmaBindingLifecycleController: CodexSessionControllerPassiveStubDefaults {
    private let recorder: FigmaBindingLifecycleRecorder?
    private let eventStream: AsyncStream<CodexNativeSessionController.Event>
    private let eventContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation

    init(recorder: FigmaBindingLifecycleRecorder? = nil) {
        self.recorder = recorder
        var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
        eventContinuation.finish()
    }

    deinit {
        eventContinuation.finish()
    }

    var hasActiveThread: Bool {
        true
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        eventStream
    }

    func ensureEventsStreamReady() {}

    func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
        expectedCurrentTurnID _: String,
        acceptedDispatchTurnID _: String
    ) async -> Bool {
        true
    }

    func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: "figma-binding-test")
    }

    func shutdown() async {
        recorder?.recordShutdown()
    }
}
