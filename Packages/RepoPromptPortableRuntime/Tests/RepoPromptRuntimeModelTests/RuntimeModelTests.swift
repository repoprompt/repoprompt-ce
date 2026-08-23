import Foundation
@testable import RepoPromptRuntimeModel
import XCTest

final class RuntimeModelTests: XCTestCase {
    func testIdentifiersRejectEmptyValues() throws {
        XCTAssertThrowsError(try RuntimeOwnerID(validating: "  "))
        XCTAssertThrowsError(try RuntimeResourceID(validating: "\n"))
    }

    func testWorkflowValueUsesNaturalJSONAndPreservesIntegers() throws {
        let value = WorkflowValue.object([
            "integer": .integer(42),
            "number": .number(2.5),
            "enabled": .boolean(true),
            "items": .array([.string("value"), .null])
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(WorkflowValue.self, from: data), value)

        let decoded = try JSONDecoder().decode(WorkflowValue.self, from: Data("42".utf8))
        XCTAssertEqual(decoded, .integer(42))
    }

    func testProviderSettingsPersistedRawValuesAndDefaultsRemainStable() throws {
        XCTAssertEqual(
            ProviderSettingsID.allCases.map(\.rawValue),
            [
                "codex", "claudeCompatible", "claudeGLM", "claudeKimi", "claudeCustom",
                "openCodeACP", "cursorACP", "grokBuildACP", "openAIAPI", "anthropicAPI",
                "openRouter", "customOpenAICompatible", "gemini", "azure", "deepseek",
                "fireworks", "xAI", "groq", "zAI", "ollama"
            ]
        )
        XCTAssertEqual(
            Set(ProviderSettingsID.directAPIProviders),
            Set([
                .openAIAPI,
                .anthropicAPI,
                .openRouter,
                .customOpenAICompatible,
                .gemini,
                .azure,
                .deepseek,
                .fireworks,
                .xAI,
                .groq,
                .zAI,
                .ollama
            ])
        )
        XCTAssertEqual(ProviderSettingsID.claudeGLM.runtimeSettingsOwner, .claudeCompatible)
        XCTAssertEqual(ProviderSettingsID.claudeKimi.runtimeSettingsOwner, .claudeCompatible)
        XCTAssertEqual(ProviderSettingsID.claudeCustom.runtimeSettingsOwner, .claudeCompatible)
        XCTAssertEqual(ProviderSettingsID.ollama.desktopBootstrapMaxTokens, 4096)
        XCTAssertEqual(ProviderSettingsID.groq.desktopBootstrapMaxTokens, 16384)
        XCTAssertEqual(ProviderSettingsID.openAIAPI.desktopBootstrapMaxTokens, 0)
        XCTAssertEqual(ProviderSettingsID.desktopOllamaDefaultURL, "http://localhost:11434")
        XCTAssertEqual(
            ProviderAuthenticationMethod.allCases.map(\.rawValue),
            [
                "browserOAuth",
                "deviceCodeBeta",
                "apiKey",
                "enterpriseAccessToken",
                "authToken",
                "keyHelper",
                "workloadIdentityFederation",
                "browserLogin",
                "providerSpecific"
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            try String(decoding: encoder.encode(ProviderSettingsID.allCases), as: UTF8.self),
            #"["codex","claudeCompatible","claudeGLM","claudeKimi","claudeCustom","openCodeACP","cursorACP","grokBuildACP","openAIAPI","anthropicAPI","openRouter","customOpenAICompatible","gemini","azure","deepseek","fireworks","xAI","groq","zAI","ollama"]"#
        )
    }

    func testEstablishedLifecycleAndTransitionRawValuesRemainStable() {
        XCTAssertEqual(
            [
                SessionLifecycleState.preparing, .idle, .running, .waiting, .completed,
                .failed, .canceled, .interrupted, .archived
            ].map(\.rawValue),
            ["preparing", "idle", "running", "waiting", "completed", "failed", "canceled", "interrupted", "archived"]
        )
        XCTAssertEqual(
            [ProjectLifecycleState.active, .degraded, .archived].map(\.rawValue),
            ["active", "degraded", "archived"]
        )
        XCTAssertEqual(
            [AgentSubmissionState.preparing, .accepted, .rejected].map(\.rawValue),
            ["preparing", "accepted", "rejected"]
        )
        XCTAssertEqual(
            [
                ProjectSourceOperationState.validating, .cloning, .promoting,
                .completed, .failed
            ].map(\.rawValue),
            ["validating", "cloning", "promoting", "completed", "failed"]
        )
        XCTAssertEqual(
            [ProviderConnectionState.connected, .attention, .disconnected].map(\.rawValue),
            ["connected", "attention", "disconnected"]
        )
        XCTAssertEqual(
            RunPresentationPhase.allCases.map(\.rawValue),
            ["preparing", "thinking", "working", "waiting", "cancelling"]
        )
    }

    func testWorkflowRejectsUnsupportedVersion() {
        XCTAssertThrowsError(try WorkflowDefinition(formatVersion: 2)) { error in
            XCTAssertEqual(error as? RuntimeModelError, .unsupportedWorkflowVersion(2))
        }
    }

    func testWorkflowRejectsNestedNonFiniteNumberAtConstruction() {
        XCTAssertThrowsError(try WorkflowDefinition(payload: .object([
            "nested": .array([.number(.nan)])
        ]))) { error in
            XCTAssertEqual(error as? RuntimeModelError, .invalidNumber)
        }
    }
}
