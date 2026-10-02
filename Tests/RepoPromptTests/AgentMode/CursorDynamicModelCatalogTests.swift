import MCP
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Contract for Cursor's discovery-backed catalogue projection.
///
/// The compiled model inventory and its live-vs-release reconciliation are gone: membership and
/// parameter metadata now come from the resolved ACP discovery snapshot (live → persisted → Auto),
/// while selection identity stays pure. These cases pin the behaviors that replaced them rather
/// than re-pinning a per-release model table.
final class CursorDynamicModelCatalogTests: XCTestCase {
    private let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true)

    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        super.tearDown()
    }

    func testProjectionOffersNewlyAdvertisedModelsAndTheirLiveParameterMetadata() throws {
        seedCursorCatalog(
            options: [
                discoveredOption("default", "Auto", isDefault: true),
                discoveredOption("grok-4.7", "Cursor Grok 4.7"),
                discoveredOption("future-cursor-model", "Future Cursor Model")
            ],
            currentModelRaw: "grok-4.7",
            parameterSets: [
                ACPModelParameterSet(
                    baseModelRaw: "grok-4.7",
                    parameters: [
                        effortDefinition(
                            configID: "reasoning_effort",
                            values: ["low", "medium", "high", "xhigh"],
                            currentValueRaw: "high"
                        ),
                        speedDefinition(currentValueRaw: "true")
                    ]
                )
            ]
        )

        // A model CE never shipped a table row for is offered and accepted, and Auto stays first.
        XCTAssertEqual(
            CursorAIModelCatalog.options.map(\.rawValue),
            ["auto", "future-cursor-model", "grok-4.7"]
        )
        XCTAssertEqual(
            AgentModelCatalog.options(for: .cursor, availability: availability).map(\.rawValue),
            ["auto", "future-cursor-model", "grok-4.7"]
        )
        XCTAssertEqual(
            CursorAIModelCatalog.option(matching: "future-cursor-model")?.displayName,
            "Future Cursor Model"
        )
        XCTAssertTrue(AgentModelCatalog.isValid(
            rawModel: "future-cursor-model",
            for: .cursor,
            availability: availability
        ))

        // Parameter metadata is the advertised selector, not a reconstructed one: Grok 4.7's
        // `reasoning_effort` selector and its live choices/current values reach the resolver.
        let grok = try XCTUnwrap(ACPModelParameterResolver.parameterSet(
            providerID: .cursor,
            selectedModelRaw: "Cursor Grok 4.7"
        ))
        XCTAssertEqual(grok.baseModelRaw, "grok-4.7")
        XCTAssertEqual(grok.parameters.map(\.configID), ["reasoning_effort", "fast"])
        XCTAssertEqual(
            grok.definition(kind: .thinking)?.choices.map(\.rawValue),
            ["low", "medium", "high", "xhigh"]
        )
        XCTAssertEqual(grok.definition(kind: .thinking)?.currentValueRaw, "high")
        XCTAssertEqual(grok.definition(kind: .speed)?.currentValueRaw, "true")

        // A model that advertises no selectors exposes no controls.
        XCTAssertNil(ACPModelParameterResolver.parameterSet(
            providerID: .cursor,
            selectedModelRaw: "future-cursor-model"
        ))
    }

    @MainActor
    func testAutoStaysPinnedFirstDefaultAndParameterFreeEvenWhenCursorAdvertisesIt() async throws {
        // Before any discovery or cache warm the projection is Auto-only.
        XCTAssertEqual(CursorAIModelCatalog.options.map(\.rawValue), ["auto"])
        XCTAssertTrue(CursorAIModelCatalog.contains(modelRaw: "auto"))
        XCTAssertNil(CursorAIModelCatalog.parameterSet(for: "auto"))

        // With Cursor as the only recommendation provider, every role must remain visible even
        // when Composer is absent. Auto is a floor, not a reason to discover or rewrite a pin.
        let cursorOnly = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.cursor)
        let settings = GlobalSettingsStore.shared
        let previousProfile = settings.globalAgentModelsProfile()
        defer { settings.setGlobalAgentModelsProfile(previousProfile, contextBuilderWriteIntent: .preserveExistingOwnership) }
        settings.setAgentModelsMCPAgentRoleOverrides(nil, scope: .global)
        let roles: [AgentModelCatalog.TaskLabelKind] = [.engineer, .pair, .design]
        for role in roles {
            MCPAgentRoleDefaultsService.setSelection(
                .init(agent: .cursor, modelRaw: AgentModel.cursorAuto.rawValue),
                for: role,
                scope: .global
            )
        }
        let savedOverrides = settings.mcpAgentRoleOverrides(scope: .global)
        var refreshCount = 0
        for role in roles {
            XCTAssertEqual(
                savedOverrides?[role.rawValue],
                AgentModelSelectionID(agentRaw: AgentProviderKind.cursor.rawValue, modelRaw: AgentModel.cursorAuto.rawValue).rawValue
            )
            let recommended = try XCTUnwrap(AgentModelCatalog.resolveTaskLabelKind(role, availability: cursorOnly))
            XCTAssertEqual(recommended.agent, .cursor)
            XCTAssertEqual(recommended.modelRaw, AgentModel.cursorAuto.rawValue)
            let selected = try await AgentMCPSelectionResolver.resolve(
                modelID: role.rawValue,
                availability: cursorOnly,
                cursorCatalogRefresh: { _ in refreshCount += 1 }
            )
            XCTAssertEqual(selected.modelRaw, AgentModel.cursorAuto.rawValue)
            XCTAssertEqual(settings.mcpAgentRoleOverrides(scope: .global), savedOverrides)
        }
        XCTAssertEqual(refreshCount, 0)

        let cursorAndGrok = cursorOnly.assumingAvailable(.grokBuild)
        for role: AgentModelCatalog.TaskLabelKind in [.engineer, .pair, .design] {
            XCTAssertEqual(AgentModelCatalog.resolveTaskLabelKind(role, availability: cursorAndGrok)?.agent, .grokBuild)
        }

        seedCursorCatalog(
            options: [
                discoveredOption("default", "Auto", isDefault: true),
                discoveredOption("grok-4.7", "Cursor Grok 4.7")
            ],
            currentModelRaw: "default",
            parameterSets: [
                ACPModelParameterSet(
                    baseModelRaw: "default",
                    parameters: [speedDefinition(currentValueRaw: "true")]
                )
            ]
        )

        let options = CursorAIModelCatalog.options
        // The provider's own Auto entry is projected onto CE's `auto` identity, never duplicated,
        // and never becomes a second default.
        XCTAssertEqual(options.map(\.rawValue), ["auto", "grok-4.7"])
        XCTAssertEqual(options.first?.isDefault, true)
        XCTAssertEqual(options.count(where: \.isDefault), 1)
        XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .cursor, availability: availability), "auto")

        // Auto stays parameter-free even though the wire default advertises a selector.
        XCTAssertNil(CursorAIModelCatalog.parameterSet(for: "auto"))
        XCTAssertNil(CursorAIModelCatalog.parameterSet(for: "default"))
        XCTAssertTrue(ACPModelParameterResolver.resolve(
            providerID: .cursor,
            selectedModelRaw: "auto",
            persistedSelections: []
        ).isEmpty)

        seedCursorCatalog(
            options: [discoveredOption(AgentModel.cursorComposer2.rawValue, "Composer 2")],
            currentModelRaw: AgentModel.cursorComposer2.rawValue
        )
        for role: AgentModelCatalog.TaskLabelKind in [.engineer, .pair, .design] {
            XCTAssertEqual(
                AgentModelCatalog.resolveTaskLabelKind(role, availability: cursorOnly)?.modelRaw,
                AgentModel.cursorComposer2.rawValue
            )
        }
    }

    @MainActor
    func testSavedCursorSelectionSurvivesColdStartAndProviderRemovalButFailsClosedAtAdmission() {
        // Cold: the persisted catalogue has not warmed yet, so membership is unknown — the saved
        // model must not be rewritten to Auto.
        let cold = AgentModelCatalog.normalizePersistedSelection(
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "grok-4.7",
            availability: availability
        )
        XCTAssertEqual(cold.agent, .cursor)
        XCTAssertEqual(cold.modelRaw, "grok-4.7")
        XCTAssertFalse(AgentModelCatalog.isValid(
            rawModel: "grok-4.7",
            for: .cursor,
            availability: availability
        ))

        // Warm with a catalogue that no longer advertises it: still saved, still not offered.
        seedCursorCatalog(
            options: [
                discoveredOption("default", "Auto", isDefault: true),
                discoveredOption("grok-4.8", "Cursor Grok 4.8")
            ],
            currentModelRaw: "grok-4.8"
        )
        let removed = AgentModelCatalog.normalizePersistedSelection(
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "grok-4.7",
            availability: availability
        )
        XCTAssertEqual(removed.modelRaw, "grok-4.7")
        XCTAssertFalse(CursorAIModelCatalog.contains(modelRaw: "grok-4.7"))
        XCTAssertFalse(
            AgentModelCatalog.options(for: .cursor, availability: availability)
                .contains { $0.rawValue == "grok-4.7" }
        )

        // Executing it is refused with actionable recovery instead of silently running Auto.
        XCTAssertThrowsError(try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
            agentKind: .cursor,
            modelString: "grok-4.7"
        )) { error in
            guard case let AIProviderError.invalidConfiguration(detail) = error else {
                return XCTFail("Expected an invalid Cursor model configuration, got \(error)")
            }
            XCTAssertTrue(detail.contains("grok-4.7"), detail)
            XCTAssertTrue(detail.contains("last known"), detail)
            XCTAssertTrue(detail.contains("Test Connection"), detail)
        }
        XCTAssertEqual(
            try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
                agentKind: .cursor,
                modelString: "grok-4.8"
            ),
            "grok-4.8"
        )
    }

    func testPersistedCatalogRestoresAfterMemoryLossAndSurvivesAFailedRefresh() async {
        seedCursorCatalog(
            options: [
                discoveredOption("default", "Auto", isDefault: true),
                discoveredOption("composer-2.5", "Composer 2.5"),
                discoveredOption("grok-4.7", "Cursor Grok 4.7")
            ],
            currentModelRaw: "grok-4.7"
        )

        // Relaunch: memory is empty until the persisted store warms.
        AgentACPModelRegistry.shared.test_clearMemoryPreservingStore(providerID: .cursor)
        XCTAssertEqual(CursorAIModelCatalog.options.map(\.rawValue), ["auto"])

        await AgentACPModelRegistry.shared.test_warmStandardStore()
        XCTAssertEqual(
            CursorAIModelCatalog.options.map(\.rawValue),
            ["auto", "composer-2.5", "grok-4.7"]
        )
        XCTAssertTrue(AgentModelCatalog.isValid(
            rawModel: "composer-2.5",
            for: .cursor,
            availability: availability
        ))

        // A failed or empty refresh keeps the last-known catalogue rather than emptying it.
        XCTAssertFalse(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(options: [], currentModelRaw: nil),
            for: .cursor
        ))
        XCTAssertEqual(
            CursorAIModelCatalog.options.map(\.rawValue),
            ["auto", "composer-2.5", "grok-4.7"]
        )
    }

    func testLegacyCursorIdentitiesAreStableAcrossWarmStatesAndResolveAgainstDiscovery() {
        let legacyIdentities: [(spelling: String, identity: String)] = [
            ("composer-2", "composer-2.5"),
            ("Composer 2.5", "composer-2.5"),
            ("cursor-grok-4.5", "grok-4.5"),
            ("Cursor Grok 4.6", "grok-4.6"),
            ("cursor-grok-4.7", "grok-4.7"),
            ("Cursor Grok 4.7", "grok-4.7"),
            ("Grok 4.6", "grok-4.6"),
            // Display spellings whose normalized form differs from the advertised raw ID; without
            // these a pin saved under the display name would split from the raw-ID pin.
            ("Claude Opus 4.5", "claude-opus-4-5"),
            ("Claude Opus 4.6", "claude-opus-4-6"),
            ("Claude Opus 4.8", "claude-opus-4-8"),
            ("Claude Sonnet 4.6", "claude-sonnet-4-6"),
            ("Claude Haiku 4.5", "claude-haiku-4-5"),
            ("Codex 5.3", "gpt-5.3-codex"),
            ("default", "auto"),
            ("Auto", "auto"),
            ("future-cursor-model", "future-cursor-model")
        ]

        // Identity is pure: identical with no snapshot at all...
        for entry in legacyIdentities {
            XCTAssertEqual(
                CursorAIModelCatalog.canonicalIdentity(entry.spelling),
                entry.identity,
                entry.spelling
            )
        }

        seedCursorCatalog(
            options: [
                discoveredOption("default", "Auto", isDefault: true),
                discoveredOption("claude-opus-4-5", "Claude Opus 4.5"),
                discoveredOption("composer-2.5", "Composer 2.5"),
                discoveredOption("future-cursor-model", "Future Cursor Model"),
                discoveredOption("grok-4.6", "Cursor Grok 4.6"),
                discoveredOption("grok-4.7", "Cursor Grok 4.7")
            ],
            currentModelRaw: "grok-4.7"
        )

        // ...and unchanged once discovery has warmed, so saved parameter pins never split.
        for entry in legacyIdentities {
            XCTAssertEqual(
                CursorAIModelCatalog.canonicalIdentity(entry.spelling),
                entry.identity,
                entry.spelling
            )
        }

        XCTAssertEqual(CursorAIModelCatalog.option(matching: "composer-2")?.rawValue, "composer-2.5")
        XCTAssertEqual(CursorAIModelCatalog.option(matching: "Cursor Grok 4.6")?.rawValue, "grok-4.6")
        XCTAssertEqual(CursorAIModelCatalog.option(matching: "Claude Opus 4.5")?.rawValue, "claude-opus-4-5")
        // Membership is advertised raw IDs plus the closed legacy spellings. A new model's display
        // name is admitted only when it normalizes exactly onto its advertised raw, as here — then
        // identity and raw coincide and no parameter pin can split. A display spelling that
        // diverges from the raw is rejected instead; see
        // `testFutureModelIsAdmittedByRawIDOnlySoItsExplicitPinSurvivesDispatch`.
        XCTAssertEqual(
            CursorAIModelCatalog.option(matching: "Future Cursor Model")?.rawValue,
            "future-cursor-model"
        )
        XCTAssertEqual(
            CursorAIModelCatalog.canonicalIdentity("Future Cursor Model"),
            "future-cursor-model"
        )
        XCTAssertTrue(AgentModelCatalog.isValid(
            rawModel: "Cursor Grok 4.6",
            for: .cursor,
            availability: availability
        ))

        // The legacy alias canonicalizes on restore without duplicating a picker entry.
        XCTAssertEqual(
            AgentModelCatalog.normalizePersistedSelection(
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: "composer-2",
                availability: availability
            ).modelRaw,
            "composer-2.5"
        )
        let options = AgentModelCatalog.options(for: .cursor, availability: availability)
        XCTAssertEqual(options.count(where: { $0.rawValue == "composer-2.5" }), 1)
        XCTAssertFalse(options.contains { $0.rawValue == "composer-2" })
    }

    @MainActor
    func testFutureModelIsAdmittedByRawIDOnlySoItsExplicitPinSurvivesDispatch() async throws {
        // A model CE never shipped, whose display name carries a dot where the wire ID carries a
        // dash — the shape that historically needed alias rows.
        seedCursorCatalog(
            options: [
                discoveredOption("default", "Auto", isDefault: true),
                discoveredOption("claude-opus-9-1", "Claude Opus 9.1"),
                discoveredOption("grok-4.6", "Cursor Grok 4.6")
            ],
            currentModelRaw: "claude-opus-9-1",
            parameterSets: [
                ACPModelParameterSet(
                    baseModelRaw: "claude-opus-9-1",
                    parameters: [
                        effortDefinition(
                            configID: "reasoning_effort",
                            values: ["low", "medium", "high"],
                            currentValueRaw: "medium"
                        )
                    ]
                )
            ]
        )

        // The advertised raw ID is admitted, and a selection saved from it keeps that identity.
        XCTAssertTrue(CursorAIModelCatalog.contains(modelRaw: "claude-opus-9-1"))
        let restored = AgentModelCatalog.normalizePersistedSelection(
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "claude-opus-9-1",
            availability: availability
        )
        XCTAssertEqual(restored.modelRaw, "claude-opus-9-1")

        // A pin saved from the advertised parameter set still reaches dispatch for that selection.
        let parameterSet = try XCTUnwrap(ACPModelParameterResolver.parameterSet(
            providerID: .cursor,
            selectedModelRaw: restored.modelRaw
        ))
        XCTAssertEqual(parameterSet.baseModelRaw, "claude-opus-9-1")
        let pin = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: parameterSet.baseModelRaw,
            kind: .thinking,
            configID: "reasoning_effort",
            valueRaw: "high"
        )
        XCTAssertEqual(
            ACPModelParameterResolver.effectiveSelections(
                providerID: .cursor,
                selectedModelRaw: restored.modelRaw,
                persistedSelections: [pin]
            ),
            [pin]
        )

        // The new model's display spelling is not admitted anywhere — admitting it would store a
        // dotted identity whose pins (keyed on the advertised raw) drop out at dispatch.
        XCTAssertFalse(CursorAIModelCatalog.contains(modelRaw: "Claude Opus 9.1"))
        XCTAssertFalse(AgentModelCatalog.isValid(
            rawModel: "Claude Opus 9.1",
            for: .cursor,
            availability: availability
        ))
        XCTAssertNil(ACPModelParameterResolver.parameterSet(
            providerID: .cursor,
            selectedModelRaw: "Claude Opus 9.1"
        ))
        do {
            _ = try await AgentMCPSelectionResolver.resolve(
                modelID: "cursor:Claude Opus 9.1",
                availability: availability
            )
            XCTFail("Expected an unadvertised display spelling to be rejected")
        } catch {
            // Only advertised raw IDs and closed legacy aliases are admitted.
        }

        // Legacy display spellings CE already accepted keep working through the closed alias map.
        XCTAssertTrue(CursorAIModelCatalog.contains(modelRaw: "Cursor Grok 4.6"))
        let legacy = try await AgentMCPSelectionResolver.resolve(
            modelID: "cursor:Cursor Grok 4.6",
            availability: availability
        )
        XCTAssertEqual(legacy.modelRaw, "Cursor Grok 4.6")
    }

    func testSavedParameterPinIdentityIsIdenticalAcrossSpellingsAndWarmStates() {
        let equivalentSpellings: [[String]] = [
            ["grok-4.6", "Cursor Grok 4.6", "cursor-grok-4.6", "Grok 4.6"],
            ["composer-2.5", "composer-2", "Composer 2.5"],
            ["claude-opus-4-6", "Claude Opus 4.6"],
            ["gpt-5.3-codex", "Codex 5.3"],
            ["auto", "Auto", "default"]
        ]

        func assertPinIdentitiesAgree(_ context: String) {
            for spellings in equivalentSpellings {
                let identities = spellings.map {
                    ACPModelParameterIdentity(providerID: .cursor, baseModelRaw: $0, kind: .thinking)
                }
                XCTAssertEqual(Set(identities).count, 1, "\(context): \(spellings)")
            }
            // Distinct models must not collapse into one pin identity.
            XCTAssertNotEqual(
                ACPModelParameterIdentity(providerID: .cursor, baseModelRaw: "grok-4.6", kind: .thinking),
                ACPModelParameterIdentity(providerID: .cursor, baseModelRaw: "grok-4.7", kind: .thinking)
            )
        }

        assertPinIdentitiesAgree("cold")
        seedCursorCatalog(
            options: [
                discoveredOption("default", "Auto", isDefault: true),
                discoveredOption("grok-4.6", "Cursor Grok 4.6")
            ],
            currentModelRaw: "grok-4.6"
        )
        assertPinIdentitiesAgree("warm")
    }

    @MainActor
    func testMCPCompoundAdmissionFollowsTheDiscoveredCursorCatalog() async throws {
        var unsuccessfulRefreshes = 0
        let noModels: AgentMCPSelectionResolver.CursorCatalogRefresh = { _ in unsuccessfulRefreshes += 1 }
        do {
            _ = try await AgentMCPSelectionResolver.resolve(
                modelID: "cursor:grok-4.7", availability: availability,
                cursorCatalogRefresh: noModels
            )
            XCTFail("A refresh without published models must not admit a concrete model")
        } catch {
            XCTAssertTrue(String(describing: error).contains("not valid"), "\(error)")
        }
        XCTAssertEqual(unsuccessfulRefreshes, 1)
        XCTAssertNil(AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor))

        let coldAuto = try await AgentMCPSelectionResolver.resolve(
            modelID: "cursor:auto", availability: availability,
            cursorCatalogRefresh: noModels
        )
        XCTAssertEqual(coldAuto.modelRaw, "auto")
        XCTAssertEqual(unsuccessfulRefreshes, 1)

        var refreshedPaths: [String?] = []
        let coldResolved = try await AgentMCPSelectionResolver.resolve(
            modelID: "cursor:future-cursor-model", availability: availability,
            workspacePath: "/tmp/cursor-model-discovery-test",
            cursorCatalogRefresh: { path in
                refreshedPaths.append(path)
                self.seedCursorCatalog(
                    options: [
                        self.discoveredOption("default", "Auto", isDefault: true),
                        self.discoveredOption("future-cursor-model", "Future Cursor Model")
                    ],
                    currentModelRaw: "future-cursor-model"
                )
            }
        )
        XCTAssertEqual(refreshedPaths, ["/tmp/cursor-model-discovery-test"])
        XCTAssertEqual(coldResolved.modelRaw, "future-cursor-model")

        let resolved = try await AgentMCPSelectionResolver.resolve(
            modelID: "cursor:future-cursor-model",
            availability: availability
        )
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.cursor.rawValue)
        XCTAssertEqual(resolved.modelRaw, "future-cursor-model")

        let auto = try await AgentMCPSelectionResolver.resolve(
            modelID: "cursor:auto",
            availability: availability
        )
        XCTAssertEqual(auto.modelRaw, "auto")

        do {
            _ = try await AgentMCPSelectionResolver.resolve(
                modelID: "cursor:grok-4.7", availability: availability,
                cursorCatalogRefresh: noModels
            )
            XCTFail("Expected an unadvertised Cursor model to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("not valid"), "\(error)")
        }
        XCTAssertEqual(unsuccessfulRefreshes, 1, "A settled catalogue must not trigger discovery")
    }

    @MainActor
    func testCursorRoleOverrideAndItsPinSurviveUnknownOrRemovedCatalogue() throws {
        let pin = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.7",
            kind: .thinking,
            configID: "reasoning_effort",
            valueRaw: "xhigh"
        )
        let store = RoleDefaultsStoreDouble(
            overrides: ["engineer": "cursor:grok-4.7"],
            roleModelParameters: ["engineer": [pin]]
        )

        func resolvedEngineerRole(
            _ availability: AgentModelCatalog.AvailabilityContext,
            store: RoleDefaultsStoreDouble
        ) throws -> MCPAgentRoleDefaultsService.RoleDefaultResolution {
            try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
                for: .engineer,
                availability: availability,
                settingsStore: store
            ))
        }

        let cursorOnly = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.cursor)
        let roles: [AgentModelCatalog.TaskLabelKind] = [.engineer, .pair, .design]
        let cursorOnlyStore = RoleDefaultsStoreDouble(
            overrides: Dictionary(uniqueKeysWithValues: roles.map { ($0.rawValue, "cursor:grok-4.7") }),
            roleModelParameters: Dictionary(uniqueKeysWithValues: roles.map { ($0.rawValue, [pin]) })
        )
        for role in roles {
            let resolved = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
                for: role, availability: cursorOnly, settingsStore: cursorOnlyStore
            ))
            XCTAssertEqual(resolved.recommended.modelRaw, AgentModel.cursorAuto.rawValue)
            XCTAssertEqual(resolved.effective.modelRaw, "grok-4.7")
            XCTAssertEqual(resolved.modelParameters, [pin])
        }

        // Cold: the persisted catalogue has not warmed, so membership is unknown. The stored role
        // model and its pin must survive rather than being swapped for the recommendation.
        let cold = try resolvedEngineerRole(availability, store: store)
        XCTAssertEqual(cold.effective.agent, .cursor)
        XCTAssertEqual(cold.effective.modelRaw, "grok-4.7")
        XCTAssertFalse(cold.overrideUnavailable)
        XCTAssertEqual(cold.modelParameters, [pin])

        // A warm catalogue that no longer advertises it is still not a reason to rewrite the
        // user's stored role choice; admission and the runner fence reject it instead.
        seedCursorCatalog(
            options: [
                discoveredOption("default", "Auto", isDefault: true),
                discoveredOption("grok-4.8", "Cursor Grok 4.8")
            ],
            currentModelRaw: "grok-4.8"
        )
        let removed = try resolvedEngineerRole(availability, store: store)
        XCTAssertEqual(removed.effective.modelRaw, "grok-4.7")
        XCTAssertFalse(removed.overrideUnavailable)
        XCTAssertEqual(removed.modelParameters, [pin])
        for role in roles {
            let resolved = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
                for: role, availability: cursorOnly, settingsStore: cursorOnlyStore
            ))
            XCTAssertEqual(resolved.recommended.modelRaw, AgentModel.cursorAuto.rawValue)
            XCTAssertEqual(resolved.effective.modelRaw, "grok-4.7")
            XCTAssertEqual(resolved.modelParameters, [pin])
        }

        seedCursorCatalog(
            options: [discoveredOption("grok-4.7", "Cursor Grok 4.7")],
            currentModelRaw: "grok-4.7"
        )
        for role in roles {
            let advertised = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
                for: role, availability: cursorOnly, settingsStore: cursorOnlyStore
            ))
            XCTAssertEqual(advertised.effective.modelRaw, "grok-4.7")
            XCTAssertEqual(advertised.modelParameters, [pin])
        }

        // Provider-unavailable policy is unchanged: a disconnected Cursor still falls back to the
        // recommendation, and the fallback still yields no pin.
        let disconnected = try resolvedEngineerRole(
            AgentModelCatalog.AvailabilityContext(cursorAvailable: false),
            store: store
        )
        XCTAssertNotEqual(disconnected.effective.agent, .cursor)
        XCTAssertTrue(disconnected.overrideUnavailable)
        XCTAssertTrue(disconnected.modelParameters.isEmpty)

        // Non-Cursor providers keep the existing unknown-model fallback.
        let openCode = try resolvedEngineerRole(
            availability,
            store: RoleDefaultsStoreDouble(
                overrides: ["engineer": "openCode:not-a-real-opencode-model"],
                roleModelParameters: [:]
            )
        )
        XCTAssertTrue(openCode.overrideUnavailable)
        XCTAssertNotEqual(openCode.effective.modelRaw, "not-a-real-opencode-model")
    }

    @MainActor
    func testCursorRoleLaunchRejectsUnadvertisedModelButAcceptsTheAdvertisedOne() async throws {
        let settings = GlobalSettingsStore.shared
        let previousProfile = settings.globalAgentModelsProfile()
        defer { settings.setGlobalAgentModelsProfile(previousProfile, contextBuilderWriteIntent: .preserveExistingOwnership) }
        let cursorOnly = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.cursor)
        let pin = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.7",
            kind: .thinking,
            configID: "reasoning_effort",
            valueRaw: "xhigh"
        )
        MCPAgentRoleDefaultsService.setSelection(
            .init(agent: .cursor, modelRaw: "grok-4.7"),
            for: .engineer,
            scope: .global
        )
        settings.setAgentModelsRoleModelParameter(
            [pin],
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: AgentProviderKind.cursor.rawValue, modelRaw: "grok-4.7"),
            scope: .global
        )
        let savedOverrides = settings.mcpAgentRoleOverrides(scope: .global)
        let savedPins = settings.mcpAgentRoleModelParameters(scope: .global)
        XCTAssertEqual(savedPins?["engineer"], [pin])

        // A first cold attempt may finish before discovery publishes any model. It must fail
        // without changing the stored model or pin; a later discovery can make the same choice
        // admissible on retry. The injected refresh never launches Cursor.
        var refreshCount = 0
        do {
            _ = try await AgentMCPSelectionResolver.resolve(
                modelID: "engineer", availability: cursorOnly,
                cursorCatalogRefresh: { _ in refreshCount += 1 }
            )
            XCTFail("A missing catalogue must not substitute Cursor Auto")
        } catch let error as MCPError {
            guard case let .invalidParams(message) = error, let detail = message else {
                return XCTFail("Expected a model-specific invalid-params error: \(error)")
            }
            XCTAssertTrue(detail.contains("engineer") && detail.contains("grok-4.7"), detail)
        }
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(settings.mcpAgentRoleOverrides(scope: .global), savedOverrides)
        XCTAssertEqual(settings.mcpAgentRoleModelParameters(scope: .global), savedPins)

        // The role-specific admission guard must recheck membership after its awaited refresh,
        // not retain the cold miss. This is distinct from compound-ID admission.
        let discoveredDuringAdmission = try await AgentMCPSelectionResolver.resolve(
            modelID: "engineer", availability: cursorOnly,
            cursorCatalogRefresh: { _ in
                refreshCount += 1
                self.seedCursorCatalog(
                    options: [self.discoveredOption("grok-4.7", "Cursor Grok 4.7")],
                    currentModelRaw: "grok-4.7"
                )
            }
        )
        XCTAssertEqual(refreshCount, 2)
        XCTAssertEqual(discoveredDuringAdmission.modelRaw, "grok-4.7")
        XCTAssertEqual(discoveredDuringAdmission.modelParameterSelections, [pin])
        XCTAssertEqual(settings.mcpAgentRoleOverrides(scope: .global), savedOverrides)
        XCTAssertEqual(settings.mcpAgentRoleModelParameters(scope: .global), savedPins)

        // Catalogue no longer advertises the stored role model: admission must error out before a
        // session is created or a run starts, never substitute another model silently.
        seedCursorCatalog(
            options: [
                discoveredOption("default", "Auto", isDefault: true),
                discoveredOption("grok-4.8", "Cursor Grok 4.8")
            ],
            currentModelRaw: "grok-4.8"
        )
        do {
            _ = try await AgentMCPSelectionResolver.resolve(
                modelID: "engineer", availability: cursorOnly,
                cursorCatalogRefresh: { _ in refreshCount += 1 }
            )
            XCTFail("Expected an unadvertised saved Cursor role model to be rejected")
        } catch let error as MCPError {
            guard case let .invalidParams(message) = error, let detail = message else {
                return XCTFail("Expected a model-specific invalid-params error: \(error)")
            }
            XCTAssertTrue(detail.contains("engineer") && detail.contains("grok-4.7"), detail)
            XCTAssertTrue(detail.contains("last known model catalog"), detail)
        }
        XCTAssertEqual(refreshCount, 2, "A settled catalogue must not start another discovery")
        XCTAssertEqual(settings.mcpAgentRoleOverrides(scope: .global), savedOverrides)
        XCTAssertEqual(settings.mcpAgentRoleModelParameters(scope: .global), savedPins)

        // Once the catalogue advertises it again, the stored role model launches unchanged.
        seedCursorCatalog(
            options: [
                discoveredOption("default", "Auto", isDefault: true),
                discoveredOption("grok-4.7", "Cursor Grok 4.7")
            ],
            currentModelRaw: "grok-4.7"
        )
        let advertised = try await AgentMCPSelectionResolver.resolve(
            modelID: "engineer",
            availability: cursorOnly
        )
        XCTAssertEqual(advertised.agentRaw, AgentProviderKind.cursor.rawValue)
        XCTAssertEqual(advertised.modelRaw, "grok-4.7")
        XCTAssertEqual(advertised.modelParameterSelections, [pin])
        let defaulted = try await AgentMCPSelectionResolver.resolve(
            modelID: nil, defaultTaskLabel: .engineer, availability: cursorOnly
        )
        XCTAssertEqual(defaulted.modelRaw, "grok-4.7")
        XCTAssertEqual(defaulted.modelParameterSelections, [pin])
        XCTAssertEqual(settings.mcpAgentRoleOverrides(scope: .global), savedOverrides)
        XCTAssertEqual(settings.mcpAgentRoleModelParameters(scope: .global), savedPins)

        // Cursor Auto carries no advertised identity, so it is exempt even with no catalogue.
        MCPAgentRoleDefaultsService.setSelection(
            .init(agent: .cursor, modelRaw: AgentModel.cursorAuto.rawValue),
            for: .engineer,
            scope: .global
        )
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        let auto = try await AgentMCPSelectionResolver.resolve(modelID: "engineer", availability: cursorOnly)
        XCTAssertEqual(auto.modelRaw, AgentModel.cursorAuto.rawValue)
    }

    func testNonCursorDiscoveredProviderKeepsInvalidToDefaultNormalization() {
        let grokAvailability = AgentModelCatalog.AvailabilityContext(grokBuildAvailable: true)

        let normalized = AgentModelCatalog.normalizePersistedSelection(
            agentRaw: AgentProviderKind.grokBuild.rawValue,
            modelRaw: "not-a-grok-build-model",
            availability: grokAvailability
        )

        XCTAssertEqual(normalized.agent, .grokBuild)
        XCTAssertEqual(
            normalized.modelRaw,
            AgentModelCatalog.defaultModelRaw(for: .grokBuild, availability: grokAvailability)
        )
        XCTAssertNotEqual(normalized.modelRaw, "not-a-grok-build-model")
    }

    // MARK: - Helpers

    /// Role overrides and their pins without touching global settings.
    private final class RoleDefaultsStoreDouble: MCPAgentRoleDefaultsStoring {
        private var overrides: [String: String]?
        private var roleModelParameters: [String: [ACPModelParameterSelection]]?

        init(overrides: [String: String]?, roleModelParameters: [String: [ACPModelParameterSelection]]?) {
            self.overrides = overrides
            self.roleModelParameters = roleModelParameters
        }

        func mcpAgentRoleOverrides(workspaceID _: UUID?) -> [String: String]? {
            overrides
        }

        func mcpAgentRoleOverrides(scope _: AgentModelsEditingScope) -> [String: String]? {
            overrides
        }

        func updateMCPAgentRoleOverrides(
            _ overrides: [String: String]?,
            scope _: AgentModelsEditingScope,
            commit _: Bool
        ) {
            self.overrides = overrides
        }

        func mcpAgentRoleModelParameters(scope _: AgentModelsEditingScope) -> [String: [ACPModelParameterSelection]]? {
            roleModelParameters
        }

        func mcpAgentRoleModelParameters(workspaceID _: UUID?) -> [String: [ACPModelParameterSelection]]? {
            roleModelParameters
        }
    }

    private func seedCursorCatalog(
        options: [AgentModelOption],
        currentModelRaw: String?,
        parameterSets: [ACPModelParameterSet] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            AgentACPModelRegistry.shared.updateDiscoveredModels(
                ACPDiscoveredSessionModels(
                    options: options,
                    currentModelRaw: currentModelRaw,
                    modelParameterSets: parameterSets
                ),
                for: .cursor
            ),
            "Expected the seeded Cursor snapshot to publish",
            file: file,
            line: line
        )
    }

    private func discoveredOption(
        _ rawValue: String,
        _ displayName: String,
        isDefault: Bool = false
    ) -> AgentModelOption {
        AgentModelOption(
            rawValue: rawValue,
            displayName: displayName,
            description: nil,
            isDefault: isDefault
        )
    }

    private func effortDefinition(
        configID: String,
        values: [String],
        currentValueRaw: String
    ) -> ACPModelParameterDefinition {
        ACPModelParameterDefinition(
            kind: .thinking,
            configID: configID,
            displayName: "Effort",
            choices: values.map { ACPModelParameterChoice(rawValue: $0, displayName: $0.capitalized) },
            currentValueRaw: currentValueRaw
        )
    }

    private func speedDefinition(currentValueRaw: String) -> ACPModelParameterDefinition {
        ACPModelParameterDefinition(
            kind: .speed,
            configID: "fast",
            displayName: "Speed",
            choices: [
                ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
                ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
            ],
            currentValueRaw: currentValueRaw
        )
    }
}
