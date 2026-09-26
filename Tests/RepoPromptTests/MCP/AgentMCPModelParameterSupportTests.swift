import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AgentMCPModelParameterSupportTests: XCTestCase {
    /// Cursor's selectors are advertised per model by discovery, so the Cursor cases below run
    /// against a published catalogue rather than a compiled model table.
    override func setUp() {
        super.setUp()
        CursorDiscoveredCatalogTestSupport.reset()
        CursorDiscoveredCatalogTestSupport.seedStandardCatalog()
    }

    override func tearDown() {
        CursorDiscoveredCatalogTestSupport.reset()
        super.tearDown()
    }

    func testCursorDefinitionsPreserveExactWireIdentifiersAndChoices() {
        let definitions = AgentMCPModelParameterSupport.definitions(agent: .cursor, modelRaw: "grok-4.6")

        XCTAssertEqual(definitions.count, 2)
        XCTAssertEqual(definitions[0].configID, "effort")
        XCTAssertEqual(definitions[0].choices.map(\.rawValue), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(definitions[1].configID, "fast")
        XCTAssertEqual(definitions[1].choices.map(\.rawValue), ["false", "true"])
    }

    func testCursorDefinitionValuesPreserveListAgentsWireShape() {
        let values = AgentMCPModelParameterSupport.definitionValues(agent: .cursor, modelRaw: "grok-4.6")

        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].objectValue?["kind"]?.stringValue, "thinking")
        XCTAssertEqual(values[0].objectValue?["config_id"]?.stringValue, "effort")
        XCTAssertEqual(values[0].objectValue?["name"]?.stringValue, "Effort")
        XCTAssertEqual(values[0].objectValue?["current_value"]?.stringValue, "high")
        XCTAssertEqual(
            values[0].objectValue?["choices"]?.arrayValue?.compactMap { $0.objectValue?["value"]?.stringValue },
            ["low", "medium", "high", "xhigh"]
        )
        XCTAssertEqual(values[1].objectValue?["kind"]?.stringValue, "speed")
        XCTAssertEqual(values[1].objectValue?["config_id"]?.stringValue, "fast")
        XCTAssertEqual(values[1].objectValue?["name"]?.stringValue, "Speed")
        XCTAssertEqual(values[1].objectValue?["current_value"]?.stringValue, "true")
        XCTAssertEqual(
            values[1].objectValue?["choices"]?.arrayValue?.compactMap { $0.objectValue?["value"]?.stringValue },
            ["false", "true"]
        )
    }

    /// OpenCode definitions no longer read the provider-global registry synchronously: the
    /// demand-scoped authority lives behind the async observation overload, so the sync surface
    /// is Cursor-only and returns empty for OpenCode without acquired metadata.
    func testOpenCodeDefinitionsEmptyWithoutDiscoveryMetadata() {
        XCTAssertTrue(
            AgentMCPModelParameterSupport.definitions(
                agent: .openCode,
                modelRaw: "ollama-cloud/kimi-k3"
            ).isEmpty
        )
        XCTAssertTrue(
            AgentMCPModelParameterSupport.definitionValues(
                agent: .openCode,
                modelRaw: "ollama-cloud/kimi-k3"
            ).isEmpty
        )
    }

    /// Advertisement reduces a one-shot demand-scoped observation: a terminal `.available`
    /// observation for the exact (workspace, model) yields definitions; `.noUsableParameters`
    /// yields none. The per-call injected provider keeps this hermetic (no live ACP process,
    /// no mutable global override).
    func testOpenCodeAsyncDefinitionsComeFromOneShotObservation() async throws {
        let availableProvider: AgentMCPModelParameterSupport.OneShotObservationProvider = { _, _, _ in
            OpenCodeACPModelParameterSnapshot(
                key: OpenCodeACPModelParameterKey(workspacePath: "/workspace-a", modelRaw: "ollama-cloud/kimi-k3"),
                state: .available(self.openCodeEffortSet()),
                updatedAt: Date()
            )
        }
        let definitions = try await AgentMCPModelParameterSupport.definitions(
            agent: .openCode,
            modelRaw: "ollama-cloud/kimi-k3",
            workspacePath: "/workspace-a",
            oneShot: availableProvider
        )
        XCTAssertEqual(definitions.map(\.configID), ["effort"])
        XCTAssertEqual(definitions.first?.choices.map(\.rawValue), ["low", "high"])

        let noUsableProvider: AgentMCPModelParameterSupport.OneShotObservationProvider = { _, _, _ in
            OpenCodeACPModelParameterSnapshot(
                key: OpenCodeACPModelParameterKey(workspacePath: "/workspace-a", modelRaw: "ollama-cloud/kimi-k3"),
                state: .noUsableParameters,
                updatedAt: Date()
            )
        }
        let emptyDefinitions = try await AgentMCPModelParameterSupport.definitions(
            agent: .openCode,
            modelRaw: "ollama-cloud/kimi-k3",
            workspacePath: "/workspace-a",
            oneShot: noUsableProvider
        )
        XCTAssertTrue(emptyDefinitions.isEmpty)
    }

    func testNonACPDefinitionsReturnEmpty() {
        XCTAssertTrue(AgentMCPModelParameterSupport.definitions(agent: .codexExec, modelRaw: "gpt-5").isEmpty)
        XCTAssertTrue(AgentMCPModelParameterSupport.definitionValues(agent: .codexExec, modelRaw: "gpt-5").isEmpty)
    }

    func testResolveRejectsUnknownConfigBeforeProducingSelections() throws {
        let requested: Value = .array([
            .object(["config_id": .string("unknown"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok-4.6"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("unknown"))
        }
    }

    func testResolveRejectsUnknownValueBeforeProducingSelections() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("maximum")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok-4.6"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("maximum"))
        }
    }

    func testResolvePreservesExactProviderWireValueAndCanonicalBase() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("HIGH")]),
            .object(["config_id": .string("fast"), "value": .string("true")])
        ])

        let selections = try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "Cursor Grok 4.6"
        )

        XCTAssertEqual(selections.map(\.configID), ["effort", "fast"])
        XCTAssertEqual(selections.map(\.valueRaw), ["high", "true"])
        XCTAssertEqual(selections.map(\.baseModelRaw), ["grok-4.6", "grok-4.6"])
    }

    func testResolveCanonicalizesLegacyComposer2BaseModel() throws {
        let selections = try AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string("fast"), "value": .string("true")])
            ]),
            agent: .cursor,
            modelRaw: "composer-2"
        )

        XCTAssertEqual(selections.map(\.baseModelRaw), ["composer-2.5"])
        XCTAssertEqual(selections.map(\.configID), ["fast"])
        XCTAssertEqual(selections.map(\.valueRaw), ["true"])
    }

    func testResolveRejectsWhitespaceBearingProviderConfigID() throws {
        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string(" effort "), "value": .string("high")])
            ]),
            agent: .cursor,
            modelRaw: "grok-4.6"
        ))
    }

    func testResolveRejectsDuplicateConfigIDs() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("low")]),
            .object(["config_id": .string("effort"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok-4.6"
        ))
    }

    func testNonACPProviderRejectsModelParameters() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .codexExec,
            modelRaw: "gpt-5"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("ACP"))
        }
    }

    /// OpenCode explicit parameters are demand-scoped: the synchronous resolver cannot satisfy
    /// them, so it rejects with the existing "metadata unavailable" argument error rather than
    /// reading a provider-global snapshot.
    func testOpenCodeSyncResolveRejectsAsDemandScoped() {
        XCTAssertThrowsError(
            try AgentMCPModelParameterSupport.resolve(
                value: .array([
                    .object(["config_id": .string("effort"), "value": .string("high")])
                ]),
                agent: .openCode,
                modelRaw: "ollama-cloud/kimi-k3"
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("metadata is unavailable"))
        }
    }

    /// An explicit OpenCode request is validated by a fresh targeted observation. A throwing
    /// injected provider produces the existing "metadata unavailable" argument error — never an
    /// empty successful selection list.
    func testOpenCodeAsyncResolveErrorsWhenMetadataUnavailable() async {
        struct ScriptedTransportError: Error {}
        let failingProvider: AgentMCPModelParameterSupport.OneShotObservationProvider = { _, _, _ in
            throw ScriptedTransportError()
        }
        do {
            _ = try await AgentMCPModelParameterSupport.resolve(
                value: .array([
                    .object(["config_id": .string("effort"), "value": .string("high")])
                ]),
                agent: .openCode,
                modelRaw: "anthropic/claude-sonnet",
                workspacePath: nil,
                oneShot: failingProvider
            )
            XCTFail("Expected an argument error when OpenCode metadata is unavailable.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("metadata is unavailable"))
        }
    }

    /// The central regression: metadata reaches the resolver and validates an explicit request
    /// *before any ACP session exists*, via the demand-scoped observation rather than a
    /// provider-global snapshot.
    func testOpenCodeAsyncResolveAcceptsInjectedObservationBeforeFirstPrompt() async throws {
        let provider: AgentMCPModelParameterSupport.OneShotObservationProvider = { _, _, _ in
            OpenCodeACPModelParameterSnapshot(
                key: OpenCodeACPModelParameterKey(workspacePath: "/workspace-a", modelRaw: "ollama-cloud/kimi-k3"),
                state: .available(self.openCodeEffortSet()),
                updatedAt: Date()
            )
        }
        let selections = try await AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string("effort"), "value": .string("high")])
            ]),
            agent: .openCode,
            modelRaw: "ollama-cloud/kimi-k3",
            workspacePath: "/workspace-a",
            oneShot: provider
        )
        XCTAssertEqual(selections.map(\.providerID), [.openCode])
        XCTAssertEqual(selections.map(\.valueRaw), ["high"])
        XCTAssertEqual(selections.map(\.baseModelRaw), ["ollama-cloud/kimi-k3"])
    }

    /// The explicit-request path preserves cancellation: when the acquisition itself throws
    /// `CancellationError`, the explicit resolver surfaces it rather than converting it into
    /// "metadata unavailable". Real in-flight cancellation belongs to the polling-service
    /// lifecycle tests; here the injected provider proves the resolver's catch does not swallow
    /// cancellation.
    func testOpenCodeExplicitResolvePreservesCancellation() async throws {
        let provider: AgentMCPModelParameterSupport.OneShotObservationProvider = { _, _, _ in
            throw CancellationError()
        }
        do {
            _ = try await AgentMCPModelParameterSupport.resolve(
                value: .array([
                    .object(["config_id": .string("effort"), "value": .string("high")])
                ]),
                agent: .openCode,
                modelRaw: "ollama-cloud/kimi-k3",
                workspacePath: "/workspace-a",
                oneShot: provider
            )
            XCTFail("Expected cancellation to propagate from the explicit OpenCode resolver.")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "Cancellation must propagate, not be converted into another error; got \(error)"
            )
        }
    }

    private func openCodeEffortSet() -> ACPModelParameterSet {
        ACPModelParameterSet(
            baseModelRaw: "ollama-cloud/kimi-k3",
            parameters: [
                .init(
                    kind: .thinking,
                    configID: "effort",
                    displayName: "Effort",
                    choices: [
                        .init(rawValue: "low", displayName: "Low"),
                        .init(rawValue: "high", displayName: "High")
                    ],
                    currentValueRaw: "low"
                )
            ]
        )
    }

    func testEffectiveSelectionsIncludeOpenCodeProvider() {
        let selections = [
            ACPModelParameterSelection(
                providerID: .openCode,
                baseModelRaw: "ollama-cloud/kimi-k3",
                kind: .thinking,
                configID: "effort",
                valueRaw: "high"
            )
        ]

        XCTAssertEqual(
            AgentMCPModelParameterSupport.effectiveSelections(
                selections,
                agentRaw: AgentProviderKind.openCode.rawValue,
                modelRaw: "ollama-cloud/kimi-k3"
            ),
            selections
        )
    }

    func testAgentRunSnapshotPublishesEffectiveModelParameterSelections() throws {
        let snapshot = AgentRunMCPSnapshot(
            sessionID: UUID(),
            tabID: UUID(),
            sessionName: "Cursor run",
            agentRaw: AgentProviderKind.cursor.rawValue,
            agentDisplayName: "Cursor",
            modelRaw: "grok",
            reasoningEffortRaw: nil,
            modelParameterSelections: [
                .init(
                    providerID: ACPProviderID.cursor.rawValue,
                    baseModelRaw: "grok",
                    kind: ACPModelParameterKind.thinking.rawValue,
                    configID: "thought_level",
                    valueRaw: "high"
                )
            ],
            status: .running,
            statusText: nil,
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )

        let parameter = try XCTUnwrap(
            snapshot.asObject()["agent"]?.objectValue?["model_parameters"]?.arrayValue?.first?.objectValue
        )
        XCTAssertEqual(parameter["provider_id"]?.stringValue, "cursor")
        XCTAssertEqual(parameter["base_model"]?.stringValue, "grok")
        XCTAssertEqual(parameter["kind"]?.stringValue, "thinking")
        XCTAssertEqual(parameter["config_id"]?.stringValue, "thought_level")
        XCTAssertEqual(parameter["value"]?.stringValue, "high")
    }

    func testEffectiveSelectionsExcludeOtherCursorBaseModels() {
        let selections = [
            ACPModelParameterSelection(
                providerID: .cursor,
                baseModelRaw: "grok-4.6",
                kind: .thinking,
                configID: "Cursor.Thought-Level",
                valueRaw: "high"
            ),
            ACPModelParameterSelection(
                providerID: .cursor,
                baseModelRaw: "composer-2",
                kind: .speed,
                configID: "model_config",
                valueRaw: "fast"
            )
        ]

        XCTAssertEqual(
            AgentMCPModelParameterSupport.effectiveSelections(
                selections,
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: "Grok 4.6"
            ),
            [
                ACPModelParameterSelection(
                    providerID: .cursor,
                    baseModelRaw: "grok-4.6",
                    kind: .thinking,
                    configID: "Cursor.Thought-Level",
                    valueRaw: "high"
                )
            ]
        )
    }
}
