import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Direct-model (SessionModelState) path coverage for the Grok Build ACP provider:
/// session-open ingestion into the registry, `session/set_model` dispatch, validation,
/// and modern-configOptions precedence. Uses a self-contained fake ACP server.
final class GrokBuildACPDirectModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
        super.tearDown()
    }

    func testSessionModelStatePopulatesRegistryWhenConfigOptionsAbsent() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)
        // The registry canonicalizes ordering; membership is the contract. Options carry the
        // two base models plus every advertised effort variant (4.6 adds xhigh).
        XCTAssertEqual(Set(snapshot?.options.map(\.rawValue) ?? []), [
            "grok-4.6", "grok-4.5",
            "grok-4.6-xhigh", "grok-4.6-high", "grok-4.6-medium", "grok-4.6-low",
            "grok-4.5-high", "grok-4.5-medium", "grok-4.5-low"
        ])
        XCTAssertEqual(snapshot?.currentModelRaw, "grok-4.6")
        XCTAssertEqual(snapshot?.currentEffortRaw, "high")

        let base46 = snapshot?.options.first { $0.rawValue == "grok-4.6" }
        XCTAssertEqual(
            base46?.supportedReasoningEfforts,
            [.low, .medium, .high, .xhigh],
            "the dynamic store canonicalizes effort lists into displayOrder"
        )
        XCTAssertEqual(base46?.defaultReasoningEffort, .high)
        let base45 = snapshot?.options.first { $0.rawValue == "grok-4.5" }
        XCTAssertEqual(base45?.supportedReasoningEfforts, [.low, .medium, .high])
    }

    func testEveryAcceptedEffortSendsBaseModelIdAndEffortMeta() async throws {
        // Table-driven positive wire coverage for the accepted efforts beyond the live
        // fixture's default list: none, minimal, max, ultra.
        for effort in ["none", "minimal", "max", "ultra"] {
            let fixture = try makeFixture(shape: "grok_direct", extra46Effort: effort)
            try await bootstrap(fixture.controller)

            try await fixture.controller.setSessionModel("grok-4.6-\(effort)")
            let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_model")
            XCTAssertEqual(mutations.count, 1, "effort \(effort): selection must dispatch")
            XCTAssertEqual(
                mutations.first?.params["modelId"] as? String,
                "grok-4.6",
                "effort \(effort): modelId is the literal base id"
            )
            XCTAssertEqual(
                (mutations.first?.params["_meta"] as? [String: Any])?["reasoningEffort"] as? String,
                effort,
                "effort \(effort): _meta.reasoningEffort equals the advertised effort"
            )
            await fixture.controller.shutdown()
        }
    }

    func testEffortVariantSelectionSendsModelAndEffortMeta() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        try await fixture.controller.setSessionModel("grok-4.5-low")

        let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_model")
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.params["modelId"] as? String, "grok-4.5")
        XCTAssertEqual(
            (mutations.first?.params["_meta"] as? [String: Any])?["reasoningEffort"] as? String,
            "low",
            "effort rides the camelCase _meta.reasoningEffort key (live-verified grok 1.0.4)"
        )
        let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)
        XCTAssertEqual(snapshot?.currentModelRaw, "grok-4.5")
        XCTAssertNil(
            snapshot?.currentEffortRaw,
            "the Ok confirms only the base model — an applied effort stays unconfirmed until a fresh session config parse"
        )
    }

    func testUnconfirmedEffortNeverSuppressesIdenticalRepeatSelection() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        try await fixture.controller.setSessionModel("grok-4.5-low")
        try await fixture.controller.setSessionModel("grok-4.5-low")
        // The effort is never confirmed by the wire, so the repeat pick re-sends rather than
        // trusting a locally recorded effort. The redundant RPC is harmless; a wrongly
        // suppressed mutation is not.
        XCTAssertEqual(recordedRequests(at: fixture.recordURL, method: "session/set_model").count, 2)
    }

    func testBareSelectionAfterVariantResetsToDefaultEffort() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        try await fixture.controller.setSessionModel("grok-4.5-low")
        try await fixture.controller.setSessionModel("grok-4.5")

        let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_model")
        XCTAssertEqual(mutations.count, 2, "bare-after-variant must re-send to reset effort")
        XCTAssertEqual(
            (mutations.last?.params["_meta"] as? [String: Any])?["reasoningEffort"] as? String,
            "high",
            "the bare pick resolves to the model's advertised default effort"
        )
        XCTAssertNil(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentEffortRaw,
            "effort authority is cleared until the next session config parse confirms it"
        )
    }

    func testUnadvertisedEffortIsRejectedBeforeRPC() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        do {
            // grok-4.5 does not advertise xhigh — the compound is not a snapshot member.
            try await fixture.controller.setSessionModel("grok-4.5-xhigh")
            XCTFail("expected unadvertised effort to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("grok-4.5-xhigh"), "unexpected error: \(error)")
        }
        XCTAssertTrue(recordedRequests(at: fixture.recordURL, method: "session/set_model").isEmpty)
    }

    func testSessionEffortComesFromSessionConfigNotModelDefault() async throws {
        // The session's active effort (low) differs from every model's advertised default
        // (high): the snapshot must report the session value, and a bare pick must resolve
        // to the DEFAULT and re-send rather than short-circuiting on the model's value.
        let fixture = try makeFixture(shape: "grok_direct", sessionEffort: "low")
        try await bootstrap(fixture.controller)

        let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)
        XCTAssertEqual(snapshot?.currentEffortRaw, "low", "session config is the only current-effort authority")
        XCTAssertEqual(snapshot?.options.first { $0.rawValue == "grok-4.6" }?.defaultReasoningEffort, .high)

        try await fixture.controller.setSessionModel("grok-4.6")
        let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_model")
        XCTAssertEqual(mutations.count, 1, "bare pick at non-default session effort must reset to the default")
        XCTAssertEqual(
            (mutations.first?.params["_meta"] as? [String: Any])?["reasoningEffort"] as? String,
            "high"
        )
    }

    func testMissingSessionConfigLeavesEffortUnknown() async throws {
        let fixture = try makeFixture(shape: "grok_direct", sessionEffort: "absent")
        try await bootstrap(fixture.controller)

        XCTAssertNil(AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentEffortRaw)
        // Unknown current effort must not be inferred from the default: a bare pick of the
        // current model still sends the explicit default effort.
        try await fixture.controller.setSessionModel("grok-4.6")
        let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_model")
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(
            (mutations.first?.params["_meta"] as? [String: Any])?["reasoningEffort"] as? String,
            "high"
        )
    }

    func testUnadvertisedDeclaredDefaultFallsBackToAdvertisedListDefault() async throws {
        // grok-4.5 declares default "ultra", which is not in its advertised list: the
        // declared value must not be trusted, no ultra variant may exist, and the default
        // falls back to the advertised list's own default entry (high), so anything sent
        // stays within the advertised set.
        let fixture = try makeFixture(shape: "grok_direct", default45Effort: "ultra")
        try await bootstrap(fixture.controller)

        let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)
        let base45 = snapshot?.options.first { $0.rawValue == "grok-4.5" }
        XCTAssertEqual(base45?.defaultReasoningEffort, .high, "unadvertised declared default falls back to the list default")
        XCTAssertFalse(snapshot?.options.contains { $0.rawValue == "grok-4.5-ultra" } ?? true)

        try await fixture.controller.setSessionModel("grok-4.5")
        let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_model")
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.params["modelId"] as? String, "grok-4.5")
        XCTAssertEqual(
            (mutations.first?.params["_meta"] as? [String: Any])?["reasoningEffort"] as? String,
            "high",
            "only advertised efforts may leave the client"
        )
    }

    func testCompoundSelectionMismatchInvalidatesModelAndEffortAuthority() async throws {
        let fixture = try makeFixture(shape: "grok_direct", setModelAck: "mismatch")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-4.5-low")
            XCTFail("expected mismatched Ok to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not confirm"), "unexpected error: \(error)")
        }
        let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)
        XCTAssertNil(snapshot?.currentModelRaw, "ambiguous ack: model authority invalidated, not preserved or moved")
        XCTAssertNil(snapshot?.currentEffortRaw, "ambiguous ack: effort authority invalidated too")
    }

    func testBareSelectionRejectedWhenDefaultUnknown() async throws {
        // Effort-capable with an untrusted declared default (ultra) and NO list default:
        // a bare pick has nothing to resolve to and must be rejected before any RPC —
        // silently keeping the active effort is not an option.
        let fixture = try makeFixture(shape: "grok_direct", default45Effort: "ultra", listDefault45: "none")
        try await bootstrap(fixture.controller)

        XCTAssertNil(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.options
                .first { $0.rawValue == "grok-4.5" }?.defaultReasoningEffort
        )
        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected bare pick without an authoritative default to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no authoritative default"), "unexpected error: \(error)")
        }
        XCTAssertTrue(recordedRequests(at: fixture.recordURL, method: "session/set_model").isEmpty)

        // An explicit variant remains selectable.
        try await fixture.controller.setSessionModel("grok-4.5-low")
        XCTAssertEqual(recordedRequests(at: fixture.recordURL, method: "session/set_model").count, 1)
    }

    func testBareSelectionRejectedWhenListDefaultsConflict() async throws {
        // Two distinct `default: true` entries cancel out; with the declared value also
        // untrusted, the model has no authoritative default and bare picks are rejected.
        let fixture = try makeFixture(shape: "grok_direct", default45Effort: "ultra", listDefault45: "multi")
        try await bootstrap(fixture.controller)

        XCTAssertNil(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.options
                .first { $0.rawValue == "grok-4.5" }?.defaultReasoningEffort,
            "conflicting list defaults cancel out"
        )
        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected bare pick with conflicting defaults to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no authoritative default"), "unexpected error: \(error)")
        }
        XCTAssertTrue(recordedRequests(at: fixture.recordURL, method: "session/set_model").isEmpty)
    }

    func testVariantNeverShadowsAdvertisedBaseWithEffortTokenSuffix() async throws {
        let fixture = try makeFixture(shape: "grok_collision")
        try await bootstrap(fixture.controller)

        let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)
        let collisionRaws = snapshot?.options.filter { $0.rawValue == "grok-4.6-low" } ?? []
        XCTAssertEqual(collisionRaws.count, 1, "the synthesized variant must yield to the real base")
        XCTAssertTrue(collisionRaws.first?.supportedReasoningEfforts.isEmpty == true, "the surviving option is the no-effort base")

        try await fixture.controller.setSessionModel("grok-4.6-low")
        let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_model")
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.params["modelId"] as? String, "grok-4.6-low", "an exact advertised base stays selectable as that base")
        XCTAssertNil(mutations.first?.params["_meta"])
        let after = AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)
        XCTAssertEqual(after?.currentModelRaw, "grok-4.6-low")
        XCTAssertEqual(
            after?.currentEffortRaw,
            "high",
            "a model-only request confirms nothing about effort — the last confirmed effort is preserved"
        )

        // Re-selecting the same effort-free base is a complete no-op.
        try await fixture.controller.setSessionModel("grok-4.6-low")
        XCTAssertEqual(recordedRequests(at: fixture.recordURL, method: "session/set_model").count, 1)
    }

    func testWarmedRegistryCannotAuthorizeEffortSelection() async throws {
        // Warm the registry with a full snapshot first.
        let warmFixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(warmFixture.controller)
        XCTAssertNotNil(AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild))

        // A new session advertising NO model metadata: validation falls back to the warmed
        // registry, which must never authorize an effort mutation — the provider may have
        // removed the effort since, and grok silently ignores unknown efforts while still
        // acknowledging the base.
        let coldFixture = try makeFixture(shape: "grok_bare")
        try await bootstrap(coldFixture.controller)

        do {
            try await coldFixture.controller.setSessionModel("grok-4.5-low")
            XCTFail("expected warmed-only effort selection to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("live session model set"), "unexpected error: \(error)")
        }
        do {
            // Bare picks resolve to the (stale) advertised default — also an effort mutation.
            try await coldFixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected warmed-only default-effort selection to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("live session model set"), "unexpected error: \(error)")
        }
        XCTAssertTrue(recordedRequests(at: coldFixture.recordURL, method: "session/set_model").isEmpty)
    }

    func testModelOnlyMutationDoesNotPromoteWarmedSnapshotToLiveAuthority() async throws {
        // Warm with the collision shape (it carries an effort-free base, so a model-only
        // selection is legal even without live authority).
        let warmFixture = try makeFixture(shape: "grok_collision")
        try await bootstrap(warmFixture.controller)

        let coldFixture = try makeFixture(shape: "grok_bare")
        try await bootstrap(coldFixture.controller)

        // Model-only selection via warmed data: allowed (the Ok echoes the base id).
        try await coldFixture.controller.setSessionModel("grok-4.6-low")
        XCTAssertEqual(recordedRequests(at: coldFixture.recordURL, method: "session/set_model").count, 1)

        // The warmed options now sit in discoveredSessionModels, but they must NOT have
        // acquired live authority: an effort-bearing selection still fails before any RPC.
        do {
            try await coldFixture.controller.setSessionModel("grok-4.5-low")
            XCTFail("expected effort selection after warmed-only mutation to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("live session model set"), "unexpected error: \(error)")
        }
        XCTAssertEqual(recordedRequests(at: coldFixture.recordURL, method: "session/set_model").count, 1)
    }

    func testSessionModeIdResolvesThroughAdvertisedIdValuePairs() async throws {
        // The wire separates reasoningEfforts[].id from .value; the session config selects
        // by id. Here grok-4.6's low entry has id "eff-low" / value "low" and the session
        // selects "eff-low" — the recorded active effort must be the canonical value.
        let fixture = try makeFixture(shape: "grok_direct", sessionEffort: "low", lowModeID: "eff-low")
        try await bootstrap(fixture.controller)

        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentEffortRaw,
            "low",
            "the selected mode id resolves to its canonical value through the advertised pairs"
        )
    }

    func testValidPlusMalformedDoubleSelectionLeavesEffortUnknown() async throws {
        // One valid selected mode plus a malformed selected entry (no id): cardinality is
        // counted over ALL selected entries, so this must not confirm anything.
        let fixture = try makeFixture(shape: "grok_direct", doubleSelect: true)
        try await bootstrap(fixture.controller)

        XCTAssertNil(AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentEffortRaw)
    }

    func testSelectedIdNamingUnknownEffortLeavesEffortUnknown() async throws {
        // The selected id "high" names a pair whose value is the unknown "ultra" AND
        // matches another pair by value (eff-high→high). Dropping the unparsed pair would
        // misrecord "high" as confirmed authority; instead the effort stays unknown and a
        // corrective selection re-sends.
        let fixture = try makeFixture(shape: "grok_direct", ultraIDCollision: true)
        try await bootstrap(fixture.controller)

        XCTAssertNil(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentEffortRaw,
            "an id naming an unparsed value must never resolve to a different pair's effort"
        )
        try await fixture.controller.setSessionModel("grok-4.6-high")
        XCTAssertEqual(
            recordedRequests(at: fixture.recordURL, method: "session/set_model").count,
            1,
            "unknown current effort must not suppress the selection"
        )
    }

    func testModeIdValueCrossCollisionLeavesEffortUnknown() async throws {
        // The selected id "high" matches one pair through its VALUE (eff-high→high) and
        // another through its ID (high→low): two distinct efforts, ambiguous → unknown.
        let fixture = try makeFixture(shape: "grok_direct", crossCollision: true)
        try await bootstrap(fixture.controller)

        XCTAssertNil(AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentEffortRaw)
    }

    func testPreferredModelRawResolvesNonDefaultActiveEffortToVariant() {
        let base = AgentModelOption(
            rawValue: "grok-4.6",
            displayName: "Grok 4.6",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false,
            supportedReasoningEfforts: [.low, .medium, .high, .xhigh],
            defaultReasoningEffort: .high
        )
        let lowVariant = AgentModelOption(
            rawValue: "grok-4.6-low",
            displayName: "Grok 4.6 Low",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false,
            effortVariant: AgentModelEffortVariant(baseModelRaw: "grok-4.6", reasoningEffort: .low)
        )
        let highVariant = AgentModelOption(
            rawValue: "grok-4.6-high",
            displayName: "Grok 4.6 High",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false,
            effortVariant: AgentModelEffortVariant(baseModelRaw: "grok-4.6", reasoningEffort: .high)
        )
        let options = [base, lowVariant, highVariant]

        // Confirmed non-default active effort → the provenanced variant.
        XCTAssertEqual(
            ACPDiscoveredSessionModels(options: options, currentModelRaw: "grok-4.6", currentEffortRaw: "low").preferredModelRaw,
            "grok-4.6-low"
        )
        // Default effort → the bare base alias.
        XCTAssertEqual(
            ACPDiscoveredSessionModels(options: options, currentModelRaw: "grok-4.6", currentEffortRaw: "high").preferredModelRaw,
            "grok-4.6"
        )
        // Unknown effort → base.
        XCTAssertEqual(
            ACPDiscoveredSessionModels(options: options, currentModelRaw: "grok-4.6").preferredModelRaw,
            "grok-4.6"
        )
    }

    func testStoreMergeKeepsVariantProvenanceOnlyOnAgreement() throws {
        let variantOption = AgentModelOption(
            rawValue: "grok-4.6-low",
            displayName: "Grok 4.6 Low",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false,
            effortVariant: AgentModelEffortVariant(baseModelRaw: "grok-4.6", reasoningEffort: .low)
        )
        let realBase = AgentModelOption(
            rawValue: "grok-4.6-low",
            displayName: "Grok 4.6 Low Edition",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false
        )
        let snapshot = ACPDiscoveredSessionModels(options: [variantOption, realBase], currentModelRaw: nil)
        let record = try XCTUnwrap(ACPDynamicModelStore.canonicalProviderRecord(from: snapshot, providerID: .grokBuild))
        let restored = try XCTUnwrap(ACPDynamicModelStore.snapshot(from: record))
        let merged = restored.options.first { $0.rawValue == "grok-4.6-low" }
        XCTAssertNotNil(merged)
        XCTAssertNil(merged?.effortVariant, "disagreeing provenance must not stick to the merged record")
    }

    func testLegacyProviderRecordWithoutEffortDecodes() throws {
        // Records persisted before effort support lack currentEffortRaw; decoding must not
        // break existing stores.
        let legacy = """
        {"providerID":"grokBuild","currentModelRaw":"grok-4.6","options":[
          {"rawValue":"grok-4.6","displayName":"Grok 4.6","description":null,
           "isPlaceholderDefault":false,"isProviderDefault":false,
           "supportedReasoningEfforts":[],"defaultReasoningEffort":null}
        ]}
        """
        let record = try JSONDecoder().decode(ACPDynamicProviderRecord.self, from: Data(legacy.utf8))
        let snapshot = try XCTUnwrap(ACPDynamicModelStore.snapshot(from: record))
        XCTAssertEqual(snapshot.currentModelRaw, "grok-4.6")
        XCTAssertNil(snapshot.currentEffortRaw)
    }

    func testEffortVariantReuseKeysOnCompoundSelection() async throws {
        // Controllers key reuse on the requested model string; different efforts must never
        // share a process silently.
        let workspace = try makeTestDirectory(name: "GrokBuildEffortReuse")
        func makeController(_ model: String?) throws -> ACPAgentSessionController {
            try ACPAgentSessionController(
                provider: GrokDirectFakeACPProvider(commandPath: "/bin/echo", environment: [:]),
                runRequest: ACPRunRequest(
                    agentKind: .grokBuild,
                    modelString: model,
                    workspacePath: workspace.path,
                    resumeSessionID: nil,
                    attachments: [],
                    taskLabelKind: nil
                )
            )
        }
        let low = try makeController("grok-4.6-low")
        let sameEffort = await low.isCompatibleWith(request: ACPRunRequest(
            agentKind: .grokBuild, modelString: "grok-4.6-low",
            workspacePath: workspace.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil
        ))
        let otherEffort = await low.isCompatibleWith(request: ACPRunRequest(
            agentKind: .grokBuild, modelString: "grok-4.6-xhigh",
            workspacePath: workspace.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil
        ))
        let bare = await low.isCompatibleWith(request: ACPRunRequest(
            agentKind: .grokBuild, modelString: "grok-4.6",
            workspacePath: workspace.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil
        ))
        XCTAssertTrue(sameEffort)
        XCTAssertFalse(otherEffort, "effort change must force a fresh controller")
        XCTAssertFalse(bare, "compound → bare transition must force a fresh controller")
        await low.shutdown()
    }

    func testDirectSetModelSendsExactProviderRequest() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        try await fixture.controller.setSessionModel("grok-4.5")

        let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_model")
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.params["sessionId"] as? String, "grok-direct-session")
        XCTAssertEqual(mutations.first?.params["modelId"] as? String, "grok-4.5")
        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "grok-4.5"
        )
    }

    func testDirectSetModelSkipsWhenSessionAlreadyCurrent() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        try await fixture.controller.setSessionModel("grok-4.6")
        XCTAssertTrue(recordedRequests(at: fixture.recordURL, method: "session/set_model").isEmpty)
    }

    func testDefaultNeverSendsSetModel() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        try await fixture.controller.setSessionModel("default")
        try await fixture.controller.setSessionModel(" Default ")
        XCTAssertTrue(recordedRequests(at: fixture.recordURL, method: "session/set_model").isEmpty)
    }

    func testUnknownDirectModelIsRejectedBeforeRPC() async throws {
        let fixture = try makeFixture(shape: "grok_direct")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-9.9")
            XCTFail("expected unknown model to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("grok-9.9"), "unexpected error: \(error)")
        }
        XCTAssertTrue(recordedRequests(at: fixture.recordURL, method: "session/set_model").isEmpty)
    }

    func testErrModelOutcomeThrowsAndPreservesCurrentModel() async throws {
        let fixture = try makeFixture(shape: "grok_direct", setModelAck: "err")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected Err outcome to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rejected"), "unexpected error: \(error)")
        }
        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "grok-4.6",
            "a rejected selection must not move local model authority"
        )
    }

    func testMissingModelAckFailsClosed() async throws {
        let fixture = try makeFixture(shape: "grok_direct", setModelAck: "missing")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected missing acknowledgement to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not confirm"), "unexpected error: \(error)")
        }
        let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)
        XCTAssertNil(
            snapshot?.currentModelRaw,
            "an ambiguous ack leaves server state unknowable — current-model authority is invalidated"
        )
        XCTAssertNil(snapshot?.currentEffortRaw)
        XCTAssertFalse(snapshot?.options.isEmpty ?? true, "the advertised options remain live")
    }

    func testMalformedModelAckFailsClosed() async throws {
        let fixture = try makeFixture(shape: "grok_direct", setModelAck: "malformed")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected malformed acknowledgement to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not confirm"), "unexpected error: \(error)")
        }
        XCTAssertNil(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "an ambiguous ack invalidates current-model authority"
        )
    }

    func testMismatchedOkFailsClosed() async throws {
        // The server confirms a DIFFERENT model than requested: local state must not move.
        let fixture = try makeFixture(shape: "grok_direct", setModelAck: "mismatch")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected mismatched Ok to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not confirm"), "unexpected error: \(error)")
        }
        XCTAssertNil(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "an Ok naming another model confirms nothing — authority is invalidated, not moved"
        )
    }

    func testAmbiguousAckDoesNotSuppressCorrectiveReselection() async throws {
        // After an ambiguous ack invalidates authority, re-selecting even the PREVIOUSLY
        // current model must send a fresh RPC — stale state may never short-circuit it.
        let fixture = try makeFixture(shape: "grok_direct", setModelAck: "mismatch")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-4.5-low")
            XCTFail("expected mismatched Ok to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not confirm"), "unexpected error: \(error)")
        }
        XCTAssertNil(AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw)

        // The mismatch fixture's Ok names grok-4.6, which IS the expected base for this
        // corrective selection, so it confirms and re-establishes authority.
        try await fixture.controller.setSessionModel("grok-4.6")
        let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_model")
        XCTAssertEqual(mutations.count, 2, "the corrective selection must not be suppressed")
        XCTAssertEqual(mutations.last?.params["modelId"] as? String, "grok-4.6")
        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "grok-4.6"
        )
    }

    func testMixedOkAndErrAckInvalidatesAuthority() async throws {
        // Both branches present is ambiguous under the {"Ok"}|{"Err"} contract — it must
        // NOT take the confirmed-rejection path and preserve state.
        let fixture = try makeFixture(shape: "grok_direct", setModelAck: "mixed")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected mixed acknowledgement to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not confirm"), "unexpected error: \(error)")
        }
        XCTAssertNil(AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw)
    }

    func testPostDispatchThrowInvalidatesAuthority() async throws {
        // The server dying mid-request is an ambiguous post-dispatch outcome: the mutation
        // may have been applied. Authority must be invalidated, not preserved.
        let fixture = try makeFixture(shape: "grok_direct", setModelAck: "close")
        try await bootstrap(fixture.controller)

        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected a post-dispatch failure to throw")
        } catch {
            // Any transport-level error is acceptable here.
        }
        XCTAssertNil(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "a post-dispatch throw invalidates current-model authority"
        )
    }

    func testWarmedOnlyAmbiguousAckInvalidatesRegistryAuthority() async throws {
        // Warm the registry (collision shape carries an effort-free base so the model-only
        // mutation below is legal without live authority).
        let warmFixture = try makeFixture(shape: "grok_collision")
        try await bootstrap(warmFixture.controller)
        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "grok-4.6"
        )

        // A metadata-free session validating against the warmed registry: an ambiguous ack
        // must still invalidate the registry's current authority.
        let coldFixture = try makeFixture(shape: "grok_bare", setModelAck: "mismatch")
        try await bootstrap(coldFixture.controller)

        do {
            try await coldFixture.controller.setSessionModel("grok-4.6-low")
            XCTFail("expected mismatched Ok to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not confirm"), "unexpected error: \(error)")
        }
        XCTAssertNil(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.currentModelRaw,
            "warmed-only sessions invalidate registry authority on ambiguous acks too"
        )
    }

    func testMalformedSessionModelStateDoesNotPersistAndSelectionFails() async throws {
        let fixture = try makeFixture(shape: "grok_direct_malformed")
        try await bootstrap(fixture.controller)

        XCTAssertNil(AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild))
        do {
            try await fixture.controller.setSessionModel("grok-4.5")
            XCTFail("expected malformed metadata to fail selection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("malformed"), "unexpected error: \(error)")
        }
    }

    func testModernConfigOptionsTakePrecedenceOverSessionModelState() async throws {
        // A session advertising BOTH a modern selector and legacy `models` must use the
        // modern path: no direct RPC, configOptions remain authoritative.
        let fixture = try makeFixture(shape: "grok_dual")
        try await bootstrap(fixture.controller)

        try await fixture.controller.setSessionModel("model-b")
        XCTAssertTrue(recordedRequests(at: fixture.recordURL, method: "session/set_model").isEmpty)
        let configMutations = recordedRequests(at: fixture.recordURL, method: "session/set_config_option")
        XCTAssertEqual(configMutations.count, 1)
        XCTAssertEqual(configMutations.first?.params["value"] as? String, "model-b")
    }

    func testDiscoveryClientRetainsVerifiedSessionPerWorkspace() async throws {
        // Polling must not mint a fresh persistent Grok session every 300s: the first
        // discovery opens session/new, later discoveries for the same workspace reuse the
        // verified identity through session/load.
        let workspace = try makeTestDirectory(name: "GrokBuildDiscoveryRetention")
        let scriptURL = try makeFakeGrokACPServerScript(in: workspace)
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let environment = [
            "ACP_RECORD_PATH": recordURL.path,
            "ACP_SHAPE": "grok_direct",
            "PATH": "/usr/bin:/bin"
        ]
        let client = GrokBuildACPControllerModelDiscoveryClient(
            providerFactory: { _, _ in
                GrokDirectFakeACPProvider(commandPath: scriptURL.path, environment: environment)
            },
            controllerFactory: { provider, runRequest in
                try ACPAgentSessionController(provider: provider, runRequest: runRequest)
            }
        )

        _ = try await client.discoverModels(workspacePath: workspace.path)
        _ = try await client.discoverModels(workspacePath: workspace.path)

        let newCalls = recordedRequests(at: recordURL, method: "session/new")
        let loadCalls = recordedRequests(at: recordURL, method: "session/load")
        XCTAssertEqual(newCalls.count, 1)
        XCTAssertEqual(loadCalls.count, 1)
        XCTAssertEqual(loadCalls.first?.params["sessionId"] as? String, "grok-direct-session")
    }

    func testStderrNoiseIsFilteredThroughProviderOverride() async throws {
        // Regression: `shouldEmitStderrLine` must be a protocol requirement so the
        // controller's existential call dispatches to the Grok override. The fake server
        // emits both suppressed noise and a regular stderr line.
        let workspace = try makeTestDirectory(name: "GrokBuildStderrFilter")
        let scriptURL = try makeFakeGrokACPServerScript(in: workspace)
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let provider = GrokDirectFakeACPProvider(
            commandPath: scriptURL.path,
            environment: [
                "ACP_RECORD_PATH": recordURL.path,
                "ACP_SHAPE": "grok_direct",
                "PATH": "/usr/bin:/bin"
            ]
        )
        let request = ACPRunRequest(
            agentKind: .grokBuild,
            modelString: nil,
            workspacePath: workspace.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        let events = await controller.currentEventsStream()
        var systemTexts: [String] = []
        let collector = Task {
            for await event in events {
                if case let .stream(result) = event, result.type == "system", let text = result.text {
                    systemTexts.append(text)
                }
            }
        }
        _ = try await controller.bootstrap()
        try await Task.sleep(nanoseconds: 300_000_000)
        await controller.shutdown()
        _ = await collector.value

        XCTAssertFalse(
            systemTexts.contains { $0.contains("worker quit with fatal: Transport channel closed") },
            "suppressed worker-transport noise must not surface: \(systemTexts)"
        )
        XCTAssertTrue(
            systemTexts.contains { $0.contains("ordinary grok stderr line") },
            "regular stderr lines must still surface: \(systemTexts)"
        )
    }

    // MARK: - Harness

    private struct Fixture {
        let controller: ACPAgentSessionController
        let recordURL: URL
    }

    private struct RecordedRequest {
        let method: String
        let params: [String: Any]
    }

    private func recordedRequests(at url: URL, method: String) -> [RecordedRequest] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let requestMethod = object["method"] as? String,
                  requestMethod == method
            else { return nil }
            return RecordedRequest(
                method: requestMethod,
                params: object["params"] as? [String: Any] ?? [:]
            )
        }
    }

    private func bootstrap(_ controller: ACPAgentSessionController) async throws {
        do {
            _ = try await controller.bootstrap()
        } catch {
            await controller.shutdown()
            throw error
        }
        addTeardownBlock {
            await controller.shutdown()
        }
    }

    private func makeFixture(
        shape: String,
        setModelAck: String = "ok",
        sessionEffort: String = "high",
        default45Effort: String = "high",
        lowModeID: String = "low",
        doubleSelect: Bool = false,
        crossCollision: Bool = false,
        ultraIDCollision: Bool = false,
        listDefault45: String = "single",
        extra46Effort: String = ""
    ) throws -> Fixture {
        let workspace = try makeTestDirectory(name: "GrokBuildACPDirectModelTests")
        let scriptURL = try makeFakeGrokACPServerScript(in: workspace)
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let environment = [
            "ACP_RECORD_PATH": recordURL.path,
            "ACP_SHAPE": shape,
            "ACP_SET_MODEL_ACK": setModelAck,
            "ACP_SESSION_EFFORT": sessionEffort,
            "ACP_45_DEFAULT_EFFORT": default45Effort,
            "ACP_LOW_MODE_ID": lowModeID,
            "ACP_DOUBLE_SELECT": doubleSelect ? "1" : "0",
            "ACP_CROSS_COLLISION": crossCollision ? "1" : "0",
            "ACP_ULTRA_ID_COLLISION": ultraIDCollision ? "1" : "0",
            "ACP_45_LIST_DEFAULT": listDefault45,
            "ACP_46_EXTRA_EFFORT": extra46Effort,
            "PATH": "/usr/bin:/bin"
        ]
        let request = ACPRunRequest(
            agentKind: .grokBuild,
            modelString: nil,
            workspacePath: workspace.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let provider = GrokDirectFakeACPProvider(
            commandPath: scriptURL.path,
            environment: environment
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        return Fixture(controller: controller, recordURL: recordURL)
    }

    private func makeFakeGrokACPServerScript(in directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("fake_grok_acp_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys

        record_path = os.environ.get("ACP_RECORD_PATH")
        shape = os.environ.get("ACP_SHAPE", "grok_direct")
        set_model_ack = os.environ.get("ACP_SET_MODEL_ACK", "ok")
        session_effort = os.environ.get("ACP_SESSION_EFFORT", "high")
        effort_default_override = os.environ.get("ACP_45_DEFAULT_EFFORT", "high")
        low_mode_id = os.environ.get("ACP_LOW_MODE_ID", "low")
        list_default_45 = os.environ.get("ACP_45_LIST_DEFAULT", "single")
        extra_46_effort = os.environ.get("ACP_46_EXTRA_EFFORT", "")
        session_id = "grok-direct-session"
        current_model = "grok-4.6"
        modern_current_model = "model-a"

        def record(method, params):
            if not record_path:
                return
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method, "params": params}) + "\n")

        def send(payload):
            print(json.dumps(payload), flush=True)

        def respond(request_id, result=None, error=None):
            payload = {"jsonrpc": "2.0", "id": request_id}
            if error is not None:
                payload["error"] = error
            else:
                payload["result"] = result if result is not None else {}
            send(payload)

        def grok_models():
            # Mirrors the live grok 1.0.4 wire: 4.6 supports xhigh/high/medium/low with
            # current effort high; 4.5 supports high/medium/low.
            return {
                "currentModelId": current_model,
                "availableModels": [
                    {"modelId": "grok-4.6", "name": "Grok 4.6", "description": "Frontier",
                     "_meta": {"totalContextTokens": 500000,
                               "supportsReasoningEffort": True,
                               "reasoningEffort": "high",
                               "reasoningEfforts": (
                                   [
                                       {"id": "xhigh", "value": "xhigh", "label": "Extra High Effort", "default": False},
                                       # True id/value cross-collision: the selected id
                                       # "high" matches this pair by VALUE…
                                       {"id": "eff-high", "value": "high", "label": "High Effort", "default": True},
                                       {"id": "medium", "value": "medium", "label": "Medium Effort", "default": False},
                                       # …and this pair by ID — two distinct efforts, ambiguous.
                                       {"id": "high", "value": "low", "label": "Low Effort", "default": False}
                                   ] if os.environ.get("ACP_CROSS_COLLISION") == "1" else
                                   [
                                       {"id": "xhigh", "value": "xhigh", "label": "Extra High Effort", "default": False},
                                       # The selected id "high" names THIS pair (id match),
                                       # whose value is the unknown "ultra"…
                                       {"id": "high", "value": "ultra", "label": "High Effort", "default": True},
                                       {"id": "medium", "value": "medium", "label": "Medium Effort", "default": False},
                                       {"id": low_mode_id, "value": "low", "label": "Low Effort", "default": False},
                                       # …but ALSO matches this pair by value. Dropping the
                                       # unparsed pair would misrecord "high" as confirmed.
                                       {"id": "eff-high", "value": "high", "label": "Eff High", "default": False}
                                   ] if os.environ.get("ACP_ULTRA_ID_COLLISION") == "1" else
                                   [
                                       {"id": "xhigh", "value": "xhigh", "label": "Extra High Effort", "default": False},
                                       {"id": "high", "value": "high", "label": "High Effort", "default": True},
                                       {"id": "medium", "value": "medium", "label": "Medium Effort", "default": False},
                                       {"id": low_mode_id, "value": "low", "label": "Low Effort", "default": False}
                                       ]
                               ) + ([{"id": extra_46_effort, "value": extra_46_effort,
                                      "label": extra_46_effort, "default": False}]
                                    if extra_46_effort else [])}},
                    {"modelId": "grok-4.5", "name": "Grok 4.5",
                     "_meta": {"supportsReasoningEffort": True,
                               "reasoningEffort": effort_default_override,
                               "reasoningEfforts": [
                                   {"id": "high", "value": "high", "label": "High Effort",
                                    "default": list_default_45 in ("single", "multi")},
                                   {"id": "medium", "value": "medium", "label": "Medium Effort",
                                    "default": list_default_45 == "multi"},
                                   {"id": "low", "value": "low", "label": "Low Effort", "default": False}
                               ]}}
                ]
            }

        def session_config_meta():
            # Mirrors grok 1.0.4's `_meta["x.ai/sessionConfig"]`: the session's ACTIVE
            # effort is the selected category-"mode" entry.
            if session_effort == "absent":
                return {}
            modes = ["xhigh", "high", "medium", "low"]
            options = [
                {"id": low_mode_id if m == "low" else m,
                 "category": "mode", "label": m, "selected": m == session_effort}
                for m in modes
            ]
            if os.environ.get("ACP_DOUBLE_SELECT") == "1":
                # A malformed second selected entry: cardinality must still fail closed.
                options.append({"category": "mode", "label": "broken", "selected": True})
            return {"x.ai/sessionConfig": {"options": options}}

        def modern_model_selector(value=None):
            return {
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "currentValue": value if value is not None else modern_current_model,
                "options": [
                    {"value": "model-a", "name": "Model A"},
                    {"value": "model-b", "name": "Model B"}
                ]
            }

        def session_result():
            if shape == "grok_direct":
                return {"sessionId": session_id, "models": grok_models(), "_meta": session_config_meta()}
            if shape == "grok_collision":
                # A real advertised base id that ends in an effort token: variant synthesis
                # must never shadow it.
                models = grok_models()
                models["availableModels"].append({"modelId": "grok-4.6-low", "name": "Grok 4.6 Low Edition"})
                return {"sessionId": session_id, "models": models, "_meta": session_config_meta()}
            if shape == "grok_direct_malformed":
                return {"sessionId": session_id, "models": {"currentModelId": "x", "availableModels": "nope"}}
            if shape == "grok_dual":
                return {
                    "sessionId": session_id,
                    "configOptions": [modern_model_selector()],
                    "models": grok_models()
                }
            return {"sessionId": session_id}

        sys.stderr.write("2026-08-14T00:00:00Z ERROR worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)\n")
        sys.stderr.flush()
        sys.stderr.write("ordinary grok stderr line\n")
        sys.stderr.flush()

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            method = message.get("method")
            request_id = message.get("id")
            params = message.get("params") or {}
            if method is None:
                continue
            record(method, params)
            if method == "initialize":
                respond(request_id, {
                    "protocolVersion": 1,
                    "agentCapabilities": {"loadSession": True, "promptCapabilities": {"embeddedContext": True}},
                    "authMethods": []
                })
            elif method == "session/new":
                respond(request_id, session_result())
            elif method == "session/load":
                respond(request_id, session_result())
            elif method == "session/set_model":
                requested = params.get("modelId")
                valid_ids = [m["modelId"] for m in grok_models()["availableModels"]]
                if shape in ("grok_collision", "grok_bare"):
                    valid_ids.append("grok-4.6-low")
                if set_model_ack == "missing":
                    respond(request_id, {})
                elif set_model_ack == "malformed":
                    respond(request_id, {"_meta": {"model": "not-a-model-outcome"}})
                elif set_model_ack == "mismatch":
                    respond(request_id, {"_meta": {"model": {"Ok": "grok-4.6"}}})
                elif set_model_ack == "err":
                    respond(request_id, {"_meta": {"model": {"Err": {"message": "model unavailable"}}}})
                elif set_model_ack == "mixed":
                    # Both branches present: ambiguous under the {"Ok"}|{"Err"} contract.
                    respond(request_id, {"_meta": {"model": {"Ok": "grok-4.5", "Err": {"message": "confused"}}}})
                elif set_model_ack == "close":
                    # Post-dispatch ambiguity: the server dies without answering.
                    sys.exit(0)
                elif requested in valid_ids:
                    current_model = requested
                    respond(request_id, {"_meta": {"model": {"Ok": requested}}})
                else:
                    respond(request_id, error={"code": -32602, "message": "unknown model"})
            elif method == "session/set_config_option":
                if params.get("configId") == "model":
                    modern_current_model = params.get("value")
                respond(request_id, {"configOptions": [modern_model_selector()]})
            elif method == "session/prompt":
                send({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session_id,
                        "update": {"sessionUpdate": "agent_message_chunk",
                                   "content": {"type": "text", "text": "pong"}}
                    }
                })
                respond(request_id, {
                    "stopReason": "end_turn",
                    "_meta": {"usage": {"inputTokens": 10, "outputTokens": 5}}
                })
            elif method == "session/cancel":
                pass
            elif request_id is not None:
                respond(request_id, {})
        """# + "\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}

/// Fake provider that speaks the Grok direct-model capability while launching the fake
/// server script directly (no executable discovery).
private struct GrokDirectFakeACPProvider: ACPAgentProvider, ACPDirectSessionModelProvider {
    let commandPath: String
    let environment: [String: String]

    var providerID: ACPProviderID {
        .grokBuild
    }

    private let directDelegate = GrokBuildACPAgentProvider(
        config: GrokBuildAgentConfig(commandName: "/bin/echo", includeRepoPromptMCPServer: false)
    )

    func support(for _: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        let mode: ACPSessionConfiguration.Mode = if let resume = request.resumeSessionID {
            .load(existingSessionID: resume)
        } else {
            .new
        }
        return ACPSessionConfiguration(
            mode: mode,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(_ payload: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        GrokBuildACPEventNormalizer.normalize(payload)
    }

    func shouldEmitStderrLine(_ line: String) -> Bool {
        directDelegate.shouldEmitStderrLine(line)
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }

    func parseDirectSessionModelSnapshot(from sessionResponse: [String: Any]) -> ACPProviderModelSnapshotResult {
        directDelegate.parseDirectSessionModelSnapshot(from: sessionResponse)
    }

    func makeDirectModelSelectionRequest(
        sessionID: String,
        baseModelRaw: String,
        reasoningEffortRaw: String?
    ) -> ACPDirectModelSelectionRequest {
        directDelegate.makeDirectModelSelectionRequest(
            sessionID: sessionID,
            baseModelRaw: baseModelRaw,
            reasoningEffortRaw: reasoningEffortRaw
        )
    }
}
