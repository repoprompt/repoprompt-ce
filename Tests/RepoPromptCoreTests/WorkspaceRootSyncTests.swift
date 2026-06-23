@testable import RepoPromptCore
import XCTest

final class WorkspaceRootSyncTests: XCTestCase {
    func testWorkspaceDecodeCreatesDefaultComposeTabAndIgnoresRemovedLegacyFields() throws {
        let workspaceID = UUID()
        let payload = """
        {
          "id": "\(workspaceID.uuidString)",
          "schemaVersion": 1,
          "dateModified": 0,
          "name": "Legacy Fields",
          "repoPaths": ["/tmp/root"],
          "presets": [],
          "lastUsed": 0,
          "selectedMetaPromptIDs": [],
          "workingFilePaths": ["/tmp/root/legacy.swift"],
          "workingExpandedFolders": ["/tmp/root"],
          "contextBuilderState": { "useOverridePrompt": true, "overridePromptText": "legacy override" },
          "discoveryInstructions": "legacy instructions",
          "discoveryAgentRaw": "codexExec",
          "composeTabs": [],
          "stashedTabs": []
        }
        """

        let decoded = try JSONDecoder().decode(WorkspaceModel.self, from: Data(payload.utf8))

        XCTAssertEqual(decoded.composeTabs.count, 1)
        XCTAssertEqual(decoded.activeComposeTabID, decoded.composeTabs[0].id)
        XCTAssertEqual(decoded.composeTabs[0].selection, StoredSelection())
        XCTAssertEqual(decoded.composeTabs[0].expandedFolders, [])
        XCTAssertEqual(decoded.composeTabs[0].contextOverrides, ContextBuilderOverrides())
        XCTAssertEqual(decoded.composeTabs[0].contextBuilder.instructions, "")
        XCTAssertTrue(decoded.normalizationRequiresSave)

        let encoded = try String(data: JSONEncoder().encode(decoded), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("workingFilePaths"), encoded)
        XCTAssertFalse(encoded.contains("contextBuilderState"), encoded)
        XCTAssertFalse(encoded.contains("discoveryInstructions"), encoded)
    }

    func testWorkspacePersistenceLegacyDecodeCurrentEncodeAndCurrentReaderRoundTripContract() throws {
        let legacyPayload = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "schemaVersion": 1,
          "dateModified": 0,
          "isSystemWorkspace": false,
          "isHiddenInMenus": false,
          "ephemeralFlag": false,
          "name": "Persistence Contract",
          "repoPaths": ["/tmp/root-b", "/tmp/root-a"],
          "presets": [],
          "lastUsed": 42,
          "currentPromptText": "legacy top-level prompt",
          "lastSearchQuery": "needle",
          "selectedMetaPromptIDs": [],
          "workingFilePaths": ["/tmp/root-b/removed.swift"],
          "contextBuilderState": {"useOverridePrompt": true},
          "composeTabs": [{
            "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "name": "T1",
            "lastModified": 5,
            "isPinned": true,
            "selection": {
              "selectedPaths": ["/tmp/root-b/B.swift", "/tmp/root-a/A.swift"],
              "autoCodemapPaths": ["/tmp/root-a/A.swift"],
              "slices": {
                "/tmp/root-b/B.swift": [{"start": 2, "end": 4, "description": "kept"}]
              },
              "codemapAutoEnabled": false
            },
            "expandedFolders": ["/tmp/root-b", "/tmp/root-a"],
            "promptText": "tab prompt",
            "selectedMetaPromptIDs": [],
            "contextOverrides": {"useOverridePrompt": true, "overridePromptText": "override"},
            "discover": {
              "instructions": "review the workspace",
              "autoGeneratePlan": true,
              "followUpTypeRaw": "review",
              "selectedContextBuilderPromptIDs": ["99999999-8888-7777-6666-555555555555"]
            }
          }],
          "activeComposeTabID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "stashedTabs": []
        }
        """
        let expectedCurrentPayload = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "schemaVersion": 1,
          "dateModified": 0,
          "isSystemWorkspace": false,
          "isHiddenInMenus": false,
          "ephemeralFlag": false,
          "name": "Persistence Contract",
          "repoPaths": ["/tmp/root-b", "/tmp/root-a"],
          "presets": [],
          "lastUsed": 42,
          "currentPromptText": "legacy top-level prompt",
          "lastSearchQuery": "needle",
          "selectedMetaPromptIDs": [],
          "composeTabs": [{
            "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "name": "T1",
            "lastModified": 5,
            "isPinned": true,
            "selection": {
              "selectedPaths": ["/tmp/root-b/B.swift", "/tmp/root-a/A.swift"],
              "autoCodemapPaths": ["/tmp/root-a/A.swift"],
              "slices": {
                "/tmp/root-b/B.swift": [{"start": 2, "end": 4, "description": "kept"}]
              },
              "codemapAutoEnabled": false
            },
            "expandedFolders": ["/tmp/root-b", "/tmp/root-a"],
            "promptText": "tab prompt",
            "selectedMetaPromptIDs": [],
            "contextOverrides": {"useOverridePrompt": true, "overridePromptText": "override"},
            "discover": {
              "instructions": "review the workspace",
              "autoGeneratePlan": true,
              "followUpTypeRaw": "review",
              "selectedContextBuilderPromptIDs": ["99999999-8888-7777-6666-555555555555"]
            }
          }],
          "activeComposeTabID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "stashedTabs": []
        }
        """

        let decoded = try JSONDecoder().decode(WorkspaceModel.self, from: Data(legacyPayload.utf8))
        XCTAssertFalse(decoded.normalizationRequiresSave)

        let currentBytes = try JSONEncoder().encode(decoded)
        XCTAssertEqual(
            try canonicalJSON(currentBytes),
            try canonicalJSON(Data(expectedCurrentPayload.utf8))
        )

        let currentReaderDecoded = try JSONDecoder().decode(WorkspaceModel.self, from: currentBytes)
        XCTAssertEqual(currentReaderDecoded, decoded)
        XCTAssertFalse(currentReaderDecoded.normalizationRequiresSave)
        XCTAssertEqual(
            try canonicalJSON(JSONEncoder().encode(currentReaderDecoded)),
            try canonicalJSON(currentBytes)
        )
    }

    func testNewWorkspaceBytesDecodeThroughIndependentLegacyRollbackReader() throws {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let tabID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let promptID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let tab = ComposeTabState(
            id: tabID,
            name: "T1",
            lastModified: Date(timeIntervalSinceReferenceDate: 5),
            isPinned: true,
            selection: StoredSelection(
                selectedPaths: ["/tmp/root-b/B.swift", "/tmp/root-a/A.swift"],
                autoCodemapPaths: ["/tmp/root-a/A.swift"],
                slices: ["/tmp/root-b/B.swift": [LineRange(start: 2, end: 4, description: "kept")]],
                codemapAutoEnabled: false
            ),
            expandedFolders: ["/tmp/root-b", "/tmp/root-a"],
            promptText: "tab prompt",
            selectedMetaPromptIDs: [],
            activeSubView: .context,
            contextOverrides: ContextBuilderOverrides(
                useOverridePrompt: true,
                overridePromptText: "override"
            ),
            contextBuilder: ContextBuilderTabConfig(
                instructions: "review the workspace",
                autoGeneratePlan: true,
                followUpTypeRaw: "review",
                selectedContextBuilderPromptIDs: [promptID]
            )
        )
        let workspace = WorkspaceModel(
            id: workspaceID,
            schemaVersion: 1,
            dateModified: Date(timeIntervalSinceReferenceDate: 0),
            name: "Persistence Contract",
            repoPaths: ["/tmp/root-b", "/tmp/root-a"],
            lastUsed: Date(timeIntervalSinceReferenceDate: 42),
            currentPromptText: "legacy top-level prompt",
            lastSearchQuery: "needle",
            composeTabs: [tab],
            activeComposeTabID: tabID
        )

        let newBytes = try JSONEncoder().encode(workspace)
        let rollback = try JSONDecoder().decode(LegacyRollbackWorkspace.self, from: newBytes)

        XCTAssertEqual(rollback.id, workspaceID)
        XCTAssertEqual(rollback.schemaVersion, 1)
        XCTAssertEqual(rollback.name, "Persistence Contract")
        XCTAssertEqual(rollback.repoPaths, ["/tmp/root-b", "/tmp/root-a"])
        XCTAssertEqual(rollback.composeTabs.map(\.id), [tabID])
        XCTAssertEqual(rollback.composeTabs[0].selection.selectedPaths, [
            "/tmp/root-b/B.swift",
            "/tmp/root-a/A.swift"
        ])
        XCTAssertEqual(rollback.composeTabs[0].selection.slices["/tmp/root-b/B.swift"]?.first?.description, "kept")
        XCTAssertEqual(rollback.composeTabs[0].discover.instructions, "review the workspace")
        XCTAssertEqual(rollback.composeTabs[0].discover.followUpTypeRaw, "review")
        XCTAssertEqual(rollback.activeComposeTabID, tabID)
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private struct LegacyRollbackWorkspace: Decodable {
    struct Tab: Decodable {
        struct Selection: Decodable {
            let selectedPaths: [String]
            let autoCodemapPaths: [String]
            let slices: [String: [LineRange]]
            let codemapAutoEnabled: Bool
        }

        struct Discover: Decodable {
            let instructions: String
            let autoGeneratePlan: Bool?
            let followUpTypeRaw: String?
            let selectedContextBuilderPromptIDs: [UUID]
        }

        let id: UUID
        let name: String
        let selection: Selection
        let expandedFolders: [String]
        let promptText: String
        let discover: Discover
    }

    let id: UUID
    let schemaVersion: Int
    let name: String
    let repoPaths: [String]
    let composeTabs: [Tab]
    let activeComposeTabID: UUID?
}
