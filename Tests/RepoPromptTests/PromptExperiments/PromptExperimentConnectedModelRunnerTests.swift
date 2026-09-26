import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class PromptExperimentConnectedModelRunnerTests: XCTestCase {
        func testOnlyToolFreeProvidersArePromptOnlyTargetsAndErrorsNameTheField() throws {
            let claude = PromptExperimentTestFixtures.execution
            let codex = try PromptExperimentTestFixtures.resolveTarget("codex")
            XCTAssertNoThrow(try PromptExperimentConnectedModelRunner.requirePromptOnlyTarget(claude))
            XCTAssertThrowsError(try PromptExperimentConnectedModelRunner.requirePromptOnlyTarget(codex))
            let unknown = PromptExperimentResolvedTarget(role: "x", agentRaw: "notAProvider", modelRaw: "m", displayName: "X")
            XCTAssertThrowsError(try PromptExperimentConnectedModelRunner.requirePromptOnlyTarget(unknown))

            let errors = PromptExperimentConnectedModelRunner.targetErrors(
                PromptExperimentTargets(execution: claude, reflection: codex, judge: unknown)
            )
            XCTAssertEqual(errors.map(\.field), ["reflection", "judge"])
        }

        func testProviderFailureClassificationIsClosedAndRetryabilityIsExplicit() {
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyProviderDescription("HTTP 429 rate limit").code, .rateLimited)
            XCTAssertTrue(PromptExperimentProviderFailureCode.rateLimited.isRetryable)
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyProviderDescription("OAuth authentication expired").code, .rejected)
            XCTAssertFalse(PromptExperimentProviderFailureCode.rejected.isRetryable)
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyProviderDescription("surprising opaque failure").code, .unknown)
            XCTAssertFalse(PromptExperimentProviderFailureCode.unknown.isRetryable)
            XCTAssertFalse(PromptExperimentProviderFailureCode.timedOut.isRetryable)
        }

        func testInStreamErrorEventsClassifyTransientFailuresAsRetryable() {
            let overloaded = AIStreamResult(
                type: "error",
                text: #"API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
            )
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyStreamError(overloaded).code, .temporarilyUnavailable)
            let rateLimited = AIStreamResult(
                type: "error",
                text: #"API Error: 429 {"type":"error","error":{"type":"rate_limit_error"}}"#
            )
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyStreamError(rateLimited).code, .rateLimited)
            let unavailable = AIStreamResult(type: "error", text: "API Error: 503 Service Unavailable")
            XCTAssertTrue(PromptExperimentConnectedModelRunner.classifyStreamError(unavailable).code.isRetryable)
            let typed = AIStreamResult(type: "error", text: "opaque", stopReason: "rate_limit")
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyStreamError(typed).code, .rateLimited)
            let opaque = AIStreamResult(type: "error", text: "Something odd happened")
            XCTAssertEqual(PromptExperimentConnectedModelRunner.classifyStreamError(opaque).code, .unknown)
            XCTAssertFalse(PromptExperimentConnectedModelRunner.classifyStreamError(opaque).code.isRetryable)
        }

        func testCompletionPreservesMessageBoundariesAndTerminalUsage() throws {
            let provider = CodexExecAgentProvider(config: .init(commandName: "codex", additionalPathHints: []))
            var accumulator = PromptExperimentCompletionAccumulator()
            let answer = "{\"action\":\"answer\",\"text\":\"same answer\"}"
            for id in ["commentary-id", "final-id"] {
                let data = try JSONSerialization.data(withJSONObject: [
                    "type": "item.completed", "item": ["type": "agent_message", "id": id, "text": answer]
                ])
                let event = try XCTUnwrap(provider.parseJSONLEvent(data))
                XCTAssertEqual(event.contentMessageID, id)
                accumulator.consume(event)
            }
            let terminal = try XCTUnwrap(provider.parseJSONLEvent(Data(
                #"{"type":"turn.completed","usage":{"input_tokens":31,"output_tokens":9}}"#.utf8
            )))
            accumulator.consume(terminal)
            XCTAssertEqual(accumulator.output, answer)
            XCTAssertEqual(accumulator.promptTokens, 31)
            XCTAssertEqual(accumulator.completionTokens, 9)
            var deltas = PromptExperimentCompletionAccumulator()
            deltas.consume(AIStreamResult(type: "content", text: "same"))
            deltas.consume(AIStreamResult(type: "content", text: "same"))
            XCTAssertEqual(deltas.output, "samesame", "Do not heuristically deduplicate valid token deltas")
            deltas.consume(AIStreamResult(type: "final_content", text: "authoritative final"))
            XCTAssertEqual(deltas.output, "authoritative final")
        }

        func testPromptOnlyClaudeProfileDisablesNativeAndWebTools() {
            let configuration = ClaudeCodeAgentConfig.promptExperiment(modelString: "claude-sonnet-4-6")
            XCTAssertFalse(configuration.allowNativeBashTool)
            XCTAssertTrue(configuration.mcpStrictMode)
            XCTAssertFalse(configuration.toolSearchEnabled)
            for tool in ["Bash", "Read", "Write", "Edit", "WebSearch", "WebFetch", "Task"] {
                XCTAssertTrue(configuration.disallowedBuiltInTools.contains(tool))
            }
            XCTAssertTrue(configuration.processEnvironmentOverrides.isEmpty)
        }
    }
#endif
