import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceRestoreSafetyTests: XCTestCase {
    func testStoredSelectionEncodesLegacyAutoCodemapPathsForOlderDecoder() throws {
        struct OldSelectionDecoder: Decodable {
            let autoCodemapPaths: [String]
        }

        let selection = StoredSelection(manualCodemapPaths: ["/tmp/A.swift"])
        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(OldSelectionDecoder.self, from: data)
        XCTAssertEqual(decoded.autoCodemapPaths, ["/tmp/A.swift"])
    }

    func testStoredSelectionUsesManualCodemapPathsWhenLegacyAutoCodemapPathsAlsoExists() throws {
        let json = #"""
        {
          "selectedPaths": [],
          "manualCodemapPaths": ["/tmp/A.swift", "/tmp/Case.swift", " /tmp/Space.swift"],
          "autoCodemapPaths": ["/tmp/A.swift", "/tmp/B.swift", "/tmp/case.swift", "/tmp/Space.swift"],
          "slices": {},
          "codemapAutoEnabled": false
        }
        """#.data(using: .utf8)!

        let selection = try JSONDecoder().decode(StoredSelection.self, from: json)
        XCTAssertEqual(
            selection.manualCodemapPaths,
            ["/tmp/A.swift", "/tmp/Case.swift", " /tmp/Space.swift"]
        )
    }

    func testStoredSelectionFallsBackToLegacyAutoCodemapPathsWhenManualKeyIsAbsent() throws {
        let json = #"""
        {
          "selectedPaths": [],
          "autoCodemapPaths": ["/tmp/Legacy.swift", "/tmp/Legacy.swift", "/tmp/Other.swift"],
          "slices": {},
          "codemapAutoEnabled": false
        }
        """#.data(using: .utf8)!

        let selection = try JSONDecoder().decode(StoredSelection.self, from: json)
        XCTAssertEqual(selection.manualCodemapPaths, ["/tmp/Legacy.swift", "/tmp/Other.swift"])
    }

    func testWorkspaceDecodePreservesTabWhenLegacyAutoCodemapPathsIsMalformed() throws {
        let tabID = UUID()
        let workspaceID = UUID()
        let tabObject = try XCTUnwrap(encodedJSONObject(ComposeTabState(id: tabID, name: "Keep Me")) as? [String: Any])
        var selectionObject = try XCTUnwrap(tabObject["selection"] as? [String: Any])
        selectionObject["manualCodemapPaths"] = ["/tmp/Manual.swift"]
        selectionObject["autoCodemapPaths"] = ["unexpected": "object"]
        var malformedTabObject = tabObject
        malformedTabObject["selection"] = selectionObject
        let jsonObject: [String: Any] = baseWorkspaceJSON(
            id: workspaceID,
            name: "Malformed Legacy Selection",
            composeTabs: [malformedTabObject],
            activeComposeTabID: tabID.uuidString
        )
        let json = try JSONSerialization.data(withJSONObject: jsonObject)

        let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: json)
        XCTAssertFalse(workspace.lossyDecodeRecovered)
        XCTAssertEqual(workspace.composeTabs.map(\.id), [tabID])
        XCTAssertEqual(workspace.composeTabs.first?.selection.manualCodemapPaths, ["/tmp/Manual.swift"])
    }

    func testMalformedCoreSelectionFieldMarksWorkspaceLossy() throws {
        let tabID = UUID()
        let workspaceID = UUID()
        let tabObject = try XCTUnwrap(encodedJSONObject(ComposeTabState(id: tabID, name: "Drop Me")) as? [String: Any])
        var selectionObject = try XCTUnwrap(tabObject["selection"] as? [String: Any])
        selectionObject["selectedPaths"] = ["unexpected": "object"]
        var malformedTabObject = tabObject
        malformedTabObject["selection"] = selectionObject
        let jsonObject = baseWorkspaceJSON(
            id: workspaceID,
            name: "Malformed Core Selection",
            composeTabs: [malformedTabObject],
            activeComposeTabID: tabID.uuidString
        )
        let json = try JSONSerialization.data(withJSONObject: jsonObject)

        let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: json)
        XCTAssertTrue(workspace.lossyDecodeRecovered)
        XCTAssertNotEqual(workspace.composeTabs.map(\.id), [tabID])
        XCTAssertFalse(workspace.normalizationRequiresSave)
    }

    func testWorkspaceDecodePreservesValidComposeTabsWhenOneEntryIsCorrupt() throws {
        let goodTabID = UUID()
        let badTabID = UUID()
        let workspaceID = UUID()
        let goodTabJSON = try encodedJSONObject(ComposeTabState(id: goodTabID, name: "Keep Me", promptText: "important prompt"))
        let jsonObject = baseWorkspaceJSON(
            id: workspaceID,
            name: "Lossy Tabs",
            composeTabs: [goodTabJSON, ["id": 5, "name": "Corrupt"]],
            activeComposeTabID: badTabID.uuidString
        )
        let json = try JSONSerialization.data(withJSONObject: jsonObject)

        let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: json)
        XCTAssertTrue(workspace.lossyDecodeRecovered)
        XCTAssertEqual(workspace.composeTabs.map(\.id), [goodTabID])
        XCTAssertEqual(workspace.activeComposeTabID, goodTabID)
        XCTAssertFalse(workspace.normalizationRequiresSave)
    }

    func testMalformedTopLevelComposeTabsDoesNotScheduleNormalizationWriteback() throws {
        #if DEBUG
            WorkspaceFileDecodeCache.shared.removeAllForTesting()
        #endif
        let root = try makeTemporaryDirectory(named: "MalformedComposeTabsLoad")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("workspace.json")
        let jsonObject: [String: Any] = [
            "id": UUID().uuidString,
            "schemaVersion": 1,
            "name": "Malformed Compose Tabs",
            "repoPaths": [],
            "presets": [],
            "selectedMetaPromptIDs": [],
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
            "composeTabs": ["unexpected": "object"],
            "stashedTabs": []
        ]
        let json = try JSONSerialization.data(withJSONObject: jsonObject)
        try json.write(to: fileURL, options: .atomic)

        let originalBytes = try Data(contentsOf: fileURL)
        let result = try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: fileURL)
        let loadedBytes = try Data(contentsOf: fileURL)
        XCTAssertEqual(loadedBytes, originalBytes)
        XCTAssertTrue(result.lossyDecodeRecovered)
        XCTAssertEqual(result.workspace.composeTabs.count, 1)
        XCTAssertFalse(result.normalizationRequiresSave)
        XCTAssertNil(result.normalizationSaveTask)
    }

    func testLoadWorkspaceFromFileDoesNotScheduleNormalizationWritebackAfterLossyRecovery() throws {
        #if DEBUG
            WorkspaceFileDecodeCache.shared.removeAllForTesting()
        #endif
        let root = try makeTemporaryDirectory(named: "LossyWorkspaceLoad")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("workspace.json")
        let goodTabID = UUID()
        let badTabID = UUID()
        let goodTabJSON = try encodedJSONObject(ComposeTabState(id: goodTabID, name: "Keep Me", promptText: "important prompt"))
        let jsonObject = baseWorkspaceJSON(
            id: UUID(),
            name: "Lossy Load",
            composeTabs: [goodTabJSON, ["id": 5]],
            activeComposeTabID: badTabID.uuidString
        )
        let json = try JSONSerialization.data(withJSONObject: jsonObject)
        try json.write(to: fileURL, options: .atomic)

        let result = try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: fileURL)
        XCTAssertTrue(result.lossyDecodeRecovered)
        XCTAssertFalse(result.normalizationRequiresSave)
        XCTAssertNil(result.normalizationSaveTask)
    }

    func testLossyStashedTabsPreservesValidEntries() throws {
        let activeTabID = UUID()
        let stashedTabID = UUID()
        let activeTabJSON = try encodedJSONObject(ComposeTabState(id: activeTabID, name: "Active"))
        let stashedJSON = try encodedJSONObject(StashedTab(tab: ComposeTabState(id: stashedTabID, name: "Stashed")))
        let jsonObject = baseWorkspaceJSON(
            id: UUID(),
            name: "Lossy Stash",
            composeTabs: [activeTabJSON],
            activeComposeTabID: activeTabID.uuidString,
            stashedTabs: [stashedJSON, ["id": 5]]
        )
        let json = try JSONSerialization.data(withJSONObject: jsonObject)

        let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: json)
        XCTAssertTrue(workspace.lossyDecodeRecovered)
        XCTAssertEqual(workspace.stashedTabs.map(\.tab.id), [stashedTabID])
        XCTAssertFalse(workspace.normalizationRequiresSave)
    }

    func testWindowSessionSnapshotTracksLossyDecode() throws {
        let validEntry = try encodedJSONObject(makeWindowEntry(workspaceID: UUID(), workspaceName: "A"))
        let jsonObject: [String: Any] = [
            "version": 4,
            "windows": [validEntry, ["windowKind": "standard", "workspaceName": "Missing required booleans"]]
        ]
        let json = try JSONSerialization.data(withJSONObject: jsonObject)

        let snapshot = try JSONDecoder().decode(WindowSessionSnapshot.self, from: json)
        XCTAssertTrue(snapshot.lossyDecodeRecovered)
        XCTAssertEqual(snapshot.decodedWindowElementCount, 2)
        XCTAssertEqual(snapshot.droppedWindowElementCount, 1)
        XCTAssertEqual(snapshot.windows.count, 1)

        let encoded = try JSONEncoder().encode(snapshot)
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(encodedObject["lossyDecodeRecovered"])
        XCTAssertNil(encodedObject["decodedWindowElementCount"])
        XCTAssertNil(encodedObject["droppedWindowElementCount"])
    }

    func testWindowSessionSnapshotTracksMalformedWindowsPayloadAsLossy() throws {
        let json = #"{"version":4,"windows":{"unexpected":"object"}}"#.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(WindowSessionSnapshot.self, from: json)
        XCTAssertTrue(snapshot.lossyDecodeRecovered)
        XCTAssertNil(snapshot.decodedWindowElementCount)
        XCTAssertEqual(snapshot.droppedWindowElementCount, 0)
        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    func testWindowSessionBaselineIgnoresEphemeralEntriesButCountsDroppedEntries() throws {
        let standardA = makeWindowEntry(workspaceID: UUID(), workspaceName: "A", repoPath: "/repo/a", instance: 1)
        let standardB = makeWindowEntry(workspaceID: UUID(), workspaceName: "B", repoPath: "/repo/b", instance: 2)
        let ephemeral = makeWindowEntry(
            workspaceID: UUID(),
            workspaceName: "Ephemeral",
            repoPath: "/tmp/ephemeral",
            instance: 3,
            isEphemeral: true
        )
        let snapshotWithEphemeralOnly = WindowSessionSnapshot(
            version: 4,
            windows: [standardA, ephemeral, standardB]
        )
        let restorableEntries = snapshotWithEphemeralOnly.windows.filter { !$0.isEphemeral }
        let baselineCount = WindowSessionPersistenceGuard.baselineCountForLoadedRestoreSession(
            restorableEntryCount: restorableEntries.count,
            droppedWindowElementCount: snapshotWithEphemeralOnly.droppedWindowElementCount
        )
        XCTAssertEqual(baselineCount, 2)
        XCTAssertEqual(
            WindowSessionPersistenceGuard.decision(
                capturedSignatures: restorableEntries.map(WindowSessionPersistenceSignature.init(entry:)),
                restoredBaselineCount: baselineCount,
                restoredBaselineSignatures: restorableEntries.map(WindowSessionPersistenceSignature.init(entry:)),
                allowedReductionBudget: 0,
                restoreIncomplete: false,
                restoredSessionWasLossy: false
            ),
            .persist
        )

        let standardJSON = try encodedJSONObject(standardA)
        let ephemeralJSON = try encodedJSONObject(ephemeral)
        let jsonObject: [String: Any] = [
            "version": 4,
            "windows": [
                standardJSON,
                ephemeralJSON,
                ["windowKind": "standard", "workspaceName": "Missing required booleans"]
            ]
        ]
        let lossySnapshot = try JSONDecoder().decode(
            WindowSessionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: jsonObject)
        )
        let lossyRestorableEntries = lossySnapshot.windows.filter { !$0.isEphemeral }
        let lossyBaselineCount = WindowSessionPersistenceGuard.baselineCountForLoadedRestoreSession(
            restorableEntryCount: lossyRestorableEntries.count,
            droppedWindowElementCount: lossySnapshot.droppedWindowElementCount
        )
        XCTAssertEqual(lossySnapshot.decodedWindowElementCount, 3)
        XCTAssertEqual(lossySnapshot.droppedWindowElementCount, 1)
        XCTAssertEqual(lossyBaselineCount, 2)
        XCTAssertEqual(
            WindowSessionPersistenceGuard.decision(
                capturedSignatures: lossyRestorableEntries.map(WindowSessionPersistenceSignature.init(entry:)),
                restoredBaselineCount: lossyBaselineCount,
                restoredBaselineSignatures: lossyRestorableEntries.map(WindowSessionPersistenceSignature.init(entry:)),
                allowedReductionBudget: 0,
                restoreIncomplete: false,
                restoredSessionWasLossy: false
            ),
            .blockDestructiveReduction
        )
    }

    func testWindowSessionPersistenceGuardBlocksIncompleteLossyReductionAndReplacement() {
        let baselineA = WindowSessionPersistenceSignature(entry: makeWindowEntry(workspaceID: UUID(), workspaceName: "A", repoPath: "/repo/a", instance: 1))
        let baselineB = WindowSessionPersistenceSignature(entry: makeWindowEntry(workspaceID: UUID(), workspaceName: "B", repoPath: "/repo/b", instance: 2))
        let degradedA = WindowSessionPersistenceSignature(entry: makeWindowEntry(workspaceID: UUID(), workspaceName: "T1", repoPath: nil, instance: 1))
        let degradedB = WindowSessionPersistenceSignature(entry: makeWindowEntry(workspaceID: UUID(), workspaceName: "T1", repoPath: nil, instance: 2))

        XCTAssertEqual(
            WindowSessionPersistenceGuard.decision(
                capturedSignatures: [baselineA],
                restoredBaselineCount: 2,
                restoredBaselineSignatures: [baselineA, baselineB],
                allowedReductionBudget: 0,
                restoreIncomplete: true,
                restoredSessionWasLossy: false
            ),
            .deferUntilRestoreCompletes
        )
        XCTAssertEqual(
            WindowSessionPersistenceGuard.decision(
                capturedSignatures: [baselineA],
                restoredBaselineCount: 2,
                restoredBaselineSignatures: [baselineA, baselineB],
                allowedReductionBudget: 0,
                restoreIncomplete: false,
                restoredSessionWasLossy: false
            ),
            .blockDestructiveReduction
        )
        XCTAssertEqual(
            WindowSessionPersistenceGuard.decision(
                capturedSignatures: [baselineA, baselineB],
                restoredBaselineCount: 2,
                restoredBaselineSignatures: [baselineA, baselineB],
                allowedReductionBudget: 0,
                restoreIncomplete: false,
                restoredSessionWasLossy: true
            ),
            .blockAfterLossyRestore
        )
        XCTAssertEqual(
            WindowSessionPersistenceGuard.decision(
                capturedSignatures: [degradedA, degradedB],
                restoredBaselineCount: 2,
                restoredBaselineSignatures: [baselineA, baselineB],
                allowedReductionBudget: 0,
                restoreIncomplete: false,
                restoredSessionWasLossy: false
            ),
            .blockDestructiveReplacement
        )
        XCTAssertEqual(
            WindowSessionPersistenceGuard.decision(
                capturedSignatures: [baselineA],
                restoredBaselineCount: 2,
                restoredBaselineSignatures: [baselineA, baselineB],
                allowedReductionBudget: 1,
                restoreIncomplete: false,
                restoredSessionWasLossy: false
            ),
            .persist
        )
        XCTAssertEqual(
            WindowSessionPersistenceGuard.baselineCountAfterPersist(
                currentBaselineCount: 2,
                capturedWindowCount: 1
            ),
            1
        )
        XCTAssertNil(
            WindowSessionPersistenceGuard.baselineCountForLoadedRestoreSession(
                restorableEntryCount: 0,
                droppedWindowElementCount: 0
            )
        )
        XCTAssertEqual(
            WindowSessionPersistenceGuard.baselineCountForLoadedRestoreSession(
                restorableEntryCount: 1,
                droppedWindowElementCount: 1
            ),
            2
        )
        XCTAssertNil(
            WindowSessionPersistenceGuard.baselineCountAfterPersist(
                currentBaselineCount: nil,
                capturedWindowCount: 1
            )
        )
        XCTAssertNil(
            WindowSessionPersistenceGuard.baselineSignaturesAfterPersist(
                currentBaselineSignatures: [baselineA, baselineB],
                capturedSignatures: [baselineA, baselineB]
            )
        )
        XCTAssertEqual(
            WindowSessionPersistenceGuard.decision(
                capturedSignatures: [degradedA, degradedB],
                restoredBaselineCount: 2,
                restoredBaselineSignatures: nil,
                allowedReductionBudget: 0,
                restoreIncomplete: false,
                restoredSessionWasLossy: false
            ),
            .persist
        )
    }

    func testLossyWorkspaceBackupHelperCopiesExistingWorkspaceJSON() throws {
        let root = try makeTemporaryDirectory(named: "LossyBackup")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("workspace.json")
        let original = Data("original workspace".utf8)
        try original.write(to: fileURL, options: .atomic)

        let backupURL = try XCTUnwrap(
            WorkspaceManagerViewModel.backupExistingWorkspaceJSONBeforeLossySave(
                at: fileURL,
                now: Date(timeIntervalSince1970: 0)
            )
        )
        XCTAssertEqual(try Data(contentsOf: backupURL), original)
        XCTAssertTrue(backupURL.lastPathComponent.contains("pre-lossy-restore"))
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testMissingWorkspaceIndexFallsBackToWorkspaceDirectories() throws {
        let root = try makeTemporaryDirectory(named: "MissingWorkspaceIndexRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(name: "Recovered Missing", repoPaths: [root.path])
        let workspaceDirectory = root.appendingPathComponent("Workspace-RecoveredMissing-\(workspace.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(workspace).write(to: workspaceDirectory.appendingPathComponent("workspace.json"), options: .atomic)
        let indexURL = root.appendingPathComponent("workspaceIndex.json")

        let entries = WorkspaceManagerViewModel.loadWorkspaceIndex(from: indexURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, workspace.id)
        XCTAssertEqual(entries.first?.name, "Recovered Missing")
    }

    func testCorruptWorkspaceIndexFallsBackToWorkspaceDirectories() throws {
        let root = try makeTemporaryDirectory(named: "WorkspaceIndexRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(name: "Recovered", repoPaths: [root.path])
        let workspaceDirectory = root.appendingPathComponent("Workspace-Recovered-\(workspace.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(workspace).write(to: workspaceDirectory.appendingPathComponent("workspace.json"), options: .atomic)
        let indexURL = root.appendingPathComponent("workspaceIndex.json")
        try "not json".write(to: indexURL, atomically: true, encoding: .utf8)

        let entries = WorkspaceManagerViewModel.loadWorkspaceIndex(from: indexURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, workspace.id)
        XCTAssertEqual(entries.first?.name, "Recovered")
    }

    func testRecoveredWorkspaceIndexUsesDeterministicDirectoryOrderForDuplicateIDs() throws {
        let root = try makeTemporaryDirectory(named: "WorkspaceIndexDuplicateIDRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let zWorkspace = WorkspaceModel(id: workspaceID, name: "Zed", repoPaths: [root.path])
        let aWorkspace = WorkspaceModel(id: workspaceID, name: "Alpha", repoPaths: [root.path])
        try writeWorkspace(zWorkspace, under: root, suffix: "z")
        try writeWorkspace(aWorkspace, under: root, suffix: "a")

        let entries = WorkspaceManagerViewModel.recoverWorkspaceIndexEntries(fromBaseRoot: root)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, workspaceID)
        XCTAssertEqual(entries.first?.name, "Alpha")
    }

    func testRecoveredWorkspaceIndexSortsDuplicateNamesDeterministicallyByID() throws {
        let root = try makeTemporaryDirectory(named: "WorkspaceIndexDuplicateNameRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let highID = try XCTUnwrap(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let lowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highWorkspace = WorkspaceModel(id: highID, name: "Same", repoPaths: [root.path])
        let lowWorkspace = WorkspaceModel(id: lowID, name: "Same", repoPaths: [root.path])
        try writeWorkspace(highWorkspace, under: root, suffix: "high")
        try writeWorkspace(lowWorkspace, under: root, suffix: "low")

        let entries = WorkspaceManagerViewModel.recoverWorkspaceIndexEntries(fromBaseRoot: root)
        XCTAssertEqual(entries.map(\.id), [lowID, highID])
    }

    private func baseWorkspaceJSON(
        id: UUID,
        name: String,
        composeTabs: [Any],
        activeComposeTabID: String?,
        stashedTabs: [Any] = []
    ) -> [String: Any] {
        var json: [String: Any] = [
            "id": id.uuidString,
            "schemaVersion": 1,
            "name": name,
            "repoPaths": [],
            "presets": [],
            "selectedMetaPromptIDs": [],
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
            "composeTabs": composeTabs,
            "stashedTabs": stashedTabs
        ]
        if let activeComposeTabID {
            json["activeComposeTabID"] = activeComposeTabID
        }
        return json
    }

    private func makeWindowEntry(
        workspaceID: UUID?,
        workspaceName: String,
        repoPath: String? = "/repo",
        instance: Int? = 1,
        isEphemeral: Bool = false
    ) -> WindowSessionEntry {
        WindowSessionEntry(
            windowKind: .standard,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            isSystemWorkspace: false,
            isEphemeral: isEphemeral,
            primaryRepoPath: repoPath,
            lastFocused: false,
            workspaceInstanceNumber: instance
        )
    }

    private func writeWorkspace(_ workspace: WorkspaceModel, under root: URL, suffix: String) throws {
        let workspaceDirectory = root.appendingPathComponent("Workspace-\(suffix)-\(workspace.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(workspace).write(to: workspaceDirectory.appendingPathComponent("workspace.json"), options: .atomic)
    }

    private func encodedJSONObject(_ value: some Encodable) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
