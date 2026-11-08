import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentSavedSessionTargetLoaderTests: XCTestCase {
    func testExactDiskLookupNeedsNoWindowAndDoesNotChangeTheVisibleCarrier() async throws {
        let service = AgentSessionDataService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedID = UUID()
        let tab = ComposeTabState(activeAgentSessionID: UUID())
        var workspace = WorkspaceModel(name: "Saved target", repoPaths: [], customStoragePath: directory)
        workspace.composeTabs = [tab]
        workspace.stashedTabs = []
        let file = try await service.saveAgentSession(AgentSession(
            id: savedID, workspaceID: workspace.id, composeTabID: tab.id,
            name: "Historical target", itemCount: 0
        ), for: workspace)
        let before = try Data(contentsOf: file)
        var reads = 0
        let result = await AgentSavedSessionTargetLoader.load(
            sessionID: savedID, workspaces: [workspace],
            readRecord: { id, candidate in
                reads += 1
                return try await service.metadataRecordForSessionID(id, for: candidate)
            },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        let target = try result.get()
        XCTAssertEqual(target.entry.id, savedID)
        XCTAssertEqual(target.entry.tabID, tab.id)
        XCTAssertEqual(target.tab.activeAgentSessionID, tab.activeAgentSessionID)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try Data(contentsOf: file), before, "Metadata lookup must not rewrite the payload.")
    }

    func testReadResamplesLiveEvidenceAndAuthoritativeRuntimeDoesNotNeedDisk() async throws {
        let id = UUID(), tab = ComposeTabState()
        var workspace = WorkspaceModel(name: "Live", repoPaths: [])
        workspace.composeTabs = [tab]
        workspace.stashedTabs = []
        var live = AgentSavedSessionTargetLoader.LiveMetadata(entry: entry(id, tab.id, name: "Before"), isAuthoritative: false)
        var reads = 0
        let result = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace],
            readRecord: { _, _ in
                reads += 1
                live = .init(entry: self.entry(id, tab.id, name: "After"), isAuthoritative: true)
                return nil
            },
            currentMetadata: { _ in live }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { $0.entry.name == "After" }
        )
        XCTAssertEqual(try result.get().entry.name, "After")
        let second = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace],
            readRecord: { _, _ in reads += 1
                throw CocoaError(.fileReadNoPermission)
            },
            currentMetadata: { _ in live }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        XCTAssertEqual(try second.get().entry.name, "After")
        XCTAssertEqual(reads, 1, "Known live state remains usable when persistence is unavailable.")
    }

    func testDeletionAndEarlierMatchInvalidationDuringReadsFailClosed() async {
        let id = UUID(), tab = ComposeTabState()
        var first = WorkspaceModel(name: "First", repoPaths: [])
        first.composeTabs = [tab]
        first.stashedTabs = []
        let later = WorkspaceModel(name: "Later", repoPaths: [])
        var available = true
        let deleted = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [first],
            readRecord: { _, _ in available = false
                return nil
            },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in first }, isAvailable: { available }, isCurrent: { _ in true }
        )
        assertFailure(deleted, .changed)

        var firstIsCurrent = true
        let moved = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [first, later],
            readRecord: { _, _ in firstIsCurrent = false
                return nil
            },
            currentMetadata: { workspaceID in
                workspaceID == first.id ? .init(entry: self.entry(id, tab.id), isAuthoritative: true) : nil
            },
            currentWorkspace: { $0 == first.id ? first : later },
            isAvailable: { true }, isCurrent: { _ in firstIsCurrent }
        )
        assertFailure(moved, .changed)
    }

    func testDistinctMissingAmbiguousAndUnreadableOutcomes() async {
        let id = UUID(), tab = ComposeTabState()
        var workspace = WorkspaceModel(name: "Outcomes", repoPaths: [])
        workspace.composeTabs = [tab]
        workspace.stashedTabs = []
        let missing = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace], readRecord: { _, _ in nil },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(missing, .missing)
        let unreadable = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace], readRecord: { _, _ in throw CocoaError(.fileReadCorruptFile) },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(unreadable, .unreadable)
        workspace.composeTabs.append(tab)
        let ambiguous = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace], readRecord: { _, _ in XCTFail("Live target does not need IO")
                return nil
            },
            currentMetadata: { _ in .init(entry: self.entry(id, tab.id), isAuthoritative: true) },
            currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(ambiguous, .ambiguous)
    }

    func testFreshStashedPlacementIsUsedAfterRead() async throws {
        let id = UUID(), tab = ComposeTabState()
        let stash = StashedTab(tab: tab)
        var workspace = WorkspaceModel(name: "Moving", repoPaths: [], composeTabs: [tab])
        let result = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace],
            readRecord: { _, _ in
                workspace.composeTabs = []
                workspace.stashedTabs = [stash]
                return nil
            },
            currentMetadata: { _ in .init(entry: self.entry(id, tab.id), isAuthoritative: false) },
            currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        XCTAssertEqual(try result.get().stashedTabID, stash.id)
        XCTAssertEqual(try result.get().workspace.stashedTabs, [stash])
    }

    func testDiskIdentityMismatchAndTwoWorkspaceMatchesAreAmbiguous() async throws {
        let service = AgentSessionDataService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), tab = ComposeTabState()
        let workspace = WorkspaceModel(name: "Original", repoPaths: [], customStoragePath: directory, composeTabs: [tab])
        _ = try await service.saveAgentSession(AgentSession(
            id: id, workspaceID: workspace.id, composeTabID: tab.id, name: "Disk", itemCount: 0
        ), for: workspace)
        let loadedRecord = try await service.metadataRecordForSessionID(id, for: workspace)
        let record = try XCTUnwrap(loadedRecord)
        let other = WorkspaceModel(name: "Other", repoPaths: [], composeTabs: [tab])
        for (requestedID, candidate) in [(UUID(), workspace), (id, other)] {
            let result = await AgentSavedSessionTargetLoader.load(
                sessionID: requestedID, workspaces: [candidate], readRecord: { _, _ in record },
                currentMetadata: { _ in nil }, currentWorkspace: { _ in candidate },
                isAvailable: { true }, isCurrent: { _ in true }
            )
            assertFailure(result, .ambiguous)
        }
        let duplicated = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace, other], readRecord: { _, _ in nil },
            currentMetadata: { _ in .init(entry: self.entry(id, tab.id), isAuthoritative: true) },
            currentWorkspace: { $0 == workspace.id ? workspace : other }, isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(duplicated, .ambiguous)
    }

    func testCancellationDuringReadIsChangedNotUnreadable() async {
        let workspace = WorkspaceModel(name: "Cancelled", repoPaths: [])
        let result = await AgentSavedSessionTargetLoader.load(
            sessionID: UUID(), workspaces: [workspace], readRecord: { _, _ in throw CancellationError() },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in workspace },
            isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(result, .changed)
    }

    private func entry(_ id: UUID, _ tabID: UUID, name: String = "Target") -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id, tabID: tabID, name: name, savedAt: .distantPast,
            itemCount: 0, autoEditEnabled: false, hasUnknownConversationContent: false,
            isMCPOriginated: false, worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
        )
    }

    private func assertFailure(
        _ result: Result<AgentSavedSessionTargetLoader.Target, AgentSavedSessionTargetLoader.Failure>,
        _ expected: AgentSavedSessionTargetLoader.Failure,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case let .failure(actual) = result else { return XCTFail("Expected \(expected)", file: file, line: line) }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}
