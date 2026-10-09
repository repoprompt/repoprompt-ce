import Foundation
@testable import RepoPromptSettingsCore
import XCTest

/// Pure primitives behind the unified usage section and the Agent Mode usage pill.
final class ProviderUsagePresentationPrimitivesTests: XCTestCase {
    func testCLIConsentIsVersionedAndLegacyConsentDoesNotPopulateIt() throws {
        let grant = ClaudeCLIUsageGrant(credentialProfileID: "/profile", grantedAt: Date())
        let decoded = try JSONDecoder().decode(ClaudeCLIUsageGrant.self, from: JSONEncoder().encode(grant))
        XCTAssertEqual(decoded, grant)
        XCTAssertTrue(decoded.applies(toProfileID: "/profile"))
        XCTAssertFalse(ClaudeCLIUsageGrant(credentialProfileID: "/profile", grantedAt: Date(), consentVersion: 99).applies(toProfileID: "/profile"))
        XCTAssertFalse(decoded.applies(toProfileID: "/different"))
        let legacy = Data(#"{"claudeAccountUsageGrant":{"credentialProfileID":"/profile","grantedAt":0}}"#.utf8)
        let settings = try JSONDecoder().decode(GlobalScalarPreferences.AgentModeSettings.self, from: legacy)
        XCTAssertNil(settings.claudeCLIUsageGrant)
    }

    // MARK: Source state

    func testClaudeSourceIsActiveOnlyForAGrantMatchingTheCurrentProfile() {
        let grant = ClaudeCLIUsageGrant(credentialProfileID: "/a/.claude", grantedAt: Date())
        XCTAssertTrue(ProviderUsageSourceState.claude(grant: grant, currentProfileID: "/a/.claude").isActive)

        let otherProfile = ProviderUsageSourceState.claude(grant: grant, currentProfileID: "/b/.claude")
        XCTAssertFalse(otherProfile.isActive)
        guard case let .inactive(_, explanation, requiresConsent) = otherProfile else {
            return XCTFail("expected inactive")
        }
        XCTAssertTrue(requiresConsent, "a profile change requires fresh consent")
        XCTAssertTrue(explanation.contains("different Claude profile"))

        // Profile not yet resolved: never treat a stored grant as active.
        XCTAssertFalse(ProviderUsageSourceState.claude(grant: grant, currentProfileID: nil).isActive)

        guard case let .inactive(_, _, noGrantConsent) = ProviderUsageSourceState.claude(grant: nil, currentProfileID: "/a/.claude") else {
            return XCTFail("expected inactive")
        }
        XCTAssertTrue(noGrantConsent)
    }

    func testCodexSourceNeedsNoCredentialConsent() {
        XCTAssertTrue(ProviderUsageSourceState.codex(enabled: true).isActive)
        guard case let .inactive(_, _, requiresConsent) = ProviderUsageSourceState.codex(enabled: false) else {
            return XCTFail("expected inactive")
        }
        XCTAssertFalse(requiresConsent)
    }

    // MARK: Pill

    func testPillHidesUnknownAndNeverFabricatesAFigure() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(AgentUsageLimitsPillPresentation(usedPercent: nil, isReached: false, resetAt: nil, providerName: "Claude", now: now))

        let zero = AgentUsageLimitsPillPresentation(usedPercent: 0, isReached: false, resetAt: nil, providerName: "Claude", now: now)
        XCTAssertEqual(zero?.label, "0%", "zero is a real reading, distinct from unknown")
        XCTAssertEqual(zero?.ringFraction, 0)

        let reachedUnknownPercent = AgentUsageLimitsPillPresentation(usedPercent: nil, isReached: true, resetAt: nil, providerName: "Codex", now: now)
        XCTAssertEqual(reachedUnknownPercent?.label, "Limit")
        XCTAssertNil(reachedUnknownPercent?.ringFraction, "reached without a percentage draws no ring")

        let reachedBelowHundred = AgentUsageLimitsPillPresentation(usedPercent: 80, isReached: true, resetAt: nil, providerName: "Codex", now: now)
        XCTAssertEqual(reachedBelowHundred?.label, "Limit", "the explicit flag wins over the percentage")
    }

    func testPillRingClampsButTooltipKeepsRealFigureAndOmitsElapsedReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let over = AgentUsageLimitsPillPresentation(usedPercent: 130, isReached: false, resetAt: now.addingTimeInterval(-60), providerName: "Claude", now: now)
        XCTAssertEqual(over?.ringFraction, 1)
        XCTAssertEqual(over?.label, "130%")
        XCTAssertEqual(over?.tooltip, "Claude plan usage: 130% used")

        let withReset = AgentUsageLimitsPillPresentation(usedPercent: 42, isReached: false, resetAt: now.addingTimeInterval(3600), providerName: "Claude", now: now)
        XCTAssertTrue(withReset?.tooltip.hasPrefix("Claude plan usage: 42% used · resets ") ?? false)
        XCTAssertEqual(withReset?.isDimmed, false, "a fresh reading is not dimmed")
    }

    func testPillKeepsLastValueAndStatesWhyItIsNotCurrent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = AgentUsageLimitsPillPresentation(
            state: .init(usedPercent: 42, isReached: false, resetAt: nil, observedAt: now.addingTimeInterval(-3 * 3600), freshness: .stale),
            providerName: "Claude",
            now: now
        )
        XCTAssertEqual(stale.label, "42%")
        XCTAssertTrue(stale.isDimmed)
        XCTAssertEqual(stale.tooltip, "Claude plan usage: 42% used · Updated 3 hours ago")

        let resetPassed = AgentUsageLimitsPillPresentation(
            state: .init(usedPercent: 80, isReached: false, resetAt: now.addingTimeInterval(-60), freshness: .resetPassed, isUpdating: true),
            providerName: "Claude",
            now: now
        )
        XCTAssertEqual(resetPassed.label, "80%")
        XCTAssertTrue(resetPassed.isDimmed)
        XCTAssertEqual(resetPassed.tooltip, "Claude plan usage: 80% used · Reset passed · updating…")

        let failed = AgentUsageLimitsPillPresentation(
            state: .init(usedPercent: 42, isReached: false, resetAt: nil, refreshFailed: true),
            providerName: "Codex",
            now: now
        )
        XCTAssertEqual(failed.label, "42%")
        XCTAssertEqual(failed.tooltip, "Codex plan usage: 42% used · Couldn't refresh")

        let unavailable = AgentUsageLimitsPillPresentation(state: .unavailable, providerName: "Claude", now: now)
        XCTAssertEqual(unavailable.label, "—", "a cleared snapshot is a neutral placeholder, not a removed pill")
        XCTAssertNil(unavailable.ringFraction)
        XCTAssertTrue(unavailable.isDimmed)
        XCTAssertTrue(unavailable.tooltip.contains("sign in"))
    }
}
