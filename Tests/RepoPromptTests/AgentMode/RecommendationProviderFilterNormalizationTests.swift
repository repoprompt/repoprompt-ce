@testable import RepoPromptApp
import XCTest

@MainActor
final class RecommendationProviderFilterNormalizationTests: XCTestCase {
    func testRecommendationProviderFilterNormalizationMatrix() {
        let currentAllProviders = Set(RecommendationProviderKind.allCases)
        let rows: [(label: String, raw: [String], expected: Set<RecommendationProviderKind>)] = [
            ("removed-only", ["geminiCLI"], currentAllProviders),
            ("explicit-empty", [], []),
            ("legacy-all-providers", ["claudeCode", "codex", "openAI", "anthropic", "geminiCLI"], currentAllProviders)
        ]

        for row in rows {
            XCTAssertEqual(
                GlobalSettingsStore.normalizedRecommendationProviderFilter(raw: row.raw),
                row.expected,
                row.label
            )
        }
    }
}
