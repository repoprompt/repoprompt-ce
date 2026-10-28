import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentAutomationTurnAuditTests: XCTestCase {
    func testSessionRoundTripJoinsAuditToExistingUsageTurnID() throws {
        let turnID = UUID()
        let audit = AgentAutomationTurnAudit(
            turnID: turnID,
            createdAt: Date(timeIntervalSince1970: 100),
            router: .init(
                configured: true,
                eligible: true,
                judgmentRequested: true,
                decision: .selected,
                chosenModelRaw: "gpt-6-sol",
                chosenEffortRaw: "medium",
                application: .turnAccepted
            ),
            autoEffort: .init(configured: false, eligible: false, judgmentRequested: false, decision: .disabled),
            acceptedProviderRaw: "codexExec",
            acceptedModelRaw: "gpt-6-sol",
            acceptedEffortRaw: "low",
            providerTurnAccepted: true
        )
        let usage = AgentTokenUsagePersist(turnID: turnID, promptTokens: 12, completionTokens: 3)
        let session = AgentSession(
            providerTokenUsageByTurn: [usage],
            automationTurnAudit: [audit]
        )
        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        XCTAssertEqual(decoded.automationTurnAudit, [audit])
        XCTAssertEqual(decoded.automationTurnAudit.first?.router.chosenEffortRaw, "medium")
        XCTAssertEqual(decoded.automationTurnAudit.first?.acceptedEffortRaw, "low")
        XCTAssertEqual(decoded.providerTokenUsageByTurn.first?.turnID, turnID)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("promptExcerpt"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("providerEffective"))
    }

    func testVersionOneAuditWithoutCodexDeliveryStillDecodes() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(makeSelectedAudit())) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object.removeValue(forKey: "codexDelivery")
        let decoded = try JSONDecoder().decode(
            AgentAutomationTurnAudit.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.codexDelivery)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testLegacySessionWithoutAuditDecodesAsEmpty() throws {
        let encoded = try JSONEncoder().encode(AgentSession())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "automationTurnAudit")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: legacy)
        XCTAssertTrue(decoded.automationTurnAudit.isEmpty)
    }

    func testCodexSteerAndQueuedFallbackSeparateLocalAndProviderAcceptance() {
        var audit = makeSelectedAudit()
        audit.recordCodexQueuedFallback()
        XCTAssertEqual(audit.codexDelivery, .queuedFallback)
        XCTAssertFalse(audit.providerDispatchAttempted)
        XCTAssertFalse(audit.providerTurnAccepted)

        audit.recordCodexDispatch(.fallbackStart)
        XCTAssertTrue(audit.providerDispatchAttempted)
        XCTAssertFalse(audit.providerTurnAccepted)
        audit.recordCodexStartAccepted(effortRaw: "high", autoEffortApplied: false)
        XCTAssertTrue(audit.providerTurnAccepted)
        XCTAssertEqual(audit.acceptedEffortRaw, "high")
        XCTAssertEqual(audit.autoEffort.application, .fallbackToManual)

        var steer = makeSelectedAudit()
        steer.recordCodexDispatch(.steer)
        steer.recordCodexSteerAccepted()
        XCTAssertEqual(steer.codexDelivery, .steer)
        XCTAssertTrue(steer.providerTurnAccepted)
        XCTAssertEqual(steer.router.application, .notObserved)
        XCTAssertEqual(steer.autoEffort.application, .notObserved)
    }

    func testManagedAuthReplayUpdatesPhysicalDispatchWithoutInventingEffectiveEffort() {
        var audit = makeSelectedAudit()
        audit.recordCodexDispatch(.start)
        audit.recordCodexDispatch(.managedAuthReplay)
        audit.recordCodexStartAccepted(effortRaw: "medium", autoEffortApplied: true)
        XCTAssertEqual(audit.codexDelivery, .managedAuthReplay)
        XCTAssertTrue(audit.providerTurnAccepted)
        XCTAssertEqual(audit.acceptedEffortRaw, "medium")
        XCTAssertEqual(audit.autoEffort.application, .turnAccepted)
    }

    func testClaudeAcceptedEffortFollowsAppliedControlOrManualFallback() {
        var applied = makeSelectedAudit()
        applied.autoEffort.application = .controlAccepted
        applied.recordClaudeTurnAccepted(autoEffortRaw: "high", manualEffortRaw: "low")
        XCTAssertEqual(applied.acceptedEffortRaw, "high")
        XCTAssertEqual(applied.autoEffort.application, .turnAccepted)

        var fallback = makeSelectedAudit()
        fallback.autoEffort.application = .controlAccepted
        fallback.recordClaudeTurnAccepted(autoEffortRaw: nil, manualEffortRaw: "low")
        XCTAssertEqual(fallback.acceptedEffortRaw, "low")
        XCTAssertEqual(fallback.autoEffort.application, .fallbackToManual)
        XCTAssertTrue(fallback.autoEffort.fallbackApplied)
    }

    func testDiscardedMCPJudgmentRetainsCallAndChoice() {
        let original = makeSelectedAudit().autoEffort
        let discarded = original.discardedAfterMCPReclassification()
        XCTAssertTrue(discarded.judgmentRequested)
        XCTAssertEqual(discarded.chosenEffortRaw, "high")
        XCTAssertTrue(discarded.fallbackApplied)
        XCTAssertEqual(discarded.application, .fallbackToManual)
    }

    @MainActor
    func testRemovingRejectedOptimisticUserTurnRemovesOnlyItsAudit() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let rejected = AgentChatItem.user("rejected", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(rejected)
        var audit = makeSelectedAudit()
        audit = AgentAutomationTurnAudit(
            turnID: rejected.id,
            createdAt: rejected.timestamp,
            router: audit.router,
            autoEffort: audit.autoEffort
        )
        session.appendAutomationAudit(audit)
        XCTAssertNotNil(session.removeItem(at: 0))
        XCTAssertTrue(session.automationTurnAudit.isEmpty)
    }

    private func makeSelectedAudit() -> AgentAutomationTurnAudit {
        AgentAutomationTurnAudit(
            turnID: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            router: .init(
                configured: true, eligible: true, judgmentRequested: true,
                decision: .selected, chosenModelRaw: "gpt-6-sol", chosenEffortRaw: "medium"
            ),
            autoEffort: .init(
                configured: true, eligible: true, judgmentRequested: true,
                decision: .selected, chosenModelRaw: "gpt-6-sol", chosenEffortRaw: "high"
            ),
            acceptedEffortRaw: "low"
        )
    }

    func testAuditRetentionIsBoundedWithoutFabricatingUsage() {
        let records = (0 ..< 140).map { index in
            AgentAutomationTurnAudit(
                turnID: UUID(),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                router: .init(configured: false, eligible: false, judgmentRequested: false, decision: .disabled),
                autoEffort: .init(configured: true, eligible: false, judgmentRequested: false, decision: .ineligible)
            )
        }
        let retained = AgentAutomationTurnAudit.retain(records)
        XCTAssertEqual(retained.count, AgentAutomationTurnAudit.retainedTurnLimit)
        XCTAssertEqual(retained.first?.turnID, records[12].turnID)
        XCTAssertFalse(retained.last?.providerTurnAccepted ?? true)
    }
}

@MainActor
final class RoutingExecutionMetadataTests: XCTestCase {
    private let available = AgentModelCatalog.AvailabilityContext(
        claudeCodeAvailable: true,
        codexAvailable: true,
        openCodeAvailable: true
    )

    private func option(
        _ raw: String,
        _ providerDefault: Bool = false,
        effortVariant: AgentModelEffortVariant? = nil,
        rawEfforts: [String] = []
    ) -> AgentModelOption {
        .init(
            rawValue: raw,
            displayName: raw,
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: providerDefault,
            supportedReasoningEffortRawValues: rawEfforts,
            effortVariant: effortVariant
        )
    }

    private func builder(
        _ catalog: [AgentProviderKind: [AgentModelOption]],
        key: @escaping () -> String = { UUID().uuidString }
    ) -> AgentTaskRoutingCandidateBuilder {
        AgentTaskRoutingCandidateBuilder(opaqueKey: key) { provider, _ in catalog[provider] ?? [] }
    }

    func testPreviewCatalogMemoRetainsExactOutputsAndRemovesDuplicateRead() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let catalog: [AgentProviderKind: [AgentModelOption]] = [
            .codexExec: [option("gpt-6-sol", true), option("gpt-6-luna")]
        ]
        let profileSnapshot = RoutingModelProfileSnapshot.bundled
        var baselineCalls = 0
        let baselineOptions: @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = { provider, _ in
            baselineCalls += 1
            return catalog[provider] ?? []
        }
        let baselineProviders = AgentTaskRoutingCandidateBuilder.availableProviders(
            availability: availability,
            modelOptions: baselineOptions
        )
        var baselineKey = 0
        let baselineCandidates = try AgentTaskRoutingCandidateBuilder(
            opaqueKey: {
                baselineKey += 1
                return "candidate-\(baselineKey)"
            },
            profileSnapshot: profileSnapshot,
            modelOptions: baselineOptions
        ).build(allowedProviders: baselineProviders, availability: availability)

        var memoCalls = 0
        var memoizedOptions: [AgentProviderKind: [AgentModelOption]] = [:]
        let memoOptions: @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = { provider, _ in
            if let options = memoizedOptions[provider] {
                return options
            }
            memoCalls += 1
            let options = catalog[provider] ?? []
            memoizedOptions[provider] = options
            return options
        }
        let memoProviders = AgentTaskRoutingCandidateBuilder.availableProviders(
            availability: availability,
            modelOptions: memoOptions
        )
        var memoKey = 0
        let memoCandidates = try AgentTaskRoutingCandidateBuilder(
            opaqueKey: {
                memoKey += 1
                return "candidate-\(memoKey)"
            },
            profileSnapshot: profileSnapshot,
            modelOptions: memoOptions
        ).build(allowedProviders: memoProviders, availability: availability)

        XCTAssertEqual(baselineProviders, [.codexExec])
        XCTAssertEqual(memoProviders, baselineProviders)
        XCTAssertEqual(baselineCalls, 2)
        XCTAssertEqual(memoCalls, 1)
        XCTAssertEqual(memoCandidates, baselineCandidates)
        XCTAssertEqual(
            Self.previewSignatures(memoCandidates, availability: availability),
            Self.previewSignatures(baselineCandidates, availability: availability)
        )
    }

    private static func previewSignatures(
        _ candidates: [AgentTaskRoutingCandidateBuilder.Candidate],
        availability: AgentModelCatalog.AvailabilityContext
    ) -> [String] {
        candidates.compactMap { candidate in
            guard let provider = AgentProviderKind(rawValue: candidate.target.agentRaw) else { return nil }
            let displayName = AgentModelCatalog.displayName(
                for: candidate.target.modelRaw,
                agentKind: provider,
                availability: availability
            )
            return "\(candidate.utilityTier)|\(provider.rawValue)|\(candidate.target.modelRaw)|\(candidate.target.reasoningEffortRaw ?? "")|\(displayName)"
        }
    }

    func testSnapshotScopeIsStableAndChangesWithCatalogSurfaceAndAvailability() {
        let first = builder([.codexExec: [option("future-model", true)]])
        let original = first.capture(allowedProviders: [.codexExec], availability: available)
        let repeatCapture = first.capture(allowedProviders: [.codexExec], availability: available)
        XCTAssertEqual(original, repeatCapture)
        XCTAssertEqual(original.models.map(\.baseModelRaw), ["future-model"])

        let changed = builder([.codexExec: [option("future-model", true, rawEfforts: ["new-effort"])]]).capture(
            allowedProviders: [.codexExec], availability: available
        )
        XCTAssertNotEqual(original.scope.catalogRevision, changed.scope.catalogRevision)
        XCTAssertNotEqual(original.scope, changed.scope)
        XCTAssertNotEqual(
            original.scope,
            first.capture(allowedProviders: [.codexExec], availability: available, surface: .headless).scope
        )
        XCTAssertNotEqual(
            original.scope,
            first.capture(
                allowedProviders: [.codexExec],
                availability: .init(claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false)
            ).scope
        )
    }

    func testUnknownAdvertisedModelRemainsInCatalogButNotRouterShortlist() throws {
        let raw = "future-model-high"
        let builder = builder([.codexExec: [option(raw), option("gpt-6-sol"), option("gpt-6-luna")]])
        let snapshot = builder.capture(allowedProviders: [.codexExec], availability: available)
        XCTAssertEqual(snapshot.models.map(\.baseModelRaw), [raw, "gpt-6-sol", "gpt-6-luna"])
        XCTAssertTrue(snapshot.contains(.init(agentRaw: AgentProviderKind.codexExec.rawValue, modelRaw: raw, reasoningEffortRaw: nil, modelParameters: [])))
        XCTAssertEqual(try builder.build(snapshot: snapshot).map(\.target.modelRaw), ["gpt-6-sol", "gpt-6-luna"])

        let exactRecord = CodexDynamicModelRecord(
            id: raw, model: raw, displayName: raw, description: "", isDefault: false
        )
        let parsed = CodexModelSpecifier.splitLegacyModelID(raw, discoveredRecords: [exactRecord])
        XCTAssertEqual(parsed.baseModel, raw)
        XCTAssertNil(parsed.reasoningEffort)
    }

    func testDistinctExactProviderIDsAreNotCaseFoldedOrDeduplicated() throws {
        let builder = builder([.codexExec: [option("Future"), option("future")]])
        let snapshot = builder.capture(allowedProviders: [.codexExec], availability: available)
        XCTAssertEqual(snapshot.models.map(\.baseModelRaw), ["Future", "future"])
        XCTAssertThrowsError(try builder.build(snapshot: snapshot))
    }

    func testEffortLikeExactUnknownModelAndExcludedProviderCannotEnterShortlist() throws {
        let builder = builder([.codexExec: [option("gpt-6-sol-high"), option("ordinary-model")]])
        let snapshot = builder.capture(allowedProviders: [.codexExec], availability: available)
        XCTAssertEqual(snapshot.models.map(\.baseModelRaw), ["gpt-6-sol-high", "ordinary-model"])
        XCTAssertThrowsError(try builder.build(snapshot: snapshot))

        let otherProvider = self.builder([.openCode: [option("gpt-6-sol"), option("ordinary-model")]])
        let otherSnapshot = otherProvider.capture(allowedProviders: [.openCode], availability: available)
        XCTAssertEqual(otherSnapshot.models.map(\.baseModelRaw), ["gpt-6-sol", "ordinary-model"])
        XCTAssertThrowsError(try otherProvider.build(snapshot: otherSnapshot))
    }

    func testAdvertisedRawEffortIsPreservedButNotOfferedUnlessExecutable() throws {
        let base = option("gpt-6-sol", true, rawEfforts: ["high", "future-depth"])
        let builder = builder([.codexExec: [base, option("gpt-6-luna")]])
        let snapshot = builder.capture(allowedProviders: [.codexExec], availability: available)
        let model = try XCTUnwrap(snapshot.models.first { $0.baseModelRaw == "gpt-6-sol" })
        XCTAssertEqual(model.efforts.map(\.id.rawValue), ["high", "future-depth"])
        XCTAssertNil(model.defaultEffortID)
        XCTAssertEqual(model.efforts.map(\.isExecutable), [true, false])
        XCTAssertEqual(model.efforts.first?.executableTarget?.modelRaw, "gpt-6-sol")
        XCTAssertEqual(model.efforts.first?.executableTarget?.reasoningEffortRaw, "high")
        let chosen = try XCTUnwrap(builder.build(snapshot: snapshot).first { $0.target.modelRaw == "gpt-6-sol" })
        let efforts = try builder.buildEfforts(for: chosen, snapshot: snapshot)
        XCTAssertEqual(Set(efforts.compactMap(\.target.reasoningEffortRaw)), ["high"])
        XCTAssertFalse(efforts.contains { $0.utilityTier == "future-depth" })
        XCTAssertTrue(try snapshot.contains(XCTUnwrap(efforts.first { $0.target.reasoningEffortRaw == "high" }).target))
    }

    func testCodexDynamicMapperRetainsUnknownRawEffortsThroughOptionProjection() {
        let remote = CodexAppServerClient.RemoteModel(
            id: "future-codex",
            model: "future-codex",
            displayName: "Future Codex",
            description: "",
            isDefault: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: "high", description: ""),
                .init(reasoningEffort: "future-depth", description: "")
            ],
            defaultReasoningEffort: "future-depth"
        )
        let mapped = CodexDynamicModelMapper.options(from: [remote])
        XCTAssertFalse(mapped.isEmpty)
        XCTAssertTrue(mapped.allSatisfy {
            $0.supportedReasoningEffortRawValues == ["high", "future-depth", "future-depth"]
        })
        let projected = AgentCodexModelRegistry().resolvedOptions(
            staticOptions: [], preferredLiveModels: [remote]
        )
        XCTAssertTrue(projected.contains {
            $0.rawValue == "future-codex-high"
                && $0.effortVariant?.baseModelRaw == "future-codex"
                && $0.supportedReasoningEffortRawValues.contains("future-depth")
        })
    }

    func testCodexStoreRoundTripsUnknownRawEffortAndDefault() throws {
        let suite = "RoutingCodexRawEffort.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let remote = CodexAppServerClient.RemoteModel(
            id: "future-codex", model: "future-codex", displayName: "Future Codex",
            description: "", isDefault: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: "high", description: ""),
                .init(reasoningEffort: "future-depth", description: "")
            ],
            defaultReasoningEffort: "future-depth"
        )
        CodexDynamicModelStore.save([remote], defaults: defaults)
        let loaded = try XCTUnwrap(CodexDynamicModelStore.load(defaults: defaults).first)
        XCTAssertEqual(loaded.supportedReasoningEfforts.map(\.reasoningEffort), ["high", "future-depth"])
        XCTAssertEqual(loaded.defaultReasoningEffort, "future-depth")
        let projected = CodexDynamicModelStore.modelOptions(defaults: defaults)
        XCTAssertTrue(projected.allSatisfy { $0.supportedReasoningEffortRawValues.contains("future-depth") })
    }

    func testFastCodexVariantsRetainServiceTierInTheirBaseTarget() throws {
        let remote = CodexAppServerClient.RemoteModel(
            id: "gpt-6-sol",
            model: "gpt-6-sol",
            displayName: "GPT-6 Sol",
            description: "",
            isDefault: false,
            supportedReasoningEfforts: [.init(reasoningEffort: "high", description: "")],
            defaultReasoningEffort: "high"
        )
        let options = AgentCodexModelRegistry().resolvedOptions(
            staticOptions: [], preferredLiveModels: [remote]
        )
        let fast = try XCTUnwrap(options.first { $0.rawValue == "gpt-6-sol-fast-high" })
        XCTAssertEqual(fast.effortVariant?.baseModelRaw, "gpt-6-sol-fast")
        let snapshot = builder([.codexExec: options]).capture(
            allowedProviders: [.codexExec], availability: available
        )
        let fastModel = try XCTUnwrap(snapshot.models.first { $0.baseModelRaw == "gpt-6-sol-fast" })
        XCTAssertEqual(fastModel.efforts.first?.executableTarget?.modelRaw, "gpt-6-sol-fast")
        XCTAssertEqual(fastModel.efforts.first?.executableTarget?.reasoningEffortRaw, "high")
    }

    func testACPCatalogRoundTripsUnknownEffortRawWithoutAuthorizingExecution() throws {
        let suite = "RoutingRawEffort.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = ACPDiscoveredSessionModels(
            options: [AgentModelOption(
                rawValue: "acp-future",
                displayName: "acp-future",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: false,
                supportedReasoningEffortRawValues: ["future-depth", "high"],
                defaultReasoningEffortRawValue: "future-depth"
            )],
            currentModelRaw: "acp-future"
        )
        ACPDynamicModelStore.save(source, for: .openCode, defaults: defaults)
        let loaded = try XCTUnwrap(ACPDynamicModelStore.load(providerID: .openCode, defaults: defaults))
        XCTAssertEqual(loaded.options.first?.supportedReasoningEffortRawValues, ["future-depth", "high"])
        XCTAssertEqual(loaded.options.first?.defaultReasoningEffortRawValue, "future-depth")
        let metadata = builder([.openCode: loaded.options]).capture(
            allowedProviders: [.openCode], availability: available
        )
        XCTAssertEqual(metadata.models.first?.efforts.map(\.id.rawValue), ["future-depth", "high"])
        XCTAssertEqual(metadata.models.first?.efforts.map(\.isExecutable), [false, false])
        XCTAssertEqual(metadata.models.first?.defaultEffortID?.rawValue, "future-depth")
    }

    func testCuratedFrontierIsDeterministicBoundedAndExcludesAdvertisedACPProvider() throws {
        let catalog: [AgentProviderKind: [AgentModelOption]] = [
            .codexExec: [option("gpt-6-sol"), option("gpt-6-luna"), option("gpt-6-astra")],
            .claudeCode: [option("claude-sonnet-5"), option("claude-opus-5-5")],
            .openCode: [option("opencode-new")]
        ]
        var next = 0
        let builder = builder(catalog) { next += 1
            return "choice-\(next)"
        }
        let snapshot = builder.capture(allowedProviders: Set(catalog.keys), availability: available)
        let references: [AgentTaskRoutingCandidateBuilder.RoleDefaultReference] = [
            .init(roleLabel: "Engineer", provider: .codexExec, modelRaw: "gpt-6-sol", isUserOverride: true)
        ]
        let first = try builder.build(snapshot: snapshot, roleDefaults: references, maximumChoices: 4)
        let second = try builder.build(snapshot: snapshot, roleDefaults: references, maximumChoices: 4)
        XCTAssertEqual(first.map(\.target), second.map(\.target))
        XCTAssertEqual(first.map(\.target.modelRaw), ["gpt-6-sol", "gpt-6-astra", "gpt-6-luna", "claude-opus-5-5"])
        XCTAssertTrue(try XCTUnwrap(first.first { $0.target.modelRaw == "gpt-6-sol" }).descriptor.targetDescription.contains("Engineer (user-set)"))
        XCTAssertFalse(first.contains { $0.target.agentRaw == AgentProviderKind.openCode.rawValue })
    }

    func testRoleReferencesDoNotReorderCuratedShortlist() throws {
        let catalog: [AgentProviderKind: [AgentModelOption]] = [
            .codexExec: [option("gpt-6-sol"), option("gpt-6-luna")],
            .claudeCode: [option("claude-sonnet-5"), option("claude-opus-5-5")]
        ]
        let references: [AgentTaskRoutingCandidateBuilder.RoleDefaultReference] = [
            .init(roleLabel: "Engineer", provider: .claudeCode, modelRaw: "claude-opus-5-5", isUserOverride: true)
        ]
        let candidates = try builder(catalog).build(
            allowedProviders: Set(catalog.keys), availability: available,
            roleDefaults: references, maximumChoices: 4
        )
        XCTAssertEqual(candidates.map(\.target.modelRaw), ["gpt-6-sol", "gpt-6-luna", "claude-opus-5-5", "claude-sonnet-5"])
        XCTAssertTrue(candidates.first { $0.target.modelRaw == "claude-opus-5-5" }?.descriptor.targetDescription.contains("Engineer (user-set)") == true)
    }

    func testInsufficientServiceCapacityFallsBackBeforeCallingService() {
        let builder = builder([.codexExec: [option("gpt-6-luna"), option("gpt-6-sol")]])
        let snapshot = builder.capture(allowedProviders: [.codexExec], availability: available)
        XCTAssertThrowsError(try builder.build(snapshot: snapshot, maximumChoices: 1)) { error in
            XCTAssertEqual(error as? AgentTaskRoutingCandidateBuilder.BuildError, .insufficientCapacity)
        }
    }

    func testSnapshotRejectsEffortDecisionAfterCatalogChanges() throws {
        let originalBuilder = builder([.codexExec: [option("gpt-6-sol", rawEfforts: ["high"]), option("gpt-6-luna")]])
        let original = originalBuilder.capture(allowedProviders: [.codexExec], availability: available)
        let selected = try XCTUnwrap(originalBuilder.build(snapshot: original).first { $0.target.modelRaw == "gpt-6-sol" })
        let changedBuilder = builder([.codexExec: [option("gpt-6-sol", rawEfforts: ["low"]), option("gpt-6-luna")]])
        let changed = changedBuilder.capture(allowedProviders: [.codexExec], availability: available)
        XCTAssertThrowsError(try changedBuilder.buildEfforts(for: selected, snapshot: changed))
    }
}
