import Foundation
import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class AIProviderContractTests: XCTestCase {
    private final class Probe: AIProvider, AIModelGetter {
        var calls: [(String, AIModel, Int?)] = []

        func streamMessage(_ message: RepoPromptDomainRuntime.AIMessage, model: AIModel, maxTokens: Int?) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error> {
            calls.append((message.conversationMessages.last?.content ?? "", model, maxTokens))
            return AsyncThrowingStream { continuation in
                continuation.yield(.init(type: "text", text: "stream-result"))
                continuation.finish()
            }
        }

        func completeMessage(_ message: RepoPromptDomainRuntime.AIMessage, model: AIModel, maxTokens: Int?) async throws -> RepoPromptDomainRuntime.AICompletionResult {
            calls.append((message.conversationMessages.last?.content ?? "", model, maxTokens))
            return .init(text: "completion-result")
        }

        func getAvailableModels() async throws -> [String] {
            [" Raw/Model ", "raw/model"]
        }
    }

    func testConvenienceOverloadsForwardNilLimitsAndPreserveExplicitLimits() async throws {
        let probe = Probe()
        let provider: any AIProvider = probe
        let message = RepoPromptDomainRuntime.AIMessage(systemPrompt: "system", userMessage: "request")
        let model = AIModel.openaiCustomReasoning(name: " Exact/Model ", effort: .high)
        var text: [String] = []
        for try await result in try await provider.streamMessage(message, model: model) {
            text.append(result.text ?? "")
        }
        let completion = try await provider.completeMessage(message, model: model)
        _ = try await provider.completeMessage(message, model: model, maxTokens: 17)
        for try await _ in try await provider.streamMessage(message, model: model, maxTokens: 23) {}
        XCTAssertEqual(text, ["stream-result"])
        XCTAssertEqual(completion.text, "completion-result")
        XCTAssertEqual(probe.calls.map(\.0), Array(repeating: "request", count: 4))
        XCTAssertEqual(probe.calls.map(\.1), Array(repeating: model, count: 4))
        XCTAssertEqual(probe.calls.map(\.2), [nil, nil, 17, 23])
        let getter: any AIModelGetter = probe
        let available = try await getter.getAvailableModels()
        XCTAssertEqual(available, [" Raw/Model ", "raw/model"])
    }

    func testDefaultCleanupAndDisposeDoNotInventProviderEffects() async throws {
        let probe = Probe()
        let provider: any AIProvider = probe
        let handle = ProviderConversationCleanupHandle(provider: "fixture", conversationID: "conversation")
        for action in ProviderConversationCleanupAction.allCases {
            let outcome = await provider.cleanupConversation(handle, action: action)
            XCTAssertEqual(outcome, .unsupported(message: "Provider has no local API for \(action.rawValue) cleanup of conversations."))
        }
        await provider.dispose()
        XCTAssertTrue(probe.calls.isEmpty)
        let result = try await provider.completeMessage(.init(systemPrompt: "", userMessage: "after-dispose"), model: .gpt41)
        XCTAssertEqual(result.text, "completion-result")
        XCTAssertEqual(probe.calls.map(\.0), ["after-dispose"])
    }
}
