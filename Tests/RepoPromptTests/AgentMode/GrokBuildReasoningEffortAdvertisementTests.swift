import Foundation
@testable import RepoPromptApp
import XCTest

/// Provider-boundary coverage for exact Grok reasoning-effort wire values and fail-closed
/// interpretation of malformed or ambiguous advertisements.
final class GrokBuildReasoningEffortAdvertisementTests: XCTestCase {
    func testExactAdvertisedAliasIsUsedOnWire() throws {
        let provider = makeProvider()
        let models = try validModels(provider.parseDirectSessionModelSnapshot(from: response(
            sessionID: "alias-session",
            efforts: standardEfforts + [
                ["id": "maximum", "value": "maximum", "default": false]
            ]
        )))

        XCTAssertTrue(models.options.contains { $0.rawValue == "grok-4.6-max" })
        let request = provider.makeDirectModelSelectionRequest(
            sessionID: "alias-session",
            baseModelRaw: "grok-4.6",
            reasoningEffortRaw: "max"
        )
        XCTAssertEqual(request.params["modelId"] as? String, "grok-4.6")
        XCTAssertEqual(
            (request.params["_meta"] as? [String: Any])?["reasoningEffort"] as? String,
            "maximum",
            "the provider must send the exact advertised value, not the enum's canonical raw"
        )
        XCTAssertEqual(request.expectedConfirmationModelRaw, "grok-4.6")
    }

    func testConflictingWireAliasesRemoveSemanticEffort() throws {
        let provider = makeProvider()
        let models = try validModels(provider.parseDirectSessionModelSnapshot(from: response(
            sessionID: "alias-collision-session",
            efforts: standardEfforts + [
                ["id": "max", "value": "max", "default": false],
                ["id": "maximum", "value": "maximum", "default": false]
            ]
        )))

        let base = try XCTUnwrap(models.options.first { $0.rawValue == "grok-4.6" })
        XCTAssertFalse(base.supportedReasoningEfforts.contains(.max))
        XCTAssertFalse(models.options.contains { $0.rawValue == "grok-4.6-max" })
    }

    func testUnknownListDefaultKeepsBareDefaultUnknown() throws {
        let provider = makeProvider()
        let models = try validModels(provider.parseDirectSessionModelSnapshot(from: response(
            sessionID: "unknown-default-session",
            efforts: standardEfforts + [
                ["id": "future", "value": "future-effort", "default": true]
            ],
            declaredDefault: "future-effort"
        )))

        let base = try XCTUnwrap(models.options.first { $0.rawValue == "grok-4.6" })
        XCTAssertNil(
            base.defaultReasoningEffort,
            "an unknown competing list default must not be filtered before authority is decided"
        )
    }

    func testMissingIDValueCollisionKeepsCurrentEffortUnknown() throws {
        let provider = makeProvider()
        let models = try validModels(provider.parseDirectSessionModelSnapshot(from: response(
            sessionID: "missing-id-session",
            efforts: [
                ["value": "high", "default": true],
                ["id": "high", "value": "low", "default": false]
            ],
            selectedID: "high"
        )))

        XCTAssertNil(
            models.currentEffortRaw,
            "a value-only match must remain in the ambiguity set"
        )
    }

    func testGenuineUnknownIDCollisionKeepsCurrentEffortUnknown() throws {
        let provider = makeProvider()
        let models = try validModels(provider.parseDirectSessionModelSnapshot(from: response(
            sessionID: "unknown-id-session",
            efforts: [
                ["id": "high", "value": "future-effort", "default": true],
                ["id": "eff-high", "value": "high", "default": false]
            ],
            selectedID: "high"
        )))

        XCTAssertNil(
            models.currentEffortRaw,
            "the test must use a genuinely unparsed future token; `ultra` is accepted"
        )
    }

    func testMissingSessionWireMappingCannotConfirmBaseOnlyMutation() throws {
        let provider = makeProvider()
        _ = try validModels(provider.parseDirectSessionModelSnapshot(from: response(
            sessionID: "parsed-session",
            efforts: standardEfforts + [
                ["id": "maximum", "value": "maximum", "default": false]
            ]
        )))

        let request = provider.makeDirectModelSelectionRequest(
            sessionID: "different-session",
            baseModelRaw: "grok-4.6",
            reasoningEffortRaw: "max"
        )
        XCTAssertNil(request.params["_meta"])
        XCTAssertNotEqual(
            request.expectedConfirmationModelRaw,
            "grok-4.6",
            "an unavailable exact effort mapping must make a base-only acknowledgement fail closed"
        )
    }

    private var standardEfforts: [[String: Any]] {
        [
            ["id": "high", "value": "high", "default": true],
            ["id": "low", "value": "low", "default": false]
        ]
    }

    private func makeProvider() -> GrokBuildACPAgentProvider {
        GrokBuildACPAgentProvider(
            config: GrokBuildAgentConfig(includeRepoPromptMCPServer: false)
        )
    }

    private func response(
        sessionID: String,
        efforts: [[String: Any]],
        declaredDefault: String = "high",
        selectedID: String = "high"
    ) -> [String: Any] {
        [
            "sessionId": sessionID,
            "models": [
                "currentModelId": "grok-4.6",
                "availableModels": [[
                    "modelId": "grok-4.6",
                    "name": "Grok 4.6",
                    "_meta": [
                        "supportsReasoningEffort": true,
                        "reasoningEffort": declaredDefault,
                        "reasoningEfforts": efforts
                    ]
                ]]
            ],
            "_meta": [
                "x.ai/sessionConfig": [
                    "options": [[
                        "id": selectedID,
                        "category": "mode",
                        "selected": true
                    ]]
                ]
            ]
        ]
    }

    private func validModels(
        _ result: ACPProviderModelSnapshotResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ACPDiscoveredSessionModels {
        switch result {
        case let .valid(models):
            return models
        case .absent:
            XCTFail("expected valid model metadata, got absent", file: file, line: line)
        case let .malformed(reason):
            XCTFail("expected valid model metadata, got malformed: \(reason)", file: file, line: line)
        }
        throw SnapshotError.notValid
    }

    private enum SnapshotError: Error {
        case notValid
    }
}
