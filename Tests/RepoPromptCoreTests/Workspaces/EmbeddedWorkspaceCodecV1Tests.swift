import Foundation
@testable import RepoPromptCore
import XCTest

final class EmbeddedWorkspaceCodecV1Tests: XCTestCase {
    func testRoundTripPreservesAppV1CodingKeysAndValues() throws {
        let tab = ComposeTabState(
            name: "T1",
            selection: StoredSelection(
                selectedPaths: ["/tmp/root/Full.swift"],
                autoCodemapPaths: ["/tmp/root/Structure.swift"],
                slices: ["/tmp/root/Sliced.swift": [LineRange(start: 2, end: 4, description: "slice")]],
                codemapAutoEnabled: false
            ),
            promptText: "prompt",
            contextBuilder: ContextBuilderTabConfig(instructions: "discover instructions")
        )
        let workspace = WorkspaceModel(
            id: UUID(),
            dateModified: Date(timeIntervalSince1970: 123),
            name: "Codec",
            repoPaths: ["/tmp/root"],
            composeTabs: [tab],
            activeComposeTabID: tab.id
        )
        let codec = EmbeddedWorkspaceCodecV1()

        let encoded = try codec.encode(workspace)
        let json = try XCTUnwrap(String(data: encoded.data, encoding: .utf8))
        let decoded = try codec.decode(encoded.data)

        XCTAssertEqual(encoded.schemaVersion, EmbeddedWorkspaceCodecV1.formatVersion)
        XCTAssertTrue(json.contains("\"discover\""), json)
        XCTAssertFalse(json.contains("\"contextBuilder\""), json)
        XCTAssertEqual(decoded.sourceVersion, EmbeddedWorkspaceCodecV1.formatVersion)
        XCTAssertFalse(decoded.requiresRewrite)
        XCTAssertEqual(decoded.document, workspace)
    }

    func testDecodeReportsNormalizationWithoutMutatingBytes() throws {
        let workspaceID = UUID()
        let payload = Data("""
        {
          "id": "\(workspaceID.uuidString)",
          "schemaVersion": 1,
          "dateModified": 0,
          "name": "Legacy",
          "repoPaths": ["/tmp/root"],
          "currentPromptText": "legacy prompt",
          "selectedMetaPromptIDs": [],
          "composeTabs": [],
          "stashedTabs": []
        }
        """.utf8)

        let result = try EmbeddedWorkspaceCodecV1().decode(payload)

        XCTAssertTrue(result.requiresRewrite)
        XCTAssertEqual(result.document.composeTabs.count, 1)
        XCTAssertEqual(result.document.composeTabs[0].promptText, "legacy prompt")
        XCTAssertEqual(result.sourceVersion, EmbeddedWorkspaceCodecV1.formatVersion)
        XCTAssertEqual(payload, Data(payload))
    }

    func testMalformedComposeTabsProducesWarningAndNormalizedDefaultTab() throws {
        let workspaceID = UUID()
        let payload = Data("""
        {
          "id": "\(workspaceID.uuidString)",
          "schemaVersion": 1,
          "dateModified": 0,
          "name": "Malformed",
          "repoPaths": ["/tmp/root"],
          "composeTabs": "not-an-array",
          "stashedTabs": []
        }
        """.utf8)

        let result = try EmbeddedWorkspaceCodecV1().decode(payload)

        XCTAssertEqual(result.warnings.map(\.code), ["compose_tabs_decode_failed"])
        XCTAssertTrue(result.requiresRewrite)
        XCTAssertEqual(result.document.composeTabs.count, 1)
    }
}
