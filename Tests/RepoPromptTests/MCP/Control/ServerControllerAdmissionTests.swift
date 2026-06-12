@testable import RepoPrompt
import XCTest

final class ServerControllerAdmissionTests: XCTestCase {
    func testRepoPromptCLIClientNamesAreRecognizedForVerificationOnly() {
        #if DEBUG
            XCTAssertTrue(ServerController.test_isRepoPromptCLIClientName("RepoPrompt CLI"))
            XCTAssertTrue(ServerController.test_isRepoPromptCLIClientName(" RepoPrompt CLI (Exec) "))
            XCTAssertTrue(ServerController.test_isRepoPromptCLIClientName("RepoPrompt CLI 1.2.3"))
            XCTAssertFalse(ServerController.test_isRepoPromptCLIClientName("Spoofed RepoPrompt CLI"))
            XCTAssertFalse(ServerController.test_isRepoPromptCLIClientName("repoPrompt CLI"))
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testDefaultAllowListDoesNotIncludeRepoPromptCLI() {
        #if DEBUG
            XCTAssertFalse(
                ServerController.test_defaultAlwaysAllowedClients.contains {
                    ServerController.test_isRepoPromptCLIClientName($0)
                }
            )
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testDefaultAllowListIncludesSynchronousACPClients() throws {
        #if DEBUG
            let allowed = ServerController.test_defaultAlwaysAllowedClients

            XCTAssertTrue(allowed.contains(AgentProviderKind.openCodeMCPClientID))
            XCTAssertTrue(allowed.contains(AgentProviderKind.cursorMCPClientID))
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testBuiltInAlwaysAllowedClientMatchesDefaultFamiliesAndVariants() {
        XCTAssertTrue(ServerController.isBuiltInAlwaysAllowedClient("claude-code"))
        XCTAssertTrue(ServerController.isBuiltInAlwaysAllowedClient("Claude Code v2.1"))
        XCTAssertTrue(ServerController.isBuiltInAlwaysAllowedClient("opencode"))
        XCTAssertTrue(ServerController.isBuiltInAlwaysAllowedClient("cursor-agent"))
        XCTAssertFalse(ServerController.isBuiltInAlwaysAllowedClient("my-custom-client"))
        XCTAssertFalse(ServerController.isBuiltInAlwaysAllowedClient("RepoPrompt CLI"))
    }

    func testSanitizerRemovesPersistedRepoPromptCLIAllowListEntries() {
        #if DEBUG
            let sanitized = ServerController.test_sanitizedAlwaysAllowedClients([
                "RepoPrompt CLI",
                "RepoPrompt CLI (Exec)",
                "RepoPrompt CLI 1.2.3",
                "claude-code",
                "custom-client"
            ])

            XCTAssertEqual(sanitized, ["claude-code", "custom-client"])
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }
}
