import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class WindowStateOpenFolderCommandTests: XCTestCase {
        private var originalMCPAutoStart = false
        private var originalStoragePath: String?
        private var storageRoot: URL!
        private var windows: [WindowState] = []

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("WindowStateOpenFolderCommandTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        }

        override func tearDown() async throws {
            for window in windows {
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            windows.removeAll()
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
            try? FileManager.default.removeItem(at: storageRoot)
            if let originalStoragePath {
                UserDefaults.standard.set(originalStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
            }
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try await super.tearDown()
        }

        func testFolderCommandActivatesResolverRankedWinnerWithoutCreatingWorkspace() async throws {
            let window = await makeWindow()
            let folder = try makeFolder(named: "RankedProject")
            let older = try WorkspaceModel(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
                dateModified: Date(timeIntervalSince1970: 10),
                name: "Older Match",
                repoPaths: [folder.path]
            )
            let newest = try WorkspaceModel(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
                dateModified: Date(timeIntervalSince1970: 20),
                name: "Newest Match",
                repoPaths: [folder.path]
            )
            window.workspaceManager.workspaces.append(contentsOf: [older, newest])
            let countBeforeCommand = window.workspaceManager.workspaces.count

            window.enqueueCommand(folderCommand(folderPath: folder.path))

            try await waitUntil {
                window.workspaceManager.activeWorkspaceID == newest.id
            }
            XCTAssertEqual(window.workspaceManager.workspaces.count, countBeforeCommand)
        }

        func testEphemeralFlagsDoNotDowngradeMatchedPersistentWorkspace() async throws {
            let cases: [(name: String, ephemeral: Bool?, persist: Bool?)] = [
                ("EphemeralTrue", true, nil),
                ("PersistFalse", nil, false)
            ]

            for testCase in cases {
                let window = await makeWindow()
                let folder = try makeFolder(named: testCase.name)
                let persistent = window.workspaceManager.createWorkspace(
                    name: testCase.name,
                    repoPaths: [folder.path]
                )

                let initialSwitch = await window.workspaceManager.switchWorkspace(
                    to: persistent,
                    saveState: false,
                    reason: "folderCommandPersistentFixture"
                )
                XCTAssertEqual(initialSwitch, .switched)

                window.enqueueCommand(folderCommand(
                    folderPath: folder.path,
                    ephemeral: testCase.ephemeral,
                    persist: testCase.persist
                ))
                await window.processCommands()

                XCTAssertFalse(
                    try XCTUnwrap(window.workspaceManager.workspace(withID: persistent.id)).isEphemeral,
                    testCase.name
                )
            }
        }

        func testAlreadyActiveMatchedWorkspaceReceivesPromptAndFilePayload() async throws {
            let window = await makeWindow()
            let folder = try makeFolder(named: "ActivePayload")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let value = 1\n".utf8).write(to: payloadFile)
            let workspace = window.workspaceManager.createWorkspace(
                name: "Active Payload",
                repoPaths: [folder.path]
            )
            let initialSwitch = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "folderCommandActivePayloadFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            window.promptManager.promptText = "before"

            window.enqueueCommand(folderCommand(
                folderPath: folder.path,
                fileList: [payloadFile.path],
                promptText: "after"
            ))
            await window.processCommands()

            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, workspace.id)
            XCTAssertEqual(window.promptManager.promptText, "after")
            XCTAssertTrue(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
        }

        func testNoMatchCreationPreservesCommandPersistenceFlags() async throws {
            let cases: [(name: String, ephemeral: Bool?, persist: Bool?, expectsEphemeral: Bool)] = [
                ("DefaultPersistent", nil, nil, false),
                ("ExplicitEphemeral", true, nil, true),
                ("PersistFalse", nil, false, true)
            ]

            for testCase in cases {
                let window = await makeWindow()
                let folder = try makeFolder(named: "NoMatch-\(testCase.name)")
                let countBeforeCommand = window.workspaceManager.workspaces.count

                window.enqueueCommand(folderCommand(
                    folderPath: folder.path,
                    ephemeral: testCase.ephemeral,
                    persist: testCase.persist
                ))

                try await waitUntil {
                    window.workspaceManager.activeWorkspace?.repoPaths == [folder.path]
                }
                let created = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                XCTAssertEqual(window.workspaceManager.workspaces.count, countBeforeCommand + 1, testCase.name)
                XCTAssertEqual(created.isEphemeral, testCase.expectsEphemeral, testCase.name)
            }
        }

        func testEphemeralWorkspaceIsReusedOnlyByEphemeralCommands() async throws {
            let window = await makeWindow()
            let folder = try makeFolder(named: "EphemeralReuse")

            window.enqueueCommand(folderCommand(folderPath: folder.path, ephemeral: true))
            await window.processCommands()
            let ephemeral = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            XCTAssertEqual(ephemeral.repoPaths, [folder.path])
            XCTAssertTrue(ephemeral.isEphemeral)
            let countAfterFirstCommand = window.workspaceManager.workspaces.count

            window.enqueueCommand(folderCommand(folderPath: folder.path, ephemeral: true))
            await window.processCommands()

            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, ephemeral.id)
            XCTAssertEqual(window.workspaceManager.workspaces.count, countAfterFirstCommand)
            XCTAssertTrue(try XCTUnwrap(window.workspaceManager.activeWorkspace).isEphemeral)

            window.enqueueCommand(folderCommand(folderPath: folder.path))
            await window.processCommands()

            let persistent = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            XCTAssertNotEqual(persistent.id, ephemeral.id)
            XCTAssertEqual(persistent.repoPaths, [folder.path])
            XCTAssertEqual(window.workspaceManager.workspaces.count, countAfterFirstCommand + 1)
            XCTAssertFalse(persistent.isEphemeral)
        }

        func testBlockedMatchedSwitchCreatesNoReplacementAndAppliesNoPayload() async throws {
            let window = await makeWindow()
            let activeFolder = try makeFolder(named: "BlockedActive")
            let targetFolder = try makeFolder(named: "BlockedTarget")
            let active = window.workspaceManager.createWorkspace(
                name: "Blocked Active",
                repoPaths: [activeFolder.path]
            )
            let target = window.workspaceManager.createWorkspace(
                name: "Blocked Target",
                repoPaths: [targetFolder.path]
            )
            let initialSwitch = await window.workspaceManager.switchWorkspace(
                to: active,
                saveState: false,
                reason: "folderCommandBlockedFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            let countBeforeCommand = window.workspaceManager.workspaces.count
            window.promptManager.promptText = "before"
            window.workspaceManager.isRefreshing = true
            defer { window.workspaceManager.isRefreshing = false }

            window.enqueueCommand(folderCommand(
                folderPath: targetFolder.path,
                promptText: "after"
            ))
            await window.processCommands()

            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, active.id)
            XCTAssertNotEqual(window.workspaceManager.activeWorkspaceID, target.id)
            XCTAssertEqual(window.workspaceManager.workspaces.count, countBeforeCommand)
            XCTAssertEqual(window.promptManager.promptText, "before")
            XCTAssertEqual(
                window.workspaceManager.pendingWorkspaceSwitchBlockedNotice?.message,
                "Cannot switch workspaces while refresh is in progress."
            )
        }

        func testFocusFolderURLDoesNotForwardPayloadThroughPreliminaryPathMatch() async throws {
            let sourceWindow = await makeWindow()
            let lowerRankedWindow = await makeWindow()
            let winnerWindow = await makeWindow()
            let folder = try makeFolder(named: "CrossWindowFocus")
            let lowerRanked = try WorkspaceModel(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000011")),
                dateModified: Date(timeIntervalSince1970: 10),
                name: "Lower Ranked Match",
                repoPaths: [folder.path]
            )
            let winner = try WorkspaceModel(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000012")),
                dateModified: Date(timeIntervalSince1970: 20),
                name: "Resolver Winner",
                repoPaths: [folder.path]
            )
            sourceWindow.workspaceManager.workspaces.append(contentsOf: [lowerRanked, winner])
            lowerRankedWindow.workspaceManager.workspaces.append(lowerRanked)
            winnerWindow.workspaceManager.workspaces.append(winner)
            let lowerSwitch = await lowerRankedWindow.workspaceManager.switchWorkspace(
                to: lowerRanked,
                saveState: false,
                reason: "folderCommandLowerRankedFocusFixture"
            )
            XCTAssertEqual(lowerSwitch, .switched)
            let winnerSwitch = await winnerWindow.workspaceManager.switchWorkspace(
                to: winner,
                saveState: false,
                reason: "folderCommandWinnerFocusFixture"
            )
            XCTAssertEqual(winnerSwitch, .switched)
            sourceWindow.promptManager.promptText = "source-before"
            lowerRankedWindow.promptManager.promptText = "lower-before"
            winnerWindow.promptManager.promptText = "winner-before"
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?focus=true&prompt=after"
            ))

            sourceWindow.handleIncomingURL(url)
            await sourceWindow.processCommands()
            await lowerRankedWindow.processCommands()
            await winnerWindow.processCommands()

            XCTAssertEqual(sourceWindow.promptManager.promptText, "source-before")
            XCTAssertEqual(lowerRankedWindow.promptManager.promptText, "lower-before")
            XCTAssertEqual(winnerWindow.promptManager.promptText, "winner-before")
            XCTAssertEqual(lowerRankedWindow.workspaceManager.activeWorkspaceID, lowerRanked.id)
            XCTAssertEqual(winnerWindow.workspaceManager.activeWorkspaceID, winner.id)
        }

        func testCancelledMatchedSwitchCreatesNoReplacementAndAppliesNoPayload() async throws {
            let window = await makeWindow()
            let activeFolder = try makeFolder(named: "CancelledActive")
            let targetFolder = try makeFolder(named: "CancelledTarget")
            let active = window.workspaceManager.createWorkspace(
                name: "Cancelled Active",
                repoPaths: [activeFolder.path]
            )
            _ = window.workspaceManager.createWorkspace(
                name: "Cancelled Target",
                repoPaths: [targetFolder.path]
            )
            let initialSwitch = await window.workspaceManager.switchWorkspace(
                to: active,
                saveState: false,
                reason: "folderCommandCancelledFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            let countBeforeCommand = window.workspaceManager.workspaces.count
            window.promptManager.promptText = "before"
            let sessionProvider = FolderCommandWorkspaceSwitchSessionProvider()
            window.workspaceManager.registerSwitchSessionProvider(sessionProvider)

            window.enqueueCommand(folderCommand(
                folderPath: targetFolder.path,
                promptText: "after"
            ))
            let confirmation = try await waitForPendingSwitchConfirmation(in: window.workspaceManager)
            window.workspaceManager.resolveSwitchConfirmation(id: confirmation.id, allow: false)
            try await waitUntil {
                window.workspaceManager.pendingSwitchConfirmation == nil
            }

            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, active.id)
            XCTAssertEqual(window.workspaceManager.workspaces.count, countBeforeCommand)
            XCTAssertEqual(window.promptManager.promptText, "before")
            XCTAssertNil(window.workspaceManager.pendingWorkspaceSwitchBlockedNotice)
        }

        private func waitForPendingSwitchConfirmation(
            in manager: WorkspaceManagerViewModel
        ) async throws -> WorkspaceSwitchConfirmation {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while clock.now < deadline {
                if let confirmation = manager.pendingSwitchConfirmation {
                    return confirmation
                }
                try await clock.sleep(for: .milliseconds(10))
            }
            throw WindowStateOpenFolderCommandTestError.conditionTimedOut
        }

        private func makeWindow() async -> WindowState {
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            windows.append(window)
            await window.workspaceManager.awaitInitialized()
            return window
        }

        private func makeFolder(named name: String) throws -> URL {
            let folder = storageRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        private func folderCommand(
            folderPath: String,
            fileList: [String] = [],
            promptText: String? = nil,
            focus: Bool? = nil,
            ephemeral: Bool? = nil,
            persist: Bool? = nil
        ) -> AppCommand {
            AppCommand(
                workspaceName: nil,
                fileList: fileList,
                promptText: promptText,
                folderPath: folderPath,
                newPrompt: nil,
                focus: focus,
                ephemeral: ephemeral,
                persist: persist
            )
        }

        private func waitUntil(
            timeout: Duration = .seconds(2),
            condition: @escaping @MainActor () -> Bool
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if condition() {
                    return
                }
                try await clock.sleep(for: .milliseconds(10))
            }
            throw WindowStateOpenFolderCommandTestError.conditionTimedOut
        }
    }

    @MainActor
    private final class FolderCommandWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
        func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
            [WorkspaceSwitchSessionItem(
                id: "folder-command",
                count: 1,
                singularLabel: "active session",
                pluralLabel: "active sessions"
            )]
        }

        func cancelSwitchSessions() async {}
    }

    private enum WindowStateOpenFolderCommandTestError: Error {
        case conditionTimedOut
    }
#endif
