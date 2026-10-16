import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import SwiftAnthropic
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

final class OracleImageSerializationTests: XCTestCase {
    func testAnthropicAttachesOnlyToFinalUserTurn() throws {
        let json = try jsonObject(AnthropicProvider.makeMessages(for: makeMessage()))
        let text = try jsonText(json)

        XCTAssertEqual(countObjects(type: "image", in: json), 1)
        XCTAssertTrue(text.contains("Image title: Diagram"))
        XCTAssertTrue(text.contains("AQID"))
        XCTAssertFalse(text.contains("/Users/secret.png"))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        XCTAssertFalse(try jsonText(messages[0]).contains("AQID"))
        XCTAssertTrue(try jsonText(XCTUnwrap(messages.last)).contains("AQID"))
    }

    func testAnthropicSynthesizesUserTurnWhenNoUserEntryExists() throws {
        let message = AIMessage(
            systemPrompt: "system",
            fileTree: "root",
            conversationMessages: [.init(role: .assistant, content: "answer")],
            transientImages: [
                .init(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")
            ],
            temperature: nil,
            promptSectionsOrder: [.fileMap],
            disabledPromptSections: []
        )
        let json = try jsonObject(AnthropicProvider.makeMessages(for: message))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let synthesized = try XCTUnwrap(messages.last)

        XCTAssertEqual(synthesized["role"] as? String, "user")
        XCTAssertEqual(countObjects(type: "image", in: json), 1)
        XCTAssertTrue(try jsonText(synthesized).contains("AQID"))
    }

    func testAnthropicImageTurnOmitsEmptyTextAndNormalizesTitles() throws {
        let message = AIMessage(
            systemPrompt: "system",
            conversationMessages: [.init(role: .user, content: "")],
            transientImages: [
                .init(bytes: Data([1, 2, 3]), mediaType: .png, title: "  Diagram  ")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
        let json = try jsonObject(AnthropicProvider.makeMessages(for: message))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let textBlocks = content.filter { $0["type"] as? String == "text" }

        // Anthropic rejects empty text blocks; only the normalized title line may appear.
        XCTAssertTrue(textBlocks.allSatisfy { (($0["text"] as? String) ?? "").isEmpty == false })
        XCTAssertTrue(try jsonText(content).contains("Image title: Diagram"))
        XCTAssertFalse(try jsonText(content).contains("  Diagram  "))
        XCTAssertEqual(countObjects(type: "image", in: json), 1)
    }

    func testRouteAdmissionAllowsEveryVerifiedOracleProviderTransport() {
        let models: [AIModel] = [
            .claude4Sonnet,
            .anthropicCustom(name: "custom"),
            .gpt5,
            .openAIServiceTierVariant(base: .gpt5, tier: "flex"),
            .openaiCustom(name: "custom"),
            .ollama,
            .azureCustom(name: "azure"),
            .openrouterCustom(name: "openrouter"),
            .geminiFlash25,
            .deepseekChat,
            .customProviderUser(name: "custom"),
            .fireworksDeepseekV3p1Terminus,
            .grokCodeFast1,
            .groqKimi,
            .zaiGLM45,
            .claudeCodeSonnet,
            .codexCustom(name: "codex"),
            .openCodeCustom(name: "opencode"),
            .cursorCustom(name: "cursor"),
            .devinCustom(name: "devin")
        ]
        for model in models {
            XCTAssertTrue(OracleImageRouteAdmission.supports(model), "Expected \(model) to admit images")
        }
        XCTAssertFalse(OracleImageRouteAdmission.supports(.grokBuildCustom(name: "grok")))
    }

    func testOpenAITextOnlyMessagesRemainScalar() throws {
        let message = AIMessage(systemPrompt: "system", userMessage: "plain")
        let chat = try XCTUnwrap(try jsonObject(
            message.openAIChatMessages(embedSystemPrompt: false)
        ) as? [[String: Any]])
        XCTAssertTrue(chat.allSatisfy { $0["content"] is String })

        let provider = CustomOpenAIProvider(
            baseURL: "https://example.test/v1",
            apiKey: "key",
            defaultModel: "text-model"
        )
        let custom = try XCTUnwrap(try jsonObject(
            provider.serializedMessagesForTesting(message)
        ) as? [[String: Any]])
        XCTAssertTrue(custom.allSatisfy { $0["content"] is String })

        let assistantOnly = AIMessage(
            systemPrompt: "",
            fileTree: "root",
            conversationMessages: [.init(role: .assistant, content: "answer")],
            temperature: nil,
            promptSectionsOrder: [.fileMap],
            disabledPromptSections: []
        )
        let responses = try XCTUnwrap(try jsonObject(
            assistantOnly.openAIResponsesInput()
        ) as? [[String: Any]])
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?["role"] as? String, "assistant")
    }

    func testOpenAIChatAttachesOnlyToFinalUserTurn() throws {
        let json = try jsonObject(makeMessage().openAIChatMessages(embedSystemPrompt: false))
        let text = try jsonText(json)
        let messages = try XCTUnwrap(json as? [[String: Any]])

        XCTAssertEqual(countObjects(type: "image_url", in: json), 1)
        XCTAssertTrue(
            text.contains("data:image/png;base64,AQID") ||
                text.contains("data:image\\/png;base64,AQID")
        )
        XCTAssertTrue(text.contains("Image title: Diagram"))
        XCTAssertFalse(try jsonText(messages[1]).contains("AQID"))
        XCTAssertTrue(try jsonText(XCTUnwrap(messages.last)).contains("AQID"))
    }

    func testOpenAIResponsesAttachesOnlyToFinalUserTurn() throws {
        let json = try jsonObject(makeMessage().openAIResponsesInput())
        let text = try jsonText(json)

        XCTAssertEqual(countObjects(type: "input_image", in: json), 1)
        XCTAssertTrue(
            text.contains("data:image/png;base64,AQID") ||
                text.contains("data:image\\/png;base64,AQID")
        )
        XCTAssertTrue(text.contains("Image title: Diagram"))
    }

    func testCustomOpenAIEncodesFinalUserAsContentArray() throws {
        let provider = CustomOpenAIProvider(
            baseURL: "https://example.test/v1",
            apiKey: "key",
            defaultModel: "vision-model"
        )
        let json = try jsonObject(provider.serializedMessagesForTesting(makeMessage()))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let earlierContent = messages[1]["content"]
        let finalMessage = try XCTUnwrap(messages.last)
        let finalContent = try XCTUnwrap(finalMessage["content"] as? [[String: Any]])

        XCTAssertTrue(earlierContent is String)
        XCTAssertEqual(countObjects(type: "image_url", in: finalContent), 1)
        let finalText = try jsonText(finalContent)
        XCTAssertTrue(
            finalText.contains("data:image/png;base64,AQID") ||
                finalText.contains("data:image\\/png;base64,AQID")
        )
    }

    func testCustomOpenAISynthesizedImageTurnKeepsAdditionsBeforeImages() throws {
        let provider = CustomOpenAIProvider(
            baseURL: "https://example.test/v1",
            apiKey: "key",
            defaultModel: "vision-model"
        )
        let message = AIMessage(
            systemPrompt: "system",
            fileTree: "root",
            conversationMessages: [.init(role: .assistant, content: "answer")],
            transientImages: [
                .init(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")
            ],
            temperature: nil,
            promptSectionsOrder: [.fileMap],
            disabledPromptSections: []
        )
        let json = try jsonObject(provider.serializedMessagesForTesting(message))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let synthesized = try XCTUnwrap(messages.last)
        let parts = try XCTUnwrap(synthesized["content"] as? [[String: Any]])

        XCTAssertEqual(synthesized["role"] as? String, "user")
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        XCTAssertTrue((parts.first?["text"] as? String)?.contains("root") == true)
        XCTAssertEqual(parts.last?["type"] as? String, "image_url")
    }

    func testACPEncodesTransientImagesInlineWithoutURI() throws {
        let image = AITransientImage(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")
        let blocks = try ACPPromptContentBuilder.blocks(
            text: "Inspect",
            attachments: [],
            transientImages: [image]
        )
        let imageBlock = try XCTUnwrap(blocks.last)

        XCTAssertEqual(imageBlock["type"] as? String, "image")
        XCTAssertEqual(imageBlock["mimeType"] as? String, "image/png")
        XCTAssertEqual(imageBlock["data"] as? String, "AQID")
        XCTAssertNil(imageBlock["uri"])
    }

    func testACPCLIAdaptersPreserveTransientImages() {
        let message = makeMessage()
        let openCode = OpenCodeCLIProvider.test_makeAgentMessage(from: message)
        let cursor = CursorCLIProvider.test_makeAgentMessage(from: message)
        let devin = DevinCLIProvider.test_makeImageAgentMessage(from: message)

        XCTAssertEqual(openCode.transientImages, message.transientImages)
        XCTAssertEqual(cursor.transientImages, message.transientImages)
        XCTAssertEqual(devin.transientImages, message.transientImages)
    }

    func testDevinACPPromptBlocksCarryTransientImages() throws {
        let message = DevinCLIProvider.test_makeImageAgentMessage(from: makeMessage())
        let provider = DevinACPAgentProvider(
            config: DevinCLIProvider().test_makeImageHeadlessConfig(modelName: nil)
        )
        let blocks = try provider.buildPromptBlocks(
            for: message,
            request: ACPRunRequest(
                agentKind: .devin,
                modelString: nil,
                workspacePath: nil,
                resumeSessionID: nil,
                attachments: [],
                taskLabelKind: nil
            )
        )
        let imageBlock = try XCTUnwrap(blocks.last)

        XCTAssertEqual(imageBlock["type"] as? String, "image")
        XCTAssertEqual(imageBlock["mimeType"] as? String, "image/png")
        XCTAssertEqual(imageBlock["data"] as? String, "AQID")
    }

    func testCodexStagesTransientImagesWithOwnerOnlyPermissionsAndCleansUp() async throws {
        let bytes = Data([0xFF, 0xD8, 0xFF])
        var stagedFileURL: URL?
        var stagedDirectoryURL: URL?

        let stagedImages = try await OracleTransientImageStaging.stage([
            .init(bytes: bytes, mediaType: .jpeg, title: "  Reference  ")
        ])
        let staging = try XCTUnwrap(stagedImages)
        do {
            let file = try XCTUnwrap(staging.files.first)
            XCTAssertEqual(staging.files.count, 1)
            XCTAssertEqual(file.title, "Reference")

            let fileURL = URL(fileURLWithPath: file.path)
            let directoryURL = fileURL.deletingLastPathComponent()
            stagedFileURL = fileURL
            stagedDirectoryURL = directoryURL

            XCTAssertTrue(directoryURL.lastPathComponent.hasPrefix("RepoPromptOracleImages-"))
            XCTAssertEqual(fileURL.pathExtension, "jpg")
            XCTAssertEqual(try Data(contentsOf: fileURL), bytes)

            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directoryURL.path)
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        staging.cleanup()

        let fileURL = try XCTUnwrap(stagedFileURL)
        let directoryURL = try XCTUnwrap(stagedDirectoryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.path))
    }

    func testClaudeStreamJSONEncodesTransientImages() throws {
        let line = try ClaudeCodeProvider.makeStreamJSONInput(
            prompt: "Inspect",
            images: [.init(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")]
        )
        XCTAssertTrue(line.hasSuffix("\n"))
        let data = try XCTUnwrap(line.dropLast().data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try XCTUnwrap(payload["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        let image = try XCTUnwrap(content.last)
        let source = try XCTUnwrap(image["source"] as? [String: Any])

        XCTAssertEqual(payload["type"] as? String, "user")
        XCTAssertEqual(image["type"] as? String, "image")
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "AQID")

        var options = ClaudeCLIOptions()
        XCTAssertFalse(options.toTokens().contains("--input-format"))
        ClaudeCodeProvider.applyStreamJSONImageTransport(to: &options)
        let tokens = options.toTokens()
        XCTAssertTrue(tokens.contains("--input-format"))
        XCTAssertTrue(tokens.contains("stream-json"))
        // stream-json input in print mode requires --verbose, matching the Agent Mode runner.
        XCTAssertTrue(tokens.contains("--verbose"))
        XCTAssertTrue(tokens.contains("-p"))
    }

    func testClaudeStreamJSONParsesTerminalResultAndUsage() throws {
        let output = """
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"Done","usage":{"input_tokens":11,"output_tokens":7},"total_cost_usd":0.12}
        """

        let completion = try ClaudeCodeProvider.test_parseStreamJSONCompletionPayload(Data(output.utf8))

        XCTAssertEqual(completion.text, "Done")
        XCTAssertEqual(completion.promptTokens, 11)
        XCTAssertEqual(completion.completionTokens, 7)
        XCTAssertEqual(completion.cost, 0.12)
    }

    func testClaudeStreamJSONExtractsTerminalError() {
        let output = """
        {"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Request was aborted by user"],"usage":{"input_tokens":11,"output_tokens":0},"total_cost_usd":0.12}
        """

        XCTAssertEqual(
            ClaudeCodeProvider.test_extractStreamJSONErrorDetail(from: Data(output.utf8)),
            "Request was aborted by user"
        )
    }

    private func makeMessage() -> AIMessage {
        AIMessage(
            systemPrompt: "system",
            conversationMessages: [
                .init(role: .user, content: "first"),
                .init(role: .assistant, content: "answer"),
                .init(role: .user, content: "final")
            ],
            transientImages: [
                .init(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
    }

    private func jsonObject(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func jsonText(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func countObjects(type: String, in value: Any) -> Int {
        if let object = value as? [String: Any] {
            return (object["type"] as? String == type ? 1 : 0)
                + object.values.reduce(0) { $0 + countObjects(type: type, in: $1) }
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + countObjects(type: type, in: $1) }
        }
        return 0
    }
}
