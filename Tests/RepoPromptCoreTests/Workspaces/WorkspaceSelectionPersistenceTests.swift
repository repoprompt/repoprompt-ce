import Foundation
@testable import RepoPromptCore
import XCTest

final class WorkspaceSelectionPersistenceTests: XCTestCase {
    func testWriterPreservesNewerSelectionRevisionAgainstLaterStalePayload() async throws {
        let url = try makeWorkspaceURL()
        let writer = WorkspacePersistenceWriter()
        let workspaceID = UUID()
        let tabID = UUID()
        let correct = workspace(
            id: workspaceID,
            tabID: tabID,
            selection: selection(count: 7),
            dateModified: Date(timeIntervalSince1970: 100),
            promptText: "correct"
        )
        let correctReceipt = try await writer.enqueueWorkspace(
            correct,
            url: url,
            metadata: makeSlice1Metadata(for: correct, source: "test.correctSelection", selectionRevision: 2)
        )
        _ = await writer.flush(correctReceipt)

        let stale = workspace(
            id: workspaceID,
            tabID: tabID,
            selection: selection(count: 15, includeSlices: true),
            dateModified: Date(timeIntervalSince1970: 200),
            promptText: "stale-non-selection-field"
        )
        let staleReceipt = try await writer.enqueueWorkspace(
            stale,
            url: url,
            metadata: makeSlice1Metadata(for: stale, source: "test.staleSelection", selectionRevision: 1)
        )
        _ = await writer.flush(staleReceipt)

        let decoded = try EmbeddedWorkspaceCodecV1().decode(Data(contentsOf: url)).document
        XCTAssertEqual(decoded.composeTabs[0].selection, correct.composeTabs[0].selection)
        XCTAssertEqual(decoded.composeTabs[0].promptText, "stale-non-selection-field")
    }

    func testWriterPreservesNewerInactiveTabSelectionAgainstLaterStalePayload() async throws {
        let url = try makeWorkspaceURL()
        let writer = WorkspacePersistenceWriter()
        let workspaceID = UUID()
        let activeTabID = UUID()
        let inactiveTabID = UUID()
        let correctSelection = selection(count: 7)
        let staleSelection = selection(count: 15, includeSlices: true)
        let activeTab = ComposeTabState(id: activeTabID, name: "Active")
        let correctInactive = ComposeTabState(id: inactiveTabID, name: "Inactive", selection: correctSelection)
        let correct = WorkspaceModel(
            id: workspaceID,
            dateModified: Date(timeIntervalSince1970: 100),
            name: "Inactive selection",
            repoPaths: ["/tmp/root"],
            composeTabs: [activeTab, correctInactive],
            activeComposeTabID: activeTabID
        )
        let correctMetadata = WorkspaceSavePayloadMetadata(
            source: "test.correctInactive",
            owner: .none,
            workspaceID: workspaceID,
            workspaceName: correct.name,
            workspaceDateModified: correct.dateModified,
            activeTabID: activeTabID,
            activeSelectionRevision: 0,
            activeSelection: activeTab.selection,
            selectionRecords: [
                WorkspaceSaveSelectionRecord(tabID: inactiveTabID, revision: 2, selection: correctSelection)
            ]
        )
        let correctReceipt = try await writer.enqueueWorkspace(correct, url: url, metadata: correctMetadata)
        _ = await writer.flush(correctReceipt)

        var stale = correct
        stale.dateModified = Date(timeIntervalSince1970: 200)
        stale.composeTabs[1].selection = staleSelection
        stale.composeTabs[1].promptText = "newer non-selection field"
        let staleMetadata = WorkspaceSavePayloadMetadata(
            source: "test.staleInactive",
            owner: .none,
            workspaceID: workspaceID,
            workspaceName: stale.name,
            workspaceDateModified: stale.dateModified,
            activeTabID: activeTabID,
            activeSelectionRevision: 0,
            activeSelection: activeTab.selection,
            selectionRecords: [
                WorkspaceSaveSelectionRecord(tabID: inactiveTabID, revision: 1, selection: staleSelection)
            ]
        )
        let staleReceipt = try await writer.enqueueWorkspace(stale, url: url, metadata: staleMetadata)
        _ = await writer.flush(staleReceipt)

        let decoded = try EmbeddedWorkspaceCodecV1().decode(Data(contentsOf: url)).document
        XCTAssertEqual(decoded.composeTabs[1].selection, correctSelection)
        XCTAssertEqual(decoded.composeTabs[1].promptText, "newer non-selection field")
    }

    func testWriterMergesNewerSelectionIntoNewerDiskWorkspaceInsteadOfSkipping() async throws {
        let url = try makeWorkspaceURL()
        let writer = WorkspacePersistenceWriter()
        let workspaceID = UUID()
        let tabID = UUID()
        let staleDisk = workspace(
            id: workspaceID,
            tabID: tabID,
            selection: selection(count: 15, includeSlices: true),
            dateModified: Date(timeIntervalSince1970: 300),
            promptText: "disk-field"
        )
        try EmbeddedWorkspaceCodecV1().encode(staleDisk).data.write(to: url, options: .atomic)

        let incoming = workspace(
            id: workspaceID,
            tabID: tabID,
            selection: selection(count: 7),
            dateModified: Date(timeIntervalSince1970: 200),
            promptText: "incoming-field"
        )
        let receipt = try await writer.enqueueWorkspace(
            incoming,
            url: url,
            metadata: makeSlice1Metadata(for: incoming, source: "test.newerSelectionOlderPayload", selectionRevision: 2)
        )
        _ = await writer.flush(receipt)

        let decoded = try EmbeddedWorkspaceCodecV1().decode(Data(contentsOf: url)).document
        XCTAssertEqual(decoded.composeTabs[0].selection, incoming.composeTabs[0].selection)
        XCTAssertEqual(decoded.composeTabs[0].promptText, "disk-field")
        XCTAssertGreaterThan(decoded.dateModified, staleDisk.dateModified)
    }

    private func makeWorkspaceURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSelectionPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workspace.json")
    }

    private func workspace(
        id: UUID,
        tabID: UUID,
        selection: StoredSelection,
        dateModified: Date,
        promptText: String
    ) -> WorkspaceModel {
        let tab = ComposeTabState(id: tabID, name: "T1", selection: selection, promptText: promptText)
        return WorkspaceModel(
            id: id,
            dateModified: dateModified,
            name: "Selection Persistence",
            repoPaths: ["/tmp/root"],
            composeTabs: [tab],
            activeComposeTabID: tabID
        )
    }

    private func selection(count: Int, includeSlices: Bool = false) -> StoredSelection {
        let paths = (0 ..< count).map { "/tmp/root/file\($0).swift" }
        let slices: [String: [LineRange]] = if includeSlices, let first = paths.first {
            [first: [LineRange(start: 1, end: 3), LineRange(start: 8, end: 13)]]
        } else {
            [:]
        }
        return StoredSelection(
            selectedPaths: paths,
            autoCodemapPaths: Array(paths.prefix(max(0, count / 3))),
            slices: slices,
            codemapAutoEnabled: !includeSlices
        )
    }
}
