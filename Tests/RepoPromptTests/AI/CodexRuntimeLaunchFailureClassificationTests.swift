import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexRuntimeLaunchFailureClassificationTests: XCTestCase {
    func testSentinelClassifierAcceptsPrefixedMessagesAndRejectsRewrittenGuidance() {
        XCTAssertTrue(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "RepoPrompt could not start Codex: the bundled package is missing. Reinstall RepoPrompt CE."
            )
        )
        XCTAssertTrue(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "\n  RepoPrompt could not start Codex: leading whitespace is tolerated."
            )
        )
        XCTAssertFalse(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "The selected Codex runtime could not be started. Reinstall RepoPrompt CE or configure a valid explicit override."
            )
        )
        XCTAssertFalse(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "Permission denied. Ensure the 'codex' executable is accessible."
            )
        )
        XCTAssertFalse(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "Codex is unavailable because RepoPrompt could not start Codex: (prefix must lead the message)"
            )
        )
    }
}
