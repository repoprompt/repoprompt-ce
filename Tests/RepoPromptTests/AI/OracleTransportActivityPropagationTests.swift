import Foundation
@testable import RepoPromptApp
import SwiftOpenAI
import XCTest

final class OracleTransportActivityPropagationTests: XCTestCase {
    func testOpenAIDecodedChunkAdapterPreservesChoiceAndDeltaSemantics() throws {
        func chunk(_ object: [String: Any]) throws -> ChatCompletionChunkObject {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(ChatCompletionChunkObject.self, from: data)
        }

        let heartbeatChoice: [String: Any] = ["delta": [String: Any](), "index": 0]
        let semanticChoice: [String: Any] = ["delta": ["content": "content"], "index": 1]

        XCTAssertTrue(try OpenAIProvider.isTransportActivityChunk(chunk(["choices": [heartbeatChoice]])))
        XCTAssertTrue(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [heartbeatChoice, semanticChoice]
        ])))
        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk(["choices": []])))
        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [["index": 0]]
        ])))

        let semanticDeltas: [[String: Any]] = [
            ["content": "content"],
            ["reasoning_content": "reasoning"],
            ["role": "assistant"],
            ["tool_calls": [[
                "index": 0,
                "id": "call-1",
                "type": "function",
                "function": ["arguments": "{}", "name": "tool"]
            ]]],
            ["function_call": ["arguments": "{}", "name": "tool"]],
            ["refusal": "refusal"]
        ]
        for delta in semanticDeltas {
            XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
                "choices": [["delta": delta, "index": 0]]
            ])))
        }

        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [["delta": [String: Any](), "finish_reason": "stop", "index": 0]]
        ])))
        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [heartbeatChoice],
            "usage": ["prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3]
        ])))
    }

    func testOpenAITransportPredicateRejectsEachSemanticFact() {
        func classifies(
            hasChoice: Bool = true,
            hasDelta: Bool = true,
            content: String? = nil,
            reasoning: String? = nil,
            role: String? = nil,
            hasToolCalls: Bool = false,
            hasFunctionCall: Bool = false,
            refusal: String? = nil,
            hasFinishReason: Bool = false,
            hasUsage: Bool = false
        ) -> Bool {
            OpenAIProvider.isTransportActivityChunk(
                hasChoice: hasChoice,
                hasDelta: hasDelta,
                content: content,
                reasoning: reasoning,
                role: role,
                hasToolCalls: hasToolCalls,
                hasFunctionCall: hasFunctionCall,
                refusal: refusal,
                hasFinishReason: hasFinishReason,
                hasUsage: hasUsage
            )
        }

        XCTAssertTrue(classifies())
        XCTAssertFalse(classifies(hasChoice: false))
        XCTAssertFalse(classifies(hasDelta: false))
        XCTAssertFalse(classifies(content: "content"))
        XCTAssertFalse(classifies(reasoning: "reasoning"))
        XCTAssertFalse(classifies(role: "assistant"))
        XCTAssertFalse(classifies(hasToolCalls: true))
        XCTAssertFalse(classifies(hasFunctionCall: true))
        XCTAssertFalse(classifies(refusal: "refusal"))
        XCTAssertFalse(classifies(hasFinishReason: true))
        XCTAssertFalse(classifies(hasUsage: true))
    }

    func testAIQueriesServiceSanitizesTransportActivityOutput() {
        let activity = AIStreamResult(
            type: AIStreamResult.transportActivityType,
            text: "ignored",
            reasoning: "ignored",
            promptTokens: 1,
            completionTokens: 2,
            cost: 3,
            providerSessionID: "ignored",
            cleanupHandle: ProviderConversationCleanupHandle(
                provider: "ignored",
                conversationID: "ignored"
            )
        )

        let output = AIQueriesService.transportActivityOutput(for: activity)

        XCTAssertNotNil(output)
        XCTAssertEqual(output?.text, "")
        XCTAssertNil(output?.reasoning)
        XCTAssertEqual(output?.tokens, ChatTokenInfo())
        XCTAssertFalse(output?.isFinal ?? true)
        XCTAssertNil(output?.cleanupHandle)
        XCTAssertTrue(output?.isTransportActivity ?? false)
        XCTAssertNil(
            AIQueriesService.transportActivityOutput(
                for: AIStreamResult(type: "content", text: "hello")
            )
        )
    }

    @MainActor
    func testOraclePostContentWatchdogUsesStrictGraceBoundary() {
        let grace = OracleViewModel.postContentGrace
        let epsilon = 0.001
        let origin = Date(timeIntervalSinceReferenceDate: 0)

        for cycle in 1 ... 3 {
            let heartbeat = origin.addingTimeInterval(Double(cycle) * (grace - epsilon))
            let scheduledCheck = origin.addingTimeInterval(Double(cycle) * grace)
            XCTAssertFalse(
                OracleViewModel.shouldFireStreamInactivityWatchdog(
                    lastActivityAt: heartbeat,
                    now: scheduledCheck,
                    grace: grace
                )
            )
        }

        XCTAssertFalse(
            OracleViewModel.shouldFireStreamInactivityWatchdog(
                lastActivityAt: origin,
                now: origin.addingTimeInterval(grace),
                grace: grace
            )
        )
        XCTAssertTrue(
            OracleViewModel.shouldFireStreamInactivityWatchdog(
                lastActivityAt: origin,
                now: origin.addingTimeInterval(grace + epsilon),
                grace: grace
            )
        )
    }

    @MainActor
    func testOracleCoalescesTransportProgressWhileTrackingEveryHeartbeat() {
        let oracle = makeOracleViewModel()
        let recorder = OracleLifecycleActivityRecorder()
        let queryID = UUID()
        let observerID = oracle.addMessageLifecycleActivityObserver(for: queryID) {
            recorder.record($0)
        }
        defer {
            oracle.removeMessageLifecycleActivityObserver(
                for: queryID,
                observerID: observerID
            )
        }

        let origin = Date(timeIntervalSinceReferenceDate: 100)
        var latestActivity = origin
        for step in 0 ... 9 {
            latestActivity = origin.addingTimeInterval(Double(step) / 10.0)
            oracle.recordObservedStreamActivity(
                for: queryID,
                at: latestActivity
            )
        }

        XCTAssertEqual(recorder.kinds, [.streamActivity])
        XCTAssertEqual(
            oracle.lastObservedStreamActivityForTesting(for: queryID),
            latestActivity
        )

        oracle.recordObservedStreamActivity(
            for: queryID,
            at: origin.addingTimeInterval(1.0)
        )
        XCTAssertEqual(recorder.kinds, [.streamActivity, .streamActivity])
    }

    @MainActor
    func testOracleMapsTransportAndSemanticOutputsToExistingStreamActivity() {
        let transportOutput = ChatStreamOutput(
            text: "",
            reasoning: nil,
            tokens: ChatTokenInfo(),
            isTransportActivity: true
        )
        let emptyOutput = ChatStreamOutput(
            text: "",
            reasoning: nil,
            tokens: ChatTokenInfo()
        )
        let contentOutput = ChatStreamOutput(
            text: "hello",
            reasoning: nil,
            tokens: ChatTokenInfo()
        )
        let reasoningOutput = ChatStreamOutput(
            text: "",
            reasoning: "thinking",
            tokens: ChatTokenInfo()
        )

        XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: transportOutput), .streamActivity)
        XCTAssertNil(OracleViewModel.lifecycleActivityKind(for: emptyOutput))
        XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: contentOutput), .streamActivity)
        XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: reasoningOutput), .streamActivity)
    }

    @MainActor
    private func makeOracleViewModel() -> OracleViewModel {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let fileManager = WorkspaceFilesViewModel()
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -696,
            settingsManager: WindowSettingsManager(windowID: -696)
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        return OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
    }
}

@MainActor
private final class OracleLifecycleActivityRecorder {
    private(set) var kinds: [OracleMessageLifecycleActivityEvent.Kind] = []

    func record(_ event: OracleMessageLifecycleActivityEvent) {
        kinds.append(event.kind)
    }
}
