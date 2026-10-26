import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import RepoPromptShared
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
            attachments: [
                .init(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "Diagram")
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
            attachments: [
                .init(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "  Diagram  ")
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

    func testAttachmentRouteFollowsTheCodeThatEncodesTheRequest() {
        XCTAssertEqual(AIModel.gpt5.attachmentRoute, .openAIResponses)
        XCTAssertEqual(AIModel.ollama.attachmentRoute, .openAIChat)
        XCTAssertEqual(AIModel.claude4Sonnet.attachmentRoute, .anthropicMessages)
        XCTAssertEqual(AIModel.grokBuildCustom(name: "grok").attachmentRoute, .grokBuild)
        XCTAssertEqual(AIModel.azureCustom(name: "azure").attachmentRoute, .openAIChat)
        XCTAssertEqual(AIModel.customProviderUser(name: "custom").attachmentRoute, .customOpenAI)
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
            attachments: [
                .init(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "Diagram")
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
        let image = OracleAttachment(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "Diagram")
        let blocks = try ACPPromptContentBuilder.blocks(
            text: "Inspect",
            attachments: [],
            oracleAttachments: [image]
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

        XCTAssertEqual(openCode.attachments, message.attachments)
        XCTAssertEqual(cursor.attachments, message.attachments)
        XCTAssertEqual(devin.attachments, message.attachments)
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

        let planned = try AttachmentEncoding.plan(
            [.init(payload: .image(.jpeg, bytes), fileName: "image.jpg", title: "  Reference  ")],
            route: .codexAppServer
        )
        let stagedImages = try await OracleTransientImageStaging.stage(planned, route: .codexAppServer)
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
            attachments: [.init(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "Diagram")]
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
        {"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"Done","usage":{"input_tokens":11,"output_tokens":7},"total_cost_usd":0.12}
        """

        let completion = try ClaudeCodeProvider.test_parseStreamJSONCompletionPayload(Data(output.utf8))

        XCTAssertEqual(completion.text, "Done")
        XCTAssertEqual(completion.promptTokens, 11)
        XCTAssertEqual(completion.completionTokens, 7)
        XCTAssertEqual(completion.cost, 0.12)
    }

    func testClaudeStreamJSONPreservesContinuedAnswerWithoutDuplicatingResult() throws {
        let first = String(repeating: "First section. ", count: 20000) + "\n```swift\nfunc handl"
        let output = try [
            jsonText(["type": "assistant", "message": ["stop_reason": "max_tokens", "content": [
                ["type": "text", "text": first],
                ["type": "tool_use", "text": "not answer text"]
            ]]]),
            jsonText(["type": "user", "message": ["content": "continue"]]),
            jsonText(["type": "assistant", "parent_tool_use_id": "child", "message": ["content": [
                ["type": "text", "text": "not the parent reply"]
            ]]]),
            jsonText(["type": "assistant", "parent_tool_use_id": NSNull(), "message": ["stop_reason": "end_turn", "content": [
                ["type": "thinking", "thinking": "private"],
                ["type": "text", "text": "eRequest() {}\n"],
                ["type": "text", "text": "```"]
            ]]]),
            jsonText(["type": "result", "subtype": "success", "result": "eRequest() {}\n```"])
        ].joined(separator: "\n")

        let completion = try ClaudeCodeProvider.test_parseStreamJSONCompletionPayload(Data(output.utf8))
        XCTAssertEqual(completion.text, first + "eRequest() {}\n```")
    }

    func testClaudeStreamJSONIgnoresNonJSONStdoutDiagnostics() throws {
        let output = """
        [SandboxDebug] Preparing sandbox
        {"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"First "}]}}
        [SandboxDebug] Sandbox ready
        {"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"last"}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"last"}
        """

        let completion = try ClaudeCodeProvider.test_parseStreamJSONCompletionPayload(Data(output.utf8))
        XCTAssertEqual(completion.text, "First last")
    }

    func testClaudeStreamJSONRejectsErrorsAndIncompleteOutput() throws {
        let assistant = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Partial"}]}}"#
        let success = #"{"type":"result","subtype":"success","result":"Done"}"#
        for output in [
            assistant,
            assistant + "\n" + #"{"type":"result","is_error":true,"errors":["Failed"]}"#,
            assistant + "\n" + #"{"type":"error","message":"Failed"}"#,
            assistant + "\n{malformed}\n" + success,
            assistant + "\n" + success + "\n{"
        ] {
            XCTAssertThrowsError(try ClaudeCodeProvider.test_parseStreamJSONCompletionPayload(Data(output.utf8)))
        }
        let completion = try ClaudeCodeProvider.test_parseStreamJSONCompletionPayload(Data(success.utf8))
        XCTAssertEqual(completion.text, "Done")
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
            attachments: [
                .init(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "Diagram")
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

final class AttachmentRouteEncoderMatrixAppTests: XCTestCase {
    private enum Emitted: Hashable {
        case image
        case document
        case inlineText
    }

    private enum Reach {
        case appTarget(([OracleAttachment]) async throws -> Set<Emitted>)
        case domainRuntime
    }

    private func reach(of route: AttachmentRoute) -> Reach {
        switch route {
        case .anthropicMessages: .appTarget(Self.anthropic)
        case .openAIChat: .appTarget(Self.openAIChat)
        case .openAIResponses: .appTarget(Self.openAIResponses)
        case .codexAppServer: .appTarget(Self.codex)
        case .grokBuild: .appTarget(Self.grok)
        case .customOpenAI, .claudeCodeStreamJSON, .acp: .domainRuntime
        }
    }

    func testEveryAppEncoderEmitsExactlyWhatItsRowPromisesOrRefusesByName() async throws {
        var exercised = 0
        for route in AttachmentRoute.allCases {
            guard case let .appTarget(encode) = reach(of: route) else { continue }
            let row = AttachmentRouteCapability.capability(for: route)
            for kind in AttachmentKind.allCases {
                let attachment = Self.sample(kind)
                let label = "\(route) × \(kind)"
                switch Self.promised(by: row, kind: kind) {
                case let promised?:
                    let emitted = try await encode([attachment])
                    XCTAssertEqual(emitted, [promised], label)
                case nil:
                    do {
                        let emitted = try await encode([attachment])
                        XCTFail("\(label) emitted \(emitted) but its row refuses it")
                    } catch let error as AttachmentAdmissionError {
                        XCTAssertTrue(
                            error.localizedDescription.contains(attachment.fileName),
                            "\(label) refusal must name the file: \(error.localizedDescription)"
                        )
                    }
                }
                exercised += 1
            }
        }
        XCTAssertEqual(exercised, 5 * AttachmentKind.allCases.count)
    }

    func testAnthropicSendsPDFCSVAndPNGInOneRequest() throws {
        let json = try Self.json(AnthropicProvider.makeMessages(for: Self.message([
            Self.sample(.pdf), Self.sample(.text), Self.sample(.image)
        ])))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.compactMap { $0["type"] as? String }.sorted(), ["document", "image", "text"])
        let text = try XCTUnwrap(parts.first { $0["type"] as? String == "text" }?["text"] as? String)
        XCTAssertTrue(text.hasPrefix("Attached file: data.csv\n```\na,b\n1,2\n```"), text)
        XCTAssertTrue(text.hasSuffix("Question"), text)
        let document = try XCTUnwrap(parts.first { $0["type"] as? String == "document" })
        XCTAssertEqual((document["source"] as? [String: Any])?["media_type"] as? String, "application/pdf")
    }

    func testOpenAIChatRefusesThePDFByNameAndStillPlansTheCSVAndPNG() throws {
        let attachments = [Self.sample(.pdf), Self.sample(.text), Self.sample(.image)]
        XCTAssertThrowsError(try Self.message(attachments).openAIChatMessages(embedSystemPrompt: false)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("report.pdf"), message)
            XCTAssertFalse(message.contains("data.csv"), message)
            XCTAssertFalse(message.contains("diagram.png"), message)
        }

        let delivered = try Self.json(
            Self.message([Self.sample(.text), Self.sample(.image)]).openAIChatMessages(embedSystemPrompt: false)
        )
        let messages = try XCTUnwrap(delivered as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(Self.emitted(fromParts: parts), [.inlineText, .image])
    }

    func testResponsesEncoderAcceptsASetAdmittedUnderTheChatRow() throws {
        let attachments = [Self.sample(.text), Self.sample(.image)]
        XCTAssertNoThrow(try AttachmentEncoding.plan(attachments, route: .openAIChat))
        let json = try Self.json(Self.message(attachments).openAIResponsesInput())
        let items = try XCTUnwrap(json as? [[String: Any]])
        let parts = try XCTUnwrap(items.last?["content"] as? [[String: Any]])
        XCTAssertEqual(Self.emitted(fromParts: parts), [.inlineText, .image])
    }

    func testResponsesCarriesThePDFAsAFileWithItsName() throws {
        let json = try Self.json(Self.message([Self.sample(.pdf)]).openAIResponsesInput())
        let items = try XCTUnwrap(json as? [[String: Any]])
        let parts = try XCTUnwrap(items.last?["content"] as? [[String: Any]])
        let file = try XCTUnwrap(parts.first { $0["type"] as? String == "input_file" })
        XCTAssertEqual(file["filename"] as? String, "report.pdf")
        XCTAssertTrue((file["file_data"] as? String)?.hasPrefix("data:application/pdf;base64,") == true)
    }

    func testAnthropicRefusesBeforeTheSDKWhenEncodedPDFsExceedTheRequestCap() throws {
        let limit = try XCTUnwrap(AttachmentRouteCapability.capability(for: .anthropicMessages).maxEncodedRequestBytes)
        let size = limit / 4 * 3 / 2 + 1024
        let pdfs = ["first.pdf", "second.pdf"].map {
            OracleAttachment(payload: .pdf(Self.pdfBytes(extra: size)), fileName: $0, title: nil)
        }
        XCTAssertThrowsError(try AnthropicProvider.makeMessages(for: Self.message(pdfs))) { error in
            XCTAssertTrue(error is AttachmentAdmissionError, "\(error)")
        }
    }

    private static func promised(by row: AttachmentRouteCapability, kind: AttachmentKind) -> Emitted? {
        switch kind {
        case .image: row.image == .nativeImage ? .image : nil
        case .pdf: row.pdf == .nativeDocument ? .document : nil
        case .text: row.text == .inlineText ? .inlineText : nil
        case .binary: nil
        }
    }

    private static func sample(_ kind: AttachmentKind) -> OracleAttachment {
        switch kind {
        case .image:
            OracleAttachment(payload: .image(.png, Data([1, 2, 3])), fileName: "diagram.png", title: nil)
        case .pdf:
            OracleAttachment(payload: .pdf(pdfBytes()), fileName: "report.pdf", title: nil)
        case .text:
            OracleAttachment(payload: .text("a,b\n1,2\n", Data("a,b\n1,2\n".utf8)), fileName: "data.csv", title: nil)
        case .binary:
            OracleAttachment(payload: .binary(Data([0, 1, 2, 3])), fileName: "blob.bin", title: nil)
        }
    }

    private static func pdfBytes(extra: Int = 0) -> Data {
        var data = Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)
        if extra > 0 { data.append(Data(count: extra)) }
        return data
    }

    private static func message(_ attachments: [OracleAttachment]) -> AIMessage {
        AIMessage(
            systemPrompt: "",
            conversationMessages: [.init(role: .user, content: "Question")],
            attachments: attachments,
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
    }

    private static func json(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private static func anthropic(_ attachments: [OracleAttachment]) throws -> Set<Emitted> {
        let json = try json(AnthropicProvider.makeMessages(for: message(attachments)))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        return try emitted(fromContent: XCTUnwrap(messages.last?["content"]))
    }

    private static func openAIChat(_ attachments: [OracleAttachment]) throws -> Set<Emitted> {
        let json = try json(message(attachments).openAIChatMessages(embedSystemPrompt: false))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        return try emitted(fromContent: XCTUnwrap(messages.last?["content"]))
    }

    private static func openAIResponses(_ attachments: [OracleAttachment]) throws -> Set<Emitted> {
        let json = try json(message(attachments).openAIResponsesInput())
        let items = try XCTUnwrap(json as? [[String: Any]])
        return try emitted(fromContent: XCTUnwrap(items.last?["content"]))
    }

    private static func emitted(fromContent content: Any) -> Set<Emitted> {
        if let parts = content as? [[String: Any]] { return emitted(fromParts: parts) }
        return emitted(fromParts: [["type": "text", "text": content]])
    }

    private static func emitted(fromParts parts: [[String: Any]]) -> Set<Emitted> {
        var emitted = Set<Emitted>()
        for part in parts {
            switch part["type"] as? String {
            case "image", "image_url", "input_image": emitted.insert(.image)
            case "document", "input_file", "file": emitted.insert(.document)
            default:
                let text = (part["text"] as? String) ?? ""
                if text.contains("Attached file: data.csv"), text.contains("a,b\n1,2") { emitted.insert(.inlineText) }
            }
        }
        return emitted
    }

    private static func isInlineBlock(_ text: String) -> Bool {
        text.contains("Attached file: data.csv") && text.contains("a,b\n1,2")
    }

    private static func codex(_ attachments: [OracleAttachment]) async throws -> Set<Emitted> {
        let controller = RecordingCodexController()
        let provider = CodexCLIProvider(sessionControllerFactory: { _, _ in controller })
        let stream = try await provider.streamMessage(message(attachments), model: .codexCliGpt5Low)
        for try await _ in stream {}
        await provider.dispose()

        let turn = try XCTUnwrap(controller.recordedTurn, "Codex never started a turn")
        var emitted = Set<Emitted>()
        if !turn.attachmentFilesExisted.isEmpty, turn.attachmentFilesExisted.allSatisfy(\.self) {
            emitted.insert(.image)
        }
        if isInlineBlock(turn.text) { emitted.insert(.inlineText) }
        return emitted
    }

    private static func grok(_ attachments: [OracleAttachment]) async throws -> Set<Emitted> {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokMatrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("grok")
        let script = #"""
        #!/bin/sh
        if [ "$1" = agent ] && [ "$2" = --help ]; then
            printf 'stdio\n'
            exit 0
        fi
        /bin/cat prompt.txt > "$RPCE_FIXTURE_ROOT/prompt-seen"
        printf '%s\n' '{"text":"ok","stopReason":"end_turn","sessionId":"s","usage":{"input_tokens":1,"output_tokens":1}}'
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": root.appendingPathComponent("home", isDirectory: true).path,
            "GROK_HOME": root.appendingPathComponent("grok-home", isDirectory: true).path,
            "RPCE_FIXTURE_ROOT": root.path
        ]
        let provider = GrokBuildOneShotHeadlessAgentProvider(
            config: GrokBuildAgentConfig(
                commandName: executable.path,
                modelString: nil,
                includeRepoPromptMCPServer: false
            ),
            launchResolver: GrokBuildACPLaunchResolver(environmentProvider: { _ in environment }),
            requestTimeout: 30,
            apiKeyProvider: { nil }
        )
        let agentMessage = AgentMessage(systemPrompt: "", userMessage: "Question", attachments: attachments)
        try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            let stream = try await provider.streamAgentMessage(agentMessage)
            for try await _ in stream {}
        }
        await provider.dispose()

        let seen = try String(contentsOf: root.appendingPathComponent("prompt-seen"), encoding: .utf8)
        return isInlineBlock(seen) ? [.inlineText] : []
    }
}

private final class RecordingCodexController: CodexSessionControllerPassiveStubDefaults, @unchecked Sendable {
    struct Turn {
        let text: String
        let attachmentFilesExisted: [Bool]
    }

    private let lock = NSLock()
    private var turn: Turn?
    private var active = false
    private let stream = AsyncStream<CodexNativeSessionController.Event>.makeStream()

    var hasActiveThread: Bool {
        lock.withLock { active }
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        stream.stream
    }

    var recordedTurn: Turn? {
        lock.withLock { turn }
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        lock.withLock { active = true }
        return .init(conversationID: "matrix", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startUserTurn(
        text: String,
        attachments: [AgentFileAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        let existed = attachments.map { attachment -> Bool in
            guard case let .localFile(path) = attachment.source else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
        lock.withLock { turn = Turn(text: text, attachmentFilesExisted: existed) }
        stream.continuation.yield(.turnCompleted(turnID: "matrix", status: .completed))
        return CodexTurnStartReceipt(provisionalSubmissionID: "matrix")
    }

    func shutdown() async {
        lock.withLock { active = false }
        stream.continuation.finish()
    }
}
