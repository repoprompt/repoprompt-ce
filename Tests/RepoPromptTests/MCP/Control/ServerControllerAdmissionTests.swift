@testable import RepoPromptApp
import XCTest

final class ServerControllerAdmissionTests: XCTestCase {
    func testRepoPromptCLIAdmissionIdentityIsRecognizedButSanitizedFromPersistence() throws {
        #if DEBUG
            do {
                let caseLabel = "testRepoPromptCLIClientNamesAreRecognizedForVerificationOnly"
                XCTAssertTrue(ServerController.test_isRepoPromptCLIClientName("RepoPrompt CLI"), caseLabel)
                XCTAssertTrue(ServerController.test_isRepoPromptCLIClientName(" RepoPrompt CLI (Exec) "), caseLabel)
                XCTAssertTrue(ServerController.test_isRepoPromptCLIClientName("RepoPrompt CLI 1.2.3"), caseLabel)
                XCTAssertFalse(ServerController.test_isRepoPromptCLIClientName("Spoofed RepoPrompt CLI"), caseLabel)
                XCTAssertFalse(ServerController.test_isRepoPromptCLIClientName("repoPrompt CLI"), caseLabel)
            }

            do {
                let caseLabel = "testSanitizerRemovesPersistedRepoPromptCLIAllowListEntries"
                let sanitized = ServerController.test_sanitizedAlwaysAllowedClients([
                    "RepoPrompt CLI",
                    "RepoPrompt CLI (Exec)",
                    "RepoPrompt CLI 1.2.3",
                    "claude-code",
                    "custom-client"
                ])

                XCTAssertEqual(sanitized, ["claude-code", "custom-client"], caseLabel)
            }
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds: testRepoPromptCLIClientNamesAreRecognizedForVerificationOnly, testSanitizerRemovesPersistedRepoPromptCLIAllowListEntries")
        #endif
    }

    func testDefaultAdmissionAllowListExcludesRepoPromptCLIAndIncludesSynchronousACPClients() throws {
        #if DEBUG
            do {
                let caseLabel = "testDefaultAllowListDoesNotIncludeRepoPromptCLI"
                XCTAssertFalse(
                    ServerController.test_defaultAlwaysAllowedClients.contains {
                        ServerController.test_isRepoPromptCLIClientName($0)
                    },
                    caseLabel
                )
            }

            do {
                let caseLabel = "testDefaultAllowListIncludesSynchronousACPClients"
                let allowed = ServerController.test_defaultAlwaysAllowedClients

                XCTAssertTrue(allowed.contains(AgentProviderKind.openCodeMCPClientID), caseLabel)
                XCTAssertTrue(allowed.contains(AgentProviderKind.cursorMCPClientID), caseLabel)
            }
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds: testDefaultAllowListDoesNotIncludeRepoPromptCLI, testDefaultAllowListIncludesSynchronousACPClients")
        #endif
    }

    func testBuiltInAlwaysAllowedClientRecognizesConfiguredDefaultsAndVariants() throws {
        #if DEBUG
            for clientID in ServerController.test_defaultAlwaysAllowedClients {
                XCTAssertTrue(
                    ServerController.isBuiltInAlwaysAllowedClient(clientID),
                    "Expected configured default to be recognized: \(clientID)"
                )
            }

            for clientID in ["Claude Code v2.1", "cursor-agent"] {
                XCTAssertTrue(
                    ServerController.isBuiltInAlwaysAllowedClient(clientID),
                    "Expected supported family variant to be recognized: \(clientID)"
                )
            }

            for clientID in ["my-custom-client", "RepoPrompt CLI", "claude-code-wrapper", "cursor-agent-wrapper"] {
                XCTAssertFalse(
                    ServerController.isBuiltInAlwaysAllowedClient(clientID),
                    "Expected non-built-in client to require approval: \(clientID)"
                )
            }
        #else
            throw XCTSkip("DEBUG-only default allow-list seam is unavailable in release builds")
        #endif
    }
}
