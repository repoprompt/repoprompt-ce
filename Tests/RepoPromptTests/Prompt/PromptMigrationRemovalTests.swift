@testable import RepoPromptApp
import RepoPromptSecureStorage
import XCTest

final class PromptMigrationRemovalTests: XCTestCase {
    @MainActor
    func testMissingCopyPresetSelectionFallsBackToDocumentedStandardDefault() {
        XCTAssertEqual(PromptViewModel.defaultCopyPresetID, BuiltInCopyPresets.standard.id)
    }

    @MainActor
    func testPromptSectionOrderUsesValidStoredOrderWithoutOldDefaultMigration() throws {
        let order: [PromptSection] = [.fileMap, .fileContents, .gitDiff, .metaPrompts, .userInstructions]
        let raw = try String(data: JSONEncoder().encode(order), encoding: .utf8).unwrapForTest()

        XCTAssertEqual(PromptViewModel.resolvedPromptSectionOrder(raw: raw), order)
    }

    @MainActor
    func testLegacyDiffFormattingSectionFallsBackToCurrentDefault() {
        let legacyRaw = "[\u{22}fileMap\u{22},\u{22}fileContents\u{22},\u{22}gitDiff\u{22},\u{22}diffFormatting\u{22},\u{22}metaPrompts\u{22},\u{22}userInstructions\u{22}]"

        XCTAssertEqual(PromptViewModel.resolvedPromptSectionOrder(raw: legacyRaw), PromptAssemblyBuilder.defaultSectionOrder)
    }

    @MainActor
    func testPromptSectionOrderFallsBackToCurrentDefaultForMissingOrInvalidOrder() throws {
        XCTAssertEqual(PromptViewModel.resolvedPromptSectionOrder(raw: ""), PromptAssemblyBuilder.defaultSectionOrder)

        let incomplete: [PromptSection] = [.fileMap, .fileContents]
        let raw = try String(data: JSONEncoder().encode(incomplete), encoding: .utf8).unwrapForTest()
        XCTAssertEqual(PromptViewModel.resolvedPromptSectionOrder(raw: raw), PromptAssemblyBuilder.defaultSectionOrder)
    }

    func testLegacyCopyPresetEditAndMCPFieldsDecodeSafelyAndDoNotReencode() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        let raw = """
        {
          "id": "\(id.uuidString)",
          "name": "Legacy MCP XML",
          "builtInKind": "mcpAgent",
          "isBuiltIn": true,
          "includeFiles": true,
          "xmlFormat": "diff",
          "systemPromptFlavor": "mcpAgent",
          "includeMCPMetadata": true
        }
        """.data(using: .utf8)!

        let preset = try JSONDecoder().decode(CopyPreset.self, from: raw)
        XCTAssertEqual(preset.builtInKind, .standard)
        XCTAssertEqual(preset.includeFiles, true)

        let encoded = try String(data: JSONEncoder().encode(preset), encoding: .utf8).unwrapForTest()
        XCTAssertFalse(encoded.contains("xmlFormat"))
        XCTAssertFalse(encoded.contains("systemPromptFlavor"))
        XCTAssertFalse(encoded.contains("includeMCPMetadata"))
    }

    func testLegacyCopyOverridesAndCustomizationsIgnoreRemovedFields() throws {
        let presetID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000456"))
        let overridesRaw = """
        {
          "presetID": "\(presetID.uuidString)",
          "includeFiles": false,
          "xmlFormat": "whole",
          "systemPromptFlavor": "mcpBuilder",
          "includeMCPMetadata": true
        }
        """.data(using: .utf8)!
        let overrides = try JSONDecoder().decode(CopyPresetOverrides.self, from: overridesRaw)
        XCTAssertEqual(overrides.presetID, presetID)
        XCTAssertEqual(overrides.includeFiles, false)

        let customRaw = """
        {
          "includeUserPrompt": false,
          "xmlFormat": "architect",
          "systemPromptFlavor": "mcpDiscover",
          "includeMCPMetadata": true
        }
        """.data(using: .utf8)!
        let custom = try JSONDecoder().decode(CopyCustomizations.self, from: customRaw)
        XCTAssertEqual(custom.includeUserPrompt, false)

        let encodedOverrides = try String(data: JSONEncoder().encode(overrides), encoding: .utf8).unwrapForTest()
        let encodedCustom = try String(data: JSONEncoder().encode(custom), encoding: .utf8).unwrapForTest()
        for removedKey in ["xmlFormat", "systemPromptFlavor", "includeMCPMetadata"] {
            XCTAssertFalse(encodedOverrides.contains(removedKey))
            XCTAssertFalse(encodedCustom.contains(removedKey))
        }
    }
}

private extension String? {
    func unwrapForTest(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(self, file: file, line: line)
    }
}

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

    func testUneditedV3ReviewPromptUpgradesAndEditedCopiesArePreserved() {
        let prompts = makePromptViewModel()
        let v3 = prompts.previousReviewPromptV3
        XCTAssertEqual(v3.id, prompts.reviewPrompt.id)
        XCTAssertNotEqual(v3.content, prompts.reviewPrompt.content)
        XCTAssertTrue(prompts.isKnownPreviousCanonical(v3))

        var edited = v3
        edited.content += "\nMy extra rule."
        XCTAssertFalse(prompts.isKnownPreviousCanonical(edited))
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
        XCTAssertFalse(content.contains("one of several independent reviews"))
        XCTAssertFalse(content.contains("**Confidence**"))
        for required in [
            "\t- **Location**: file and line or symbol.",
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
