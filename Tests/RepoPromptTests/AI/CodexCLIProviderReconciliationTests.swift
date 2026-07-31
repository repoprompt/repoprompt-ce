import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexCLIProviderReconciliationTests: XCTestCase {
    func testThreadSnapshotPreservesLatestTerminalTurnIdentity() {
        let snapshot = CodexNativeSessionController.test_parseThreadSnapshot(
            [
                "thread": [
                    "id": "thread",
                    "status": ["type": "idle"],
                    "turns": [
                        [
                            "id": "turn-a",
                            "status": "completed",
                            "items": []
                        ],
                        [
                            "id": "turn-b",
                            "status": "failed",
                            "error": [
                                "message": "persisted terminal failure",
                                "codexErrorInfo": "quotaExceeded",
                                "additionalDetails": ["requestId": "request-1"]
                            ],
                            "items": []
                        ]
                    ]
                ]
            ],
            fallbackEffort: nil
        )

        XCTAssertEqual(snapshot.latestTerminalTurnID, "turn-b")
        XCTAssertEqual(snapshot.latestTurnStatus, .failed)
        XCTAssertEqual(snapshot.latestTurnFailure?.message, "persisted terminal failure")
        XCTAssertEqual(snapshot.latestTurnFailure?.codexErrorInfo, "quotaExceeded")
        XCTAssertEqual(snapshot.latestTurnFailure?.additionalDetails, #"{"requestId":"request-1"}"#)

        let completedAfterFailure = CodexNativeSessionController.test_parseThreadSnapshot(
            [
                "thread": [
                    "id": "thread",
                    "status": ["type": "idle"],
                    "turns": [
                        [
                            "id": "turn-a",
                            "status": "failed",
                            "error": ["message": "stale failure"],
                            "items": []
                        ],
                        [
                            "id": "turn-b",
                            "status": "completed",
                            "items": []
                        ]
                    ]
                ]
            ],
            fallbackEffort: nil
        )

        XCTAssertEqual(completedAfterFailure.latestTerminalTurnID, "turn-b")
        XCTAssertEqual(completedAfterFailure.latestTurnStatus, .completed)
        XCTAssertNil(completedAfterFailure.latestTurnFailure)
    }

    func testCanonicalCompletionReconcilesStreamingTailAndConnectionReplacement() async throws {
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn", itemID: "assistant")
        let streamingProvider = makeProvider(events: [
            .canonicalAssistantDelta(text: "hel", scope: scope),
            .assistantCompleted(.init(scope: scope, text: "hello")),
            .turnCompleted(turnID: "turn", status: .completed)
        ])

        let stream = try await streamingProvider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "prompt"),
            model: .codexCustom(name: "test-model")
        )
        var content: [String] = []
        var messageStopCount = 0
        for try await result in stream {
            if result.type == "content", let text = result.text {
                content.append(text)
            } else if result.type == "message_stop" {
                messageStopCount += 1
            }
        }
        XCTAssertEqual(content, ["hel", "lo"])
        XCTAssertEqual(messageStopCount, 1)

        let connectionProvider = makeProvider(events: [
            .canonicalAssistantDelta(text: "OK", scope: scope),
            .assistantCompleted(.init(scope: scope, text: "NO")),
            .turnCompleted(turnID: "turn", status: .completed)
        ])
        let connected = try await connectionProvider.testConnection(timeout: 5)
        XCTAssertFalse(connected)
    }

    func testStructuredFailedCompletionMessagePropagatesThroughStreamingAndConnectionPaths() async throws {
        let failure = CodexNativeSessionController.Event.turnCompleted(
            turnID: "turn",
            status: .failed,
            failure: .init(message: "authoritative provider failure")
        )

        let streamingProvider = makeProvider(events: [failure])
        let stream = try await streamingProvider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "prompt"),
            model: .codexCustom(name: "test-model")
        )
        do {
            for try await _ in stream {}
            XCTFail("Expected the structured streaming failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "authoritative provider failure")
        }

        let connectionProvider = makeProvider(events: [failure])
        do {
            _ = try await connectionProvider.testConnection(timeout: 5)
            XCTFail("Expected the structured connection failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "authoritative provider failure")
        }
    }

    @MainActor
    func testNonAgentMemoriesStayDisabledAndStreamingStartsFreshWhenAgentModePreferenceIsEnabled() async throws {
        let settings = GlobalSettingsStore.shared
        let previousMemoriesEnabled = settings.codexMemoriesEnabled()
        settings.setCodexMemoriesEnabled(true, commit: false)
        defer {
            settings.setCodexMemoriesEnabled(previousMemoriesEnabled, commit: false)
        }
        XCTAssertTrue(settings.codexMemoriesEnabled())

        let startRecorder = ScriptedCodexProviderStartRecorder()
        let provider = makeProvider(
            events: [.turnCompleted(turnID: "turn", status: .completed)],
            startRecorder: startRecorder
        )
        let overrides = provider.interactiveConfigOverrides(excludeServers: [])
        for key in ["features.memories", "memories.generate_memories", "memories.use_memories"] {
            XCTAssertEqual(overrides[key] as? Bool, false, key)
        }

        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "prompt"),
            model: .codexCustom(name: "test-model")
        )
        for try await _ in stream {}

        let startSnapshot = await startRecorder.snapshot()
        XCTAssertEqual(startSnapshot.callCount, 1)
        XCTAssertTrue(startSnapshot.resumedThreadIDs.isEmpty)
    }

    func testMissingCanonicalCompletionReconcilesFromMatchingPersistedTurn() async throws {
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn", itemID: "assistant")
        let controller = SnapshotReconcilingCodexProviderController(
            events: [
                .assistantCompleted(.init(scope: scope, text: "settled"))
            ],
            snapshotTurnID: "turn",
            snapshotStatus: .completed
        )
        let provider = makeProvider(controller: controller)

        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "prompt"),
            model: .codexCustom(name: "test-model")
        )
        var content: [String] = []
        var messageStopCount = 0
        for try await result in stream {
            if result.type == "content", let text = result.text {
                content.append(text)
            } else if result.type == "message_stop" {
                messageStopCount += 1
            }
        }

        XCTAssertEqual(content, ["settled"])
        XCTAssertEqual(messageStopCount, 1)
        XCTAssertGreaterThanOrEqual(controller.readSnapshotCount, 1)
        XCTAssertEqual(controller.shutdownCount, 2)
    }

    func testMissingFailedCompletionReconcilesFromMatchingSystemErrorSnapshot() async throws {
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn", itemID: "assistant")
        let controller = SnapshotReconcilingCodexProviderController(
            events: [
                .assistantCompleted(.init(scope: scope, text: "partial"))
            ],
            snapshotTurnID: "turn",
            snapshotStatus: .failed,
            snapshotFailure: .init(
                message: "persisted terminal failure",
                codexErrorInfo: "quotaExceeded",
                additionalDetails: #"{"requestId":"request-1"}"#
            ),
            snapshotRuntimeStatus: .systemError
        )
        let provider = makeProvider(controller: controller)

        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "prompt"),
            model: .codexCustom(name: "test-model")
        )
        do {
            for try await _ in stream {}
            XCTFail("Expected the persisted failed turn to settle the stream with an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "persisted terminal failure")
        }

        XCTAssertGreaterThanOrEqual(controller.readSnapshotCount, 1)
        XCTAssertEqual(controller.shutdownCount, 2)
    }

    func testPersistedTerminalForDifferentTurnDoesNotSettleCurrentStream() async throws {
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn", itemID: "assistant")
        let controller = SnapshotReconcilingCodexProviderController(
            events: [
                .assistantCompleted(.init(scope: scope, text: "settled"))
            ],
            snapshotTurnID: "stale-turn",
            snapshotStatus: .completed,
            canonicalCompletionDelay: 0.05
        )
        let provider = makeProvider(controller: controller)

        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "prompt"),
            model: .codexCustom(name: "test-model")
        )
        var messageStopCount = 0
        for try await result in stream where result.type == "message_stop" {
            messageStopCount += 1
        }

        XCTAssertEqual(messageStopCount, 1)
        XCTAssertGreaterThanOrEqual(controller.readSnapshotCount, 1)
    }

    func testSnapshotReconciliationDoesNotProbeBeforeAssistantCompletion() async throws {
        let controller = SnapshotReconcilingCodexProviderController(
            events: [],
            snapshotTurnID: "turn",
            snapshotStatus: .completed,
            canonicalCompletionDelay: 0.05
        )
        let provider = makeProvider(controller: controller)

        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "prompt"),
            model: .codexCustom(name: "test-model")
        )
        for try await _ in stream {}

        XCTAssertEqual(controller.readSnapshotCount, 0)
    }

    func testMatchingTerminalSnapshotWithActiveTurnDoesNotSettleCurrentStream() async throws {
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn", itemID: "assistant")
        let controller = SnapshotReconcilingCodexProviderController(
            events: [
                .assistantCompleted(.init(scope: scope, text: "settled"))
            ],
            snapshotTurnID: "turn",
            snapshotStatus: .completed,
            snapshotRuntimeStatus: .active(activeFlags: []),
            snapshotActiveTurnIDs: ["newer-turn"],
            canonicalCompletionDelay: 0.05
        )
        let provider = makeProvider(controller: controller)

        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "prompt"),
            model: .codexCustom(name: "test-model")
        )
        var messageStopCount = 0
        for try await result in stream where result.type == "message_stop" {
            messageStopCount += 1
        }

        XCTAssertEqual(messageStopCount, 1)
        XCTAssertGreaterThanOrEqual(controller.readSnapshotCount, 1)
    }

    private func makeProvider(
        events: [CodexNativeSessionController.Event],
        startRecorder: ScriptedCodexProviderStartRecorder? = nil
    ) -> CodexCLIProvider {
        CodexCLIProvider(
            defaultRequestTimeout: 5,
            testRequestTimeout: 5,
            maxRetries: 0,
            appServerReadyHook: {},
            sessionControllerFactory: { _, _ in
                ScriptedCodexProviderController(events: events, startRecorder: startRecorder)
            }
        )
    }

    private func makeProvider(
        controller: CodexSessionControlling
    ) -> CodexCLIProvider {
        CodexCLIProvider(
            defaultRequestTimeout: 5,
            testRequestTimeout: 5,
            terminalSnapshotReconciliationInterval: 0.01,
            maxRetries: 0,
            appServerReadyHook: {},
            sessionControllerFactory: { _, _ in controller }
        )
    }
}

private final class ScriptedCodexProviderController: CodexSessionControlling {
    let events: AsyncStream<CodexNativeSessionController.Event>
    private let startRecorder: ScriptedCodexProviderStartRecorder?

    init(
        events: [CodexNativeSessionController.Event],
        startRecorder: ScriptedCodexProviderStartRecorder? = nil
    ) {
        self.startRecorder = startRecorder
        self.events = AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    var hasActiveThread: Bool {
        true
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        if let startRecorder {
            await startRecorder.record(existing: existing)
        }
        return .init(conversationID: "thread", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        .init(provisionalSubmissionID: "turn")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        .init(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        .init(interruptedTurnID: expectedTurnID)
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}

private final class SnapshotReconcilingCodexProviderController: CodexSessionControlling {
    private let lock = NSLock()
    private var eventsContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
    private var _readSnapshotCount = 0
    private var _shutdownCount = 0
    private let snapshotTurnID: String
    private let snapshotStatus: CodexNativeSessionController.TurnStatus
    private let snapshotFailure: CodexNativeSessionController.TurnFailure?
    private let snapshotRuntimeStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus
    private let snapshotActiveTurnIDs: [String]

    let events: AsyncStream<CodexNativeSessionController.Event>

    init(
        events scriptedEvents: [CodexNativeSessionController.Event],
        snapshotTurnID: String,
        snapshotStatus: CodexNativeSessionController.TurnStatus,
        snapshotFailure: CodexNativeSessionController.TurnFailure? = nil,
        snapshotRuntimeStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus = .idle,
        snapshotActiveTurnIDs: [String] = [],
        canonicalCompletionDelay: TimeInterval? = nil
    ) {
        self.snapshotTurnID = snapshotTurnID
        self.snapshotStatus = snapshotStatus
        self.snapshotFailure = snapshotFailure
        self.snapshotRuntimeStatus = snapshotRuntimeStatus
        self.snapshotActiveTurnIDs = snapshotActiveTurnIDs
        var continuationReference: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        events = AsyncStream { continuation in
            continuationReference = continuation
        }
        eventsContinuation = continuationReference
        for event in scriptedEvents {
            continuationReference?.yield(event)
        }
        if let canonicalCompletionDelay {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(canonicalCompletionDelay))
                self?.yield(.turnCompleted(
                    turnID: "turn",
                    status: .completed
                ))
            }
        }
    }

    var readSnapshotCount: Int {
        lock.withLock { _readSnapshotCount }
    }

    var shutdownCount: Int {
        lock.withLock { _shutdownCount }
    }

    var hasActiveThread: Bool {
        true
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "thread", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        .init(provisionalSubmissionID: "turn")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        .init(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        .init(interruptedTurnID: expectedTurnID)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        lock.withLock {
            _readSnapshotCount += 1
        }
        return .init(
            conversationID: "thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: snapshotRuntimeStatus,
            currentTurnID: snapshotActiveTurnIDs.last,
            activeTurnIDs: snapshotActiveTurnIDs,
            latestTerminalTurnID: snapshotTurnID,
            latestTurnStatus: snapshotStatus,
            latestTurnFailure: snapshotFailure
        )
    }

    func cancelCurrentTurn() async {}

    func shutdown() async {
        lock.withLock {
            _shutdownCount += 1
        }
        eventsContinuation?.finish()
    }

    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}

    private func yield(_ event: CodexNativeSessionController.Event) {
        eventsContinuation?.yield(event)
    }
}

private actor ScriptedCodexProviderStartRecorder {
    private var callCount = 0
    private var resumedThreadIDs: [String] = []

    func record(existing: CodexNativeSessionController.SessionRef?) {
        callCount += 1
        if let existing {
            resumedThreadIDs.append(existing.conversationID)
        }
    }

    func snapshot() -> (callCount: Int, resumedThreadIDs: [String]) {
        (callCount, resumedThreadIDs)
    }
}
