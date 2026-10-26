@testable import RepoPromptApp
import XCTest

@MainActor
final class ContextBuilderReviewDiscoveryPromptTests: XCTestCase {
    private let artifactPublicationCall = #"{"tool":"git","args":{"op":"diff","artifacts":true}}"#
    private let mustSelectArtifacts = "You **must** select the diff patches"
    private let haltingWithoutArtifacts = "Halting without selecting any diff artifacts"

    func testReviewPromptWithElectedTargetKeepsArtifactPublicationGuidance() {
        let prompt = SystemPromptService.discoverPrompt(responseType: "review")

        XCTAssertTrue(prompt.contains("## Review Mode"))
        XCTAssertTrue(prompt.contains(artifactPublicationCall))
        XCTAssertTrue(prompt.contains(mustSelectArtifacts))
        XCTAssertTrue(prompt.contains(haltingWithoutArtifacts))
        XCTAssertEqual(prompt, SystemPromptService.discoverPrompt(responseType: "review", restrictsReviewGitToExplicitReadOnly: false))
    }

    func testReviewPromptWithUnelectedTargetOnlyInstructsAdmittedReadOnlyGitInspection() {
        let prompt = SystemPromptService.discoverPrompt(
            responseType: "review",
            restrictsReviewGitToExplicitReadOnly: true,
            reviewRootNames: ["repoprompt-ce"]
        )

        XCTAssertTrue(prompt.contains("## Review Mode"))
        XCTAssertFalse(prompt.contains(#""artifacts":true"#), prompt)
        XCTAssertFalse(prompt.contains(mustSelectArtifacts), prompt)
        XCTAssertFalse(prompt.contains(haltingWithoutArtifacts), prompt)
        XCTAssertTrue(prompt.contains(#"{"tool":"git","args":{"op":"diff","repo_root":"repoprompt-ce","detail":"files"}}"#), prompt)
        XCTAssertFalse(prompt.contains("<root>"), prompt)
        XCTAssertTrue(prompt.contains("omit `artifacts`"), prompt)
        XCTAssertTrue(prompt.contains("manage_selection"), prompt)
    }

    func testReviewPromptWithUnelectedTargetAndUnknownRootsDescribesRepoRootWithoutPlaceholder() {
        let prompt = SystemPromptService.discoverPrompt(
            responseType: "review",
            restrictsReviewGitToExplicitReadOnly: true
        )

        XCTAssertFalse(prompt.contains(#""artifacts":true"#), prompt)
        XCTAssertFalse(prompt.contains("<root>"), prompt)
        XCTAssertFalse(prompt.contains(#""repo_root":""#), prompt)
        XCTAssertTrue(prompt.contains("as listed by `get_file_tree` with `type` `roots`"), prompt)
    }

    func testRestrictionFlagDoesNotAddReviewGuidanceOutsideReviewMode() {
        XCTAssertEqual(
            SystemPromptService.discoverPrompt(responseType: "plan", restrictsReviewGitToExplicitReadOnly: true),
            SystemPromptService.discoverPrompt(responseType: "plan")
        )
    }

    func testRestrictionFollowsNestedDiscoveryReviewTargetResolution() {
        func configuration(_ resolution: ContextBuilderReviewTargetResolution?) -> ContextBuilderMCPRunConfiguration {
            ContextBuilderMCPRunConfiguration(
                identity: WorkspaceSelectionIdentity(workspaceID: UUID(), tabID: UUID()),
                nestedTabContext: MCPServerViewModel.TabContextSnapshot(
                    tabID: UUID(),
                    windowID: 1,
                    workspaceID: UUID(),
                    promptText: "",
                    selection: StoredSelection(selectedPaths: [], codemapAutoEnabled: false),
                    selectedMetaPromptIDs: [],
                    tabName: "Review",
                    runID: UUID(),
                    contextBuilderReviewTargetResolution: resolution,
                    explicitlyBound: true
                ),
                providerWorkspacePath: "/tmp/workspace",
                runBehavior: ContextBuilderRunBehavior(
                    tokenBudget: 50000,
                    enhancementMode: .augment,
                    questionTimeoutSeconds: 60,
                    allowClarifyingQuestions: false,
                    automaticFollowUp: nil
                ),
                responseType: "review",
                generatedResponseAuthority: .contextOnly,
                isSystemWorkspace: false
            )
        }
        let deferred = ContextBuilderReviewTargetResolution.deferred(ContextBuilderDeferredReviewAuthority(
            workspaceID: UUID(),
            tabID: UUID(),
            initialSelectionRevision: 0,
            lookupContext: .visibleWorkspace,
            reviewGitContext: FrozenPromptGitReviewContext(
                artifactCapability: nil,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            )
        ))

        XCTAssertTrue(ContextBuilderAgentViewModel.restrictsReviewGitToExplicitReadOnly(
            workspaceContext: nil,
            mcpConfiguration: configuration(deferred)
        ))
        // The Git policy refuses artifacts for unavailable targets too, so the prompt must not ask for them.
        XCTAssertTrue(ContextBuilderAgentViewModel.restrictsReviewGitToExplicitReadOnly(
            workspaceContext: nil,
            mcpConfiguration: configuration(.unavailable(.nonGitSelection(count: 1)))
        ))
        XCTAssertFalse(ContextBuilderAgentViewModel.restrictsReviewGitToExplicitReadOnly(
            workspaceContext: nil,
            mcpConfiguration: configuration(nil)
        ))
        XCTAssertFalse(ContextBuilderAgentViewModel.restrictsReviewGitToExplicitReadOnly(workspaceContext: nil, mcpConfiguration: nil))
    }
}
