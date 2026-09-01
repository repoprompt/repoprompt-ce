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

        func testQueuedResolvedFolderRouteStopsWhenSameWorkspaceIDChangesRoots() async throws {
            let window = await makeWindow()
            let requestedFolder = try makeFolder(named: "QueuedExpectedRoot")
            let replacementFolder = try makeFolder(named: "QueuedReplacementRoot")
            let selectedFile = requestedFolder.appendingPathComponent("Selected.swift")
            let payloadFile = requestedFolder.appendingPathComponent("Payload.swift")
            try Data("let selected = true\n".utf8).write(to: selectedFile)
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000023"))
            let expectedWorkspace = WorkspaceModel(
                id: workspaceID,
                name: "Queued Workspace",
                repoPaths: [requestedFolder.path]
            )
            window.workspaceManager.workspaces.append(expectedWorkspace)
            let initialSwitch = await window.workspaceManager.switchWorkspace(
                to: expectedWorkspace,
                saveState: false,
                reason: "folderCommandQueuedRootFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            await window.workspaceFilesViewModel.selectFiles(withPaths: [selectedFile.path])
            window.promptManager.promptText = "before"
            let countBeforeRoute = window.workspaceManager.workspaces.count
            window.setAutomaticCommandProcessingForTesting(false)
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(requestedFolder.path)?files=\(payloadFile.path)&prompt=after"
            ))

            await AppDeepLinkRouter(windowStatesManager: .shared).route(url: url)
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceID })
            )
            window.workspaceManager.workspaces[workspaceIndex] = WorkspaceModel(
                id: workspaceID,
                name: "Queued Workspace",
                repoPaths: [replacementFolder.path]
            )
            await window.processCommands()

            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, workspaceID)
            XCTAssertEqual(window.workspaceManager.activeWorkspace?.repoPaths, [replacementFolder.path])
            XCTAssertEqual(window.workspaceManager.workspaces.count, countBeforeRoute)
            XCTAssertEqual(window.promptManager.promptText, "before")
            XCTAssertTrue(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == selectedFile.path
            })
            XCTAssertFalse(window.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
        }

        func testQueuedResolvedFolderRouteUsesSharedAuthorityWhenProjectionIsStale() async throws {
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
            _ = try await authorityWindow.workspaceManager.saveWorkspaceToFileAsync(expectedWorkspace)
            try await waitUntil {
                targetWindow.workspaceManager.workspace(withID: workspaceID)?.repoPaths == [requestedFolder.path]
            }
            let projectedWorkspace = try XCTUnwrap(targetWindow.workspaceManager.workspace(withID: workspaceID))
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
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(requestedFolder.path)?files=\(payloadFile.path)&prompt=after"
            ))

            await AppDeepLinkRouter(windowStatesManager: .shared).route(
                url: url,
                preferredLegacyWindow: targetWindow
            )
            targetWindow.stopDomainWorkspaceProjectionForTesting()
            var replacementWorkspace = expectedWorkspace
            replacementWorkspace.repoPaths = [replacementFolder.path]
            replacementWorkspace.dateModified = Date()
            _ = try await authorityWindow.workspaceManager.saveWorkspaceToFileAsync(replacementWorkspace)
            let routingCatalog = await targetWindow.workspaceManager.workspaceRoutingCatalogSnapshot()
            let authoritativeCatalog = try XCTUnwrap(routingCatalog)
            XCTAssertEqual(
                authoritativeCatalog.first(where: { $0.id == workspaceID })?.repoPaths,
                [replacementFolder.path]
            )

            await targetWindow.processCommands()

            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspaceID, workspaceID)
            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspace?.repoPaths, [requestedFolder.path])
            XCTAssertEqual(targetWindow.workspaceManager.workspaces.count, countBeforeRoute)
            XCTAssertEqual(targetWindow.promptManager.promptText, "before")
            XCTAssertTrue(targetWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == selectedFile.path
            })
            XCTAssertFalse(targetWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertEqual(
                targetWindow.workspaceManager.workspaces.count {
                    $0.id == workspaceID
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
            _ = try await authorityWindow.workspaceManager.saveWorkspaceToFileAsync(workspace)
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
            let runtime = try await makeDomainRuntime()
            let authorityWindow = await makeWindow(domainRuntime: runtime)
            let targetWindow = await makeWindow(domainRuntime: runtime)
            let oldFolder = try makeFolder(named: "AuthorityOldActiveRoot")
            let requestedFolder = try makeFolder(named: "AuthorityNewActiveRoot")
            let payloadFile = requestedFolder.appendingPathComponent("Payload.swift")
            try Data("let payload = true\n".utf8).write(to: payloadFile)
            let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000029"))
            let oldWorkspace = WorkspaceModel(
                id: workspaceID,
                name: "Authority Active Projection",
                repoPaths: [oldFolder.path]
            )
            _ = try await authorityWindow.workspaceManager.saveWorkspaceToFileAsync(oldWorkspace)
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
            let countBeforeRoute = targetWindow.workspaceManager.workspaces.count
            targetWindow.stopDomainWorkspaceProjectionForTesting()
            var replacementWorkspace = oldWorkspace
            replacementWorkspace.repoPaths = [requestedFolder.path]
            replacementWorkspace.dateModified = Date()
            _ = try await authorityWindow.workspaceManager.saveWorkspaceToFileAsync(replacementWorkspace)
            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspace?.repoPaths, [oldFolder.path])
            targetWindow.setAutomaticCommandProcessingForTesting(false)
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(requestedFolder.path)?files=\(payloadFile.path)&prompt=after"
            ))

            await AppDeepLinkRouter(windowStatesManager: .shared).route(
                url: url,
                preferredLegacyWindow: targetWindow
            )
            await targetWindow.processCommands()

            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspaceID, workspaceID)
            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspace?.repoPaths, [requestedFolder.path])
            XCTAssertEqual(targetWindow.workspaceManager.workspaces.count, countBeforeRoute)
            XCTAssertEqual(targetWindow.promptManager.promptText, "after")
            XCTAssertTrue(targetWindow.workspaceFilesViewModel.selectedFiles.contains {
                $0.fullPath == payloadFile.path
            })
            XCTAssertEqual(targetWindow.workspaceManager.workspaces.count { $0.id == workspaceID }, 1)
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

        func testConcurrentUnmatchedRoutesCreateOneAuthoritativeWorkspace() async throws {
            let runtime = try await makeDomainRuntime()
            let firstWindow = await makeWindow(domainRuntime: runtime)
            let secondWindow = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "ConcurrentRoutedFolder")
            firstWindow.setAutomaticCommandProcessingForTesting(false)
            secondWindow.setAutomaticCommandProcessingForTesting(false)
            let barrier = WindowFolderOpenTwoPartyBarrier()
            firstWindow.workspaceManager.setPersistentFolderOpenDidSnapshotHandlerForTesting {
                await barrier.arriveAndWait()
            }
            secondWindow.workspaceManager.setPersistentFolderOpenDidSnapshotHandlerForTesting {
                await barrier.arriveAndWait()
            }
            let url = try XCTUnwrap(URL(
                string: "repoprompt-ce://open/\(folder.path)"
            ))
            let router = AppDeepLinkRouter(windowStatesManager: .shared)

            await router.route(url: url, preferredLegacyWindow: firstWindow)
            await router.route(url: url, preferredLegacyWindow: secondWindow)
            XCTAssertEqual(firstWindow.queuedCommandCountForTesting, 1)
            XCTAssertEqual(secondWindow.queuedCommandCountForTesting, 1)

            async let firstProcess: Void = firstWindow.processCommands()
            async let secondProcess: Void = secondWindow.processCommands()
            _ = await (firstProcess, secondProcess)

            let snapshot = await firstWindow.workspaceManager.workspaceRoutingCatalogSnapshot()
            let routingSnapshot = try XCTUnwrap(snapshot)
            let matches = routingSnapshot.filter {
                WorkspaceFolderOpenResolver.containsExactRoot(folder.path, in: $0)
            }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(firstWindow.workspaceManager.activeWorkspaceID, matches.first?.id)
            XCTAssertEqual(secondWindow.workspaceManager.activeWorkspaceID, matches.first?.id)
            XCTAssertEqual(
                firstWindow.workspaceManager.workspaces.count(where: {
                    WorkspaceFolderOpenResolver.containsExactRoot(folder.path, in: $0)
                }),
                1
            )
            XCTAssertEqual(
                secondWindow.workspaceManager.workspaces.count(where: {
                    WorkspaceFolderOpenResolver.containsExactRoot(folder.path, in: $0)
                }),
                1
            )
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

        func testRouteRetriesOnlyOnceWhenBothWindowsCloseDuringAuthorityAwait() async throws {
            let runtime = try await makeDomainRuntime()
            let retryWindow = await makeWindow(domainRuntime: runtime)
            let targetWindow = await makeWindow(domainRuntime: runtime)
            let folder = try makeFolder(named: "BothWindowsClosingDuringAuthorityAwait")
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
            XCTAssertEqual(WindowStatesManager.shared.pendingURLs, [url])
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

            window.enqueueCommand(folderCommand(
                folderPath: targetFolder.path,
                promptText: "after"
            ))
            await window.processCommands()

            XCTAssertTrue(window.isClosing)
            XCTAssertNotEqual(window.promptManager.promptText, "after")
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

        private func makeWindow(domainRuntime: MCPDomainRuntime? = nil) async -> WindowState {
            let window = if let domainRuntime {
                WindowState(domainRuntime: domainRuntime)
            } else {
                WindowState()
            }
            WindowStatesManager.shared.registerWindowState(window)
            windows.append(window)
            await window.workspaceManager.awaitInitialized()
            return window
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
