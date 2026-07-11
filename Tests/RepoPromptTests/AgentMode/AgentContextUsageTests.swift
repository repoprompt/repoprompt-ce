import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentContextUsageTests: XCTestCase {
    func testClaudeProviderTokensPreserveNumeratorCanonicalAndConfiguredWindow() throws {
        let usage = AgentModeViewModel.contextUsageFromClaudeProviderTokens(
            [AgentTokenUsagePersist(promptTokens: 99999, completionTokens: 1, contextUsedTokens: 123_456)],
            modelContextWindow: 1_000_000,
            configuredContextWindow: 400_000
        )

        let resolved = try XCTUnwrap(usage)
        XCTAssertEqual(resolved.lastTotalTokens, 123_456)
        XCTAssertEqual(resolved.totalTotalTokens, 123_456)
        XCTAssertEqual(resolved.modelContextWindow, 1_000_000)
        XCTAssertEqual(resolved.configuredContextWindow, 400_000)
    }

    func testClaudeProviderTokensKeepCanonicalValidationSeparateFromConfiguredWindow() throws {
        let usage = AgentModeViewModel.contextUsageFromClaudeProviderTokens(
            [AgentTokenUsagePersist(promptTokens: 99999, completionTokens: 1, contextUsedTokens: 250_000)],
            modelContextWindow: 200_000,
            configuredContextWindow: 400_000
        )

        let resolved = try XCTUnwrap(usage)
        XCTAssertNil(resolved.lastTotalTokens)
        XCTAssertNil(resolved.totalTotalTokens)
        XCTAssertEqual(resolved.modelContextWindow, 200_000)
        XCTAssertEqual(resolved.configuredContextWindow, 400_000)
    }

    func testLegitimateNumeratorBetween200And400KAcceptedUnderCorrectedCanonicalWindow() throws {
        // With canonical corrected to 1_000_000 by main-model attribution, a legitimate
        // 350K numerator is accepted rather than dropped by the `contextUsedTokens <= maxContextTokens`
        // cap that fired when canonical was misreported as 200_000.
        let usage = AgentModeViewModel.contextUsageFromClaudeProviderTokens(
            [AgentTokenUsagePersist(promptTokens: 99999, completionTokens: 1, contextUsedTokens: 350_000)],
            modelContextWindow: 1_000_000,
            configuredContextWindow: 400_000
        )

        let resolved = try XCTUnwrap(usage)
        XCTAssertEqual(resolved.lastTotalTokens, 350_000)
        XCTAssertEqual(resolved.totalTotalTokens, 350_000)
        XCTAssertEqual(resolved.modelContextWindow, 1_000_000)
        XCTAssertEqual(resolved.configuredContextWindow, 400_000)
    }

    func testClaudeProviderTokensAcceptPersistedReadingWhenCanonicalWindowUnknown() throws {
        let usage = AgentModeViewModel.contextUsageFromClaudeProviderTokens(
            [AgentTokenUsagePersist(promptTokens: 99999, completionTokens: 1, contextUsedTokens: 350_000)],
            modelContextWindow: nil,
            configuredContextWindow: nil
        )

        let resolved = try XCTUnwrap(usage)
        XCTAssertEqual(resolved.lastTotalTokens, 350_000)
        XCTAssertEqual(resolved.totalTotalTokens, 350_000)
        XCTAssertNil(resolved.modelContextWindow)
        XCTAssertNil(resolved.configuredContextWindow)
    }

    func testClaudeProviderTokensFilterPersistedReadingAboveUnknownWindowCeiling() {
        let usage = AgentModeViewModel.contextUsageFromClaudeProviderTokens(
            [AgentTokenUsagePersist(promptTokens: 99999, completionTokens: 1, contextUsedTokens: 15_000_000)],
            modelContextWindow: nil,
            configuredContextWindow: nil
        )

        XCTAssertNil(usage)
    }

    func testClaudeProviderTokensStillFilterPersistedReadingAboveKnownCanonicalWindow() throws {
        let usage = AgentModeViewModel.contextUsageFromClaudeProviderTokens(
            [AgentTokenUsagePersist(promptTokens: 99999, completionTokens: 1, contextUsedTokens: 350_000)],
            modelContextWindow: 200_000,
            configuredContextWindow: nil
        )

        let resolved = try XCTUnwrap(usage)
        XCTAssertNil(resolved.lastTotalTokens)
        XCTAssertNil(resolved.totalTotalTokens)
        XCTAssertEqual(resolved.modelContextWindow, 200_000)
    }

    func testClaudeProviderTokensDoNotUseConfiguredWindowAsValidationBound() throws {
        let usage = AgentModeViewModel.contextUsageFromClaudeProviderTokens(
            [AgentTokenUsagePersist(promptTokens: 99999, completionTokens: 1, contextUsedTokens: 500_000)],
            modelContextWindow: nil,
            configuredContextWindow: 400_000
        )

        let resolved = try XCTUnwrap(usage)
        XCTAssertEqual(resolved.lastTotalTokens, 500_000)
        XCTAssertEqual(resolved.totalTotalTokens, 500_000)
        XCTAssertNil(resolved.modelContextWindow)
        XCTAssertEqual(resolved.configuredContextWindow, 400_000)
    }

    func testCodexTokenUsageCarriesConfiguredWindowWithoutReplacingCanonicalWindow() throws {
        let usage = CodexNativeSessionController.test_parseTokenUsage(
            from: [
                "tokenUsage": [
                    "last": ["totalTokens": 321],
                    "total": ["totalTokens": 654],
                    "modelContextWindow": 1_000_000
                ]
            ],
            configuredContextWindow: 400_000
        )

        let resolved = try XCTUnwrap(usage)
        XCTAssertEqual(resolved.modelContextWindow, 1_000_000)
        XCTAssertEqual(resolved.configuredContextWindow, 400_000)
        XCTAssertEqual(resolved.lastTotalTokens, 321)
        XCTAssertEqual(resolved.totalTotalTokens, 654)
    }
}
