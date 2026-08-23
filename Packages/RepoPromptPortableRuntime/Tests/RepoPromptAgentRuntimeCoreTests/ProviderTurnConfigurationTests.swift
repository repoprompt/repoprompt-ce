@testable import RepoPromptAgentRuntimeCore
import RepoPromptRuntimeModel
import XCTest

final class ProviderTurnConfigurationTests: XCTestCase {
    func testEveryProviderHasAvailabilityAndTurnAdapters() throws {
        let adapters = ProviderTurnConfigurationAdapters.builtIn()
        XCTAssertEqual(Set(adapters.keys), Set(ProviderSettingsID.allCases))
        XCTAssertEqual(
            Set(AgentComposerProviderMatrix.entries.map(\.providerID)),
            Set(ProviderSettingsID.allCases)
        )

        let resource = OwnedResourceReference(
            ownerID: .init(rawValue: "fixture-owner"),
            resourceID: .init(rawValue: "fixture-resource")
        )
        for providerID in ProviderSettingsID.allCases {
            let model = model(providerID)
            let optionalDescriptor = ProviderComposerStableControls.permissionDescriptor(
                providerID: providerID,
                selectedID: nil,
                mutable: true,
                lockReasonCode: nil
            )
            if providerID.isDirectAPI {
                XCTAssertNil(optionalDescriptor, providerID.rawValue)
                XCTAssertEqual(adapters[providerID]?.supportedPermissionIDs, Set<String>())
                let compiled = try ProviderTurnConfigurationAdapters.compile(.init(
                    providerID: providerID,
                    model: model,
                    settings: settings(for: providerID),
                    scopedResources: [resource]
                ))
                XCTAssertEqual(compiled.runtimeKind, .headlessAdapter)
                XCTAssertEqual(compiled.effortID, model.defaultEffortID)
                XCTAssertEqual(compiled.permissions.executionMode, .workspaceWrite)
                XCTAssertEqual(compiled.permissions.scopedResources, [resource])
                XCTAssertEqual(compiled.executionPolicy.mode, .workspaceWrite)
                XCTAssertEqual(compiled.providerSettings["provider.settingsID"], providerID.rawValue)
                XCTAssertNil(compiled.providerSettings["provider.settingsId"])
                XCTAssertNil(compiled.providerSettings["provider.permissionId"])
                continue
            }
            let descriptor = try XCTUnwrap(optionalDescriptor, providerID.rawValue)
            XCTAssertEqual(Set(descriptor.choices.map(\.id)), adapters[providerID]?.supportedPermissionIDs)
            for choice in descriptor.choices {
                let compiled = try ProviderTurnConfigurationAdapters.compile(.init(
                    providerID: providerID,
                    model: model,
                    permissionID: choice.id,
                    settings: settings(for: providerID),
                    scopedResources: [resource]
                ))
                XCTAssertEqual(compiled.runtimeKind, providerID.runtimeKind)
                XCTAssertEqual(compiled.effortID, model.defaultEffortID)
                XCTAssertEqual(compiled.permissions.executionMode, expectedMode(for: choice.id))
                XCTAssertEqual(compiled.permissions.scopedResources, [resource])
                XCTAssertEqual(compiled.executionPolicy.mode, compiled.permissions.executionMode)
                XCTAssertEqual(compiled.providerSettings["provider.permissionId"], choice.id)
            }
        }
    }

    func testStableControlDefaultsAndRequiredRepoPromptMCP() throws {
        let compiled = try ProviderTurnConfigurationAdapters.compile(.init(
            providerID: .codex,
            model: model(.codex, efforts: ["high"]),
            effortID: "high",
            permissionID: "codex.autoReview",
            settings: .codex(.init()),
            toolValues: ["codex.mcpServers": .choices([])]
        ))
        XCTAssertEqual(compiled.executionPolicy.mode, .workspaceWrite)
        XCTAssertEqual(compiled.executionPolicy.providerSettings["codex.approvalsReviewer"], "auto_review")
        XCTAssertEqual(compiled.executionPolicy.providerSettings["codex.mcpServers"], "repoprompt")
        XCTAssertEqual(compiled.normalizedToolValues["codex.mcpServers"], .choices(["repoprompt"]))
        XCTAssertEqual(Set(compiled.normalizedToolValues.keys), ProviderComposerStableControls.codex)
    }

    func testEveryClaudePromptDeliveryAndCodexSettingIsPreserved() throws {
        for providerID in [ProviderSettingsID.claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom] {
            for delivery in ["nativeSystemPrompt", "userMessageXMLWithEmptySystemPrompt", "userMessageXML"] {
                let compiled = try ProviderTurnConfigurationAdapters.compile(.init(
                    providerID: providerID,
                    model: model(providerID, efforts: ["high"]),
                    effortID: "high",
                    permissionID: "claude.autoApproveEdits",
                    settings: .claudeCompatible(.init()),
                    toolValues: [
                        "claude.bash": .boolean(false),
                        "claude.mcpStrictMode": .boolean(false),
                        "claude.toolSearch": .boolean(true),
                        "claude.promptDelivery": .choice(delivery)
                    ]
                ))
                XCTAssertEqual(compiled.effortID, "high")
                XCTAssertEqual(compiled.providerSettings["claude.bashEnabled"], "false")
                XCTAssertEqual(compiled.providerSettings["claude.strictMCPEnabled"], "false")
                XCTAssertEqual(compiled.providerSettings["claude.toolSearchEnabled"], "true")
                XCTAssertEqual(compiled.providerSettings["claude.promptDelivery"], delivery)
                XCTAssertEqual(compiled.providerSettings["provider.reasoningEffort"], "high")
            }
        }

        let codex = try ProviderTurnConfigurationAdapters.compile(.init(
            providerID: .codex,
            model: model(.codex, efforts: ["medium"], defaultEffortID: "medium", serviceTier: "flex"),
            permissionID: "codex.defaultPermission",
            settings: .codex(.init()),
            toolValues: [
                "codex.bash": .boolean(false),
                "codex.search": .boolean(false),
                "codex.goals": .boolean(false),
                "codex.reasoningSummaries": .boolean(true),
                "codex.memories": .boolean(true)
            ]
        ))
        XCTAssertEqual(codex.providerSettings["provider.reasoningEffort"], "medium")
        XCTAssertEqual(codex.providerSettings["provider.serviceTier"], "flex")
        XCTAssertEqual(codex.providerSettings["codex.bashEnabled"], "false")
        XCTAssertEqual(codex.providerSettings["codex.searchEnabled"], "false")
        XCTAssertEqual(codex.providerSettings["codex.goalsEnabled"], "false")
        XCTAssertEqual(codex.providerSettings["codex.reasoningSummariesEnabled"], "true")
        XCTAssertEqual(codex.providerSettings["codex.memoriesEnabled"], "true")
    }

    func testMalformedSettingsEffortPermissionAndControlValuesAreRejected() throws {
        XCTAssertThrowsError(try ProviderTurnConfigurationAdapters.compile(.init(
            providerID: .codex,
            model: model(.codex),
            permissionID: "codex.unknown",
            settings: .codex(.init())
        )))
        XCTAssertThrowsError(try ProviderTurnConfigurationAdapters.compile(.init(
            providerID: .codex,
            model: model(.codex, efforts: ["low"]),
            effortID: "high",
            permissionID: "codex.readOnly",
            settings: .codex(.init())
        )))
        XCTAssertThrowsError(try ProviderTurnConfigurationAdapters.compile(.init(
            providerID: .claudeCompatible,
            model: model(.claudeCompatible),
            permissionID: "claude.requireApproval",
            settings: .claudeCompatible(.init()),
            toolValues: ["claude.promptDelivery": .choice("invalid")]
        )))
        XCTAssertThrowsError(try ProviderTurnConfigurationAdapters.compile(.init(
            providerID: .openAIAPI,
            model: model(.openAIAPI),
            permissionID: "provider.workspaceWrite",
            settings: .directAPI
        )))
    }

    func testTurnRuntimeUsesInjectedSettingsClockIDAndProvider() async throws {
        let turnID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = RecordingProvider()
        let runtime = AgentTurnRuntime(
            settingsProvider: FixedSettingsProvider(snapshot: .init(
                permissionID: .init(rawValue: "codex.readOnly"),
                settings: .codex(.init(searchEnabled: false))
            )),
            provider: provider,
            clock: FixedClock(instant: instant),
            idGenerator: FixedIDGenerator(id: turnID)
        )
        let owner = RuntimeOwnerID(rawValue: "owner")
        let resource = OwnedResourceReference(
            ownerID: owner,
            resourceID: .init(rawValue: "workflow-resource")
        )
        let prepared = try await runtime.prepareAndExecute(.init(
            ownerID: owner,
            model: model(.codex),
            workflow: WorkflowDefinition(resources: [resource])
        ))

        XCTAssertEqual(prepared.turnID, turnID)
        XCTAssertEqual(prepared.preparedAt, instant)
        XCTAssertEqual(prepared.ownerID, owner)
        XCTAssertEqual(prepared.configuration.executionPolicy.mode, .readOnly)
        XCTAssertEqual(prepared.configuration.permissions.scopedResources, [resource])
        XCTAssertEqual(prepared.configuration.executionPolicy.providerSettings["codex.searchEnabled"], "false")
        let executedTurnID = await provider.executedTurnID()
        XCTAssertEqual(executedTurnID, turnID)
    }

    private func expectedMode(for permissionID: String) -> ProviderExecutionMode {
        if permissionID.hasSuffix("readOnly") { return .readOnly }
        if permissionID.hasSuffix("fullAccess") { return .fullAccess }
        return .workspaceWrite
    }

    private func settings(for providerID: ProviderSettingsID) -> ProviderTurnSettings {
        switch providerID {
        case .codex: .codex(.init())
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom: .claudeCompatible(.init())
        case .openCodeACP, .cursorACP, .grokBuildACP: .acp
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama: .directAPI
        }
    }

    private func model(
        _ providerID: ProviderSettingsID,
        efforts: [String] = [],
        defaultEffortID: String? = nil,
        serviceTier: String? = nil
    ) -> ProviderModelDescriptor {
        ProviderModelDescriptor(
            providerID: providerID,
            modelID: "test-model",
            providerRawValue: "test-model",
            displayName: "Test Model",
            supportedEffortIDs: efforts,
            defaultEffortID: defaultEffortID,
            serviceTier: serviceTier
        )
    }
}

private struct FixedSettingsProvider: ProviderTurnSettingsProviding {
    let snapshot: ProviderTurnSettingsSnapshot

    func settings(for _: ProviderSettingsID) async throws -> ProviderTurnSettingsSnapshot {
        snapshot
    }
}

private actor RecordingProvider: ProviderTurnExecuting {
    private var turnID: UUID?

    func execute(_ turn: PreparedProviderTurn) async throws {
        turnID = turn.turnID
    }

    func executedTurnID() -> UUID? {
        turnID
    }
}

private struct FixedClock: RuntimeClock {
    let instant: Date

    func now() -> Date {
        instant
    }

    func sleep(for _: Duration) async throws {}
}

private struct FixedIDGenerator: RuntimeIDGenerator {
    let id: UUID
    func next() -> UUID {
        id
    }
}
