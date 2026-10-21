import Foundation
@testable import RepoPromptProviderQuota
import XCTest

@MainActor
final class ProviderUsageBalancerTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 2_000_000_000)

    private func option(_ provider: String, peer: String? = "strong", fast: Bool = false) -> ProviderUsageModelOption {
        .init(provider: provider, peerClass: peer, modelAliases: [provider], isPaidFast: fast)
    }

    private func snapshot(_ used: Double, age: TimeInterval = 0) throws -> ProviderQuotaSnapshot {
        let reset = ISO8601DateFormatter().string(from: instant.addingTimeInterval(18000))
        return try ClaudeAccountUsageMapper.snapshot(data: Data("{\"five_hour\":{\"utilization\":\(used),\"resets_at\":\"\(reset)\"}}".utf8), account: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: "test"), observedAt: instant.addingTimeInterval(-age))
    }

    private func weeklySnapshot(_ used: Double, resetIn: TimeInterval) throws -> ProviderQuotaSnapshot {
        let reset = ISO8601DateFormatter().string(from: instant.addingTimeInterval(resetIn))
        return try ClaudeAccountUsageMapper.snapshot(data: Data("{\"seven_day\":{\"utilization\":\(used),\"resets_at\":\"\(reset)\"}}".utf8), account: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: "test"), observedAt: instant)
    }

    private func choose(_ balancer: ProviderUsageBalancer, _ selected: ProviderUsageModelOption, _ options: [ProviderUsageModelOption], strategy: ProviderUsageBalancePolicy.Strategy = .evenPace) -> ProviderUsageModelOption {
        balancer.preferredPeerIndex(selected: selected, options: options, strategy: strategy, now: instant).map { options[$0] } ?? selected
    }

    func testOnlyChangedSnapshotsReportAnEffectiveMutation() throws {
        let balancer = ProviderUsageBalancer()
        XCTAssertFalse(balancer.update(nil, provider: "claude"))
        XCTAssertFalse(balancer.clear())
        let value = try snapshot(95)
        XCTAssertTrue(balancer.update(value, provider: "claude"))
        XCTAssertFalse(balancer.update(value, provider: "claude"))
        XCTAssertTrue(try balancer.update(snapshot(10), provider: "claude"))
        XCTAssertTrue(balancer.update(nil, provider: "claude"))
        XCTAssertFalse(balancer.update(nil, provider: "claude"))
        XCTAssertFalse(balancer.clear())
        XCTAssertTrue(balancer.update(value, provider: "claude"))
        XCTAssertTrue(balancer.clear())
    }

    func testNearLimitMovesToPeerDeterministicallyForEveryStrategy() throws {
        let balancer = ProviderUsageBalancer()
        var activities = 0
        balancer.onRoutingActivity = { activities += 1 }
        let claude = option("claude"), codex = option("codex")
        try balancer.update(snapshot(95), provider: claude.provider)
        try balancer.update(snapshot(10), provider: codex.provider)
        for strategy in ProviderUsageBalancePolicy.Strategy.allCases {
            for _ in 0 ..< 2 {
                XCTAssertEqual(choose(balancer, claude, [claude, codex], strategy: strategy), codex)
            }
        }
        XCTAssertEqual(activities, 6, "Repeated identical inputs remain deterministic, not alternating admissions")
        balancer.clear()
        XCTAssertEqual(choose(balancer, claude, [claude, codex]), claude, "Cleared readings are unknown and attract no work")
    }

    func testRouterStartingOnCodexMovesToClaudeWhoseWeeklyAllowanceExpiresFirst() throws {
        let balancer = ProviderUsageBalancer()
        let claude = option("claude"), codex = option("codex")
        try balancer.update(weeklySnapshot(32, resetIn: 37 * 3600), provider: claude.provider)
        try balancer.update(weeklySnapshot(6, resetIn: 143 * 3600), provider: codex.provider)
        XCTAssertEqual(choose(balancer, codex, [codex, claude], strategy: .evenPace), claude)
        XCTAssertEqual(choose(balancer, codex, [codex, claude], strategy: .expiringQuota), claude)
        XCTAssertEqual(choose(balancer, codex, [codex, claude], strategy: .nearLimits), codex)
        XCTAssertEqual(choose(balancer, claude, [claude, codex], strategy: .evenPace), claude)
    }

    func testCriticalUsageOverrideOffersOnlyTheDominantProvidersUsableModels() throws {
        let balancer = ProviderUsageBalancer()
        let codexStrong = option("codex"), claudeStrong = option("claude"), claudeLight = option("claude", peer: "light")
        let options = [codexStrong, claudeStrong, option("codex", fast: true), claudeLight, option("claude", peer: nil)]
        try balancer.update(weeklySnapshot(32, resetIn: 37 * 3600), provider: "claude")
        try balancer.update(weeklySnapshot(6, resetIn: 143 * 3600), provider: "codex")
        let expiring = try XCTUnwrap(balancer.usageOverride(options: options, now: instant))
        XCTAssertEqual(expiring.provider, "claude")
        XCTAssertEqual(expiring.reason, .expiring)
        XCTAssertEqual(expiring.indices, [1, 3], "Only comparable Claude models; never Codex, paid Fast, or unbalanced options")

        // 30%/30% used, but one resets in a day and the other in five days.
        try balancer.update(weeklySnapshot(30, resetIn: 24 * 3600), provider: "claude")
        try balancer.update(weeklySnapshot(30, resetIn: 120 * 3600), provider: "codex")
        XCTAssertEqual(balancer.usageOverride(options: options, now: instant)?.provider, "claude")

        try balancer.update(weeklySnapshot(80, resetIn: 120 * 3600), provider: "claude")
        try balancer.update(weeklySnapshot(30, resetIn: 72 * 3600), provider: "codex")
        let lopsided = try XCTUnwrap(balancer.usageOverride(options: options, now: instant))
        XCTAssertEqual(lopsided.provider, "codex")
        XCTAssertEqual(lopsided.reason, .lopsided)
        XCTAssertEqual(lopsided.indices, [0], "Codex's paid Fast option is never forced")

        try balancer.update(weeklySnapshot(92, resetIn: 120 * 3600), provider: "codex")
        try balancer.update(weeklySnapshot(50, resetIn: 84 * 3600), provider: "claude")
        XCTAssertEqual(balancer.usageOverride(options: options, now: instant)?.reason, .limit)

        try balancer.update(weeklySnapshot(50, resetIn: 84 * 3600), provider: "codex")
        XCTAssertNil(balancer.usageOverride(options: options, now: instant), "Even usage stays a mix with Model Router")

        balancer.update(nil, provider: "codex")
        try balancer.update(weeklySnapshot(32, resetIn: 37 * 3600), provider: "claude")
        let unknownPeer = try XCTUnwrap(balancer.usageOverride(options: options, now: instant), "Unknown Codex usage never lets known Claude allowance expire")
        XCTAssertEqual(unknownPeer.provider, "claude")
        XCTAssertEqual(unknownPeer.reason, .expiring)
        try balancer.update(weeklySnapshot(50, resetIn: 84 * 3600), provider: "claude")
        XCTAssertNil(balancer.usageOverride(options: options, now: instant), "Without expiring allowance, unknown usage is not critical")
        balancer.update(nil, provider: "claude")
        XCTAssertNil(balancer.usageOverride(options: options, now: instant), "Unknown usage is never critical")
        XCTAssertNil(balancer.usageOverride(options: [claudeStrong, claudeLight], now: instant), "One provider has nothing to override")
    }

    func testUsageOverrideExcludesModelLimitedOptionsAndFailsOpenWhenNoneRemain() throws {
        let balancer = ProviderUsageBalancer()
        let claude = option("claude"), codex = option("codex")
        let base = try weeklySnapshot(32, resetIn: 37 * 3600), id = ProviderQuotaBucketID(rawValue: "model-limit")
        let window = ProviderQuotaWindow(key: .init(bucketID: id, nativeRole: "weekly"), percent: .init(rawValue: 95, sense: .used, declaredUpperBound: 100), windowDuration: 604_800, resetsAt: instant.addingTimeInterval(3600), observedAt: instant)
        let bucket = ProviderQuotaBucket(bucketID: id, displayLabel: nil, nativeModelAlias: "claude", scope: .nativeModelAlias("claude"), reachedType: nil, isReached: nil, planType: nil, credits: nil, spendControl: nil, windows: [window])
        balancer.update(.init(accountKey: base.accountKey, buckets: base.buckets + [bucket], facets: .empty, source: base.source, coverage: .accountWide, observedAt: instant), provider: claude.provider)
        try balancer.update(weeklySnapshot(6, resetIn: 143 * 3600), provider: codex.provider)
        XCTAssertNil(balancer.usageOverride(options: [codex, claude], now: instant))
    }

    func testUnknownAndStaleDoNotAttractWorkButKnownExhaustionCanUseUnknownPeer() throws {
        let balancer = ProviderUsageBalancer()
        let claude = option("claude"), codex = option("codex")
        for used in [10.0, 95.0] {
            try balancer.update(snapshot(used, age: 901), provider: claude.provider)
            try balancer.update(snapshot(10), provider: codex.provider)
            XCTAssertEqual(choose(balancer, claude, [claude, codex]), claude)
        }
        balancer.update(nil, provider: codex.provider)
        try balancer.update(snapshot(95), provider: claude.provider)
        XCTAssertEqual(choose(balancer, claude, [claude, codex]), claude)
        try balancer.update(snapshot(100), provider: claude.provider)
        XCTAssertEqual(choose(balancer, claude, [claude, codex]), codex)
    }

    func testPeerClassesSingletonsPaidFastAndModelLimitsAreRespected() throws {
        let balancer = ProviderUsageBalancer()
        var activities = 0
        balancer.onRoutingActivity = { activities += 1 }
        let claude = option("claude"), codex = option("codex")
        try balancer.update(snapshot(95), provider: claude.provider)
        try balancer.update(snapshot(5), provider: codex.provider)
        for options in [[claude], [claude, option("codex", peer: "light")], [claude, option("codex", fast: true)], [option("claude", peer: nil), codex]] {
            XCTAssertEqual(choose(balancer, options[0], options), options[0])
        }
        XCTAssertEqual(activities, 0, "No balanceable peer means no refresh activity")
        let base = try snapshot(10), id = ProviderQuotaBucketID(rawValue: "model-limit")
        let window = ProviderQuotaWindow(key: .init(bucketID: id, nativeRole: "weekly"), percent: .init(rawValue: 100, sense: .used, declaredUpperBound: 100), windowDuration: 604_800, resetsAt: instant.addingTimeInterval(60), observedAt: instant)
        let bucket = ProviderQuotaBucket(bucketID: id, displayLabel: nil, nativeModelAlias: "codex", scope: .nativeModelAlias("codex"), reachedType: nil, isReached: nil, planType: nil, credits: nil, spendControl: nil, windows: [window])
        balancer.update(.init(accountKey: base.accountKey, buckets: base.buckets + [bucket], facets: .empty, source: base.source, coverage: .accountWide, observedAt: instant), provider: codex.provider)
        XCTAssertEqual(choose(balancer, claude, [claude, codex]), claude)
    }
}
