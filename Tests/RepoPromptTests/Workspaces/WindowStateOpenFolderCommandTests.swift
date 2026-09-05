import AppKit
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
        private var domainRuntimes: [MCPDomainRuntime] = []

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
            for runtime in domainRuntimes {
                await runtime.workspaceStore.testSetAfterExactRootSavedMarkerRead(nil)
                _ = await runtime.shutdown()
            }
            domainRuntimes.removeAll()
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

        func testEphemeralCommandRevalidatesResolvedPersistentAuthorityWinner() async throws {
            let runtime = try await makeDomainRuntime()
            let authorityWindow = await makeWindow(domainRuntime: runtime)
            let window = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "EphemeralCommandPersistentWinner")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let initialWinner = WorkspaceModel(
                dateModified: Date().addingTimeInterval(-3600),
                name: "Initial Persistent Winner",
                repoPaths: [folder.path]
            )
            let replacementWinner = WorkspaceModel(
                dateModified: Date().addingTimeInterval(3600),
                name: "Replacement Persistent Winner",
                repoPaths: [folder.path]
            )
            try await saveAuthoritativeWorkspace(initialWinner, in: authorityWindow, runtime: runtime)
            try await waitUntil {
                window.workspaceManager.workspace(withID: initialWinner.id) != nil
            }
            window.stopDomainWorkspaceProjectionForTesting()
            window.setAutomaticCommandProcessingForTesting(false)
            window.promptManager.promptText = "before"
            var didPublishReplacement = false
            window.workspaceManager.setWorkspaceActivationLeaseDidAcquireHandlerForTesting { workspaceID in
                guard workspaceID == initialWinner.id, !didPublishReplacement else { return }
                didPublishReplacement = true
                try? await self.saveAuthoritativeWorkspace(
                    replacementWinner,
                    in: authorityWindow,
                    runtime: runtime
                )
            }
            defer {
                window.workspaceManager.setWorkspaceActivationLeaseDidAcquireHandlerForTesting(nil)
            }
            var completions: [AppCommandExecutionResult] = []
            window.enqueueCommand(folderCommand(
                folderPath: folder.path,
                fileList: [payloadFile.path],
                promptText: "after",
                ephemeral: true
            )) { completions.append($0) }

            await window.processCommands()

            XCTAssertTrue(didPublishReplacement)
            XCTAssertEqual(completions, [.completed(workspaceID: replacementWinner.id)])
            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, replacementWinner.id)
            XCTAssertEqual(window.promptManager.promptText, "after")
            XCTAssertTrue(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertFalse(try XCTUnwrap(window.workspaceManager.activeWorkspace).isEphemeral)
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
            window.workspaceManager.isRefreshing = true
            defer { window.workspaceManager.isRefreshing = false }

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
                window.setAutomaticCommandProcessingForTesting(false)

                window.enqueueCommand(folderCommand(
                    folderPath: folder.path,
                    ephemeral: testCase.ephemeral,
                    persist: testCase.persist
                ))
                await window.processCommands()

                XCTAssertEqual(window.workspaceManager.activeWorkspace?.repoPaths, [folder.path], testCase.name)
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

        func testQueuedOpenReportsBlockedSwitchWithoutDuplicateCreationOrApplyingPayload() async throws {
            let runtime = try await makeDomainRuntime()
            let window = await makeWindow(domainRuntime: runtime)
            let activeFolder = try makeFolder(named: "BlockedUnmatchedActive")
            let targetFolder = try makeFolder(named: "BlockedUnmatchedTarget")
            let payloadFile = targetFolder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let active = window.workspaceManager.createWorkspace(
                name: "Blocked Unmatched Active",
                repoPaths: [activeFolder.path]
            )
            let initialSwitch = await window.workspaceManager.switchWorkspace(
                to: active,
                saveState: false,
                reason: "blockedUnmatchedFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            window.promptManager.promptText = "before"
            let storedPromptTitle = "Blocked Folder Stored Prompt \(UUID().uuidString)"
            window.workspaceManager.isRefreshing = true
            defer { window.workspaceManager.isRefreshing = false }
            window.setAutomaticCommandProcessingForTesting(false)
            var completions: [AppCommandExecutionResult] = []
            window.enqueueCommand(
                folderCommand(
                    folderPath: targetFolder.path,
                    fileList: [payloadFile.path],
                    promptText: "after",
                    newPrompt: (storedPromptTitle, "blocked stored prompt")
                ),
                folderRoute: .unresolved(
                    expectedRoot: WorkspaceRootSetKey(paths: [targetFolder.path])
                )
            ) { completions.append($0) }

            await window.processCommands()

            XCTAssertEqual(completions.count, 1)
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, active.id)
            XCTAssertEqual(window.promptManager.promptText, "before")
            XCTAssertFalse(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertFalse(window.promptManager.storedPrompts.contains {
                $0.title == storedPromptTitle
            })
            let firstSnapshot = await window.workspaceManager.workspaceRoutingCatalogSnapshot()
            let firstCatalog = try XCTUnwrap(firstSnapshot)
            let firstMatches = firstCatalog.filter {
                WorkspaceFolderOpenResolver.containsExactRoot(targetFolder.path, in: $0)
            }
            let createdWorkspace = try XCTUnwrap(firstMatches.first)
            XCTAssertEqual(completions, [
                .partialSuccess(
                    workspaceID: createdWorkspace.id,
                    reason: .failed(.workspaceSwitchBlocked)
                )
            ])

            await window.processCommands()

            let secondSnapshot = await window.workspaceManager.workspaceRoutingCatalogSnapshot()
            let secondCatalog = try XCTUnwrap(secondSnapshot)
            XCTAssertEqual(
                secondCatalog.count {
                    WorkspaceFolderOpenResolver.containsExactRoot(targetFolder.path, in: $0)
                },
                1
            )
            XCTAssertEqual(completions, [
                .partialSuccess(
                    workspaceID: createdWorkspace.id,
                    reason: .failed(.workspaceSwitchBlocked)
                )
            ])
        }

        func testQueuedCreationThenCancelledActivationReportsPartialSuccess() async throws {
            let runtime = try await makeDomainRuntime()
            let window = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "CancelledUnmatchedTarget")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let storedPromptTitle = "Cancelled Creation Stored Prompt \(UUID().uuidString)"
            let sessionProvider = FolderCommandWorkspaceSwitchSessionProvider()
            window.workspaceManager.registerSwitchSessionProvider(sessionProvider)
            window.promptManager.promptText = "before"
            var completions: [AppCommandExecutionResult] = []

            window.enqueueCommand(
                folderCommand(
                    folderPath: folder.path,
                    fileList: [payloadFile.path],
                    promptText: "after",
                    newPrompt: (storedPromptTitle, "must not be stored")
                )
            ) { completions.append($0) }
            let confirmation = try await waitForPendingSwitchConfirmation(in: window.workspaceManager)
            window.workspaceManager.resolveSwitchConfirmation(id: confirmation.id, allow: false)
            try await waitUntil {
                window.workspaceManager.pendingSwitchConfirmation == nil
                    && completions.count == 1
            }

            let snapshot = await window.workspaceManager.workspaceRoutingCatalogSnapshot()
            let createdWorkspace = try XCTUnwrap(snapshot?.first(where: {
                WorkspaceFolderOpenResolver.containsExactRoot(folder.path, in: $0)
            }))
            XCTAssertEqual(completions, [
                .partialSuccess(
                    workspaceID: createdWorkspace.id,
                    reason: .cancelled
                )
            ])
            XCTAssertNotEqual(window.workspaceManager.activeWorkspaceID, createdWorkspace.id)
            XCTAssertEqual(window.promptManager.promptText, "before")
            XCTAssertFalse(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertFalse(window.promptManager.storedPrompts.contains {
                $0.title == storedPromptTitle
            })
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)

            await window.processCommands()
            XCTAssertEqual(completions, [
                .partialSuccess(
                    workspaceID: createdWorkspace.id,
                    reason: .cancelled
                )
            ])
        }

        func testQueuedCreationThenWindowCloseBeforeActivationReportsPartialSuccess() async throws {
            let runtime = try await makeDomainRuntime()
            let window = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "ClosedAfterCreationTarget")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let storedPromptTitle = "Closed Creation Stored Prompt \(UUID().uuidString)"
            window.promptManager.promptText = "before"
            window.setAutomaticCommandProcessingForTesting(false)
            var committedWorkspaceID: UUID?
            var completions: [AppCommandExecutionResult] = []
            window.setPersistentFolderCreationCommitDidRecordHandlerForTesting { workspaceID in
                committedWorkspaceID = workspaceID
                window.beginClose()
            }
            defer {
                window.setPersistentFolderCreationCommitDidRecordHandlerForTesting(nil)
            }

            window.enqueueCommand(
                folderCommand(
                    folderPath: folder.path,
                    fileList: [payloadFile.path],
                    promptText: "after",
                    newPrompt: (storedPromptTitle, "must not be stored")
                )
            ) { completions.append($0) }

            await window.processCommands()

            let createdWorkspaceID = try XCTUnwrap(committedWorkspaceID)
            XCTAssertEqual(completions, [
                .partialSuccess(
                    workspaceID: createdWorkspaceID,
                    reason: .failed(.windowClosed)
                )
            ])
            let snapshot = await window.workspaceManager.workspaceRoutingCatalogSnapshot()
            XCTAssertEqual(snapshot?.count(where: { $0.id == createdWorkspaceID }), 1)
            XCTAssertNotEqual(window.workspaceManager.activeWorkspaceID, createdWorkspaceID)
            XCTAssertEqual(window.promptManager.promptText, "before")
            XCTAssertFalse(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertFalse(window.promptManager.storedPrompts.contains {
                $0.title == storedPromptTitle
            })
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)

            await window.processCommands()
            XCTAssertEqual(completions.count, 1)
        }

        func testRouterRoutesEphemeralFolderPayloadToProcessWideWinner() async throws {
            let lowerRankedWindow = await makeWindow()
            let winnerWindow = await makeWindow()
            let sourceWindow = await makeWindow()
            let folder = try makeFolder(named: "CrossWindowFocus")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let value = 1\n".utf8).write(to: payloadFile)
            let lowerRanked = try WorkspaceModel(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000011")),
                dateModified: Date(timeIntervalSince1970: 10),
                name: "Lower Ranked Match",
                repoPaths: [folder.path],
                ephemeralFlag: true
            )
            let winner = try WorkspaceModel(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000012")),
                dateModified: Date(timeIntervalSince1970: 20),
                name: "Resolver Winner",
                repoPaths: [folder.path],
                ephemeralFlag: true
            )
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
            let sourceCountBeforeRoute = sourceWindow.workspaceManager.workspaces.count
            sourceWindow.promptManager.promptText = "source-before"
            lowerRankedWindow.promptManager.promptText = "lower-before"
            winnerWindow.promptManager.promptText = "winner-before"
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?focus=true&ephemeral=true&files=\(payloadFile.path)&prompt=after"
            ))

            await AppDeepLinkRouter(windowStatesManager: .shared).route(url: url)
            await sourceWindow.processCommands()
            await lowerRankedWindow.processCommands()
            await winnerWindow.processCommands()

            XCTAssertEqual(sourceWindow.workspaceManager.workspaces.count, sourceCountBeforeRoute)
            XCTAssertEqual(sourceWindow.promptManager.promptText, "source-before")
            XCTAssertFalse(sourceWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertEqual(lowerRankedWindow.promptManager.promptText, "lower-before")
            XCTAssertFalse(lowerRankedWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertEqual(winnerWindow.promptManager.promptText, "after")
            XCTAssertTrue(winnerWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertEqual(lowerRankedWindow.workspaceManager.activeWorkspaceID, lowerRanked.id)
            XCTAssertEqual(winnerWindow.workspaceManager.activeWorkspaceID, winner.id)
        }

        func testRouterIgnoresAuthorityAbsentPersistentWorkspaceWithoutPendingPublication() async throws {
            let runtime = try await makeDomainRuntime()
            let authorityWindow = await makeWindow(domainRuntime: runtime)
            let receivingWindow = await makeWindow(domainRuntime: runtime)
            let unownedWindow = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "RouterUnownedPersistent")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let authorityWinner = WorkspaceModel(
                dateModified: Date(timeIntervalSince1970: 10),
                name: "Authority Winner",
                repoPaths: [folder.path]
            )
            try await saveAuthoritativeWorkspace(authorityWinner, in: authorityWindow, runtime: runtime)
            try await waitUntil {
                receivingWindow.workspaceManager.workspace(withID: authorityWinner.id) != nil
            }
            let projectedWinner = try XCTUnwrap(
                receivingWindow.workspaceManager.workspace(withID: authorityWinner.id)
            )
            let initialSwitch = await receivingWindow.workspaceManager.switchWorkspace(
                to: projectedWinner,
                saveState: false,
                reason: "routerAuthorityWinnerFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)

            let unowned = WorkspaceModel(
                dateModified: Date(timeIntervalSince1970: 100),
                name: "Unowned Persistent",
                repoPaths: [folder.path]
            )
            unownedWindow.workspaceManager.workspaces.append(unowned)
            XCTAssertNil(unownedWindow.workspaceManager.pendingPersistentWorkspacePublication(
                workspaceID: unowned.id,
                exactRoot: WorkspaceRootSetKey(paths: [folder.path])
            ))
            receivingWindow.promptManager.promptText = "receiving-before"
            unownedWindow.promptManager.promptText = "unowned-before"
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?focus=true&files=\(payloadFile.path)&prompt=after"
            ))

            await AppDeepLinkRouter(windowStatesManager: .shared).route(
                url: url,
                preferredLegacyWindow: unownedWindow
            )

            XCTAssertEqual(unownedWindow.queuedCommandCountForTesting, 0)
            XCTAssertEqual(receivingWindow.queuedCommandCountForTesting, 1)
            await receivingWindow.processCommands()
            await unownedWindow.processCommands()

            XCTAssertEqual(receivingWindow.workspaceManager.activeWorkspaceID, authorityWinner.id)
            XCTAssertEqual(receivingWindow.promptManager.promptText, "after")
            XCTAssertTrue(receivingWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertEqual(unownedWindow.promptManager.promptText, "unowned-before")
            XCTAssertFalse(unownedWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertNotEqual(unownedWindow.workspaceManager.activeWorkspaceID, unowned.id)
        }

        func testRouterRetainsPendingPublicationUntilAuthorityAdmission() async throws {
            let runtime = try await makeDomainRuntime()
            let ownerWindow = await makeWindow(domainRuntime: runtime)
            let receivingWindow = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "PendingPublicationRoute")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let pending = true\n".utf8).write(to: payloadFile)
            let gate = WindowFolderOpenCreationGate()
            ownerWindow.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting { _, _, _ in
                await gate.pauseUntilReleased()
            }
            defer {
                ownerWindow.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            }
            ownerWindow.setAutomaticCommandProcessingForTesting(false)
            ownerWindow.promptManager.promptText = "before"

            let workspace = ownerWindow.workspaceManager.createWorkspace(
                name: "Pending Publication Route",
                repoPaths: [folder.path]
            )
            await gate.waitUntilPaused()
            let expectedRoot = WorkspaceRootSetKey(paths: [folder.path])
            let publication = try XCTUnwrap(
                ownerWindow.workspaceManager.pendingPersistentWorkspacePublication(
                    workspaceID: workspace.id,
                    exactRoot: expectedRoot
                )
            )
            let beforePublication = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(beforePublication.workspaces.contains(where: {
                $0.document.workspaceID == workspace.id
            }))

            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?files=\(payloadFile.path)&prompt=after"
            ))
            await AppDeepLinkRouter(windowStatesManager: .shared).route(
                url: url,
                preferredLegacyWindow: receivingWindow
            )

            XCTAssertEqual(ownerWindow.queuedCommandCountForTesting, 1)
            XCTAssertEqual(receivingWindow.queuedCommandCountForTesting, 0)
            XCTAssertEqual(
                ownerWindow.workspaceManager.pendingPersistentWorkspacePublication(
                    workspaceID: workspace.id,
                    exactRoot: expectedRoot
                ),
                publication
            )
            let processingTask = Task {
                await ownerWindow.processCommands()
            }
            try await ContinuousClock().sleep(for: .milliseconds(50))
            XCTAssertEqual(ownerWindow.queuedCommandCountForTesting, 1)
            XCTAssertEqual(ownerWindow.promptManager.promptText, "before")
            XCTAssertFalse(ownerWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })

            await gate.release()
            await processingTask.value

            let afterPublication = await runtime.workspaceStore.snapshot()
            XCTAssertTrue(afterPublication.workspaces.contains(where: {
                $0.document.workspaceID == workspace.id
            }))
            XCTAssertEqual(ownerWindow.workspaceManager.activeWorkspaceID, workspace.id)
            XCTAssertEqual(ownerWindow.promptManager.promptText, "after")
            XCTAssertTrue(ownerWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertEqual(ownerWindow.queuedCommandCountForTesting, 0)
        }

        func testCancellingPendingPublicationRouteDoesNotCancelSharedCreation() async throws {
            let runtime = try await makeDomainRuntime()
            let window = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "CancelledPendingPublicationRoute")
            let gate = WindowFolderOpenCreationGate()
            window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting { _, _, _ in
                await gate.pauseUntilReleased()
            }
            defer {
                window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            }
            window.setAutomaticCommandProcessingForTesting(false)
            window.promptManager.promptText = "before"

            let workspace = window.workspaceManager.createWorkspace(
                name: "Cancelled Pending Publication Route",
                repoPaths: [folder.path]
            )
            await gate.waitUntilPaused()
            let publication = try XCTUnwrap(
                window.workspaceManager.pendingPersistentWorkspacePublication(
                    workspaceID: workspace.id,
                    exactRoot: WorkspaceRootSetKey(paths: [folder.path])
                )
            )
            var completions: [AppCommandExecutionResult] = []
            window.enqueueCommand(
                folderCommand(folderPath: folder.path, promptText: "after"),
                folderRoute: .pendingPersistentPublication(publication)
            ) { completions.append($0) }

            let processingTask = Task {
                await window.processCommands()
            }
            try await ContinuousClock().sleep(for: .milliseconds(50))
            processingTask.cancel()
            await processingTask.value

            XCTAssertEqual(completions, [.cancelled])
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(window.promptManager.promptText, "before")

            await gate.release()
            let outcome = try await publication.join()
            XCTAssertEqual(outcome.operationID, publication.operationID)
            XCTAssertEqual(outcome.disposition, .applied)
            let snapshot = await runtime.workspaceStore.snapshot()
            XCTAssertTrue(snapshot.workspaces.contains(where: {
                $0.document.workspaceID == workspace.id
            }))
            XCTAssertNotEqual(window.workspaceManager.activeWorkspaceID, workspace.id)
        }

        func testRouterUsesCatalogSnapshotAndPreservesSelectionsAcrossDivergentWindows() async throws {
            let staleWindow = await makeWindow()
            let receivingWindow = await makeWindow()
            let staleFolder = try makeFolder(named: "StaleRoot")
            let requestedFolder = try makeFolder(named: "FreshRoot")
            let staleFile = staleFolder.appendingPathComponent("Stale.swift")
            let requestedFile = requestedFolder.appendingPathComponent("Fresh.swift")
            try Data("let stale = true\n".utf8).write(to: staleFile)
            try Data("let fresh = true\n".utf8).write(to: requestedFile)
            let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000021"))
            let staleActiveSnapshot = WorkspaceModel(
                id: workspaceID,
                dateModified: Date(timeIntervalSince1970: 10),
                name: "Shared Workspace",
                repoPaths: [staleFolder.path]
            )
            let freshCatalogSnapshot = WorkspaceModel(
                id: workspaceID,
                dateModified: Date(timeIntervalSince1970: 20),
                name: "Shared Workspace",
                repoPaths: [requestedFolder.path]
            )
            staleWindow.workspaceManager.workspaces.append(staleActiveSnapshot)
            receivingWindow.workspaceManager.workspaces.append(freshCatalogSnapshot)
            let staleSwitch = await staleWindow.workspaceManager.switchWorkspace(
                to: staleActiveSnapshot,
                saveState: false,
                reason: "folderCommandStaleActiveFixture"
            )
            XCTAssertEqual(staleSwitch, .switched)
            let staleWorkspaceIndex = try XCTUnwrap(
                staleWindow.workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceID })
            )
            staleWindow.workspaceManager.workspaces[staleWorkspaceIndex] = staleActiveSnapshot
            await staleWindow.workspaceFilesViewModel.selectFiles(withPaths: [staleFile.path])
            XCTAssertTrue(staleWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == staleFile.path
            })
            staleWindow.promptManager.promptText = "stale-before"
            receivingWindow.promptManager.promptText = "receiving-before"
            let receivingCountBeforeRoute = receivingWindow.workspaceManager.workspaces.count
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(requestedFolder.path)?focus=true&files=\(requestedFile.path)&prompt=after"
            ))

            await AppDeepLinkRouter(windowStatesManager: .shared).route(url: url)
            await receivingWindow.processCommands()
            await staleWindow.processCommands()

            XCTAssertEqual(receivingWindow.workspaceManager.activeWorkspaceID, workspaceID)
            XCTAssertEqual(receivingWindow.workspaceManager.activeWorkspace?.repoPaths, [requestedFolder.path])
            XCTAssertEqual(receivingWindow.workspaceManager.workspaces.count, receivingCountBeforeRoute)
            XCTAssertEqual(
                receivingWindow.workspaceManager.workspaces.count {
                    WorkspaceFolderOpenResolver.bestEligibleMatch(
                        forFolderPath: requestedFolder.path,
                        in: [$0]
                    ) != nil
                },
                1
            )
            XCTAssertEqual(receivingWindow.promptManager.promptText, "after")
            XCTAssertTrue(receivingWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == requestedFile.path
            })
            XCTAssertEqual(staleWindow.workspaceManager.activeWorkspace?.repoPaths, [staleFolder.path])
            XCTAssertEqual(staleWindow.workspaceManager.workspaces.count(where: { $0.id == workspaceID }), 1)
            XCTAssertEqual(staleWindow.promptManager.promptText, "stale-before")
            XCTAssertTrue(staleWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == staleFile.path
            })
        }

        func testRouterPrefersCatalogRootsOverNewerActiveWorkspaceActivity() async throws {
            let staleWindow = await makeWindow()
            let receivingWindow = await makeWindow()
            let staleFolder = try makeFolder(named: "NewerActivityStaleRoot")
            let requestedFolder = try makeFolder(named: "OlderTimestampCurrentRoot")
            let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000022"))
            let staleActiveSnapshot = WorkspaceModel(
                id: workspaceID,
                dateModified: Date(timeIntervalSince1970: 20),
                name: "Shared Workspace",
                repoPaths: [staleFolder.path]
            )
            let currentCatalogSnapshot = WorkspaceModel(
                id: workspaceID,
                dateModified: Date(timeIntervalSince1970: 10),
                name: "Shared Workspace",
                repoPaths: [requestedFolder.path]
            )
            staleWindow.workspaceManager.workspaces.append(staleActiveSnapshot)
            receivingWindow.workspaceManager.workspaces.append(currentCatalogSnapshot)
            let staleSwitch = await staleWindow.workspaceManager.switchWorkspace(
                to: staleActiveSnapshot,
                saveState: false,
                reason: "folderCommandNewerActivityStaleFixture"
            )
            XCTAssertEqual(staleSwitch, .switched)
            let staleWorkspaceIndex = try XCTUnwrap(
                staleWindow.workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceID })
            )
            staleWindow.workspaceManager.workspaces[staleWorkspaceIndex] = staleActiveSnapshot
            staleWindow.promptManager.promptText = "stale-before"
            receivingWindow.promptManager.promptText = "receiving-before"
            let receivingCountBeforeRoute = receivingWindow.workspaceManager.workspaces.count
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(requestedFolder.path)?focus=true&prompt=after"
            ))

            await AppDeepLinkRouter(windowStatesManager: .shared).route(url: url)
            await receivingWindow.processCommands()
            await staleWindow.processCommands()

            XCTAssertEqual(receivingWindow.workspaceManager.activeWorkspaceID, workspaceID)
            XCTAssertEqual(receivingWindow.workspaceManager.activeWorkspace?.repoPaths, [requestedFolder.path])
            XCTAssertEqual(receivingWindow.workspaceManager.workspaces.count, receivingCountBeforeRoute)
            XCTAssertEqual(
                receivingWindow.workspaceManager.workspaces.count {
                    WorkspaceFolderOpenResolver.bestEligibleMatch(
                        forFolderPath: requestedFolder.path,
                        in: [$0]
                    ) != nil
                },
                1
            )
            XCTAssertEqual(receivingWindow.promptManager.promptText, "after")
            XCTAssertEqual(staleWindow.workspaceManager.activeWorkspace?.repoPaths, [staleFolder.path])
            XCTAssertEqual(staleWindow.promptManager.promptText, "stale-before")
        }

        func testQueuedOpenAdmitsOlderEligibleActiveWorkspaceOverNewerIncompleteRestoreOnce() async throws {
            for flags in [(nil, nil), (true, nil), (nil, false)] as [(Bool?, Bool?)] {
                try await assertQueuedOpenAdmitsOlderEligibleActiveWorkspace(ephemeral: flags.0, persist: flags.1)
            }
        }

        private func assertQueuedOpenAdmitsOlderEligibleActiveWorkspace(
            ephemeral: Bool?,
            persist: Bool?
        ) async throws {
            let runtime = try await makeDomainRuntime()
            let window = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "EligibleActiveWithIncompleteAlternative-\(UUID().uuidString)")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let eligible = WorkspaceModel(name: "Eligible A", repoPaths: [folder.path])
            try await saveAuthoritativeWorkspace(eligible, in: window, runtime: runtime)
            try await waitUntil { window.workspaceManager.workspace(withID: eligible.id) != nil }
            let projected = try XCTUnwrap(window.workspaceManager.workspace(withID: eligible.id))
            let activation = await window.workspaceManager.switchWorkspace(
                to: projected, saveState: false, reason: "eligibleActiveRecoveryFixture"
            )
            XCTAssertEqual(activation, .switched)
            let loadedPayload = await window.workspaceFilesViewModel.findFile(atPath: payloadFile.path)
            XCTAssertNotNil(loadedPayload)
            window.stopDomainWorkspaceProjectionForTesting()
            window.setAutomaticCommandProcessingForTesting(false)
            window.promptManager.promptText = "before"
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: window.windowID)
            let activeSnapshot = await client.canonicalWorkspaceSnapshot(eligible.id)
            let beforeDirty = try XCTUnwrap(activeSnapshot)
            var dirtyEligible = projected
            dirtyEligible.name = "Ordinary dirty A"
            dirtyEligible.dateModified = Date(timeIntervalSinceReferenceDate: 100)
            let dirty = try await client.replaceWorking(
                dirtyEligible,
                fileURL: beforeDirty.document.fileURL,
                expectedWorkspaceRevision: beforeDirty.revisions.workingRevision
            )
            XCTAssertEqual(dirty.disposition, .applied)
            XCTAssertNotNil(dirty.after?.dirtyRevision)
            let incomplete = try await makeIncompleteFolderMatch(folder: folder, window: window, runtime: runtime)
            window.workspaceManager.workspaces.append(incomplete)
            // A recovery-blind catalog would choose B, which is the original admission failure.
            XCTAssertEqual(WorkspaceFolderOpenResolver.bestEligibleMatch(
                forFolderPath: folder.path, in: [dirtyEligible, incomplete]
            )?.id, incomplete.id)
            let localCount = window.workspaceManager.workspaces.count
            let localIDs = Set(window.workspaceManager.workspaces.map(\.id))
            let canonicalBefore = await client.snapshot()
            let expectedResolutionPasses = ephemeral == true || persist == false ? 0 : 1
            let expectedAdmissionPasses = ephemeral == true || persist == false ? 3 : 1
            var resolutionPasses = 0
            var admissionPasses = 0
            window.workspaceManager.setPersistentFolderOpenDidSnapshotHandlerForTesting { resolutionPasses += 1 }
            window.workspaceManager.setWorkspaceRoutingAuthorityDidSnapshotHandlerForTesting { admissionPasses += 1 }
            let title = "Recovery eligible stored prompt \(UUID().uuidString)"
            var completions: [AppCommandExecutionResult] = []
            window.enqueueCommand(folderCommand(
                folderPath: folder.path,
                fileList: [payloadFile.path],
                promptText: "after",
                newPrompt: (title, "stored once"),
                ephemeral: ephemeral,
                persist: persist
            )) { completions.append($0) }

            await window.processCommands()

            XCTAssertEqual(completions, [.completed(workspaceID: eligible.id)])
            XCTAssertEqual(resolutionPasses, expectedResolutionPasses)
            XCTAssertEqual(admissionPasses, expectedAdmissionPasses)
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, eligible.id)
            XCTAssertFalse(try XCTUnwrap(window.workspaceManager.activeWorkspace).isEphemeral)
            XCTAssertEqual(window.workspaceManager.workspaces.count, localCount)
            XCTAssertEqual(Set(window.workspaceManager.workspaces.map(\.id)), localIDs)
            let canonicalAfter = await client.snapshot()
            XCTAssertEqual(
                Set(canonicalAfter.workspaces.map(\.document.workspaceID)),
                Set(canonicalBefore.workspaces.map(\.document.workspaceID))
            )
            let canonicalEligible = try XCTUnwrap(canonicalAfter.workspaces.first { $0.document.workspaceID == eligible.id })
            XCTAssertFalse(canonicalEligible.document.metadata.isEphemeral)
            XCTAssertEqual(window.promptManager.promptText, "after")
            XCTAssertEqual(window.workspaceFilesViewModel.selectedFiles.count(where: { $0.fullPath == payloadFile.path }), 1)
            let stored = try XCTUnwrap(window.promptManager.storedPrompts.first { $0.title == title })
            XCTAssertEqual(stored.content, "stored once")
            XCTAssertTrue(window.promptManager.selectedPromptIDs.contains(stored.id))
            XCTAssertEqual(window.promptManager.storedPrompts.count { $0.title == title }, 1)

            // A drained queue must not reapply either payload or add another stored prompt.
            window.promptManager.promptText = "after drain"
            await window.workspaceFilesViewModel.selectFiles(withPaths: [], allowEmpty: true)
            await window.processCommands()
            XCTAssertEqual(completions, [.completed(workspaceID: eligible.id)])
            XCTAssertEqual(resolutionPasses, expectedResolutionPasses)
            XCTAssertEqual(admissionPasses, expectedAdmissionPasses)
            XCTAssertEqual(window.promptManager.promptText, "after drain")
            XCTAssertFalse(window.workspaceFilesViewModel.selectedFiles.contains { $0.fullPath == payloadFile.path })
            XCTAssertEqual(window.promptManager.storedPrompts.count { $0.title == title }, 1)
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(Set(window.workspaceManager.workspaces.map(\.id)), localIDs)
            XCTAssertFalse(try XCTUnwrap(window.workspaceManager.activeWorkspace).isEphemeral)
            let canonicalDrained = await client.snapshot()
            XCTAssertEqual(
                Set(canonicalDrained.workspaces.map(\.document.workspaceID)),
                Set(canonicalBefore.workspaces.map(\.document.workspaceID))
            )
        }

        func testQueuedOpenRejectsIncompleteOnlyWithoutPayloadOrCreation() async throws {
            for flags in [(nil, nil), (true, nil), (nil, false)] as [(Bool?, Bool?)] {
                try await assertQueuedOpenRejectsRecoveryBlockedMatch(
                    unreadable: false, ephemeral: flags.0, persist: flags.1
                )
            }
        }

        func testQueuedOpenRejectsUnreadableSavedMatchWithoutPayloadOrCreation() async throws {
            for flags in [(nil, nil), (true, nil), (nil, false)] as [(Bool?, Bool?)] {
                try await assertQueuedOpenRejectsRecoveryBlockedMatch(
                    unreadable: true, ephemeral: flags.0, persist: flags.1
                )
            }
        }

        func testQueuedOpenCancellationDuringSavedEligibilityReadDrainsWithoutPayloadOrCreation() async throws {
            for flags in [(nil, nil), (true, nil), (nil, false)] as [(Bool?, Bool?)] {
                try await assertQueuedOpenRejectsRecoveryBlockedMatch(
                    unreadable: false, ephemeral: flags.0, persist: flags.1, cancelDuringResolution: true
                )
            }
        }

        private func assertQueuedOpenRejectsRecoveryBlockedMatch(
            unreadable: Bool,
            ephemeral: Bool?,
            persist: Bool?,
            cancelDuringResolution: Bool = false
        ) async throws {
            let runtime = try await makeDomainRuntime()
            let window = await makeWindow(domainRuntime: runtime)
            let activeFolder = try makeFolder(named: "RecoveryBlockedActive")
            let folder = try makeFolder(named: "RecoveryBlockedRequested-\(UUID().uuidString)")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            let selectedFile = activeFolder.appendingPathComponent("Keep.swift")
            try Data("let keep = true\n".utf8).write(to: selectedFile)
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let active = WorkspaceModel(name: "Keep active", repoPaths: [activeFolder.path])
            try await saveAuthoritativeWorkspace(active, in: window, runtime: runtime)
            try await waitUntil { window.workspaceManager.workspace(withID: active.id) != nil }
            let projected = try XCTUnwrap(window.workspaceManager.workspace(withID: active.id))
            let activation = await window.workspaceManager.switchWorkspace(
                to: projected, saveState: false, reason: "recoveryBlockedCommandFixture"
            )
            XCTAssertEqual(activation, .switched)
            await window.workspaceFilesViewModel.selectFiles(withPaths: [selectedFile.path])
            window.promptManager.promptText = "keep prompt"
            window.stopDomainWorkspaceProjectionForTesting()
            window.setAutomaticCommandProcessingForTesting(false)
            let blocked = try await makeIncompleteFolderMatch(
                folder: folder, window: window, runtime: runtime, unreadable: unreadable
            )
            window.workspaceManager.workspaces.append(blocked)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: window.windowID)
            let before = await client.snapshot()
            let localCount = window.workspaceManager.workspaces.count
            let selectedBefore = Set(window.workspaceFilesViewModel.selectedFiles.map(\.fullPath))
            let storedBefore = window.promptManager.storedPrompts.map(\.id)
            let selectedPromptsBefore = window.promptManager.selectedPromptIDs
            var resolutionPasses = 0
            var admissionPasses = 0
            window.workspaceManager.setPersistentFolderOpenDidSnapshotHandlerForTesting { resolutionPasses += 1 }
            window.workspaceManager.setWorkspaceRoutingAuthorityDidSnapshotHandlerForTesting { admissionPasses += 1 }
            var completions: [AppCommandExecutionResult] = []
            window.enqueueCommand(folderCommand(
                folderPath: folder.path,
                fileList: [payloadFile.path],
                promptText: "must not apply",
                newPrompt: ("Must not store \(UUID().uuidString)", "blocked"),
                ephemeral: ephemeral,
                persist: persist
            )) { completions.append($0) }

            let expectedResult: AppCommandExecutionResult
            if cancelDuringResolution {
                let gate = WindowFolderOpenCreationGate()
                await runtime.workspaceStore.testSetAfterExactRootSavedMarkerRead { workspaceID in
                    guard workspaceID == blocked.id else { return }
                    await gate.pauseUntilReleased()
                }
                let processing = Task { await window.processCommands() }
                await gate.waitUntilPaused()
                processing.cancel()
                await gate.release()
                await processing.value
                await runtime.workspaceStore.testSetAfterExactRootSavedMarkerRead(nil)
                expectedResult = .cancelled
            } else {
                await window.processCommands()
                expectedResult = .failed(.authorityFailure)
            }
            await window.processCommands()

            XCTAssertEqual(completions, [expectedResult])
            XCTAssertEqual(resolutionPasses, ephemeral == true || persist == false ? 0 : 1)
            let expectedAdmissionPasses = ephemeral == true || persist == false ? (cancelDuringResolution ? 1 : 2) : 0
            XCTAssertEqual(admissionPasses, expectedAdmissionPasses)
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, active.id)
            XCTAssertEqual(window.workspaceManager.workspaces.count, localCount)
            XCTAssertEqual(window.promptManager.promptText, "keep prompt")
            XCTAssertEqual(Set(window.workspaceFilesViewModel.selectedFiles.map(\.fullPath)), selectedBefore)
            XCTAssertEqual(window.promptManager.storedPrompts.map(\.id), storedBefore)
            XCTAssertEqual(window.promptManager.selectedPromptIDs, selectedPromptsBefore)
            let after = await client.snapshot()
            XCTAssertEqual(
                Set(after.workspaces.map(\.document.workspaceID)),
                Set(before.workspaces.map(\.document.workspaceID))
            )
        }

        func testFlaggedQueuedOpenRanksEligiblePersistentAndLiveEphemeralOverIncompleteRestore() async throws {
            for flags in [(true, nil), (nil, false)] as [(Bool?, Bool?)] {
                for ephemeralWins in [false, true] {
                    try await assertFlaggedQueuedOpenRanksLiveEphemeral(
                        ephemeral: flags.0, persist: flags.1, persistentDate: ephemeralWins ? 100 : 200
                    )
                }
            }
        }

        func testFlaggedQueuedOpenReusesLiveEphemeralWhenPersistentRecoveryIsBlocked() async throws {
            for flags in [(true, nil), (nil, false)] as [(Bool?, Bool?)] {
                try await assertFlaggedQueuedOpenRanksLiveEphemeral(
                    ephemeral: flags.0, persist: flags.1, persistentDate: nil
                )
            }
        }

        private func assertFlaggedQueuedOpenRanksLiveEphemeral(
            ephemeral: Bool?,
            persist: Bool?,
            persistentDate: TimeInterval?
        ) async throws {
            let runtime = try await makeDomainRuntime()
            let owner = await makeWindow(domainRuntime: runtime)
            let receiver = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "MixedRecoveryCandidates-\(UUID().uuidString)")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let live = owner.workspaceManager.createWorkspace(
                name: "Live ephemeral E", repoPaths: [folder.path], ephemeral: true
            )
            let activation = await owner.workspaceManager.switchWorkspace(
                to: live, saveState: false, reason: "mixedRecoveryLiveFixture"
            )
            XCTAssertEqual(activation, .switched)
            let loadedPayload = await owner.workspaceFilesViewModel.findFile(atPath: payloadFile.path)
            XCTAssertNotNil(loadedPayload)
            for window in [owner, receiver] {
                window.stopDomainWorkspaceProjectionForTesting()
                window.setAutomaticCommandProcessingForTesting(false)
                window.promptManager.promptText = "before"
            }
            let persistent = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: persistentDate ?? 100),
                name: "Eligible persistent A", repoPaths: [folder.path]
            )
            if persistentDate != nil {
                try await saveAuthoritativeWorkspace(persistent, in: receiver, runtime: runtime)
                receiver.workspaceManager.workspaces.append(persistent)
            }
            let incomplete = try await makeIncompleteFolderMatch(folder: folder, window: receiver, runtime: runtime)
            receiver.workspaceManager.workspaces.append(incomplete)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: receiver.windowID)
            let before = await client.snapshot()
            let ownerIDs = Set(owner.workspaceManager.workspaces.map(\.id))
            let receiverIDs = Set(receiver.workspaceManager.workspaces.map(\.id))
            // Pin Recent after awaited reads too: delayed activation/save bookkeeping can
            // otherwise retimestamp the live workspace while fixture setup is suspended.
            for window in [owner, receiver] {
                window.workspaceManager.setWorkspaceRoutingAuthorityDidSnapshotHandlerForTesting {
                    guard let index = owner.workspaceManager.workspaces.firstIndex(where: { $0.id == live.id }) else {
                        return XCTFail("Live ephemeral fixture disappeared")
                    }
                    owner.workspaceManager.workspaces[index].dateModified = Date(timeIntervalSinceReferenceDate: 150)
                }
            }
            let ephemeralWins = (persistentDate ?? 100) < 150
            let winner = ephemeralWins ? owner : receiver
            let loser = ephemeralWins ? receiver : owner
            let winnerID = ephemeralWins ? live.id : persistent.id
            let loserSelectedFiles = Set(loser.workspaceFilesViewModel.selectedFiles.map(\.fullPath))
            let loserSelectedPrompts = loser.promptManager.selectedPromptIDs
            let title = "Mixed candidates stored prompt \(UUID().uuidString)"
            var completions: [AppCommandExecutionResult] = []
            receiver.enqueueCommand(folderCommand(
                folderPath: folder.path, fileList: [payloadFile.path], promptText: "after",
                newPrompt: (title, "stored once"), ephemeral: ephemeral, persist: persist
            )) { completions.append($0) }

            await receiver.processCommands()
            XCTAssertEqual(receiver.queuedCommandCountForTesting, 0)
            XCTAssertEqual(owner.queuedCommandCountForTesting, ephemeralWins ? 1 : 0)
            XCTAssertEqual(completions, ephemeralWins ? [] : [.completed(workspaceID: winnerID)])
            if ephemeralWins {
                XCTAssertEqual(owner.promptManager.promptText, "before")
                XCTAssertFalse(owner.promptManager.storedPrompts.contains { $0.title == title })
            }
            await owner.processCommands()

            XCTAssertEqual(completions, [.completed(workspaceID: winnerID)])
            XCTAssertEqual(winner.workspaceManager.activeWorkspaceID, winnerID)
            XCTAssertEqual(try XCTUnwrap(winner.workspaceManager.activeWorkspace).isEphemeral, ephemeralWins)
            XCTAssertEqual(winner.promptManager.promptText, "after")
            XCTAssertEqual(winner.workspaceFilesViewModel.selectedFiles.map(\.fullPath), [payloadFile.path])
            let stored = try XCTUnwrap(winner.promptManager.storedPrompts.first { $0.title == title })
            XCTAssertEqual(stored.content, "stored once")
            XCTAssertTrue(winner.promptManager.selectedPromptIDs.contains(stored.id))
            XCTAssertEqual(winner.promptManager.storedPrompts.count { $0.title == title }, 1)
            XCTAssertEqual(loser.promptManager.promptText, "before")
            XCTAssertEqual(Set(loser.workspaceFilesViewModel.selectedFiles.map(\.fullPath)), loserSelectedFiles)
            XCTAssertEqual(loser.promptManager.selectedPromptIDs, loserSelectedPrompts)
            XCTAssertFalse(loser.promptManager.storedPrompts.contains { $0.title == title })
            XCTAssertEqual(Set(owner.workspaceManager.workspaces.map(\.id)), ownerIDs)
            XCTAssertEqual(owner.workspaceManager.workspaces.count, ownerIDs.count)
            XCTAssertEqual(Set(receiver.workspaceManager.workspaces.map(\.id)), receiverIDs)
            XCTAssertEqual(receiver.workspaceManager.workspaces.count, receiverIDs.count)
            let after = await client.snapshot()
            XCTAssertEqual(Set(after.workspaces.map(\.document.workspaceID)), Set(before.workspaces.map(\.document.workspaceID)))
            XCTAssertFalse(after.workspaces.contains { $0.document.workspaceID == live.id })
            if persistentDate != nil {
                let canonicalPersistent = try XCTUnwrap(after.workspaces.first { $0.document.workspaceID == persistent.id })
                XCTAssertFalse(canonicalPersistent.document.metadata.isEphemeral)
                if ephemeralWins {
                    XCTAssertEqual(canonicalPersistent, before.workspaces.first { $0.document.workspaceID == persistent.id })
                }
            }
            XCTAssertEqual(
                after.workspaces.first { $0.document.workspaceID == incomplete.id },
                before.workspaces.first { $0.document.workspaceID == incomplete.id }
            )

            winner.promptManager.promptText = "after drain"
            await winner.workspaceFilesViewModel.selectFiles(withPaths: [], allowEmpty: true)
            await receiver.processCommands()
            await owner.processCommands()
            XCTAssertEqual(completions, [.completed(workspaceID: winnerID)])
            XCTAssertEqual(winner.promptManager.promptText, "after drain")
            XCTAssertTrue(winner.workspaceFilesViewModel.selectedFiles.isEmpty)
            XCTAssertEqual(winner.promptManager.storedPrompts.count { $0.title == title }, 1)
            XCTAssertEqual(owner.queuedCommandCountForTesting, 0)
            XCTAssertEqual(receiver.queuedCommandCountForTesting, 0)
            for window in [owner, receiver] {
                window.workspaceManager.setWorkspaceRoutingAuthorityDidSnapshotHandlerForTesting(nil)
            }
        }

        func testFlaggedQueuedOpenRetriesOneEligibilitySaveButRejectsRepeatedChanges() async throws {
            for flags in [(true, nil), (nil, false)] as [(Bool?, Bool?)] {
                for changeCount in [1, 2] {
                    try await assertFlaggedQueuedOpenHandlesEligibilitySaves(
                        ephemeral: flags.0, persist: flags.1, changeCount: changeCount
                    )
                }
            }
        }

        private func assertFlaggedQueuedOpenHandlesEligibilitySaves(
            ephemeral: Bool?,
            persist: Bool?,
            changeCount: Int
        ) async throws {
            let runtime = try await makeDomainRuntime()
            let window = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "EligibilitySaveRetry-\(UUID().uuidString)")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            window.stopDomainWorkspaceProjectionForTesting()
            window.setAutomaticCommandProcessingForTesting(false)
            window.promptManager.promptText = "before"
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: window.windowID)
            var candidates: [WorkspaceModel] = []
            for index in 0 ..< changeCount {
                var candidate = WorkspaceModel(name: "Save candidate \(index)", repoPaths: [folder.path])
                try await saveAuthoritativeWorkspace(candidate, in: window, runtime: runtime)
                let snapshot = await client.canonicalWorkspaceSnapshot(candidate.id)
                let current = try XCTUnwrap(snapshot)
                candidate.name += " dirty"
                let dirty = try await client.replaceWorking(
                    candidate, fileURL: current.document.fileURL,
                    expectedWorkspaceRevision: current.revisions.workingRevision
                )
                XCTAssertEqual(dirty.disposition, .applied)
                XCTAssertNotNil(dirty.after?.dirtyRevision)
                candidates.append(candidate)
                window.workspaceManager.workspaces.append(candidate)
            }
            let candidateIDs = Set(candidates.map(\.id))
            // Arm one real save per selection pass, not one per candidate in the same read.
            // Saving bypasses the catalog gate and invalidates that pass's saved-marker baseline.
            let saveOrder = candidates.map(\.id)
            var routingPasses = 0
            window.workspaceManager.setWorkspaceRoutingAuthorityDidSnapshotHandlerForTesting {
                routingPasses += 1
                guard routingPasses == 1 || routingPasses == 3 else { return }
                let index = routingPasses / 2
                guard saveOrder.indices.contains(index) else { return }
                let changingID = saveOrder[index]
                await runtime.workspaceStore.testSetAfterExactRootSavedMarkerRead { workspaceID in
                    guard workspaceID == changingID,
                          let snapshot = await runtime.workspaceStore.workspaceSnapshot(workspaceID)
                    else { return }
                    await runtime.workspaceStore.testSetAfterExactRootSavedMarkerRead(nil)
                    let saved = await runtime.workspaceStore.execute(.init(
                        operationID: UUID(), expectedWorkspaceRevision: snapshot.revisions.workingRevision,
                        origin: .appPresentation(windowID: -1314),
                        command: .saveWorkspaceDocument(workspaceID: workspaceID)
                    ))
                    XCTAssertEqual(saved.disposition, .applied)
                }
            }
            let before = await client.snapshot()
            let localIDs = Set(window.workspaceManager.workspaces.map(\.id))
            let activeID = window.workspaceManager.activeWorkspaceID
            let selectedFiles = Set(window.workspaceFilesViewModel.selectedFiles.map(\.fullPath))
            let selectedPrompts = window.promptManager.selectedPromptIDs
            let title = "Eligibility save prompt \(UUID().uuidString)"
            var completions: [AppCommandExecutionResult] = []
            window.enqueueCommand(folderCommand(
                folderPath: folder.path, fileList: [payloadFile.path], promptText: "after",
                newPrompt: (title, "stored once"), ephemeral: ephemeral, persist: persist
            )) { completions.append($0) }
            await window.processCommands()
            await runtime.workspaceStore.testSetAfterExactRootSavedMarkerRead(nil)
            XCTAssertEqual(routingPasses, changeCount == 1 ? 5 : 4)

            if changeCount == 1 {
                XCTAssertEqual(completions, [.completed(workspaceID: candidates[0].id)])
                XCTAssertFalse(try XCTUnwrap(window.workspaceManager.activeWorkspace).isEphemeral)
                XCTAssertEqual(window.promptManager.promptText, "after")
                XCTAssertEqual(window.workspaceFilesViewModel.selectedFiles.map(\.fullPath), [payloadFile.path])
                let stored = try XCTUnwrap(window.promptManager.storedPrompts.first { $0.title == title })
                XCTAssertEqual(stored.content, "stored once")
                XCTAssertTrue(window.promptManager.selectedPromptIDs.contains(stored.id))
                XCTAssertEqual(window.promptManager.storedPrompts.count { $0.title == title }, 1)
            } else {
                XCTAssertEqual(completions, [.failed(.routeChangedAfterRetry)])
                XCTAssertEqual(window.workspaceManager.activeWorkspaceID, activeID)
                XCTAssertEqual(Set(window.workspaceManager.workspaces.map(\.id)), localIDs)
                XCTAssertEqual(window.promptManager.promptText, "before")
                XCTAssertEqual(Set(window.workspaceFilesViewModel.selectedFiles.map(\.fullPath)), selectedFiles)
                XCTAssertEqual(window.promptManager.selectedPromptIDs, selectedPrompts)
                XCTAssertFalse(window.promptManager.storedPrompts.contains { $0.title == title })
            }
            let after = await client.snapshot()
            XCTAssertEqual(Set(after.workspaces.map(\.document.workspaceID)), Set(before.workspaces.map(\.document.workspaceID)))
            if changeCount == 2 {
                XCTAssertTrue(after.workspaces.filter { candidateIDs.contains($0.document.workspaceID) }.allSatisfy { $0.revisions.dirtyRevision == nil })
            }
            window.promptManager.promptText = "after drain"
            await window.workspaceFilesViewModel.selectFiles(withPaths: [], allowEmpty: true)
            await window.processCommands()
            XCTAssertEqual(completions.count, 1)
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(window.promptManager.promptText, "after drain")
            XCTAssertTrue(window.workspaceFilesViewModel.selectedFiles.isEmpty)
            XCTAssertEqual(window.promptManager.storedPrompts.count { $0.title == title }, changeCount == 1 ? 1 : 0)
        }

        private func makeIncompleteFolderMatch(
            folder: URL,
            window: WindowState,
            runtime: MCPDomainRuntime,
            unreadable: Bool = false
        ) async throws -> WorkspaceModel {
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: window.windowID)
            let saved = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 300),
                name: "Newer incomplete B",
                repoPaths: [folder.path],
                isHiddenInMenus: !unreadable,
                consolidatedIntoWorkspaceID: unreadable ? nil : UUID()
            )
            let fileURL = window.workspaceManager.workspaceFileURL(for: saved)
            let created = try await client.create(saved, fileURL: fileURL)
            XCTAssertEqual(created.disposition, .applied)
            let snapshot = try XCTUnwrap(created.workspace)
            var working = saved
            working.isHiddenInMenus = false
            working.consolidatedIntoWorkspaceID = nil
            working.name = "Newer incomplete working B"
            let dirty = try await client.replaceWorking(
                working, fileURL: fileURL, expectedWorkspaceRevision: snapshot.revisions.workingRevision
            )
            XCTAssertEqual(dirty.disposition, .applied)
            XCTAssertNotNil(dirty.after?.dirtyRevision)
            if unreadable { try FileManager.default.removeItem(at: fileURL) }
            return working
        }

        func testQueuedOpenReResolvesCurrentAuthorityWinnerAndPreservesPayload() async throws {
            let runtime = try await makeDomainRuntime()
            let authorityWindow = await makeWindow(domainRuntime: runtime)
            let targetWindow = await makeWindow(domainRuntime: runtime)
            let requestedFolder = try makeFolder(named: "QueuedCurrentWinner")
            let replacementFolder = try makeFolder(named: "QueuedFormerWinnerRoot")
            let payloadFile = requestedFolder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let formerWinnerID = try XCTUnwrap(
                UUID(uuidString: "00000000-0000-0000-0000-000000000023")
            )
            let currentWinnerID = try XCTUnwrap(
                UUID(uuidString: "00000000-0000-0000-0000-000000000024")
            )
            let finalWinnerID = try XCTUnwrap(
                UUID(uuidString: "00000000-0000-0000-0000-000000000025")
            )
            let formerWinner = WorkspaceModel(
                id: formerWinnerID,
                dateModified: Date(timeIntervalSince1970: 10),
                name: "Former Winner",
                repoPaths: [requestedFolder.path]
            )
            try await saveAuthoritativeWorkspace(formerWinner, in: authorityWindow, runtime: runtime)
            try await waitUntil {
                targetWindow.workspaceManager.workspace(withID: formerWinnerID)?.repoPaths == [requestedFolder.path]
            }
            let projectedFormerWinner = try XCTUnwrap(
                targetWindow.workspaceManager.workspace(withID: formerWinnerID)
            )
            let initialSwitch = await targetWindow.workspaceManager.switchWorkspace(
                to: projectedFormerWinner,
                saveState: false,
                reason: "queuedCurrentWinnerFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            targetWindow.promptManager.promptText = "before"
            targetWindow.setAutomaticCommandProcessingForTesting(false)
            let command = folderCommand(
                folderPath: requestedFolder.path,
                fileList: [payloadFile.path],
                promptText: "after",
                newPrompt: ("Re-resolved Stored Prompt \(UUID().uuidString)", "retry payload")
            )
            var completions: [AppCommandExecutionResult] = []
            targetWindow.enqueueCommand(
                command,
                folderRoute: .authorityExactRoot(
                    expectedRoot: WorkspaceRootSetKey(paths: [requestedFolder.path])
                )
            ) { completions.append($0) }

            targetWindow.stopDomainWorkspaceProjectionForTesting()
            var movedFormerWinner = formerWinner
            movedFormerWinner.repoPaths = [replacementFolder.path]
            movedFormerWinner.dateModified = Date(timeIntervalSince1970: 20)
            try await saveAuthoritativeWorkspace(movedFormerWinner, in: authorityWindow, runtime: runtime)
            let currentWinner = WorkspaceModel(
                id: currentWinnerID,
                dateModified: Date(timeIntervalSince1970: 30),
                name: "Current Winner",
                repoPaths: [requestedFolder.path]
            )
            try await saveAuthoritativeWorkspace(currentWinner, in: authorityWindow, runtime: runtime)
            let finalWinner = WorkspaceModel(
                id: finalWinnerID,
                dateModified: Date(timeIntervalSince1970: 40),
                name: "Final Winner",
                repoPaths: [requestedFolder.path]
            )
            var didChangeRouteDuringActivation = false
            targetWindow.workspaceManager.setWorkspaceActivationLeaseDidAcquireHandlerForTesting {
                workspaceID in
                guard workspaceID == currentWinnerID,
                      !didChangeRouteDuringActivation
                else { return }
                didChangeRouteDuringActivation = true
                var movedCurrentWinner = currentWinner
                movedCurrentWinner.repoPaths = [replacementFolder.path]
                movedCurrentWinner.dateModified = Date(timeIntervalSince1970: 35)
                try? await self.saveAuthoritativeWorkspace(movedCurrentWinner, in: authorityWindow, runtime: runtime)
                try? await self.saveAuthoritativeWorkspace(finalWinner, in: authorityWindow, runtime: runtime)
            }

            await targetWindow.processCommands()

            XCTAssertTrue(didChangeRouteDuringActivation)
            XCTAssertEqual(completions, [.completed(workspaceID: finalWinnerID)])
            XCTAssertEqual(targetWindow.queuedCommandCountForTesting, 0)
            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspaceID, finalWinnerID)
            XCTAssertEqual(targetWindow.promptManager.promptText, "after")
            XCTAssertTrue(targetWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            let storedPrompt = try XCTUnwrap(targetWindow.promptManager.storedPrompts.first {
                $0.title == command.newPrompt?.title
            })
            XCTAssertEqual(storedPrompt.content, command.newPrompt?.content)
            XCTAssertTrue(targetWindow.promptManager.selectedPromptIDs.contains(storedPrompt.id))
            XCTAssertEqual(
                targetWindow.promptManager.storedPrompts.count { $0.title == storedPrompt.title },
                1
            )
            let routingSnapshot = await targetWindow.workspaceManager.workspaceRoutingCatalogSnapshot()
            let routingCatalog = try XCTUnwrap(routingSnapshot)
            XCTAssertEqual(
                routingCatalog.first(where: { $0.id == formerWinnerID })?.repoPaths,
                [replacementFolder.path]
            )
            XCTAssertEqual(
                routingCatalog.first(where: { $0.id == currentWinnerID })?.repoPaths,
                [replacementFolder.path]
            )
            XCTAssertEqual(
                routingCatalog.filter {
                    WorkspaceFolderOpenResolver.containsExactRoot(requestedFolder.path, in: $0)
                }.map(\.id),
                [finalWinnerID]
            )
        }

        func testFinalPayloadAdmissionRetriesThenFailsWhenActiveWorkspaceChangesAfterAuthoritySnapshot() async throws {
            let runtime = try await makeDomainRuntime()
            let authorityWindow = await makeWindow(domainRuntime: runtime)
            let window = await makeWindow(domainRuntime: runtime)
            let targetFolder = try makeFolder(named: "FinalAdmissionActiveTarget")
            let alternateFolder = try makeFolder(named: "FinalAdmissionActiveAlternate")
            let payloadFile = targetFolder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let target = WorkspaceModel(
                name: "Final Admission Active Target",
                repoPaths: [targetFolder.path]
            )
            let alternate = WorkspaceModel(
                name: "Final Admission Active Alternate",
                repoPaths: [alternateFolder.path]
            )
            try await saveAuthoritativeWorkspace(target, in: authorityWindow, runtime: runtime)
            try await saveAuthoritativeWorkspace(alternate, in: authorityWindow, runtime: runtime)
            try await waitUntil {
                window.workspaceManager.workspace(withID: target.id) != nil
                    && window.workspaceManager.workspace(withID: alternate.id) != nil
            }
            let projectedAlternate = try XCTUnwrap(
                window.workspaceManager.workspace(withID: alternate.id)
            )
            let initialSwitch = await window.workspaceManager.switchWorkspace(
                to: projectedAlternate,
                saveState: false,
                reason: "finalPayloadAdmissionActiveWorkspaceFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            window.promptManager.promptText = "before"
            window.setAutomaticCommandProcessingForTesting(false)
            window.stopDomainWorkspaceProjectionForTesting()
            let storedPromptTitle = "Final Admission Active Stored Prompt \(UUID().uuidString)"
            var completions: [AppCommandExecutionResult] = []
            window.enqueueCommand(
                folderCommand(
                    folderPath: targetFolder.path,
                    fileList: [payloadFile.path],
                    promptText: "after",
                    newPrompt: (storedPromptTitle, "must not be stored")
                )
            ) { completions.append($0) }

            var snapshotRaceCount = 0
            window.workspaceManager.setWorkspaceRoutingAuthorityDidSnapshotHandlerForTesting {
                guard window.workspaceManager.activeWorkspaceID == target.id,
                      let currentAlternate = window.workspaceManager.workspace(withID: alternate.id)
                else {
                    return
                }
                snapshotRaceCount += 1
                let switchResult = await window.workspaceManager.switchWorkspace(
                    to: currentAlternate,
                    saveState: false,
                    reason: "finalPayloadAdmissionActiveWorkspaceRace"
                )
                XCTAssertEqual(switchResult, .switched)
            }

            await window.processCommands()

            XCTAssertEqual(snapshotRaceCount, 2)
            XCTAssertEqual(completions, [.failed(.routeChangedAfterRetry)])
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, alternate.id)
            XCTAssertEqual(window.promptManager.promptText, "before")
            XCTAssertFalse(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertFalse(window.promptManager.storedPrompts.contains {
                $0.title == storedPromptTitle
            })

            await window.processCommands()
            XCTAssertEqual(snapshotRaceCount, 2)
            XCTAssertEqual(completions, [.failed(.routeChangedAfterRetry)])
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(window.promptManager.promptText, "before")
            XCTAssertFalse(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertFalse(window.promptManager.storedPrompts.contains {
                $0.title == storedPromptTitle
            })
        }

        func testFinalPayloadAdmissionRetriesThenFailsWhenTargetBecomesHiddenAfterAuthoritySnapshot() async throws {
            let runtime = try await makeDomainRuntime()
            let authorityWindow = await makeWindow(domainRuntime: runtime)
            let window = await makeWindow(domainRuntime: runtime)
            let targetFolder = try makeFolder(named: "FinalAdmissionHiddenTarget")
            let payloadFile = targetFolder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let target = WorkspaceModel(
                name: "Final Admission Hidden Target",
                repoPaths: [targetFolder.path]
            )
            try await saveAuthoritativeWorkspace(target, in: authorityWindow, runtime: runtime)
            try await waitUntil {
                window.workspaceManager.workspace(withID: target.id) != nil
            }
            let projectedTarget = try XCTUnwrap(window.workspaceManager.workspace(withID: target.id))
            let initialSwitch = await window.workspaceManager.switchWorkspace(
                to: projectedTarget,
                saveState: false,
                reason: "finalPayloadAdmissionHiddenTargetFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            window.promptManager.promptText = "before"
            window.setAutomaticCommandProcessingForTesting(false)
            window.stopDomainWorkspaceProjectionForTesting()
            let storedPromptTitle = "Final Admission Hidden Stored Prompt \(UUID().uuidString)"
            var completions: [AppCommandExecutionResult] = []
            window.enqueueCommand(
                folderCommand(
                    folderPath: targetFolder.path,
                    fileList: [payloadFile.path],
                    promptText: "after",
                    newPrompt: (storedPromptTitle, "must not be stored")
                )
            ) { completions.append($0) }

            var snapshotRaceCount = 0
            window.workspaceManager.setWorkspaceRoutingAuthorityDidSnapshotHandlerForTesting {
                guard window.workspaceManager.activeWorkspaceID == target.id,
                      let activeIndex = window.workspaceManager.workspaces.firstIndex(where: {
                          $0.id == target.id
                      })
                else {
                    return
                }
                snapshotRaceCount += 1
                window.workspaceManager.workspaces[activeIndex].isHiddenInMenus = true
            }

            await window.processCommands()

            XCTAssertEqual(snapshotRaceCount, 2)
            XCTAssertEqual(completions, [.failed(.routeChangedAfterRetry)])
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, target.id)
            XCTAssertTrue(try XCTUnwrap(window.workspaceManager.activeWorkspace).isHiddenInMenus)
            XCTAssertEqual(window.promptManager.promptText, "before")
            XCTAssertFalse(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertFalse(window.promptManager.storedPrompts.contains {
                $0.title == storedPromptTitle
            })

            await window.processCommands()
            XCTAssertEqual(snapshotRaceCount, 2)
            XCTAssertEqual(completions, [.failed(.routeChangedAfterRetry)])
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(window.promptManager.promptText, "before")
            XCTAssertFalse(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertFalse(window.promptManager.storedPrompts.contains {
                $0.title == storedPromptTitle
            })
        }

        func testAuthorityBackedActivationRejectsWorkspaceAbsentFromCanonicalCatalog() async throws {
            let runtime = try await makeDomainRuntime()
            let window = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "UnownedLiveSupplementActivation")
            let workspace = WorkspaceModel(
                name: "Unowned Live Supplement",
                repoPaths: [folder.path]
            )
            let fileURL = window.workspaceManager.workspaceFileURL(for: workspace)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(workspace).write(to: fileURL, options: .atomic)
            window.workspaceManager.workspaces.append(workspace)

            let routingSnapshot = await window.workspaceManager.workspaceRoutingCatalogSnapshot()
            let routingCatalog = try XCTUnwrap(routingSnapshot)
            XCTAssertFalse(routingCatalog.contains { $0.id == workspace.id })

            let switchResult = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "unownedLiveSupplementActivationRegression"
            )

            guard case let .blocked(reason) = switchResult else {
                return XCTFail("Expected an authority-absent persistent workspace to be rejected")
            }
            XCTAssertTrue(reason.contains("could not be verified for activation"))
            XCTAssertNotEqual(window.workspaceManager.activeWorkspaceID, workspace.id)
        }

        func testQueuedHiddenEphemeralLiveSupplementRevalidatesBeforePayloadAdmission() async throws {
            try await assertQueuedEphemeralLiveSupplementRevalidatesCandidate(
                named: "HiddenLiveSupplement"
            ) { workspace in
                workspace.isHiddenInMenus = true
            }
        }

        func testQueuedEphemeralLiveSupplementBecomingPersistentIsNotAdmitted() async throws {
            try await assertQueuedEphemeralLiveSupplementRevalidatesCandidate(
                named: "EphemeralLiveSupplement"
            ) { workspace in
                workspace.ephemeralFlag = false
            }
        }

        func testQueuedLiveSupplementEligibilityChangeAfterActivationRetriesOnceWithoutPayload() async throws {
            let runtime = try await makeDomainRuntime()
            let window = await makeWindow(domainRuntime: runtime)
            let requestedFolder = try makeFolder(named: "PostActivationEligibility")
            let otherFolder = try makeFolder(named: "PostActivationOther")
            let payloadFile = requestedFolder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let candidate = try WorkspaceModel(
                name: "Post-Activation Candidate",
                repoPaths: [requestedFolder.path],
                ephemeralFlag: true
            )
            let otherWorkspace = try WorkspaceModel(
                name: "Post-Activation Other",
                repoPaths: [otherFolder.path],
                ephemeralFlag: true
            )
            let candidateFileURL = window.workspaceManager.workspaceFileURL(for: candidate)
            try FileManager.default.createDirectory(
                at: candidateFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(candidate).write(to: candidateFileURL, options: .atomic)
            window.workspaceManager.workspaces.append(contentsOf: [candidate, otherWorkspace])
            let candidateSwitch = await window.workspaceManager.switchWorkspace(
                to: candidate,
                saveState: false,
                reason: "postActivationCandidateFixture"
            )
            XCTAssertEqual(candidateSwitch, .switched)
            window.setAutomaticCommandProcessingForTesting(false)
            let storedPromptTitle = "Post-Activation Stored Prompt \(UUID().uuidString)"
            let command = folderCommand(
                folderPath: requestedFolder.path,
                fileList: [payloadFile.path],
                promptText: "after",
                newPrompt: (storedPromptTitle, "must not be stored"),
                ephemeral: true
            )
            var completions: [AppCommandExecutionResult] = []
            window.enqueueCommand(
                command,
                folderRoute: .ephemeralLiveWindowSupplement(
                    workspaceID: candidate.id,
                    expectedRoot: WorkspaceRootSetKey(paths: [requestedFolder.path])
                )
            ) { completions.append($0) }

            let otherSwitch = await window.workspaceManager.switchWorkspace(
                to: otherWorkspace,
                saveState: false,
                reason: "postActivationOtherFixture"
            )
            XCTAssertEqual(otherSwitch, .switched)
            window.promptManager.promptText = "before"
            var eligibilityChangeCount = 0
            window.workspaceManager.setWorkspaceSwitchPhaseDidChangeHandlerForTesting { phase in
                guard phase == .finalizing,
                      let activeWorkspaceID = window.workspaceManager.activeWorkspaceID,
                      let activeIndex = window.workspaceManager.workspaces.firstIndex(where: {
                          $0.id == activeWorkspaceID
                      })
                else {
                    return
                }
                window.workspaceManager.workspaces[activeIndex].isHiddenInMenus = true
                eligibilityChangeCount += 1
            }

            await window.processCommands()

            XCTAssertEqual(eligibilityChangeCount, 2)
            XCTAssertEqual(completions, [.failed(.routeChangedAfterRetry)])
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertNotEqual(window.promptManager.promptText, "after")
            XCTAssertFalse(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertFalse(window.promptManager.storedPrompts.contains {
                $0.title == storedPromptTitle
            })

            await window.processCommands()
            XCTAssertEqual(completions, [.failed(.routeChangedAfterRetry)])
        }

        func testQueuedEphemeralSupplementRouteDoesNotOverrideAuthorityOwnedID() async throws {
            let runtime = try await makeDomainRuntime()
            let authorityWindow = await makeWindow(domainRuntime: runtime)
            let targetWindow = await makeWindow(domainRuntime: runtime)
            let requestedFolder = try makeFolder(named: "AuthorityExpectedRoot")
            let replacementFolder = try makeFolder(named: "AuthorityReplacementRoot")
            let selectedFile = requestedFolder.appendingPathComponent("Selected.swift")
            let payloadFile = requestedFolder.appendingPathComponent("Payload.swift")
            try Data("let selected = true\n".utf8).write(to: selectedFile)
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000027"))
            let expectedWorkspace = WorkspaceModel(
                id: workspaceID,
                name: "Authority Workspace",
                repoPaths: [requestedFolder.path]
            )
            try await saveAuthoritativeWorkspace(expectedWorkspace, in: authorityWindow, runtime: runtime)
            try await waitUntil {
                targetWindow.workspaceManager.workspace(withID: workspaceID)?.repoPaths == [requestedFolder.path]
            }
            let projectedWorkspace = try XCTUnwrap(
                targetWindow.workspaceManager.workspace(withID: workspaceID)
            )
            let initialSwitch = await targetWindow.workspaceManager.switchWorkspace(
                to: projectedWorkspace,
                saveState: false,
                reason: "folderCommandAuthorityRootFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            await targetWindow.workspaceFilesViewModel.selectFiles(withPaths: [selectedFile.path])
            targetWindow.promptManager.promptText = "before"
            let countBeforeRoute = targetWindow.workspaceManager.workspaces.count
            targetWindow.setAutomaticCommandProcessingForTesting(false)
            let command = folderCommand(
                folderPath: requestedFolder.path,
                fileList: [payloadFile.path],
                promptText: "after"
            )
            targetWindow.enqueueCommand(
                command,
                folderRoute: .ephemeralLiveWindowSupplement(
                    workspaceID: workspaceID,
                    expectedRoot: WorkspaceRootSetKey(paths: [requestedFolder.path])
                )
            )
            targetWindow.stopDomainWorkspaceProjectionForTesting()
            var replacementWorkspace = expectedWorkspace
            replacementWorkspace.repoPaths = [replacementFolder.path]
            replacementWorkspace.dateModified = Date()
            try await saveAuthoritativeWorkspace(replacementWorkspace, in: authorityWindow, runtime: runtime)
            let routingCatalog = await targetWindow.workspaceManager.workspaceRoutingCatalogSnapshot()
            let authoritativeCatalog = try XCTUnwrap(routingCatalog)
            XCTAssertEqual(
                authoritativeCatalog.first(where: { $0.id == workspaceID })?.repoPaths,
                [replacementFolder.path]
            )

            await targetWindow.processCommands()

            XCTAssertNotEqual(targetWindow.workspaceManager.activeWorkspaceID, workspaceID)
            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspace?.repoPaths, [requestedFolder.path])
            XCTAssertEqual(targetWindow.workspaceManager.workspaces.count, countBeforeRoute + 1)
            XCTAssertEqual(targetWindow.promptManager.promptText, "after")
            XCTAssertFalse(targetWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == selectedFile.path
            })
            XCTAssertTrue(targetWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertEqual(targetWindow.workspaceManager.workspaces.count { $0.id == workspaceID }, 1)
            let updatedCatalog = await targetWindow.workspaceManager.workspaceRoutingCatalogSnapshot()
            XCTAssertEqual(
                updatedCatalog?.count {
                    WorkspaceFolderOpenResolver.containsExactRoot(requestedFolder.path, in: $0)
                },
                1
            )
        }

        func testResolvedFolderRouteLoadsAuthorityWorkspaceMissingFromTargetProjection() async throws {
            let runtime = try await makeDomainRuntime()
            let authorityWindow = await makeWindow(domainRuntime: runtime)
            let targetWindow = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "AuthorityProjectionLag")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000028"))
            let workspace = WorkspaceModel(
                id: workspaceID,
                name: "Authority Projection Lag",
                repoPaths: [folder.path]
            )
            targetWindow.stopDomainWorkspaceProjectionForTesting()
            try await saveAuthoritativeWorkspace(workspace, in: authorityWindow, runtime: runtime)
            XCTAssertNil(targetWindow.workspaceManager.workspace(withID: workspaceID))
            let countBeforeRoute = targetWindow.workspaceManager.workspaces.count
            targetWindow.setAutomaticCommandProcessingForTesting(false)
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?files=\(payloadFile.path)&prompt=after"
            ))

            await AppDeepLinkRouter(windowStatesManager: .shared).route(
                url: url,
                preferredLegacyWindow: targetWindow
            )
            await targetWindow.processCommands()

            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspaceID, workspaceID)
            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspace?.repoPaths, [folder.path])
            XCTAssertEqual(targetWindow.workspaceManager.workspaces.count, countBeforeRoute + 1)
            XCTAssertEqual(targetWindow.promptManager.promptText, "after")
            XCTAssertTrue(targetWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertEqual(
                targetWindow.workspaceManager.workspaces.count {
                    $0.id == workspaceID
                },
                1
            )
        }

        func testResolvedFolderRouteReloadsActiveWorkspaceWhenAuthorityProjectionIsNewer() async throws {
            try await assertCommandStaleActivation(metadataPublished: false, refreshBlocked: false)
        }

        func testFolderCommandReloadsStaleLoadedRootsWithCurrentMetadata() async throws {
            try await assertCommandStaleActivation(metadataPublished: true, refreshBlocked: false)
        }

        func testFolderCommandStaleSameIDRefreshBlockAppliesNoPayloadOrDuplicate() async throws {
            try await assertCommandStaleActivation(metadataPublished: false, refreshBlocked: true)
        }

        private func assertCommandStaleActivation(metadataPublished: Bool, refreshBlocked: Bool) async throws {
            let runtime = try await makeDomainRuntime()
            let authorityWindow = await makeWindow(domainRuntime: runtime)
            let targetWindow = await makeWindow(domainRuntime: runtime)
            let oldFolder = try makeFolder(named: "AuthorityOldActiveRoot")
            let requestedFolder = try makeFolder(named: "AuthorityNewActiveRoot")
            let oldFile = oldFolder.appendingPathComponent("Original.swift")
            try Data("let original = true\n".utf8).write(to: oldFile)
            let payloadFile = requestedFolder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000029"))
            let oldWorkspace = WorkspaceModel(
                id: workspaceID,
                name: "Authority Active Projection",
                repoPaths: [oldFolder.path]
            )
            try await saveAuthoritativeWorkspace(oldWorkspace, in: authorityWindow, runtime: runtime)
            try await waitUntil {
                targetWindow.workspaceManager.workspace(withID: workspaceID)?.repoPaths == [oldFolder.path]
            }
            let projectedWorkspace = try XCTUnwrap(targetWindow.workspaceManager.workspace(withID: workspaceID))
            let initialSwitch = await targetWindow.workspaceManager.switchWorkspace(
                to: projectedWorkspace,
                saveState: false,
                reason: "folderCommandAuthorityProjectionLagFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            let loadedOriginal = await targetWindow.workspaceFilesViewModel.findFile(atPath: oldFile.path)
            XCTAssertNotNil(loadedOriginal)
            await targetWindow.workspaceFilesViewModel.selectFiles(withPaths: [oldFile.path])
            XCTAssertEqual(targetWindow.workspaceFilesViewModel.selectedFiles.map(\.fullPath), [oldFile.path])
            targetWindow.promptManager.promptText = "before"
            let countBeforeRoute = targetWindow.workspaceManager.workspaces.count
            let catalogBeforeRoute = await runtime.workspaceStore.snapshot()
            targetWindow.stopDomainWorkspaceProjectionForTesting()
            var replacementWorkspace = oldWorkspace
            replacementWorkspace.repoPaths = [requestedFolder.path]
            replacementWorkspace.dateModified = Date()
            try await saveAuthoritativeWorkspace(replacementWorkspace, in: authorityWindow, runtime: runtime)
            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspace?.repoPaths, [oldFolder.path])
            if metadataPublished {
                let index = try XCTUnwrap(targetWindow.workspaceManager.workspaces.firstIndex { $0.id == workspaceID })
                targetWindow.workspaceManager.workspaces[index] = replacementWorkspace
            }
            XCTAssertTrue(targetWindow.workspaceFilesViewModel.rootFolders.contains { $0.fullPath == oldFolder.path })
            targetWindow.workspaceManager.isRefreshing = refreshBlocked
            defer { targetWindow.workspaceManager.isRefreshing = false }
            targetWindow.setAutomaticCommandProcessingForTesting(false)
            let storedPromptTitle = "Same-ID Folder Payload \(UUID().uuidString)"
            var completions: [AppCommandExecutionResult] = []
            targetWindow.enqueueCommand(
                folderCommand(
                    folderPath: requestedFolder.path,
                    fileList: [payloadFile.path],
                    promptText: "after",
                    newPrompt: (storedPromptTitle, "same-ID stored prompt")
                ),
                folderRoute: .authorityExactRoot(expectedRoot: WorkspaceRootSetKey(paths: [requestedFolder.path]))
            ) { completions.append($0) }
            await targetWindow.processCommands()
            await targetWindow.processCommands()

            XCTAssertEqual(completions, refreshBlocked ? [.failed(.workspaceSwitchBlocked)] : [.completed(workspaceID: workspaceID)])
            XCTAssertEqual(targetWindow.queuedCommandCountForTesting, 0)
            let catalogAfterRoute = await runtime.workspaceStore.snapshot()
            XCTAssertEqual(catalogAfterRoute.workspaces.count, catalogBeforeRoute.workspaces.count)
            XCTAssertEqual(catalogAfterRoute.workspaces.count(where: { $0.document.workspaceID == workspaceID }), 1)
            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspaceID, workspaceID)
            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspace?.repoPaths, [requestedFolder.path])
            XCTAssertEqual(targetWindow.workspaceManager.workspaces.count, countBeforeRoute)
            XCTAssertEqual(targetWindow.workspaceManager.workspaces.count { $0.id == workspaceID }, 1)
            if refreshBlocked {
                XCTAssertEqual(targetWindow.promptManager.promptText, "before")
                XCTAssertEqual(targetWindow.workspaceFilesViewModel.selectedFiles.map(\.fullPath), [oldFile.path])
                XCTAssertFalse(targetWindow.promptManager.storedPrompts.contains { $0.title == storedPromptTitle })
                XCTAssertTrue(targetWindow.workspaceFilesViewModel.rootFolders.contains { $0.fullPath == oldFolder.path })
                XCTAssertFalse(targetWindow.workspaceFilesViewModel.rootFolders.contains { $0.fullPath == requestedFolder.path })
                XCTAssertNotNil(targetWindow.workspaceFilesViewModel.findFileByFullPath(oldFile.path))
                XCTAssertNil(targetWindow.workspaceFilesViewModel.findFileByFullPath(payloadFile.path))
                return
            }
            XCTAssertTrue(targetWindow.workspaceFilesViewModel.rootFolders.contains { $0.fullPath == requestedFolder.path })
            XCTAssertFalse(targetWindow.workspaceFilesViewModel.rootFolders.contains { $0.fullPath == oldFolder.path })
            XCTAssertNotNil(targetWindow.workspaceFilesViewModel.findFileByFullPath(payloadFile.path))
            XCTAssertNil(targetWindow.workspaceFilesViewModel.findFileByFullPath(oldFile.path))
            XCTAssertEqual(targetWindow.promptManager.storedPrompts.count(where: { $0.title == storedPromptTitle }), 1)
            XCTAssertEqual(targetWindow.workspaceFilesViewModel.selectedFiles.map(\.fullPath), [payloadFile.path])
            XCTAssertEqual(targetWindow.promptManager.promptText, "after")
            XCTAssertTrue(targetWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertEqual(targetWindow.workspaceManager.workspaces.count { $0.id == workspaceID }, 1)
        }

        func testInactiveLocalEphemeralWorkspaceIsReused() async throws {
            let window = await makeWindow()
            let folder = try makeFolder(named: "InactiveLocalEphemeral")
            let workspace = window.workspaceManager.createWorkspace(
                name: "Inactive Local Ephemeral",
                repoPaths: [folder.path],
                ephemeral: true
            )
            let countBeforeCommand = window.workspaceManager.workspaces.count
            window.setAutomaticCommandProcessingForTesting(false)

            window.enqueueCommand(folderCommand(folderPath: folder.path, ephemeral: true))
            await window.processCommands()

            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, workspace.id)
            XCTAssertEqual(window.workspaceManager.workspaces.count, countBeforeCommand)
        }

        func testNonFocusedEphemeralRouteForwardsToOwningWindow() async throws {
            let ownerWindow = await makeWindow()
            let receivingWindow = await makeWindow()
            let folder = try makeFolder(named: "NonFocusedEphemeralOwner")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let workspace = ownerWindow.workspaceManager.createWorkspace(
                name: "Non-Focused Ephemeral Owner",
                repoPaths: [folder.path],
                ephemeral: true
            )
            let initialSwitch = await ownerWindow.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "nonFocusedEphemeralOwnerFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            ownerWindow.promptManager.promptText = "owner-before"
            receivingWindow.promptManager.promptText = "receiving-before"
            let storedPromptTitle = "Forwarded Stored Prompt \(UUID().uuidString)"
            ownerWindow.setAutomaticCommandProcessingForTesting(false)
            receivingWindow.setAutomaticCommandProcessingForTesting(false)
            var completions: [AppCommandExecutionResult] = []
            receivingWindow.enqueueCommand(
                folderCommand(
                    folderPath: folder.path,
                    fileList: [payloadFile.path],
                    promptText: "after",
                    newPrompt: (storedPromptTitle, "forwarded stored prompt"),
                    ephemeral: true
                )
            ) { completions.append($0) }

            await receivingWindow.processCommands()
            XCTAssertEqual(receivingWindow.queuedCommandCountForTesting, 0)
            XCTAssertEqual(ownerWindow.queuedCommandCountForTesting, 1)
            XCTAssertEqual(completions, [])
            XCTAssertFalse(ownerWindow.promptManager.storedPrompts.contains {
                $0.title == storedPromptTitle
            })
            await ownerWindow.processCommands()

            XCTAssertEqual(ownerWindow.workspaceManager.activeWorkspaceID, workspace.id)
            XCTAssertEqual(ownerWindow.promptManager.promptText, "after")
            XCTAssertTrue(ownerWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertEqual(receivingWindow.promptManager.promptText, "receiving-before")
            XCTAssertFalse(receivingWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            let storedPrompts = ownerWindow.promptManager.storedPrompts.filter {
                $0.title == storedPromptTitle
            }
            XCTAssertEqual(storedPrompts.count, 1)
            XCTAssertEqual(storedPrompts.first?.content, "forwarded stored prompt")
            let forwardedStoredPrompt = try XCTUnwrap(storedPrompts.first)
            XCTAssertTrue(ownerWindow.promptManager.selectedPromptIDs.contains(forwardedStoredPrompt.id))
            XCTAssertEqual(completions, [.completed(workspaceID: workspace.id)])

            await receivingWindow.processCommands()
            await ownerWindow.processCommands()
            XCTAssertEqual(completions, [.completed(workspaceID: workspace.id)])
        }

        func testSharedRuntimeFocusedEphemeralRouteReusesLiveWorkspace() async throws {
            let runtime = try await makeDomainRuntime()
            let activeWindow = await makeWindow(domainRuntime: runtime)
            let receivingWindow = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "RuntimeEphemeralReuse")
            let payloadFile = folder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let workspace = activeWindow.workspaceManager.createWorkspace(
                name: "Runtime Ephemeral",
                repoPaths: [folder.path],
                ephemeral: true
            )
            let initialSwitch = await activeWindow.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "folderCommandRuntimeEphemeralFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            let activeCountBeforeRoute = activeWindow.workspaceManager.workspaces.count
            let receivingCountBeforeRoute = receivingWindow.workspaceManager.workspaces.count
            activeWindow.setAutomaticCommandProcessingForTesting(false)
            receivingWindow.setAutomaticCommandProcessingForTesting(false)
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?focus=true&ephemeral=true&files=\(payloadFile.path)&prompt=after"
            ))

            await AppDeepLinkRouter(windowStatesManager: .shared).route(
                url: url,
                preferredLegacyWindow: receivingWindow
            )
            await activeWindow.processCommands()
            await receivingWindow.processCommands()

            XCTAssertEqual(activeWindow.workspaceManager.activeWorkspaceID, workspace.id)
            XCTAssertEqual(activeWindow.workspaceManager.workspaces.count, activeCountBeforeRoute)
            XCTAssertEqual(receivingWindow.workspaceManager.workspaces.count, receivingCountBeforeRoute)
            XCTAssertEqual(activeWindow.promptManager.promptText, "after")
            XCTAssertTrue(activeWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
        }

        func testConcurrentUnmatchedRoutesCreateOneAuthoritativeWorkspaceAndForwardLatePayload() async throws {
            let runtime = try await makeDomainRuntime()
            let firstWindow = await makeWindow(domainRuntime: runtime)
            let secondWindow = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "ConcurrentRoutedFolder")
            let firstFile = folder.appendingPathComponent("First.swift")
            let secondFile = folder.appendingPathComponent("Second.swift")
            try Data("let first = true\n".utf8).write(to: firstFile)
            try Data("let second = true\n".utf8).write(to: secondFile)
            firstWindow.setAutomaticCommandProcessingForTesting(false)
            secondWindow.setAutomaticCommandProcessingForTesting(false)
            let firstURL = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?focus=true&files=\(firstFile.path)&prompt=first"
            ))
            let secondURL = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?focus=true&files=\(secondFile.path)&prompt=second"
            ))
            let router = AppDeepLinkRouter(windowStatesManager: .shared)

            await router.route(url: firstURL, preferredLegacyWindow: firstWindow)
            await router.route(url: secondURL, preferredLegacyWindow: secondWindow)
            XCTAssertEqual(firstWindow.queuedCommandCountForTesting, 1)
            XCTAssertEqual(secondWindow.queuedCommandCountForTesting, 1)

            await firstWindow.processCommands()
            await secondWindow.processCommands()
            XCTAssertEqual(firstWindow.queuedCommandCountForTesting, 1)
            await firstWindow.processCommands()

            let snapshot = await firstWindow.workspaceManager.workspaceRoutingCatalogSnapshot()
            let routingSnapshot = try XCTUnwrap(snapshot)
            let matches = routingSnapshot.filter {
                WorkspaceFolderOpenResolver.containsExactRoot(folder.path, in: $0)
            }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(firstWindow.workspaceManager.activeWorkspaceID, matches.first?.id)
            XCTAssertEqual(firstWindow.promptManager.promptText, "second")
            XCTAssertTrue(firstWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == secondFile.path
            })
            XCTAssertFalse(firstWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == firstFile.path
            })
            XCTAssertNotEqual(secondWindow.promptManager.promptText, "second")
            XCTAssertEqual(firstWindow.queuedCommandCountForTesting, 0)
            XCTAssertEqual(secondWindow.queuedCommandCountForTesting, 0)
        }

        func testRouteRetriesAnotherWindowWhenReceiverClosesDuringAuthorityAwait() async throws {
            let runtime = try await makeDomainRuntime()
            let retryWindow = await makeWindow(domainRuntime: runtime)
            let targetWindow = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "ClosingDuringAuthorityAwait")
            retryWindow.setAutomaticCommandProcessingForTesting(false)
            targetWindow.setAutomaticCommandProcessingForTesting(false)
            targetWindow.workspaceManager.setWorkspaceRoutingAuthorityDidSnapshotHandlerForTesting {
                targetWindow.beginClose()
            }
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?prompt=after"
            ))
            let pendingCountBeforeRoute = WindowStatesManager.shared.pendingURLs.count

            await AppDeepLinkRouter(windowStatesManager: .shared).route(
                url: url,
                preferredLegacyWindow: targetWindow
            )

            XCTAssertTrue(targetWindow.isClosing)
            XCTAssertEqual(targetWindow.queuedCommandCountForTesting, 0)
            XCTAssertEqual(retryWindow.queuedCommandCountForTesting, 1)
            XCTAssertEqual(WindowStatesManager.shared.pendingURLs.count, pendingCountBeforeRoute)

            await retryWindow.processCommands()

            XCTAssertEqual(retryWindow.promptManager.promptText, "after")
            XCTAssertEqual(retryWindow.workspaceManager.activeWorkspace?.repoPaths, [folder.path])
        }

        func testRouteRetainsURLWhenLastWindowClosesDuringAuthorityAwait() async throws {
            let runtime = try await makeDomainRuntime()
            let targetWindow = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "LastWindowClosingDuringAuthorityAwait")
            targetWindow.setAutomaticCommandProcessingForTesting(false)
            targetWindow.workspaceManager.setWorkspaceRoutingAuthorityDidSnapshotHandlerForTesting {
                targetWindow.beginClose()
            }
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?prompt=after"
            ))
            let originalPendingURLs = WindowStatesManager.shared.pendingURLs
            WindowStatesManager.shared.pendingURLs = []
            defer { WindowStatesManager.shared.pendingURLs = originalPendingURLs }

            await AppDeepLinkRouter(windowStatesManager: .shared).route(
                url: url,
                preferredLegacyWindow: targetWindow
            )

            XCTAssertTrue(targetWindow.isClosing)
            XCTAssertEqual(targetWindow.queuedCommandCountForTesting, 0)
            XCTAssertEqual(WindowStatesManager.shared.pendingURLs, [url])
        }

        func testRouteExhaustsLiveWindowsWhenNewerReceiversCloseDuringAuthorityAwait() async throws {
            let runtime = try await makeDomainRuntime()
            let oldestWindow = await makeWindow(domainRuntime: runtime)
            let retryWindow = await makeWindow(domainRuntime: runtime)
            let targetWindow = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "NewerWindowsClosingDuringAuthorityAwait")
            oldestWindow.setAutomaticCommandProcessingForTesting(false)
            retryWindow.setAutomaticCommandProcessingForTesting(false)
            targetWindow.setAutomaticCommandProcessingForTesting(false)
            retryWindow.workspaceManager.setWorkspaceRoutingAuthorityDidSnapshotHandlerForTesting {
                retryWindow.beginClose()
            }
            targetWindow.workspaceManager.setWorkspaceRoutingAuthorityDidSnapshotHandlerForTesting {
                targetWindow.beginClose()
            }
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?prompt=after"
            ))
            let originalPendingURLs = WindowStatesManager.shared.pendingURLs
            WindowStatesManager.shared.pendingURLs = []
            defer { WindowStatesManager.shared.pendingURLs = originalPendingURLs }

            await AppDeepLinkRouter(windowStatesManager: .shared).route(
                url: url,
                preferredLegacyWindow: targetWindow
            )

            XCTAssertTrue(targetWindow.isClosing)
            XCTAssertTrue(retryWindow.isClosing)
            XCTAssertEqual(targetWindow.queuedCommandCountForTesting, 0)
            XCTAssertEqual(retryWindow.queuedCommandCountForTesting, 0)
            XCTAssertEqual(oldestWindow.queuedCommandCountForTesting, 1)
            XCTAssertEqual(WindowStatesManager.shared.pendingURLs, [])

            await oldestWindow.processCommands()

            XCTAssertEqual(oldestWindow.promptManager.promptText, "after")
            XCTAssertEqual(oldestWindow.workspaceManager.activeWorkspace?.repoPaths, [folder.path])
        }

        func testFocusedPersistentRouteUsesAlreadyActiveMatchingWindow() async throws {
            let activeWindow = await makeWindow()
            let receivingWindow = await makeWindow()
            let folder = try makeFolder(named: "FocusedPersistent")
            let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000024"))
            let workspace = WorkspaceModel(id: workspaceID, name: "Focused Persistent", repoPaths: [folder.path])
            activeWindow.workspaceManager.workspaces.append(workspace)
            receivingWindow.workspaceManager.workspaces.append(workspace)
            let initialSwitch = await activeWindow.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "folderCommandFocusedPersistentFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            let attachedWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            activeWindow.attachWindow(attachedWindow)
            attachedWindow.orderOut(nil)
            defer {
                attachedWindow.orderOut(nil)
                activeWindow.attachWindow(nil)
            }
            XCTAssertFalse(attachedWindow.isVisible)
            activeWindow.promptManager.promptText = "active-before"
            receivingWindow.promptManager.promptText = "receiving-before"
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?focus=true&prompt=after"
            ))

            await AppDeepLinkRouter(windowStatesManager: .shared).route(url: url)
            await activeWindow.processCommands()
            await receivingWindow.processCommands()

            XCTAssertEqual(activeWindow.workspaceManager.activeWorkspaceID, workspaceID)
            XCTAssertEqual(activeWindow.promptManager.promptText, "after")
            XCTAssertEqual(receivingWindow.promptManager.promptText, "receiving-before")
            XCTAssertTrue(attachedWindow.isVisible)
        }

        func testNonFocusedPersistentRouteUsesReceivingWindow() async throws {
            let activeWindow = await makeWindow()
            let receivingWindow = await makeWindow()
            let folder = try makeFolder(named: "NonFocusedPersistent")
            let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000025"))
            let workspace = WorkspaceModel(id: workspaceID, name: "Non-Focused Persistent", repoPaths: [folder.path])
            activeWindow.workspaceManager.workspaces.append(workspace)
            receivingWindow.workspaceManager.workspaces.append(workspace)
            let initialSwitch = await activeWindow.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "folderCommandNonFocusedPersistentFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            activeWindow.promptManager.promptText = "active-before"
            receivingWindow.promptManager.promptText = "receiving-before"
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?prompt=after"
            ))

            await AppDeepLinkRouter(windowStatesManager: .shared).route(url: url)
            await activeWindow.processCommands()
            await receivingWindow.processCommands()

            XCTAssertEqual(activeWindow.promptManager.promptText, "active-before")
            XCTAssertEqual(receivingWindow.workspaceManager.activeWorkspaceID, workspaceID)
            XCTAssertEqual(receivingWindow.promptManager.promptText, "after")
        }

        func testFocusedPersistentRouteAvoidsBlockedReceivingWindowSwitch() async throws {
            let activeWindow = await makeWindow()
            let receivingWindow = await makeWindow()
            let folder = try makeFolder(named: "FocusedBlockedReceiving")
            let otherFolder = try makeFolder(named: "FocusedBlockedOther")
            let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000026"))
            let workspace = WorkspaceModel(id: workspaceID, name: "Focused Blocked", repoPaths: [folder.path])
            let otherWorkspace = WorkspaceModel(name: "Other", repoPaths: [otherFolder.path])
            activeWindow.workspaceManager.workspaces.append(workspace)
            receivingWindow.workspaceManager.workspaces.append(contentsOf: [workspace, otherWorkspace])
            let activeSwitch = await activeWindow.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "folderCommandFocusedBlockedActiveFixture"
            )
            XCTAssertEqual(activeSwitch, .switched)
            let receivingSwitch = await receivingWindow.workspaceManager.switchWorkspace(
                to: otherWorkspace,
                saveState: false,
                reason: "folderCommandFocusedBlockedReceivingFixture"
            )
            XCTAssertEqual(receivingSwitch, .switched)
            let sessionProvider = FolderCommandWorkspaceSwitchSessionProvider()
            receivingWindow.workspaceManager.registerSwitchSessionProvider(sessionProvider)
            activeWindow.promptManager.promptText = "active-before"
            receivingWindow.promptManager.promptText = "receiving-before"
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)?focus=true&prompt=after"
            ))

            await AppDeepLinkRouter(windowStatesManager: .shared).route(url: url)
            await activeWindow.processCommands()
            await receivingWindow.processCommands()

            XCTAssertEqual(activeWindow.workspaceManager.activeWorkspaceID, workspaceID)
            XCTAssertEqual(activeWindow.promptManager.promptText, "after")
            XCTAssertEqual(receivingWindow.workspaceManager.activeWorkspaceID, otherWorkspace.id)
            XCTAssertEqual(receivingWindow.promptManager.promptText, "receiving-before")
            XCTAssertNil(receivingWindow.workspaceManager.pendingSwitchConfirmation)
        }

        func testWindowClosingDuringWorkspaceSwitchAppliesNoPayload() async throws {
            let window = await makeWindow()
            let activeFolder = try makeFolder(named: "ClosingSwitchActive")
            let targetFolder = try makeFolder(named: "ClosingSwitchTarget")
            let active = window.workspaceManager.createWorkspace(
                name: "Closing Switch Active",
                repoPaths: [activeFolder.path]
            )
            let target = window.workspaceManager.createWorkspace(
                name: "Closing Switch Target",
                repoPaths: [targetFolder.path]
            )
            let initialSwitch = await window.workspaceManager.switchWorkspace(
                to: active,
                saveState: false,
                reason: "closingSwitchFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            window.promptManager.promptText = "before"
            window.workspaceManager.setWorkspaceActivationLeaseDidAcquireHandlerForTesting { workspaceID in
                if workspaceID == target.id {
                    window.beginClose()
                }
            }
            window.setAutomaticCommandProcessingForTesting(false)
            var completions: [AppCommandExecutionResult] = []

            window.enqueueCommand(
                folderCommand(
                    folderPath: targetFolder.path,
                    promptText: "after"
                )
            ) { completions.append($0) }
            await window.processCommands()

            XCTAssertTrue(window.isClosing)
            XCTAssertNotEqual(window.promptManager.promptText, "after")
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(completions, [.failed(.windowClosed)])

            await window.processCommands()
            XCTAssertEqual(completions, [.failed(.windowClosed)])
        }

        func testWindowCloseCompletesPendingCommandsExactlyOnce() async throws {
            let window = await makeWindow()
            let firstFolder = try makeFolder(named: "ClosingPendingFirst")
            let secondFolder = try makeFolder(named: "ClosingPendingSecond")
            window.setAutomaticCommandProcessingForTesting(false)
            var firstCompletions: [AppCommandExecutionResult] = []
            var secondCompletions: [AppCommandExecutionResult] = []
            window.enqueueCommand(folderCommand(folderPath: firstFolder.path)) {
                firstCompletions.append($0)
            }
            window.enqueueCommand(folderCommand(folderPath: secondFolder.path)) {
                secondCompletions.append($0)
            }

            window.beginClose()

            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(firstCompletions, [.failed(.windowClosed)])
            XCTAssertEqual(secondCompletions, [.failed(.windowClosed)])

            await window.processCommands()
            window.beginClose()
            XCTAssertEqual(firstCompletions, [.failed(.windowClosed)])
            XCTAssertEqual(secondCompletions, [.failed(.windowClosed)])
        }

        func testCancelledMatchedSwitchCreatesNoReplacementAndAppliesNoPayload() async throws {
            let window = await makeWindow()
            let activeFolder = try makeFolder(named: "CancelledActive")
            let targetFolder = try makeFolder(named: "CancelledTarget")
            let payloadFile = targetFolder.appendingPathComponent("CancelledPayload.swift")
            try Data("let cancelled = true\n".utf8).write(to: payloadFile)
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
            let storedPromptTitle = "Cancelled Stored Prompt \(UUID().uuidString)"
            let sessionProvider = FolderCommandWorkspaceSwitchSessionProvider()
            window.workspaceManager.registerSwitchSessionProvider(sessionProvider)
            var completions: [AppCommandExecutionResult] = []

            window.enqueueCommand(
                folderCommand(
                    folderPath: targetFolder.path,
                    fileList: [payloadFile.path],
                    promptText: "after",
                    newPrompt: (storedPromptTitle, "cancelled stored prompt")
                )
            ) { completions.append($0) }
            let confirmation = try await waitForPendingSwitchConfirmation(in: window.workspaceManager)
            window.workspaceManager.resolveSwitchConfirmation(id: confirmation.id, allow: false)
            try await waitUntil {
                window.workspaceManager.pendingSwitchConfirmation == nil
                    && completions == [.cancelled]
            }

            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, active.id)
            XCTAssertEqual(window.workspaceManager.workspaces.count, countBeforeCommand)
            XCTAssertEqual(window.promptManager.promptText, "before")
            XCTAssertFalse(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertFalse(window.promptManager.storedPrompts.contains {
                $0.title == storedPromptTitle
            })
            XCTAssertNil(window.workspaceManager.pendingWorkspaceSwitchBlockedNotice)
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(completions, [.cancelled])

            await window.processCommands()
            XCTAssertEqual(completions, [.cancelled])
        }

        private func assertQueuedEphemeralLiveSupplementRevalidatesCandidate(
            named name: String,
            mutation: (inout WorkspaceModel) -> Void
        ) async throws {
            let runtime = try await makeDomainRuntime()
            let window = await makeWindow(domainRuntime: runtime)
            let requestedFolder = try makeFolder(named: name)
            let payloadFile = requestedFolder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let candidate = try WorkspaceModel(
                name: name,
                repoPaths: [requestedFolder.path],
                ephemeralFlag: true
            )
            window.workspaceManager.workspaces.append(candidate)
            let initialSwitch = await window.workspaceManager.switchWorkspace(
                to: candidate,
                saveState: false,
                reason: "queuedIneligibleLiveSupplementFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            window.promptManager.promptText = "before"
            window.setAutomaticCommandProcessingForTesting(false)
            let storedPromptTitle = "\(name) Stored Prompt \(UUID().uuidString)"
            let command = folderCommand(
                folderPath: requestedFolder.path,
                fileList: [payloadFile.path],
                promptText: "after",
                newPrompt: (storedPromptTitle, "eligible target payload"),
                ephemeral: true
            )
            var completions: [AppCommandExecutionResult] = []
            window.enqueueCommand(
                command,
                folderRoute: .ephemeralLiveWindowSupplement(
                    workspaceID: candidate.id,
                    expectedRoot: WorkspaceRootSetKey(paths: [requestedFolder.path])
                )
            ) { completions.append($0) }

            let candidateIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == candidate.id })
            )
            var ineligibleCandidate = window.workspaceManager.workspaces[candidateIndex]
            mutation(&ineligibleCandidate)
            window.workspaceManager.workspaces[candidateIndex] = ineligibleCandidate
            await window.processCommands()

            let finalWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            XCTAssertNotEqual(finalWorkspace.id, candidate.id)
            XCTAssertEqual(
                WorkspaceFolderOpenResolver.bestEligibleMatch(
                    forFolderPath: requestedFolder.path,
                    in: [finalWorkspace],
                    admittingEphemeral: true
                )?.id,
                finalWorkspace.id
            )
            XCTAssertEqual(completions, [.completed(workspaceID: finalWorkspace.id)])
            XCTAssertTrue(finalWorkspace.isEphemeral)
            XCTAssertEqual(window.queuedCommandCountForTesting, 0)
            XCTAssertEqual(window.promptManager.promptText, "after")
            XCTAssertTrue(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            let storedPrompts = window.promptManager.storedPrompts.filter {
                $0.title == storedPromptTitle
            }
            XCTAssertEqual(storedPrompts.count, 1)
            XCTAssertEqual(storedPrompts.first?.content, "eligible target payload")

            await window.processCommands()
            XCTAssertEqual(completions, [.completed(workspaceID: finalWorkspace.id)])
            XCTAssertEqual(
                window.promptManager.storedPrompts.count { $0.title == storedPromptTitle },
                1
            )
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

        private func makeWindow(domainRuntime: MCPDomainRuntime? = nil) async -> WindowState {
            let promptStorage = PromptStorage(
                fileURL: storageRoot.appendingPathComponent("SavedPrompts.json")
            )
            let window = WindowState(
                domainRuntime: domainRuntime,
                storedPromptPersistence: StoredPromptPersistenceService(storage: promptStorage)
            )
            WindowStatesManager.shared.registerWindowState(window)
            windows.append(window)
            await window.workspaceManager.awaitInitialized()
            return window
        }

        private func saveAuthoritativeWorkspace(
            _ workspace: WorkspaceModel,
            in window: WindowState,
            runtime: MCPDomainRuntime
        ) async throws {
            let client = DomainWorkspaceAuthorityClient(
                store: runtime.workspaceStore,
                windowID: window.windowID
            )
            let snapshot = await client.snapshot()
            let existing = snapshot.workspaces.first {
                $0.document.workspaceID == workspace.id
            }
            let outcome: DomainCommandOutcome = if let existing {
                try await client.save(
                    workspace,
                    fileURL: existing.document.fileURL,
                    expectedWorkspaceRevision: existing.revisions.workingRevision,
                    expectedContentDigest: existing.document.contentDigest
                )
            } else {
                try await client.create(
                    workspace,
                    fileURL: window.workspaceManager.workspaceFileURL(for: workspace)
                )
            }
            guard outcome.disposition == .applied
                || outcome.disposition == .unchanged
                || outcome.disposition == .deduplicated
            else {
                throw DomainWorkspaceAuthorityOperationError(outcome: outcome)
            }
        }

        private func makeDomainRuntime() async throws -> MCPDomainRuntime {
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "window-folder-command-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            domainRuntimes.append(runtime)
            return runtime
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
            newPrompt: (title: String, content: String)? = nil,
            focus: Bool? = nil,
            ephemeral: Bool? = nil,
            persist: Bool? = nil
        ) -> AppCommand {
            AppCommand(
                workspaceName: nil,
                fileList: fileList,
                promptText: promptText,
                folderPath: folderPath,
                newPrompt: newPrompt,
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

    private actor WindowFolderOpenCreationGate {
        private var didPause = false
        private var didRelease = false
        private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func pauseUntilReleased() async {
            didPause = true
            pauseWaiters.forEach { $0.resume() }
            pauseWaiters.removeAll()
            guard !didRelease else { return }
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }

        func waitUntilPaused() async {
            guard !didPause else { return }
            await withCheckedContinuation { continuation in
                pauseWaiters.append(continuation)
            }
        }

        func release() {
            didRelease = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private actor WindowFolderOpenTwoPartyBarrier {
        private var waiter: CheckedContinuation<Void, Never>?

        func arriveAndWait() async {
            if let waiter {
                self.waiter = nil
                waiter.resume()
                return
            }
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
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
