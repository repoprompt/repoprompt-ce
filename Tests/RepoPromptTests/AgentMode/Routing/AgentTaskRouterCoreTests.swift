import Foundation
@testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import XCTest

final class AgentTaskRouterCoreTests: XCTestCase {
    func testLongRoutingExcerptIsDeterministicBoundedAndMasksBothEnds() {
        let task = "Investigate the parser. password=openingSecret "
            + String(repeating: "irrelevant middle ", count: 300)
            + " Finally, verify the fix. token=endingSecret"
        let excerpt = AgentTaskRoutingTaskExcerpt.make(from: task)
        XCTAssertEqual(excerpt, AgentTaskRoutingTaskExcerpt.make(from: task))
        XCTAssertTrue(excerpt.contains("Investigate the parser"))
        XCTAssertTrue(excerpt.contains("verify the fix"))
        XCTAssertTrue(excerpt.contains("middle omitted"))
        XCTAssertFalse(excerpt.contains("openingSecret"))
        XCTAssertFalse(excerpt.contains("endingSecret"))
        XCTAssertLessThanOrEqual(excerpt.count, AgentTaskRoutingTaskExcerpt.maximumCharacters)
        XCTAssertLessThanOrEqual(excerpt.utf8.count, AgentTaskRoutingTaskExcerpt.maximumUTF8Bytes)
    }

    func testLongRoutingExcerptOmitsUnsafeCutSegments() {
        let task = "```\nprivate text\n" + String(repeating: "secret", count: 1000)
            + "\n```\nPlease inspect the result."
        let excerpt = AgentTaskRoutingTaskExcerpt.make(from: task)
        XCTAssertFalse(excerpt.contains("private text"))
        XCTAssertFalse(excerpt.contains("secret"))
        XCTAssertTrue(excerpt.contains("middle omitted"))
    }

    func testShortRoutingTaskRemainsExact() {
        XCTAssertEqual(AgentTaskRoutingTaskExcerpt.make(from: "  Implement a parser  "), "Implement a parser")
    }

    func testLongRoutingExcerptRespectsUTF8Limit() {
        let task = "Review Unicode handling. " + String(repeating: "✈️ ", count: 3000)
            + " Finally, add tests."
        let excerpt = AgentTaskRoutingTaskExcerpt.make(from: task)
        XCTAssertTrue(excerpt.contains("middle omitted"))
        XCTAssertTrue(excerpt.contains("add tests"))
        XCTAssertLessThanOrEqual(excerpt.utf8.count, AgentTaskRoutingTaskExcerpt.maximumUTF8Bytes)
    }

    func testExecutableIdentityIncludesEffortAndNormalizedACPParameters() {
        let low = AgentRoutingExecutableTarget(
            agentRaw: "grokBuild", modelRaw: "grok", reasoningEffortRaw: "low", modelParameters: []
        )
        let high = AgentRoutingExecutableTarget(
            agentRaw: "grokBuild", modelRaw: "grok", reasoningEffortRaw: "high", modelParameters: []
        )
        XCTAssertNotEqual(low, high)

        let first = ACPModelParameterSelection(
            providerID: .openCode, baseModelRaw: "model", kind: .thinking, configID: "effort", valueRaw: "low"
        )
        let second = ACPModelParameterSelection(
            providerID: .openCode, baseModelRaw: "model", kind: .speed, configID: "tier", valueRaw: "fast"
        )
        let ordered = AgentRoutingExecutableTarget(
            agentRaw: "openCode", modelRaw: "model", reasoningEffortRaw: nil, modelParameters: [first, second]
        )
        let reversed = AgentRoutingExecutableTarget(
            agentRaw: "openCode", modelRaw: "model", reasoningEffortRaw: nil, modelParameters: [second, first]
        )
        XCTAssertEqual(ordered, reversed)
    }
}

@MainActor
final class AgentTaskRoutingCandidateBuilderPolicyTests: XCTestCase {
    private static let advertisedCodexOptions = [
        modelOption("gpt-5.6-luna-low", "GPT-5.6 Luna Low"),
        modelOption("gpt-5.6-terra-medium", "GPT-5.6 Terra Medium"),
        modelOption("gpt-5.6-sol-high", "GPT-5.6 Sol High"),
        modelOption("gpt-6-luna-low", "GPT-6 Luna Low"),
        modelOption("gpt-6-sol-medium", "GPT-6 Sol Medium"),
        modelOption("gpt-6-sol-high", "GPT-6 Sol High"),
        modelOption("gpt-6-astra", "GPT-6 Astra")
    ]

    private static let advertisedClaudeOptions = [
        modelOption("claude-haiku-4-5", "Claude Haiku 4.5"),
        modelOption("claude-sonnet-5", "Claude Sonnet 5"),
        modelOption("opus", "Claude Opus"),
        modelOption("claude-opus-5-5", "Claude Opus 5.5"),
        modelOption("claude-fable-5-1", "Claude Fable 5.1")
    ]

    private static func modelOption(_ raw: String, _ name: String) -> AgentModelOption {
        let codex = raw.hasPrefix("gpt-") ? CodexModelSpecifier(raw: raw, discoveredRecords: []) : nil
        let claude = raw.hasPrefix("claude-") ? ClaudeModelSpecifier(raw: raw) : nil
        let effort = codex?.reasoningEffort ?? claude?.effortLevel.flatMap { CodexReasoningEffort.parse($0.rawValue) }
        let base = codex.flatMap { specifier in
            specifier.baseModel.map { $0 + (specifier.serviceTier == nil ? "" : "-fast") }
        } ?? claude?.baseModel
        return AgentModelOption(
            rawValue: raw, displayName: name, description: nil, isDefault: false,
            effortVariant: effort.flatMap { effort in base.map { AgentModelEffortVariant(baseModelRaw: $0, reasoningEffort: effort) } }
        )
    }

    private func candidateBuilder(
        codexOptions: [AgentModelOption]? = nil,
        claudeOptions: [AgentModelOption]? = nil,
        openCodeOptions: [AgentModelOption] = []
    ) -> AgentTaskRoutingCandidateBuilder {
        let codexOptions = codexOptions ?? Self.advertisedCodexOptions
        let claudeOptions = claudeOptions ?? Self.advertisedClaudeOptions
        return AgentTaskRoutingCandidateBuilder(modelOptions: { provider, _ in
            switch provider {
            case .codexExec: codexOptions
            case .claudeCode: claudeOptions
            case .openCode: openCodeOptions
            default: []
            }
        })
    }

    func testModelCandidatesIncludeAuditedCapabilityAndPricingWithoutPreselectedEffort() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )

        let candidates = try candidateBuilder().build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        )

        let lunaCandidate = try XCTUnwrap(candidates.first(where: {
            CodexModelSpecifier(raw: $0.target.modelRaw).baseModel == "gpt-6-luna"
        }))
        XCTAssertEqual(lunaCandidate.utilityTier, "gpt-6-luna")
        XCTAssertTrue(lunaCandidate.descriptor.targetDescription.contains("light, high-volume"))
        XCTAssertTrue(lunaCandidate.descriptor.targetDescription.contains("not intended for substantive implementation"))
        XCTAssertTrue(lunaCandidate.descriptor.targetDescription.contains("$0.10 input / $0.50 output"))
        XCTAssertNil(lunaCandidate.target.reasoningEffortRaw)
        XCTAssertFalse(lunaCandidate.descriptor.targetDescription.contains("Effort:"))
        XCTAssertEqual(lunaCandidate.descriptor.rubricVersion, RoutingModelProfileResolver.bundled.rubricVersion)

        let fableCandidate = try XCTUnwrap(candidates.first(where: {
            ClaudeModelSpecifier(raw: $0.target.modelRaw).baseModel == AgentModel.claudeFable51.rawValue
        }))
        XCTAssertEqual(fableCandidate.utilityTier, "claude-fable")
        XCTAssertTrue(fableCandidate.descriptor.targetDescription.contains("Terminal-Bench 4.0"))
        XCTAssertTrue(fableCandidate.descriptor.targetDescription.contains("$10 input / $50 output"))
        XCTAssertNil(fableCandidate.target.reasoningEffortRaw)

        let opusCandidate = try XCTUnwrap(candidates.first(where: {
            ClaudeModelSpecifier(raw: $0.target.modelRaw).baseModel == AgentModel.claudeOpus55.rawValue
        }))
        XCTAssertEqual(opusCandidate.utilityTier, "claude-opus")
        XCTAssertTrue(opusCandidate.descriptor.targetDescription.contains("recommended starting point for most workloads"))
        XCTAssertTrue(opusCandidate.descriptor.targetDescription.contains("$4 input / $20 output"))
    }

    func testModelFamilyAvailabilityProjectsPartialNoAndFullCatalogsWithoutChangingCandidates() throws {
        let fullAvailability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let fullBuilder = candidateBuilder()
        let candidatesBefore = try fullBuilder.build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: fullAvailability
        ).map(\.target)
        let full = fullBuilder.modelFamilyAvailability(availability: fullAvailability)
        let candidatesAfter = try fullBuilder.build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: fullAvailability
        ).map(\.target)

        XCTAssertEqual(full.map(\.displayName), ["Luna", "Terra", "Sol", "Astra", "Haiku", "Sonnet", "Opus", "Fable"])
        XCTAssertTrue(full.allSatisfy(\.isAvailable))
        XCTAssertEqual(candidatesAfter, candidatesBefore)

        let partial = candidateBuilder(codexOptions: [Self.modelOption("gpt-6-luna-low", "GPT-6 Luna Low")])
            .modelFamilyAvailability(availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false
            ))
        XCTAssertEqual(partial.filter(\.isAvailable).map(\.displayName), ["Luna"])
        XCTAssertEqual(
            partial.first(where: { $0.displayName == "Terra" })?.unavailableReason,
            "Codex CLI does not advertise a supported Terra model."
        )
        XCTAssertEqual(
            partial.first(where: { $0.displayName == "Opus" })?.unavailableReason,
            "Claude Code not connected."
        )

        let none = candidateBuilder().modelFamilyAvailability(availability: .init(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: false
        ))
        XCTAssertEqual(none.count, 8)
        XCTAssertTrue(none.allSatisfy { !$0.isAvailable })
        XCTAssertEqual(Set(none.compactMap(\.unavailableReason)), ["Codex CLI not connected.", "Claude Code not connected."])
    }

    func testClaudeOpusAliasIsFallbackWhenPinned55IsUnavailable() throws {
        let claudeOptions = Self.advertisedClaudeOptions.filter {
            $0.rawValue != AgentModel.claudeOpus55.rawValue
        }
        let candidates = try candidateBuilder(claudeOptions: claudeOptions).build(
            allowedProviders: [.claudeCode],
            availability: .init(claudeCodeAvailable: true, codexAvailable: false, openCodeAvailable: false)
        )

        let opusCandidate = try XCTUnwrap(candidates.first { $0.utilityTier == "claude-opus" })
        XCTAssertEqual(opusCandidate.target.modelRaw, "opus")
    }

    func testGPT6EffortAndAgentModelResolution() {
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-6-sol-max").reasoningEffort, .max)
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-6-sol-xhigh").reasoningEffort, .xhigh)
        XCTAssertNil(CodexModelSpecifier(raw: "gpt-6-sol-ultra").reasoningEffort)
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-6-sol-max", agentKind: .codexExec), .gpt6SolMax)
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-6-luna-low", agentKind: .codexExec), .gpt6LunaLow)
    }

    func testRoutingPrefersGPT61SolAndSonnet55WhenAdvertised() throws {
        let codexOptions = Self.advertisedCodexOptions + [
            Self.modelOption("gpt-6.1-sol-medium", "GPT-6.1 Sol Medium"),
            Self.modelOption("gpt-6.1-sol-high", "GPT-6.1 Sol High")
        ]
        let claudeOptions = Self.advertisedClaudeOptions + [
            Self.modelOption("claude-sonnet-5-5", "Claude Sonnet 5.5")
        ]
        let candidates = try candidateBuilder(codexOptions: codexOptions, claudeOptions: claudeOptions).build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: .init(claudeCodeAvailable: true, codexAvailable: true, openCodeAvailable: false)
        )

        let solCandidate = try XCTUnwrap(candidates.first {
            CodexModelSpecifier(raw: $0.target.modelRaw).baseModel?.hasSuffix("-sol") == true
        })
        XCTAssertEqual(CodexModelSpecifier(raw: solCandidate.target.modelRaw).baseModel, "gpt-6.1-sol")
        XCTAssertTrue(solCandidate.descriptor.targetDescription.contains("GPT-6.1 Sol"))
        XCTAssertTrue(solCandidate.descriptor.targetDescription.contains("$2 input / $10 output"))
        XCTAssertFalse(solCandidate.descriptor.targetDescription.contains("No verified API list price"))

        let sonnetCandidate = try XCTUnwrap(candidates.first { $0.utilityTier == "claude-sonnet" })
        XCTAssertEqual(ClaudeModelSpecifier(raw: sonnetCandidate.target.modelRaw).baseModel, "claude-sonnet-5-5")
        XCTAssertTrue(sonnetCandidate.descriptor.targetDescription.contains("Claude Sonnet 5.5"))
        XCTAssertTrue(sonnetCandidate.descriptor.targetDescription.contains("$2 input / $10 output"))
        XCTAssertFalse(sonnetCandidate.descriptor.targetDescription.contains("No verified API list price"))

        XCTAssertEqual(
            AutoEffortModelPolicy.codexEfforts(modelRaw: "gpt-6.1-sol-high", advertised: [.low, .medium, .high, .xhigh, .max, .ultra]),
            ["low", "medium", "high", "xhigh", "max"]
        )
        XCTAssertEqual(
            AutoEffortModelPolicy.claudeEfforts(modelRaw: "claude-sonnet-5-5:high", advertised: [.low, .medium, .high, .xhigh, .max]),
            ["low", "medium", "high", "xhigh", "max"]
        )
    }

    func testApprovedCodexFamilySelectionTracksNewestAdvertisedVersionOnly() throws {
        let options = [
            AgentModelOption(rawValue: "gpt-5.6-sol-high", displayName: "GPT-5.6 Sol High", description: nil, isDefault: false),
            AgentModelOption(rawValue: "gpt-6-sol-high", displayName: "GPT-6 Sol High", description: nil, isDefault: false),
            AgentModelOption(rawValue: "gpt-7-sol-high", displayName: "GPT-7 Sol High", description: nil, isDefault: false),
            AgentModelOption(rawValue: "gpt-99-nova-high", displayName: "GPT-99 Nova High", description: nil, isDefault: false)
        ]

        let selected = try XCTUnwrap(AgentModelCatalog.preferredCodexFamilyOption("sol", from: options))

        XCTAssertEqual(CodexModelSpecifier(raw: selected.rawValue).baseModel, "gpt-7-sol")
        XCTAssertNil(AgentModelCatalog.preferredCodexFamilyOption("nova", from: Array(options.prefix(3))))
    }

    func testAutomaticModelCandidatesPreserveCuratedFamiliesAndExcludeNoncuratedCatalogTargets() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: true
        )
        let builder = candidateBuilder(
            codexOptions: Self.advertisedCodexOptions + [Self.modelOption("gpt-99-nova", "Unknown Codex")],
            openCodeOptions: [Self.modelOption("gpt-6-sol", "OpenCode Sol")]
        )
        let snapshot = builder.capture(
            allowedProviders: [.claudeCode, .codexExec, .openCode],
            availability: availability
        )
        XCTAssertTrue(snapshot.models.contains { $0.provider == .openCode && $0.baseModelRaw == "gpt-6-sol" })

        let candidates = try builder.build(snapshot: snapshot)

        // Strongest-first within each provider so judge position bias and truncation favor capability.
        XCTAssertEqual(candidates.map(\.target.modelRaw), [
            "gpt-6-sol", "gpt-6-astra", "gpt-5.6-terra", "gpt-6-luna",
            "claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5", "claude-haiku-4-5"
        ])
        XCTAssertEqual(candidates.map(\.utilityTier), [
            "gpt-6-sol", "gpt-6-astra", "gpt-5.6-terra", "gpt-6-luna",
            "claude-opus", "claude-fable", "claude-sonnet", "claude-haiku"
        ])
        XCTAssertFalse(candidates.contains { $0.target.agentRaw == AgentProviderKind.openCode.rawValue })
        XCTAssertTrue(candidates.first { $0.utilityTier == "gpt-6-luna" }?.descriptor.rubric.contains("Not suitable for implementation") == true)
        XCTAssertTrue(candidates.first { $0.utilityTier == "gpt-5.6-terra" }?.descriptor.rubric.contains("previous-generation") == true)
        XCTAssertTrue(candidates.first { $0.target.modelRaw == "gpt-6-sol" }?.descriptor.rubric.contains("missed findings and retries") == true)
        XCTAssertTrue(candidates.first { $0.utilityTier == "gpt-6-astra" }?.descriptor.rubric.contains("premium price") == true)
        XCTAssertFalse(candidates.contains { $0.descriptor.rubric.contains("no preference from its market tier") })
    }

    func testPrimarySessionFloorExcludesLightAndBalancedFamiliesBeforeTruncation() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let builder = candidateBuilder(codexOptions: Self.advertisedCodexOptions)
        let snapshot = builder.capture(allowedProviders: [.claudeCode, .codexExec], availability: availability)

        let primary = try builder.build(
            snapshot: snapshot,
            usagePeerClasses: AgentTaskRoutingCandidateBuilder.primarySessionUsagePeerClasses
        )
        XCTAssertEqual(primary.map(\.utilityTier), ["gpt-6-sol", "gpt-6-astra", "claude-opus", "claude-fable"])
        XCTAssertTrue(primary.allSatisfy { ["strong", "frontier"].contains($0.usagePeerClass) })

        let truncated = try builder.build(
            snapshot: snapshot,
            maximumChoices: 2,
            usagePeerClasses: AgentTaskRoutingCandidateBuilder.primarySessionUsagePeerClasses
        )
        XCTAssertEqual(truncated.map(\.utilityTier), ["gpt-6-sol", "gpt-6-astra"], "Excluded tiers must not consume choice capacity")

        let subagent = try builder.build(snapshot: snapshot)
        XCTAssertTrue(subagent.contains { $0.utilityTier == "gpt-6-luna" }, "Subagent routing keeps the full curated frontier")
    }

    func testUnknownFamiliesDoNotEnableAutomaticRouter() {
        let builder = candidateBuilder(
            codexOptions: [Self.modelOption("gpt-99-nova", "Nova"), Self.modelOption("future-codex", "Future")],
            claudeOptions: []
        )
        XCTAssertThrowsError(try builder.build(
            allowedProviders: [.codexExec],
            availability: .init(claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false)
        )) { error in
            XCTAssertEqual(error as? AgentTaskRoutingCandidateBuilder.BuildError, .noAvailableTargets)
        }
    }

    func testTipModelEvidenceSurvivesBundledProfileMigration() throws {
        let builder = candidateBuilder(
            codexOptions: [Self.modelOption("gpt-6.1-sol-high", "GPT-6.1 Sol High")],
            claudeOptions: [Self.modelOption("claude-sonnet-5-5", "Claude Sonnet 5.5")]
        )
        let models = try builder.build(
            allowedProviders: [.codexExec, .claudeCode],
            availability: .init(claudeCodeAvailable: true, codexAvailable: true, openCodeAvailable: false)
        )
        XCTAssertEqual(Set(models.map(\.target.modelRaw)), ["gpt-6.1-sol", "claude-sonnet-5-5"])
        XCTAssertTrue(models.allSatisfy { $0.descriptor.targetDescription.contains("$2 input / $10 output") })
        XCTAssertTrue(models.allSatisfy { $0.profileIdentity != nil })
    }

    func testPaidFastExpansionOmitsAllFastChoicesWhenItWouldExceedSharedCapacity() throws {
        let efforts = ["minimal", "low", "medium", "high", "xhigh", "max"]
        let options = efforts.flatMap { effort in
            [
                Self.modelOption("gpt-6-sol-\(effort)", "Sol \(effort)"),
                Self.modelOption("gpt-6-sol-fast-\(effort)", "Sol Fast \(effort)")
            ]
        }
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false
        )
        let builder = candidateBuilder(codexOptions: options)
        let model = try XCTUnwrap(
            builder.build(allowedProviders: [.codexExec], availability: availability)
                .first { $0.target.modelRaw == "gpt-6-sol" }
        )
        let candidates = try builder.buildEfforts(for: model, availability: availability, allowPaidFast: true)
        XCTAssertEqual(candidates.count, 7, "The base and every ordinary effort must remain available")
        XCTAssertFalse(candidates.contains { AgentTaskRoutingCandidateBuilder.isPaidFast($0.target) })
        XCTAssertEqual(Set(candidates.compactMap(\.target.reasoningEffortRaw)), Set(efforts))
    }

    func testPaidFastExpansionRespectsServiceCapacityWithoutTruncatingOrdinaryChoices() throws {
        let efforts = ["low", "medium", "high"]
        let options = efforts.flatMap { effort in
            [
                Self.modelOption("gpt-6-sol-\(effort)", "Sol \(effort)"),
                Self.modelOption("gpt-6-sol-fast-\(effort)", "Sol Fast \(effort)")
            ]
        }
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false
        )
        let builder = candidateBuilder(codexOptions: options)
        let model = try XCTUnwrap(
            builder.build(allowedProviders: [.codexExec], availability: availability)
                .first { $0.target.modelRaw == "gpt-6-sol" }
        )
        let exactFit = try builder.buildEfforts(
            for: model, availability: availability, allowPaidFast: true, maximumChoices: 8
        )
        XCTAssertEqual(exactFit.count, 8)
        XCTAssertEqual(exactFit.count(where: { AgentTaskRoutingCandidateBuilder.isPaidFast($0.target) }), 4)
        let limited = try builder.buildEfforts(
            for: model, availability: availability, allowPaidFast: true, maximumChoices: 7
        )
        XCTAssertEqual(limited.count, 4)
        XCTAssertFalse(limited.contains { AgentTaskRoutingCandidateBuilder.isPaidFast($0.target) })
        XCTAssertEqual(Set(limited.compactMap(\.target.reasoningEffortRaw)), Set(efforts))
        XCTAssertThrowsError(try builder.buildEfforts(
            for: model, availability: availability, allowPaidFast: true, maximumChoices: 3
        )) { error in
            XCTAssertEqual(error as? AgentTaskRoutingCandidateBuilder.BuildError, .insufficientCapacity)
        }
    }

    func testPaidFastNeverEntersAutomaticEffortsWithoutExplicitOptIn() throws {
        let options = ["gpt-6.1-sol-high", "gpt-6.1-sol-fast", "gpt-6.1-sol-fast-high"].map {
            Self.modelOption($0, $0)
        }
        let availability = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false)
        let builder = candidateBuilder(codexOptions: options)
        let models = try builder.build(allowedProviders: [.codexExec], availability: availability)
        XCTAssertTrue(models.allSatisfy { !AgentTaskRoutingCandidateBuilder.isPaidFast($0.target) })
        let selected = try XCTUnwrap(models.first)
        let ordinary = try builder.buildEfforts(for: selected, availability: availability)
        XCTAssertFalse(ordinary.isEmpty)
        XCTAssertTrue(ordinary.allSatisfy { !AgentTaskRoutingCandidateBuilder.isPaidFast($0.target) })
        let optedIn = try builder.buildEfforts(for: selected, availability: availability, allowPaidFast: true)
        XCTAssertTrue(optedIn.contains { AgentTaskRoutingCandidateBuilder.isPaidFast($0.target) })
    }

    func testStandalonePeersKeepClassAndAdvertisedEffortWithoutFast() throws {
        let availability = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: true, codexAvailable: true, openCodeAvailable: false)
        let claudeHigh = ClaudeModelSpecifier.encodedRaw(baseModelRaw: "claude-opus-5-5", effort: .high)
        let builder = candidateBuilder(claudeOptions: Self.advertisedClaudeOptions + [Self.modelOption(claudeHigh, "Opus High")])
        let input = try XCTUnwrap(builder.usageCandidates(
            basedOn: .init(agentRaw: AgentProviderKind.codexExec.rawValue, modelRaw: "gpt-6-sol-high", reasoningEffortRaw: "high", modelParameters: []),
            allowedProviders: [.claudeCode, .codexExec], availability: availability, surface: .headless
        ))
        XCTAssertEqual(input.selected.target.modelRaw, "gpt-6-sol-high")
        let peer = try XCTUnwrap(input.candidates.first { $0.target.agentRaw == AgentProviderKind.claudeCode.rawValue })
        XCTAssertEqual(peer.usagePeerClass, input.selected.usagePeerClass)
        let captured = builder.capture(allowedProviders: [.claudeCode, .codexExec], availability: availability, surface: .headless)
        XCTAssertEqual(peer.snapshotScope, captured.scope)
        XCTAssertTrue(captured.contains(peer.target))
        XCTAssertNotNil(peer.profileIdentity)
        XCTAssertEqual(ClaudeModelSpecifier(raw: peer.target.modelRaw).effortLevel?.rawValue, "high")
        XCTAssertFalse(AgentTaskRoutingCandidateBuilder.isPaidFast(peer.target))
        let reverse = try XCTUnwrap(builder.usageCandidates(basedOn: peer.target, allowedProviders: [.claudeCode, .codexExec], availability: availability, surface: .headless))
        let reversePeer = try XCTUnwrap(reverse.candidates.first { $0.target.agentRaw == AgentProviderKind.codexExec.rawValue })
        XCTAssertEqual(reversePeer.target.reasoningEffortRaw, "high")
        let unsupported = try XCTUnwrap(candidateBuilder().usageCandidates(basedOn: input.selected.target, allowedProviders: [.claudeCode, .codexExec], availability: availability, surface: .headless))
        XCTAssertEqual(unsupported.candidates.count, 1, "No exact advertised effort means no swap—not a provider-default downgrade")
        let limited = try XCTUnwrap(builder.usageCandidates(basedOn: input.selected.target, allowedProviders: [.codexExec], availability: availability, surface: .general))
        XCTAssertEqual(limited.candidates.count, 1)
        XCTAssertNil(builder.usageCandidates(basedOn: .init(agentRaw: "codexExec", modelRaw: "default", reasoningEffortRaw: nil, modelParameters: []), allowedProviders: [.codexExec, .claudeCode], availability: availability, surface: .general))
    }

    func testEffortCandidatesAreBuiltOnlyAfterModelSelection() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let builder = candidateBuilder()
        let model = try XCTUnwrap(builder.build(
            allowedProviders: [.codexExec],
            availability: availability
        ).first(where: { $0.target.modelRaw == "gpt-6-sol" }))

        let efforts = try builder.buildEfforts(for: model, availability: availability)

        XCTAssertGreaterThan(efforts.count, 1)
        XCTAssertTrue(efforts.allSatisfy {
            CodexModelSpecifier(raw: $0.target.modelRaw).baseModel == model.target.modelRaw
        })
        XCTAssertTrue(Set(efforts.compactMap(\.target.reasoningEffortRaw)).contains("high"))
    }

    func testAgentModelDefaultsAreReferenceSignalsWithoutRestrictingCandidates() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let candidates = try candidateBuilder().build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability,
            roleDefaults: [
                .init(
                    roleLabel: "Engineer",
                    provider: .codexExec,
                    modelRaw: "gpt-6-sol-high",
                    isUserOverride: true
                )
            ]
        )

        XCTAssertGreaterThan(candidates.count, 1)
        let sol = try XCTUnwrap(candidates.first(where: { $0.target.modelRaw == "gpt-6-sol" }))
        XCTAssertTrue(sol.descriptor.targetDescription.contains("Engineer (user-set)"))
        XCTAssertTrue(sol.descriptor.targetDescription.contains("not constraints or automatic choices"))
        XCTAssertTrue(candidates.contains { $0.target.modelRaw == "gpt-5.6-terra" })
    }

    func testCodexCandidatesFallBackToGPT56BeforeDiscovery() throws {
        let codexOptions = Self.advertisedCodexOptions.filter {
            !$0.rawValue.hasPrefix("gpt-6-")
        }
        let candidates = try candidateBuilder(codexOptions: codexOptions).build(
            allowedProviders: [.codexExec],
            availability: .init(claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false)
        )

        XCTAssertEqual(Set(candidates.map(\.target.modelRaw)), [
            "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"
        ])
        XCTAssertFalse(candidates.contains { $0.target.modelRaw.hasPrefix("gpt-6-") })
    }

    func testUnknownModelEvidenceMakesCapabilityAndCostUncertaintyExplicit() {
        let metadata = RoutingExecutionModelMetadata(
            provider: .openCode, baseModelRaw: "future-model", displayName: "future-model",
            isProviderDefault: false, catalogOrder: 0, advertisedOptionRawValues: ["future-model"],
            defaultEffortID: nil, efforts: []
        )
        let resolver = RoutingModelProfileResolver.bundled
        let description = resolver.resolve(metadata, catalogRevision: "unknown-model-test")
            .description(snapshotDate: resolver.snapshotDate)

        XCTAssertTrue(description.contains("No audited benchmark or pricing profile"))
        XCTAssertTrue(description.contains("Treat capability and cost as uncertain"))
    }

    func testProviderDirectiveConstrainsAutomaticFrontier() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let candidates = try candidateBuilder().build(
            allowedProviders: [.claudeCode],
            availability: availability
        )

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.target.agentRaw == AgentProviderKind.claudeCode.rawValue })
    }

    func testAdvertisedModelsOutsideCuratedDefinitionsAreNotRouterCandidates() {
        let excludedProviders: [AgentProviderKind] = [.openCode, .cursor, .grokBuild, .devin]
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false, codexAvailable: false, openCodeAvailable: true,
            cursorAvailable: true, grokBuildAvailable: true, devinAvailable: true
        )
        let options: @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = { provider, _ in
            excludedProviders.contains(provider)
                ? [Self.modelOption("advertised-\(provider.rawValue)", provider.displayName)]
                : []
        }
        let builder = AgentTaskRoutingCandidateBuilder(modelOptions: options)

        XCTAssertTrue(AgentTaskRoutingCandidateBuilder.availableProviders(
            availability: availability,
            modelOptions: options
        ).isEmpty)
        XCTAssertThrowsError(try builder.build(
            allowedProviders: Set(excludedProviders),
            availability: availability
        )) { error in
            XCTAssertEqual(error as? AgentTaskRoutingCandidateBuilder.BuildError, .noAvailableTargets)
        }
    }

    func testUnavailableProviderPolicyFailsClosed() {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        XCTAssertThrowsError(try AgentTaskRoutingCandidateBuilder().build(
            allowedProviders: [],
            availability: availability
        ))
        XCTAssertThrowsError(try AgentTaskRoutingCandidateBuilder().build(
            allowedProviders: [.openCode],
            availability: availability
        ))
    }
}

/// `hasAvailableTarget` is the Model Router status pill's availability probe. It must answer exactly
/// what a non-empty `build` answers while never constructing candidates.
@MainActor
final class AgentTaskRoutingCandidateBuilderAvailabilityTests: XCTestCase {
    private final class Counter {
        var value = 0
    }

    private struct OptionFixture {
        let name: String
        let codex: [AgentModelOption]
        let claude: [AgentModelOption]
    }

    private static func option(_ raw: String) -> AgentModelOption {
        let specifier = raw.hasPrefix("gpt-") ? CodexModelSpecifier(raw: raw, discoveredRecords: []) : nil
        return AgentModelOption(
            rawValue: raw,
            displayName: raw,
            description: nil,
            isDefault: false,
            effortVariant: specifier?.reasoningEffort.flatMap { effort in
                specifier?.baseModel.map { AgentModelEffortVariant(baseModelRaw: $0, reasoningEffort: effort) }
            }
        )
    }

    private static let fullCodex = [
        "gpt-5.6-luna-low", "gpt-5.6-terra-medium", "gpt-5.6-sol-high",
        "gpt-6-luna-low", "gpt-6-sol-medium", "gpt-6-sol-high"
    ].map(option)

    private static let fullClaude = [
        "claude-haiku-4-5", "claude-sonnet-5", "opus", "claude-opus-5-5", "claude-fable-5-1"
    ].map(option)

    private static let optionFixtures: [OptionFixture] = [
        OptionFixture(name: "full", codex: fullCodex, claude: fullClaude),
        OptionFixture(name: "empty", codex: [], claude: []),
        OptionFixture(name: "codex-only", codex: fullCodex, claude: []),
        OptionFixture(name: "claude-only", codex: [], claude: fullClaude),
        OptionFixture(
            name: "unrecognized",
            codex: ["gpt-99-nova-high", "not-a-model"].map(option),
            claude: ["claude-unknown-9", "not-a-model"].map(option)
        ),
        OptionFixture(
            name: "pre-gpt6-terra-and-opus-alias",
            codex: ["gpt-5.6-terra-medium"].map(option),
            claude: ["opus"].map(option)
        )
    ]

    private static let providerUniverse: [AgentProviderKind] = [
        .claudeCode, .codexExec, .openCode, .antigravity
    ]

    private static var providerSets: [Set<AgentProviderKind>] {
        (0 ..< (1 << providerUniverse.count)).map { mask in
            Set(providerUniverse.enumerated().compactMap { index, provider in
                mask & (1 << index) != 0 ? provider : nil
            })
        }
    }

    private static var availabilityContexts: [AgentModelCatalog.AvailabilityContext] {
        [false, true].flatMap { claude in
            [false, true].flatMap { codex in
                [false, true].map { openCode in
                    AgentModelCatalog.AvailabilityContext(
                        claudeCodeAvailable: claude,
                        codexAvailable: codex,
                        openCodeAvailable: openCode
                    )
                }
            }
        }
    }

    private func builder(
        _ fixture: OptionFixture,
        opaqueKeys: Counter = Counter(),
        optionReads: Counter = Counter()
    ) -> AgentTaskRoutingCandidateBuilder {
        AgentTaskRoutingCandidateBuilder(
            opaqueKey: {
                opaqueKeys.value += 1
                return "key-\(opaqueKeys.value)"
            },
            modelOptions: { provider, _ in
                optionReads.value += 1
                switch provider {
                case .codexExec: return fixture.codex
                case .claudeCode: return fixture.claude
                default: return []
                }
            }
        )
    }

    func testHasAvailableTargetMatchesNonEmptyBuildAcrossFixtureMatrix() {
        var outcomes: Set<Bool> = []
        for fixture in Self.optionFixtures {
            let builder = builder(fixture)
            for providers in Self.providerSets {
                for availability in Self.availabilityContexts {
                    for surface in [AgentModelCatalog.AgentSelectionSurface.general, .headless] {
                        let expected = (try? builder.build(
                            allowedProviders: providers,
                            availability: availability,
                            surface: surface
                        )) != nil
                        let actual = builder.hasAvailableTarget(
                            allowedProviders: providers,
                            availability: availability,
                            surface: surface
                        )
                        XCTAssertEqual(
                            actual,
                            expected,
                            "fixture=\(fixture.name) providers=\(providers.map(\.rawValue).sorted()) availability=\(availability) surface=\(surface)"
                        )
                        outcomes.insert(actual)
                    }
                }
            }
        }
        // The grid must exercise both answers, or the equivalence above proves nothing.
        XCTAssertEqual(outcomes, [true, false])
    }

    func testHasAvailableTargetStopsAtFirstResolvedDefinitionWithoutBuildingCandidates() throws {
        let fixture = Self.optionFixtures[0]
        let opaqueKeys = Counter()
        let optionReads = Counter()
        let builder = builder(fixture, opaqueKeys: opaqueKeys, optionReads: optionReads)
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )

        XCTAssertTrue(builder.hasAvailableTarget(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        ))
        // An opaque key is minted immediately before each candidate's display name and description
        // are rendered, so zero keys means no candidate was constructed. One catalog read means model
        // resolution stopped at the first eligible definition that resolved (eligibility filtering
        // itself is a cheap eager pass over the static definition table).
        XCTAssertEqual(opaqueKeys.value, 0)
        XCTAssertEqual(optionReads.value, 1)

        opaqueKeys.value = 0
        optionReads.value = 0
        let candidates = try builder.build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        )
        XCTAssertEqual(opaqueKeys.value, candidates.count)
        XCTAssertGreaterThan(optionReads.value, 1)
    }

    func testHasAvailableTargetReadsEveryEligibleDefinitionBeforeAnsweringNo() {
        let fixture = Self.optionFixtures[1]
        let opaqueKeys = Counter()
        let optionReads = Counter()
        let builder = builder(fixture, opaqueKeys: opaqueKeys, optionReads: optionReads)
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )

        XCTAssertFalse(builder.hasAvailableTarget(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        ))
        let noReads = optionReads.value
        optionReads.value = 0
        XCTAssertThrowsError(try builder.build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        ))
        XCTAssertEqual(noReads, optionReads.value)
        XCTAssertEqual(opaqueKeys.value, 0)
    }
}

@MainActor
final class AgentTaskRouterRuntimeTests: XCTestCase {
    func testDemandMatrixWithoutSettingsWindowAndNoSelectionInvalidation() async throws {
        let rows: [(Bool, String?, Bool, Set<DecisionServiceID>)] = [
            (false, "openai-decisions", false, []),
            (false, "unknown", true, [.jev]),
            (true, "jev", false, [.jev]),
            (true, "jev", true, [.jev]),
            (true, "openai-decisions", false, [.openAIDecisions]),
            (true, "openai-decisions", true, [.jev, .openAIDecisions]),
            (true, nil, false, []), (true, "unknown", false, []),
            (true, "  ", false, []), (true, "unknown", true, [.jev])
        ]
        for (enabled, raw, auto, expected) in rows {
            let source = RuntimeTestDemandSource(.init(routerEnabled: enabled, selectedBackendRawValue: raw, autoEffortEnabled: auto, routerRevision: 0))
            let jev = RuntimeTestController()
            let decisions = RuntimeTestController()
            let runtime = try makeRuntime(source, jev, decisions)
            await jev.waitUntilObserved()
            await decisions.waitUntilObserved()
            await runtime.reconcileDemand()
            let jevCalls = await jev.calls
            let decisionsCalls = await decisions.calls
            XCTAssertEqual(jevCalls, expected.contains(.jev) ? 1 : 0, "\(enabled)/\(String(describing: raw))/\(auto)")
            XCTAssertEqual(decisionsCalls, expected.contains(.openAIDecisions) ? 1 : 0)
            let invalidations = await jev.invalidations + decisions.invalidations
            XCTAssertEqual(invalidations, 0)
            await runtime.teardown()
            await jev.waitUntilTerminated()
            await decisions.waitUntilTerminated()
        }
    }

    func testIndependentAutoEffortServiceDemandCoversAllFourCombinationsAndUnknownIDs() async throws {
        let rows: [(String, String, Set<DecisionServiceID>)] = [
            ("jev", "jev", [.jev]),
            ("openai-decisions", "jev", [.jev, .openAIDecisions]),
            ("jev", "openai-decisions", [.jev, .openAIDecisions]),
            ("openai-decisions", "openai-decisions", [.openAIDecisions]),
            ("jev", "future-service", [.jev, .init(rawValue: "future-service")]),
            ("", "  ", [])
        ]
        for (router, auto, expected) in rows {
            let snapshot = AgentTaskRouterDemandSnapshot(
                routerEnabled: true, selectedBackendRawValue: router,
                autoEffortEnabled: true, routerRevision: 0,
                autoEffortBackendRawValue: auto, autoEffortRevision: 0
            )
            XCTAssertEqual(snapshot.requiredBackendIDs, expected)
            let source = RuntimeTestDemandSource(snapshot)
            let jev = RuntimeTestController()
            let decisions = RuntimeTestController()
            let runtime = try makeRuntime(source, jev, decisions)
            await jev.waitUntilObserved()
            await decisions.waitUntilObserved()
            await runtime.reconcileDemand()
            let counts = await (jev.calls, decisions.calls)
            XCTAssertEqual(counts.0, expected.contains(.jev) ? 1 : 0)
            XCTAssertEqual(counts.1, expected.contains(.openAIDecisions) ? 1 : 0)
            await runtime.teardown()
        }
    }

    func testRapidTransitionsAndGuidanceRevisionDoNotRebillFailedGeneration() async throws {
        let source = RuntimeTestDemandSource(.init(routerEnabled: true, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: true, routerRevision: 0))
        let jev = RuntimeTestController()
        let decisions = RuntimeTestController()
        let runtime = try makeRuntime(source, jev, decisions)
        await jev.waitUntilObserved()
        await decisions.waitUntilObserved()
        await runtime.reconcileDemand()
        source.set(.init(routerEnabled: true, selectedBackendRawValue: "jev", autoEffortEnabled: true, routerRevision: 1))
        source.set(.init(routerEnabled: true, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: true, routerRevision: 2))
        source.set(.init(routerEnabled: true, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: true, routerRevision: 3))
        await runtime.reconcileDemand()
        let counts = await (jev.calls, decisions.calls)
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        let invalidations = await (jev.invalidations, decisions.invalidations)
        XCTAssertEqual(invalidations.0, 0)
        XCTAssertEqual(invalidations.1, 0)
        await runtime.teardown()
    }

    func testValidatingControllerIsNotBootstrappedAndCachesStayPerID() async throws {
        let source = RuntimeTestDemandSource(.init(routerEnabled: true, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: true, routerRevision: 0))
        let jev = RuntimeTestController()
        let decisions = RuntimeTestController(state: .validating(generation: 7))
        let runtime = try makeRuntime(source, jev, decisions)
        await jev.waitUntilObserved()
        await decisions.waitUntilObserved()
        await runtime.reconcileDemand()
        let calls = await decisions.calls
        XCTAssertEqual(calls, 0)
        await decisions.set(.ready(generation: 8, policyVersion: "decisions-test"))
        await runtime.reconcileDemand()
        let ready = await decisions.readinessSnapshot()
        XCTAssertEqual(ready, .ready(generation: 8, policyVersion: "decisions-test"))
        XCTAssertFalse(runtime.isBackendReady(.jev))
        await runtime.teardown()
    }

    func testRapidABARechecksLatestDemandImmediatelyBeforeAdmission() async throws {
        let source = RuntimeTestDemandSource(.init(routerEnabled: true, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: false, routerRevision: 0))
        let jev = RuntimeTestController(gateAdmission: true)
        let decisions = RuntimeTestController(gateAdmission: true)
        let runtime = try makeRuntime(source, jev, decisions)
        await decisions.waitUntilAdmission()
        source.set(.init(routerEnabled: true, selectedBackendRawValue: "jev", autoEffortEnabled: false, routerRevision: 1))
        await runtime.reconcileDemand(waitForBootstrap: false)
        await jev.waitUntilAdmission()
        source.set(.init(routerEnabled: true, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: false, routerRevision: 2))
        await runtime.reconcileDemand(waitForBootstrap: false)
        await jev.releaseAdmission()
        await decisions.releaseAdmission()
        await runtime.reconcileDemand()
        let counts = await (jev.calls, decisions.calls)
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 1)
        await runtime.teardown()
    }

    func testExplicitValidationStreamWinsOverPendingBootstrapSnapshot() async throws {
        let source = RuntimeTestDemandSource(.init(routerEnabled: true, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: false, routerRevision: 0))
        let jev = RuntimeTestController()
        let decisions = RuntimeTestController(gateAdmission: true)
        let runtime = try makeRuntime(source, jev, decisions)
        await decisions.waitUntilAdmission()
        await decisions.set(.validating(generation: 0))
        try await waitForReadiness(.validating(generation: 0), id: .openAIDecisions, runtime: runtime)
        await decisions.releaseAdmission()
        await runtime.reconcileDemand()
        let calls = await decisions.calls
        XCTAssertEqual(calls, 0)
        await runtime.teardown()
    }

    func testOlderReadinessGenerationCannotReplaceCurrentProjection() async throws {
        let source = RuntimeTestDemandSource(.init(routerEnabled: false, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: false, routerRevision: 0))
        let jev = RuntimeTestController()
        let decisions = RuntimeTestController(state: .ready(generation: 5, policyVersion: "test"))
        let runtime = try makeRuntime(source, jev, decisions)
        await runtime.reconcileDemand()
        await decisions.set(.ready(generation: 6, policyVersion: "test"))
        try await waitForReadiness(.ready(generation: 6, policyVersion: "test"), id: .openAIDecisions, runtime: runtime)
        await decisions.set(.needsConfiguration(generation: 5, reason: "stale"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(runtime.backendReadiness(.openAIDecisions), .ready(generation: 6, policyVersion: "test"))
        await runtime.teardown()
    }

    func testTeardownDoesNotAwaitCancellationIgnoringBootstrapRead() async throws {
        let source = RuntimeTestDemandSource(.init(routerEnabled: true, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: false, routerRevision: 0))
        let jev = RuntimeTestController()
        let decisions = RuntimeTestController(gateAdmission: true)
        let runtime = try makeRuntime(source, jev, decisions)
        await decisions.waitUntilAdmission()
        let finished = expectation(description: "Runtime teardown finishes before bootstrap read resumes")
        let teardown = Task {
            await runtime.teardown()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        await decisions.releaseAdmission()
        await teardown.value
    }

    func testRevisionCancelsRoutesWithoutInvalidatingCredentialsOrRebootstrapping() async throws {
        let source = RuntimeTestDemandSource(.init(routerEnabled: true, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: false, routerRevision: 0))
        let controller = RuntimeTestController(state: .ready(generation: 4, policyVersion: "test"))
        let backend = RuntimeSuspendedBackend()
        let runtime = try AgentTaskRouterRuntime(registrations: [
            .init(
                service: backend,
                configuration: .init(presentation: testPresentation("test"), controller: controller)
            )
        ], demandSource: source)
        await runtime.reconcileDemand()
        let request = FiniteChoiceDecisionRequest(
            requestID: UUID(), consumerID: .modelRouter,
            contractVersion: FiniteChoiceDecisionRequest.currentContractVersion,
            policy: ModelRouterDecisionPolicy.identity, textContext: "TASK:\ntask",
            question: .init(name: "model_route", instructions: "Choose one.", choices: ["a", "b"].map {
                .init(opaqueKey: $0, description: "test")
            })
        )
        let route = Task { await runtime.coordinator.decide(serviceID: .openAIDecisions, request: request, consumerRevision: 0) }
        await backend.waitUntilStarted()
        source.set(.init(routerEnabled: true, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: false, routerRevision: 1))
        await runtime.reconcileDemand()
        let outcome = await route.value
        XCTAssertEqual(outcome, .cancelled)
        await backend.complete()
        let counts = await (controller.calls, controller.invalidations)
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        await runtime.teardown()
    }

    func testAutoEffortRevisionCancelsOnlyAutoEffortWithoutBackendFallback() async throws {
        let source = RuntimeTestDemandSource(.init(
            routerEnabled: true, selectedBackendRawValue: "openai-decisions",
            autoEffortEnabled: true, routerRevision: 0,
            autoEffortBackendRawValue: "openai-decisions", autoEffortRevision: 0
        ))
        let controller = RuntimeTestController(state: .ready(generation: 4, policyVersion: "test"))
        let backend = RuntimeSuspendedBackend()
        let runtime = try AgentTaskRouterRuntime(registrations: [
            .init(service: backend, configuration: .init(presentation: testPresentation("test"), controller: controller))
        ], demandSource: source)
        await runtime.reconcileDemand()
        func request(_ consumer: DecisionConsumerID) -> FiniteChoiceDecisionRequest {
            .init(
                requestID: UUID(), consumerID: consumer,
                contractVersion: FiniteChoiceDecisionRequest.currentContractVersion,
                policy: .init(id: "test", version: "1"), textContext: "masked turn",
                question: .init(name: "effort", instructions: "Choose one.", choices: ["a", "b"].map {
                    .init(opaqueKey: $0, description: "test")
                })
            )
        }
        let autoRequest = request(.autoEffort)
        let task = Task { await runtime.coordinator.decide(serviceID: .openAIDecisions, request: autoRequest, consumerRevision: 0) }
        await backend.waitUntilStarted()
        source.set(.init(
            routerEnabled: true, selectedBackendRawValue: "openai-decisions",
            autoEffortEnabled: true, routerRevision: 1,
            autoEffortBackendRawValue: "openai-decisions", autoEffortRevision: 0
        ))
        await runtime.reconcileDemand()
        await backend.complete()
        let selectedOutcome = await task.value
        XCTAssertEqual(selectedOutcome, .selected(opaqueKey: "a", evidence: nil))

        let nextRequest = request(.autoEffort)
        let next = Task { await runtime.coordinator.decide(serviceID: .openAIDecisions, request: nextRequest, consumerRevision: 0) }
        await backend.waitUntilStarted()
        source.set(.init(
            routerEnabled: true, selectedBackendRawValue: "openai-decisions",
            autoEffortEnabled: true, routerRevision: 1,
            autoEffortBackendRawValue: "jev", autoEffortRevision: 1
        ))
        await runtime.reconcileDemand()
        let outcome = await next.value
        XCTAssertEqual(outcome, .cancelled)
        await backend.complete()
        await runtime.teardown()
    }

    func testExplicitInvalidationDoesNotImmediatelyBootstrapSameDemand() async throws {
        let source = RuntimeTestDemandSource(.init(routerEnabled: true, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: false, routerRevision: 0))
        let jev = RuntimeTestController()
        let decisions = RuntimeTestController()
        let runtime = try makeRuntime(source, jev, decisions)
        await runtime.reconcileDemand()
        await decisions.set(.needsConfiguration(generation: 1, reason: "removed"))
        source.set(.init(routerEnabled: true, selectedBackendRawValue: "openai-decisions", autoEffortEnabled: false, routerRevision: 1))
        await runtime.reconcileDemand()
        let calls = await decisions.calls
        XCTAssertEqual(calls, 1)
        await runtime.teardown()
    }

    func testProductionDefaultIsNilOnlyBeforeFirstSnapshotAndRegistersBoth() async throws {
        for raw in [nil, "", "  ", "openai-decisions", "future"] as [String?] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
            try file.save(GlobalSettingsDocument(scalarPreferences: .init(modelRouter: .init(enabled: false, selectedBackendRawValue: raw))))
            let suite = "RuntimeDefault.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = GlobalSettingsStore(defaults: defaults, fileStore: file)
            let runtime = AgentTaskRouterRuntime(secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()), settingsStore: store)
            XCTAssertEqual(store.routerDemandSnapshot().selectedBackendRawValue, raw ?? "jev")
            XCTAssertEqual(runtime.defaultBackendID, .jev)
            let ids = await runtime.registry.registrations().map(\.id)
            XCTAssertEqual(Set(ids), [.jev, .openAIDecisions])
            await runtime.teardown()
        }
    }

    func testBootstrapSnapshotCannotOvertakeOrderedReadinessUpdates() async throws {
        let source = RuntimeTestDemandSource(.init(routerEnabled: true, selectedBackendRawValue: "jev", autoEffortEnabled: false, routerRevision: 0))
        let ready = DecisionReadiness.ready(generation: 1, policyVersion: "test")
        let jev = RuntimeTestController(bootstrapReadiness: ready)
        let runtime = try makeRuntime(source, jev, RuntimeTestController())
        await jev.waitUntilObserved()
        await runtime.reconcileDemand()
        // The controller's final snapshot is already ready, while stream delivery is held.
        // It must not publish ahead of the ordered validating -> ready updates.
        XCTAssertEqual(runtime.backendReadiness(.jev), .needsConfiguration(generation: 0, reason: "test"))
        let calls = await jev.calls
        XCTAssertEqual(calls, 1)
        await jev.set(.validating(generation: 1))
        try await waitForReadiness(.validating(generation: 1), id: .jev, runtime: runtime)
        await jev.set(ready)
        try await waitForReadiness(ready, id: .jev, runtime: runtime)
        XCTAssertTrue(runtime.isBackendReady(.jev))
        await runtime.teardown()
    }

    func testReadyAdmissionSnapshotSettlesWithoutWaitingForHeldReadinessStream() async throws {
        let source = RuntimeTestDemandSource(.init(routerEnabled: true, selectedBackendRawValue: "jev", autoEffortEnabled: false, routerRevision: 0))
        let jev = RuntimeTestController(gateAdmission: true)
        let runtime = try makeRuntime(source, jev, RuntimeTestController())
        await jev.waitUntilObserved()
        await jev.waitUntilAdmission()
        let ready = DecisionReadiness.ready(generation: 1, policyVersion: "test")
        await jev.setSnapshotWithoutPublishing(ready)
        let reconciled = expectation(description: "ready admission needs no bootstrap or stream delivery")
        let reconciliation = Task {
            await runtime.reconcileDemand()
            reconciled.fulfill()
        }
        await jev.releaseAdmission()
        let result = await XCTWaiter.fulfillment(of: [reconciled], timeout: 15)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(runtime.backendReadiness(.jev), .needsConfiguration(generation: 0, reason: "test"))
        let calls = await jev.calls
        XCTAssertEqual(calls, 0)
        await jev.set(ready)
        await reconciliation.value
        try await waitForReadiness(ready, id: .jev, runtime: runtime)
        await runtime.teardown()
    }

    func testEnabledLegacyProductionIntentBootstrapsJevWithoutSettingsVM() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
        try file.save(GlobalSettingsDocument(scalarPreferences: .init(modelRouter: .init(enabled: true, selectedBackendRawValue: nil))))
        let suite = "LegacyDemand.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: file)
        let keys = SecureKeysService(secureStorage: TestSecureStorageBackend())
        try keys.saveAPIKey("synthetic-test-key", for: .jevRouterAPIKey)
        let client = RuntimeJevClient()
        let runtime = AgentTaskRouterRuntime(secureKeys: keys, jevClient: client, settingsStore: store)
        await runtime.reconcileDemand()
        // Bootstrap completion and the readiness stream's UI projection are separate
        // owners. Await the existing bounded observation barrier, not scheduler order.
        try await waitForReadiness(
            .ready(generation: 1, policyVersion: JevRouterCredentialService.routingPolicyVersion),
            id: .jev, runtime: runtime
        )
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(runtime.isBackendReady(.jev))
        XCTAssertFalse(runtime.isBackendReady(.openAIDecisions))
        XCTAssertEqual(store.routerDemandSnapshot().selectedBackendRawValue, "jev")
        await runtime.teardown()
    }

    func testSettingsPublishesPostMutationSnapshotsAndRevisionOnlyChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "RuntimeDemand.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json")))
        var iterator = store.routerDemandUpdates().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertNil(initial?.selectedBackendRawValue)
        store.setModelRouterBackend(.openAIDecisions, commit: false)
        let selected = await iterator.next()
        XCTAssertEqual(selected, store.routerDemandSnapshot())
        store.setModelRouterEnabled(true, commit: false)
        let enabled = await iterator.next()
        XCTAssertEqual(enabled?.routerEnabled, true)
        store.setAutoEffortEnabled(true, commit: false)
        let auto = await iterator.next()
        XCTAssertEqual(auto?.autoEffortEnabled, true)
        store.setModelRouterCustomInstructions("Prefer reliable choices", commit: false)
        let guidance = await iterator.next()
        XCTAssertEqual(guidance?.key, auto?.key)
        XCTAssertGreaterThan(try XCTUnwrap(guidance?.routerRevision), try XCTUnwrap(auto?.routerRevision))
    }

    func testReloadImportAndRecoveryPublishInstalledDemand() async throws {
        for operation in ["reload", "import", "recover"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("settings.json")
            var document = GlobalSettingsDocument(scalarPreferences: .init(modelRouter: .init(enabled: true, selectedBackendRawValue: "openai-decisions")))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            document.schemaVersion = document.requiredSchemaVersion
            if operation == "import" { document.schemaLineage = "foreign.fixture" }
            if operation == "recover" { try Data("invalid json".utf8).write(to: url) }
            else { try encoder.encode(document).write(to: url) }
            let suite = "DemandInstall.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: url))
            var iterator = store.routerDemandUpdates().makeAsyncIterator()
            let initial = await iterator.next()
            if operation == "reload" {
                document.scalarPreferences?.modelRouter?.selectedBackendRawValue = "jev"
                try encoder.encode(document).write(to: url)
                guard store.reloadFromDisk() else { return XCTFail("Reload failed") }
            } else if operation == "import" {
                guard store.importBlockedPersistenceAfterBackup() else { return XCTFail("Import failed") }
            } else {
                guard store.recoverBlockedPersistenceAfterBackup() else { return XCTFail("Recovery failed") }
            }
            let installed = await iterator.next()
            XCTAssertEqual(installed, store.routerDemandSnapshot())
            if operation == "reload" || operation == "import" {
                XCTAssertTrue(try XCTUnwrap(installed?.routerEnabled))
                XCTAssertEqual(installed?.selectedBackendRawValue, operation == "reload" ? "jev" : "openai-decisions")
                XCTAssertGreaterThan(try XCTUnwrap(installed?.routerRevision), try XCTUnwrap(initial?.routerRevision))
            }
        }
    }

    private func waitForReadiness(
        _ expected: DecisionReadiness,
        id: DecisionServiceID,
        runtime: AgentTaskRouterRuntime
    ) async throws {
        for _ in 0 ..< 100 {
            if runtime.backendReadiness(id) == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for backend readiness \(expected)")
    }

    private func makeRuntime(_ source: RuntimeTestDemandSource, _ jev: RuntimeTestController, _ decisions: RuntimeTestController) throws -> AgentTaskRouterRuntime {
        try AgentTaskRouterRuntime(registrations: [
            registration(.jev, jev), registration(.openAIDecisions, decisions)
        ], demandSource: source)
    }

    private func registration(_ id: DecisionServiceID, _ controller: RuntimeTestController) -> DecisionServiceRegistration {
        .init(
            service: RuntimeTestBackend(id: id, controller: controller),
            configuration: .init(presentation: testPresentation(id.rawValue), controller: controller)
        )
    }

    private func testPresentation(_ title: String) -> DecisionServiceSettingsPresentation {
        .init(
            title: title,
            summary: "test",
            notices: [],
            disclosures: [],
            productStatus: nil,
            capabilities: [],
            secretFieldLabel: nil,
            supportedCredentialActions: [],
            links: []
        )
    }
}

@MainActor
final class RuntimeTestDemandSource: AgentTaskRouterDemandSource {
    private var snapshot: AgentTaskRouterDemandSnapshot
    private var continuation: AsyncStream<AgentTaskRouterDemandSnapshot>.Continuation?
    init(_ snapshot: AgentTaskRouterDemandSnapshot) {
        self.snapshot = snapshot
    }

    func routerDemandSnapshot() -> AgentTaskRouterDemandSnapshot {
        snapshot
    }

    func routerDemandUpdates() -> AsyncStream<AgentTaskRouterDemandSnapshot> {
        AsyncStream { continuation = $0
            $0.yield(snapshot)
        }
    }

    func set(_ snapshot: AgentTaskRouterDemandSnapshot) {
        self.snapshot = snapshot
        continuation?.yield(snapshot)
    }
}

private actor RuntimeJevClient: JevRoutingClientProtocol {
    private(set) var calls = 0
    func listModels(apiKey: String, timeout: Duration) -> JevModelList {
        calls += 1
        return .init(models: [.init(name: "jev-latest")])
    }

    func judge(request: JevRoutingWireRequest, apiKey: String, timeout: Duration) throws -> JevRoutingWireResponse {
        throw JevRoutingClientError.invalidRequest
    }
}

private actor RuntimeSuspendedBackend: DecisionService {
    nonisolated let id = DecisionServiceID.openAIDecisions
    nonisolated let displayName = "test"
    nonisolated let capabilities = DecisionServiceCapabilities.runtimeTest
    private var completion: CheckedContinuation<DecisionOutcome, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func readinessSnapshot() -> DecisionReadiness {
        .ready(generation: 4, policyVersion: "test")
    }

    func decide(_ request: FiniteChoiceDecisionRequest) async -> DecisionOutcome {
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        return await withCheckedContinuation { completion = $0 }
    }

    func waitUntilStarted() async {
        if completion == nil { await withCheckedContinuation { waiters.append($0) } }
    }

    func complete() {
        completion?.resume(returning: .selected(opaqueKey: "a", evidence: nil))
        completion = nil
    }
}

private struct RuntimeTestBackend: DecisionService {
    let id: DecisionServiceID
    let controller: RuntimeTestController
    let capabilities = DecisionServiceCapabilities.runtimeTest
    var displayName: String {
        id.rawValue
    }

    func readinessSnapshot() async -> DecisionReadiness {
        await controller.readinessSnapshot()
    }

    func decide(_ request: FiniteChoiceDecisionRequest) async -> DecisionOutcome {
        .cancelled
    }
}

private actor RuntimeTestController: DecisionServiceConfigurationController {
    private var state: DecisionReadiness
    private(set) var calls = 0
    private(set) var invalidations = 0
    private var observed = false
    private var terminated = false
    private var observationWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: AsyncStream<DecisionReadiness>.Continuation?
    private var snapshotCalls = 0
    private var gateAdmission: Bool
    private var admissionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []
    private let bootstrapReadiness: DecisionReadiness?
    init(state: DecisionReadiness = .needsConfiguration(generation: 0, reason: "test"), gateAdmission: Bool = false, bootstrapReadiness: DecisionReadiness? = nil) {
        self.state = state
        self.gateAdmission = gateAdmission
        self.bootstrapReadiness = bootstrapReadiness
    }

    func readinessSnapshot() async -> DecisionReadiness {
        snapshotCalls += 1
        if gateAdmission, snapshotCalls > 1 {
            admissionWaiters.forEach { $0.resume() }
            admissionWaiters.removeAll()
            await withCheckedContinuation { releases.append($0) }
        }
        return state
    }

    func waitUntilAdmission() async {
        if releases.isEmpty { await withCheckedContinuation { admissionWaiters.append($0) } }
    }

    func releaseAdmission() {
        gateAdmission = false
        releases.forEach { $0.resume() }
        releases.removeAll()
    }

    func readinessUpdates() -> AsyncStream<DecisionReadiness> {
        observed = true
        observationWaiters.forEach { $0.resume() }
        observationWaiters.removeAll()
        return AsyncStream {
            continuation = $0
            $0.yield(state)
            $0.onTermination = { [weak self] _ in Task { await self?.didTerminate() } }
        }
    }

    func set(_ state: DecisionReadiness) {
        self.state = state
        continuation?.yield(state)
    }

    func setSnapshotWithoutPublishing(_ state: DecisionReadiness) {
        self.state = state
    }

    func perform(_ action: DecisionServiceSettingsAction) -> DecisionServiceSettingsActionResult {
        .succeeded("test")
    }

    func bootstrapStoredConfigurationIfNeeded() {
        calls += 1
        if let bootstrapReadiness { state = bootstrapReadiness }
    }

    func cancelAndAdvanceGeneration() {
        invalidations += 1
    }

    func waitUntilObserved() async {
        if !observed { await withCheckedContinuation { observationWaiters.append($0) } }
    }

    func waitUntilTerminated() async {
        if !terminated { await withCheckedContinuation { terminationWaiters.append($0) } }
    }

    private func didTerminate() {
        terminated = true
        terminationWaiters.forEach { $0.resume() }
        terminationWaiters.removeAll()
    }
}

private extension DecisionServiceCapabilities {
    static let runtimeTest = Self(
        contextKinds: [.text],
        finiteChoice: .init(
            minimumChoices: 2, maximumChoices: 12, maximumContextBytes: 24 * 1024,
            maximumInstructionsBytes: 16 * 1024, maximumChoiceDescriptionBytes: 8 * 1024,
            maximumAggregateBytes: 128 * 1024
        ),
        evidence: .init(confidence: true, probabilityDistribution: true, usage: true)
    )
}

@MainActor
final class RoutingModelProfileResolverTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-10-07T00:00:00Z")!

    private func family(
        _ id: String,
        provider: String = AgentProviderKind.codexExec.rawValue,
        aliases: [String] = [],
        prefixes: [String] = []
    ) -> [String: Any] {
        [
            "providerID": provider,
            "id": id,
            "utilityTier": "tier-\(id)",
            "summary": "Family \(id) annotation.",
            "rubric": "Family \(id) rubric.",
            "aliases": aliases,
            "matchers": prefixes.map { ["kind": "versionedPrefix", "prefix": $0] }
        ]
    }

    private func exact(
        _ id: String,
        familyID: String = "family",
        aliases: [String] = [],
        summary: String? = "Exact audited annotation."
    ) -> [String: Any] {
        var item: [String: Any] = [
            "providerID": AgentProviderKind.codexExec.rawValue,
            "id": id, "familyID": familyID, "aliases": aliases,
            "utilityTier": NSNull(), "rubric": NSNull(), "price": NSNull(),
            "evidenceIDs": []
        ]
        if let summary { item["summary"] = summary }
        else { item["summary"] = NSNull() }
        return item
    }

    private func data(
        families: [[String: Any]] = [],
        models: [[String: Any]] = [],
        efforts: [[String: Any]] = [],
        extra: [String: Any] = [:]
    ) throws -> Data {
        var document: [String: Any] = [
            "schemaVersion": 1,
            "profileVersion": "fixture-profile-v1",
            "evidenceVersion": "fixture-evidence-v1",
            "rubricVersion": "fixture-rubric-v1",
            "issuedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2027-09-23T00:00:00Z",
            "families": families, "models": models, "evidence": [], "efforts": efforts
        ]
        document.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    private func resolver(families: [[String: Any]], models: [[String: Any]] = []) throws -> RoutingModelProfileResolver {
        try .init(document: RoutingProfileDocumentDecoder.decode(data(families: families, models: models)))
    }

    private func model(
        _ id: String,
        provider: AgentProviderKind = .codexExec,
        efforts: [RoutingExecutionEffort] = []
    ) -> RoutingExecutionModelMetadata {
        .init(
            provider: provider,
            baseModelRaw: id,
            displayName: "Provider display \(id)",
            isProviderDefault: false,
            catalogOrder: 0,
            advertisedOptionRawValues: [id],
            defaultEffortID: .init(rawValue: "future-depth"),
            efforts: efforts
        )
    }

    func testBundledDataStrictlyDecodesAndPreservesKnownEvidence() throws {
        let resolver = RoutingModelProfileResolver.bundled
        let document = try XCTUnwrap(resolver.document)
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.models.count, 17)
        let luna = resolver.resolve(model("gpt-6-luna"), catalogRevision: "catalog-1", now: date)
        XCTAssertEqual(luna.match, .exact)
        XCTAssertTrue(luna.description(snapshotDate: resolver.snapshotDate).contains("$0.10 input / $0.50 output"))
        XCTAssertEqual(luna.price.version, document.evidenceVersion)
        XCTAssertEqual(luna.price.freshness, .current)
        XCTAssertNotNil(luna.price.checkedAt)
        let priorLuna = resolver.resolve(model("gpt-5.6-luna"), catalogRevision: "catalog-1", now: date)
        XCTAssertEqual(priorLuna.evidence.source, .exactProfile)
        XCTAssertEqual(priorLuna.evidence.version, document.evidenceVersion)
        XCTAssertNotNil(priorLuna.evidence.checkedAt)
        XCTAssertTrue(priorLuna.evidence.value.joined().contains("Terminal-Bench 2.1"))
    }

    func testStrictSchemaRejectsDuplicateJSONKeysUnknownFieldsAndUnknownMatchers() throws {
        let duplicate = Data("{\"schemaVersion\":1,\"schemaVersion\":2}".utf8)
        XCTAssertThrowsError(try RoutingProfileDocumentDecoder.decode(duplicate)) { error in
            XCTAssertEqual(error as? RoutingProfileDecodeError, .duplicateJSONKey("schemaVersion"))
        }
        XCTAssertThrowsError(try RoutingProfileDocumentDecoder.decode(data(extra: ["endpoint": "https://example.test"]))) { error in
            XCTAssertEqual(error as? RoutingProfileDecodeError, .unknownField("root.endpoint"))
        }
        var invalid = family("family", prefixes: ["model-"])
        invalid["matchers"] = [["kind": "regex", "prefix": "model-"]]
        XCTAssertThrowsError(try RoutingProfileDocumentDecoder.decode(data(families: [invalid])))
        var oversized = family("family")
        oversized["summary"] = String(repeating: "x", count: 8193)
        XCTAssertThrowsError(try RoutingProfileDocumentDecoder.decode(data(families: [oversized])))
    }

    func testDuplicateLogicalAliasesAndMatchersAreRejected() throws {
        let one = family("one", aliases: ["shared"])
        let two = family("two", aliases: ["shared"])
        XCTAssertThrowsError(try RoutingProfileDocumentDecoder.decode(data(families: [one, two])))
        let repeated = family("one", prefixes: ["model-", "model-"])
        XCTAssertThrowsError(try RoutingProfileDocumentDecoder.decode(data(families: [repeated])))
    }

    func testExactOverrideInheritsOnlySafeFamilyAnnotationsWithFieldProvenance() throws {
        var entry = exact("known")
        entry["price"] = [
            "text": "API list price: $2 input / $10 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-12-31T00:00:00Z"
        ]
        let resolver = try resolver(families: [family("family")], models: [entry])
        let advertised = RoutingExecutionEffort(id: .init(rawValue: "future-depth"), executableTarget: nil)
        let resolved = resolver.resolve(model("known", efforts: [advertised]), catalogRevision: "catalog-42", now: date)
        XCTAssertEqual(resolved.match, .exact)
        XCTAssertEqual(resolved.executionProviderID.source, .providerCatalog)
        XCTAssertEqual(resolved.executionProviderID.value, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(resolved.familyID.source, .exactProfile)
        XCTAssertEqual(resolved.familyID.value, "family")
        XCTAssertEqual(resolved.modelID.source, .providerCatalog)
        XCTAssertEqual(resolved.modelID.version, "catalog-42")
        XCTAssertEqual(resolved.displayName.value, "Provider display known")
        XCTAssertEqual(resolved.advertisedEffortIDs.value, ["future-depth"])
        XCTAssertTrue(resolved.executableEffortIDs.value.isEmpty)
        XCTAssertEqual(resolved.summary.source, .exactProfile)
        XCTAssertEqual(resolved.summary.version, "fixture-profile-v1")
        XCTAssertEqual(resolved.rubric.source, .familyProfile)
        XCTAssertEqual(resolved.rubric.value, "Family family rubric.")
        XCTAssertEqual(resolved.price.source, .exactProfile)
        XCTAssertEqual(resolved.price.version, "fixture-evidence-v1")
        XCTAssertEqual(resolved.price.freshness, .current)
    }

    func testExactAliasFamilyAliasProviderFamilyAndVersionedMatcherPrecedence() throws {
        let resolver = try resolver(
            families: [family("family", aliases: ["family-alias"], prefixes: ["future-v-"])],
            models: [exact("known", aliases: ["known-alias"])]
        )
        XCTAssertEqual(resolver.resolve(model("known-alias"), catalogRevision: "1", now: date).match, .exactAlias)
        XCTAssertEqual(resolver.resolve(model("family-alias"), catalogRevision: "1", now: date).match, .family)
        XCTAssertEqual(resolver.resolve(model("future-v-2.1"), catalogRevision: "1", now: date).match, .family)
        XCTAssertEqual(resolver.resolve(model("unexpected"), catalogRevision: "1", providerFamilyID: "family", now: date).match, .family)
        XCTAssertEqual(resolver.resolve(model("future-v-beta"), catalogRevision: "1", now: date).match, .unknown)
        XCTAssertEqual(resolver.resolve(model("future-v-2.1"), catalogRevision: "1", providerFamilyID: "conflict", now: date).match, .unknown)
        XCTAssertEqual(resolver.resolve(model("future-v-2.1", provider: .openCode), catalogRevision: "1", now: date).match, .unknown)
    }

    func testAmbiguousFamilyMatchersResolveUnknownWithoutBlockingProviderModel() throws {
        let resolver = try resolver(families: [
            family("broad", prefixes: ["future-"]),
            family("narrow", prefixes: ["future-2-"])
        ])
        let resolved = resolver.resolve(model("future-2-1"), catalogRevision: "1", now: date)
        XCTAssertEqual(resolved.match, .unknown)
        XCTAssertNil(resolved.familyID.value)
        XCTAssertEqual(resolved.familyID.source, .genericFallback)
        XCTAssertEqual(resolved.modelID.value, "future-2-1")
        XCTAssertEqual(resolved.summary.source, .genericFallback)
    }

    func testStaleAndUnknownPriceNeverRenderAsCurrent() throws {
        var entry = exact("known")
        entry["price"] = [
            "text": "API list price: $2 input / $10 output per 1M tokens.",
            "checkedAt": "2026-09-23T00:00:00Z",
            "expiresAt": "2026-09-30T00:00:00Z"
        ]
        let resolver = try resolver(families: [family("family")], models: [entry])
        let stale = resolver.resolve(model("known"), catalogRevision: "1", now: date)
        XCTAssertEqual(stale.price.freshness, .stale)
        XCTAssertTrue(stale.description(snapshotDate: "2026-09-23").contains("Stale historical price (not current)"))
        let familyOnly = resolver.resolve(model("new-family-model"), catalogRevision: "1", providerFamilyID: "family", now: date)
        XCTAssertNil(familyOnly.price.value)
        XCTAssertEqual(familyOnly.price.freshness, .unknown)
        XCTAssertTrue(familyOnly.description(snapshotDate: "2026-09-23").contains("Price is unknown"))
    }

    func testCandidateBuilderUsesProfilesOnlyForAdvertisedShortlistedModels() throws {
        let resolver = try resolver(families: [family("family")], models: [exact("gpt-6-sol"), exact("known")])
        let options = [
            AgentModelOption(rawValue: "gpt-6-sol", displayName: "Sol", description: nil, isPlaceholderDefault: false, isProviderDefault: false),
            AgentModelOption(rawValue: "gpt-6-luna", displayName: "Luna", description: nil, isPlaceholderDefault: false, isProviderDefault: false),
            AgentModelOption(rawValue: "new-model", displayName: "New", description: nil, isPlaceholderDefault: false, isProviderDefault: false)
        ]
        let builder = AgentTaskRoutingCandidateBuilder(profileResolver: resolver) { provider, _ in
            provider == .codexExec ? options : []
        }
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false
        )
        let candidates = try builder.build(allowedProviders: [.codexExec], availability: availability)
        // Curated candidates are ordered strongest-first within a provider.
        XCTAssertEqual(candidates.map(\.target.modelRaw), ["gpt-6-sol", "gpt-6-luna"])
        let luna = try XCTUnwrap(candidates.first { $0.target.modelRaw == "gpt-6-luna" })
        let sol = try XCTUnwrap(candidates.first { $0.target.modelRaw == "gpt-6-sol" })
        XCTAssertTrue(luna.descriptor.targetDescription.contains("No audited benchmark or pricing profile"))
        XCTAssertTrue(sol.descriptor.targetDescription.contains("Exact audited annotation"))
        XCTAssertFalse(candidates.contains { $0.target.modelRaw == "known" || $0.target.modelRaw == "new-model" })
    }

    func testUnknownNewModelAndEffortDoNotGuessFromNamesOrAdmitTargets() throws {
        let resolver = try resolver(families: [family("family")], models: [exact("known")])
        let unknown = resolver.resolve(model("known-high"), catalogRevision: "1", now: date)
        XCTAssertEqual(unknown.match, .unknown)
        XCTAssertTrue(unknown.summary.value.contains("No audited benchmark or pricing profile"))
        XCTAssertFalse(unknown.description(snapshotDate: "2026-09-23").contains("Exact audited annotation"))
        let effort = resolver.effortDescription(raw: "future-depth", now: date)
        XCTAssertEqual(effort.source, .genericFallback)
        XCTAssertTrue(effort.value.contains("Provider-advertised effort future-depth"))
        XCTAssertNil(resolver.document?.efforts.first { $0.id == "future-depth" })
    }
}

@MainActor
final class RoutingModelProfileSnapshotTests: XCTestCase {
    func testBundledSnapshotUsesStrictlyDecodedResolverAndContentDigest() {
        let snapshot = RoutingModelProfileSnapshot.bundled
        let resolver = RoutingModelProfileResolver.bundled

        XCTAssertEqual(snapshot.resolver.profileVersion, resolver.profileVersion)
        XCTAssertEqual(snapshot.digest.count, 64)
        XCTAssertEqual(snapshot.digest, RoutingModelProfileSnapshot.digest(BundledRoutingProfiles.data))
        XCTAssertNotNil(resolver.document)
        XCTAssertEqual(RoutingModelProfileSnapshot.digest(Data("bundled".utf8)).count, 64)
        XCTAssertNotEqual(
            RoutingModelProfileSnapshot.digest(Data("bundled".utf8)),
            RoutingModelProfileSnapshot.digest(Data("changed".utf8))
        )
        XCTAssertEqual(snapshot.identity, "bundled:\(snapshot.digest):\(resolver.profileVersion)")
    }

    func testBundledStoreReturnsStableContentDerivedSnapshot() {
        let store = RoutingProfileStore()
        let first = store.snapshot()
        let second = store.snapshot()

        XCTAssertEqual(first.identity, second.identity)
        XCTAssertEqual(first.digest, RoutingModelProfileSnapshot.bundled.digest)
        XCTAssertTrue(first.identity.hasPrefix("bundled:"))
    }

    func testSnapshotIdentityChangesWhenBundledContentDigestChanges() {
        let resolver = RoutingModelProfileResolver.bundled
        let first = RoutingModelProfileSnapshot(resolver: resolver, digest: "first")
        let second = RoutingModelProfileSnapshot(resolver: resolver, digest: "second")

        XCTAssertNotEqual(first.identity, second.identity)
    }
}
