@testable import RepoPromptApp
import XCTest

@MainActor
final class ReviewPromptUpgradeTests: XCTestCase {
    func testUneditedV2ReviewPromptUpgradesAndEditedCopiesArePreserved() {
        let prompts = makePromptViewModel()
        let v2 = prompts.previousReviewPromptV2
        XCTAssertEqual(v2.id, prompts.reviewPrompt.id)
        XCTAssertNotEqual(v2.content, prompts.reviewPrompt.content)
        XCTAssertTrue(prompts.isKnownPreviousCanonical(v2))
        XCTAssertFalse(prompts.isKnownPreviousCanonical(prompts.reviewPrompt))

        var edited = v2
        edited.content += "\nAlso check logging."
        XCTAssertFalse(prompts.isKnownPreviousCanonical(edited))

        var retitled = v2
        retitled.title = "[My Review]"
        XCTAssertFalse(prompts.isKnownPreviousCanonical(retitled))
    }

    func testV1ReviewFingerprintStillUpgrades() {
        let prompts = makePromptViewModel()
        let v1 = PromptViewModel.StoredPrompt(
            id: prompts.reviewPrompt.id,
            title: "[Review]",
            content: "Acknowledge what's done particularly well.\nAre the commit boundaries logical?"
        )
        XCTAssertTrue(prompts.isKnownPreviousCanonical(v1))
    }

    func testCurrentReviewPromptAsksForComparableFindings() {
        let content = makePromptViewModel().reviewPrompt.content
        for required in [
            "\t- **Location**: file and line or symbol.",
            "**Confidence**: Confirmed, Likely, or Speculative.",
            "Merge findings that share a root cause.",
            "`Verdict: <No findings | Approve with fixes | Request changes> — <one-sentence reason>`"
        ] {
            XCTAssertTrue(content.contains(required), required)
        }
    }

    private func makePromptViewModel() -> PromptViewModel {
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let api = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager), keyManager: keyManager, loadStoredDataOnInit: false
        )
        addTeardownBlock { @MainActor in api.prepareForWindowClose() }
        return PromptViewModel(
            fileManager: WorkspaceFilesViewModel(), apiSettingsViewModel: api, windowID: -1931,
            settingsManager: WindowSettingsManager(windowID: -1931)
        )
    }
}
