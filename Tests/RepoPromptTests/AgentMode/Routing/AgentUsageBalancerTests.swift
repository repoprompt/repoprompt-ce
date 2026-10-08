import Foundation
@testable import RepoPromptApp
import RepoPromptProviderQuota
import XCTest

@MainActor
final class AgentUsageBalancerTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 2_000_000_000)
    private func candidate(_ key: String, _ provider: AgentProviderKind, peer: String? = "strong") -> AgentTaskRoutingCandidateBuilder.Candidate {
        .init(
            opaqueKey: key,
            utilityTier: key,
            target: .init(agentRaw: provider.rawValue, modelRaw: key, reasoningEffortRaw: nil, modelParameters: []),
            descriptor: .init(opaqueKey: key, roleLabels: [], targetDescription: key, rubricVersion: "test", rubric: "test"),
            usagePeerClass: peer
        )
    }

    private func configuration(_ preset: AgentUsageBalancingPreset = .evenPace, enabled: Bool = true, jev: Bool = false, custom: String = "") -> AgentTaskRouterConfiguration {
        .init(enabled: jev, selectedBackendID: nil, selectedBackendRawValue: nil, candidateRoles: [], allowedProviders: [.claudeCode, .codexExec], candidateRolesMaterialized: true, allowedProvidersMaterialized: true, unknownRoleRawValues: [], unknownProviderRawValues: [], primaryProvider: nil, subagentProvider: nil, customInstructions: custom, validity: .disabled, revision: 1, usageBalancing: .init(enabled: enabled, preset: preset))
    }

    private func snapshot(_ used: Double, age: TimeInterval = 0) throws -> ProviderQuotaSnapshot {
        let reset = ISO8601DateFormatter().string(from: instant.addingTimeInterval(18000))
        return try ClaudeAccountUsageMapper.snapshot(data: Data("{\"five_hour\":{\"utilization\":\(used),\"resets_at\":\"\(reset)\"}}".utf8), account: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: "test"), observedAt: instant.addingTimeInterval(-age))
    }

    func testIndependentOfJevKeyEnablementScoresAndCustomGuidance() throws {
        let advisor = AgentUsageBalancer()
        var activities = 0
        advisor.onRoutingActivity = { activities += 1 }
        let claude = candidate("claude", .claudeCode), codex = candidate("codex", .codexExec)
        try advisor.update(snapshot(95), provider: claude.target.agentRaw)
        try advisor.update(snapshot(10), provider: codex.target.agentRaw)
        for settings in [configuration(), configuration(jev: true, custom: "Prefer Claude for execution")] {
            for _ in 0 ..< 3 {
                XCTAssertEqual(advisor.choose(selected: claude, candidates: [claude, codex], evidence: nil, configuration: settings, now: instant).candidate, codex)
            }
        }
        XCTAssertEqual(activities, 6, "Repeated identical inputs remain deterministic, not alternating admissions")
        XCTAssertEqual(advisor.choose(selected: claude, candidates: [claude, codex], evidence: nil, configuration: configuration(enabled: false), now: instant).candidate, claude)
        XCTAssertEqual(activities, 6)
    }

    func testUnknownAndStaleDoNotAttractWorkButKnownExhaustionCanUseUnknownPeer() throws {
        let advisor = AgentUsageBalancer()
        let claude = candidate("claude", .claudeCode), codex = candidate("codex", .codexExec)
        for used in [10.0, 95.0] {
            try advisor.update(snapshot(used, age: 901), provider: claude.target.agentRaw)
            try advisor.update(snapshot(10), provider: codex.target.agentRaw)
            XCTAssertEqual(advisor.choose(selected: claude, candidates: [claude, codex], evidence: nil, configuration: configuration(), now: instant).candidate, claude)
        }
        advisor.update(nil, provider: codex.target.agentRaw)
        try advisor.update(snapshot(95), provider: claude.target.agentRaw)
        XCTAssertEqual(advisor.choose(selected: claude, candidates: [claude, codex], evidence: nil, configuration: configuration(), now: instant).candidate, claude)
        try advisor.update(snapshot(100), provider: claude.target.agentRaw)
        XCTAssertEqual(advisor.choose(selected: claude, candidates: [claude, codex], evidence: nil, configuration: configuration(), now: instant).candidate, codex)
    }

    func testPeerClassesSingletonsAndModelLimitsAreRespected() throws {
        let advisor = AgentUsageBalancer()
        var activities = 0
        advisor.onRoutingActivity = { activities += 1 }
        let claude = candidate("claude", .claudeCode), codex = candidate("codex", .codexExec)
        try advisor.update(snapshot(95), provider: claude.target.agentRaw)
        try advisor.update(snapshot(5), provider: codex.target.agentRaw)
        for candidates in [[claude], [claude, candidate("codex", .codexExec, peer: "light")]] {
            XCTAssertEqual(advisor.choose(selected: claude, candidates: candidates, evidence: nil, configuration: configuration(), now: instant).candidate, claude)
        }
        XCTAssertEqual(activities, 0, "No balanceable peer means no refresh activity")
        let base = try snapshot(10), id = ProviderQuotaBucketID(rawValue: "model-limit")
        let window = ProviderQuotaWindow(key: .init(bucketID: id, nativeRole: "weekly"), percent: .init(rawValue: 100, sense: .used, declaredUpperBound: 100), windowDuration: 604_800, resetsAt: instant.addingTimeInterval(60), observedAt: instant)
        let bucket = ProviderQuotaBucket(bucketID: id, displayLabel: nil, nativeModelAlias: "codex", scope: .nativeModelAlias("codex"), reachedType: nil, isReached: nil, planType: nil, credits: nil, spendControl: nil, windows: [window])
        advisor.update(.init(accountKey: base.accountKey, buckets: base.buckets + [bucket], facets: .empty, source: base.source, coverage: .accountWide, observedAt: instant), provider: codex.target.agentRaw)
        XCTAssertEqual(advisor.choose(selected: claude, candidates: [claude, codex], evidence: nil, configuration: configuration(), now: instant).candidate, claude)
    }
}
