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

    private func choose(_ balancer: ProviderUsageBalancer, _ selected: ProviderUsageModelOption, _ options: [ProviderUsageModelOption], strategy: ProviderUsageBalancePolicy.Strategy = .evenPace) -> ProviderUsageModelOption {
        balancer.preferredPeerIndex(selected: selected, options: options, strategy: strategy, now: instant).map { options[$0] } ?? selected
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
