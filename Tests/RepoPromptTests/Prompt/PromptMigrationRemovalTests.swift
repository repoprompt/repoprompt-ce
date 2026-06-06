@testable import RepoPrompt
import RepoPromptCore
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

    func testPromptSnapshotProjectionDelegatesReconstructionAndGuardsAsyncPublication() throws {
        let root = try RepoRoot.url(filePath: #filePath)
        let snapshotSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel+PromptSnapshotEntries.swift"
            ),
            encoding: .utf8
        )
        let viewModelSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift"
            ),
            encoding: .utf8
        )
        let adapterSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPrompt/Features/Prompt/Services/WorkspacePromptProjectionAdapter.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(snapshotSource.contains("WorkspacePromptProjectionAdapter(store: workspaceFileContextStore)"))
        XCTAssertTrue(snapshotSource.contains("chatPromptEntriesProjectionGeneration == generation"))
        XCTAssertTrue(snapshotSource.contains("chatPromptEntriesRequest().key == request.key"))
        XCTAssertTrue(adapterSource.contains("captureWorkspaceFileContext"))
        XCTAssertTrue(adapterSource.contains("WorkspaceContextProjectionService"))
        XCTAssertTrue(adapterSource.contains("sections: [.selection]"))

        for removedReconstruction in [
            "buildPromptSnapshotEntriesForCurrentChatProjection",
            "fileManager.selectedFiles",
            "fileManager.autoCodemapFiles",
            "selectionSlicesByFileID",
            "validatedCurrentFileAPIs",
            "switch codeMapUsage"
        ] {
            XCTAssertFalse(snapshotSource.contains(removedReconstruction), removedReconstruction)
        }
        XCTAssertFalse(viewModelSource.contains("chatCodemapFileAPIs"))
        XCTAssertFalse(viewModelSource.contains("refreshChatCodemapFileAPIsFromStore"))
        XCTAssertFalse(adapterSource.contains("switch codeMapUsage"))
    }

    func testPromptTokenEstimatesUseExactRenderedPayloadAndRemovedArithmeticCannotReturn() throws {
        let root = try RepoRoot.url(filePath: #filePath)
        let packagingSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPrompt/Features/Prompt/Services/PromptPackagingService.swift"
            ),
            encoding: .utf8
        )
        let viewModelSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(packagingSource.contains("TokenProjectionService.exactRenderedPayload"))
        XCTAssertTrue(packagingSource.contains("PromptGitDiffArtifactClassifier"))
        XCTAssertTrue(packagingSource.contains("exactChatPayload"))
        XCTAssertEqual(packagingSource.components(separatedBy: "rootFolderName = \"_git_data\"").count - 1, 1)
        XCTAssertTrue(viewModelSource.contains("buildClipboardPayload"))
        XCTAssertTrue(viewModelSource.contains("packagePromptResult"))
        XCTAssertTrue(viewModelSource.contains("exactPayload.projection.total"))

        for removedTokenPath in [
            "Int(Double(text.count) / 4.0)",
            "ChatContextTokenBaselineCache",
            "baseTokensWithoutPromptText",
            "supportsPromptTextDeltas",
            "promptTextDuplicateFactor",
            "chatContextTokenBaselineCacheKey"
        ] {
            XCTAssertFalse(viewModelSource.contains(removedTokenPath), removedTokenPath)
        }
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
