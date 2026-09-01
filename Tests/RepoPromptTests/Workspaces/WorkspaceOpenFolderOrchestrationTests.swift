import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceOpenFolderOrchestrationTests: XCTestCase {
        private var originalMCPAutoStart = false
        private var originalStoragePath: String?
        private var storageRoot: URL!
        private var managers: [WorkspaceManagerViewModel] = []
        private var domainBridges: [DomainWorkspacePresentationBridge] = []
        private var domainRuntimes: [MCPDomainRuntime] = []

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceOpenFolderOrchestrationTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        }

        override func tearDown() async throws {
            domainBridges.forEach { $0.stop() }
            domainBridges.removeAll()
            managers.forEach { $0.prepareForWindowClose() }
            managers.removeAll()
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

        func testNoMatchCreatesAndActivatesPersistentWorkspace() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "NewProject")
            let countBeforeOpen = manager.workspaces.count

            try await manager.openWorkspace(
                fromFolderURL: folder,
                behavior: .createNewWorkspace
            )

            let activeWorkspace = try XCTUnwrap(manager.activeWorkspace)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen + 1)
            XCTAssertEqual(activeWorkspace.repoPaths, [folder.path])
            XCTAssertFalse(activeWorkspace.isEphemeral)
        }

        func testConcurrentNoMatchOpensShareOneAuthoritativeWorkspace() async throws {
            let runtime = try await makeDomainRuntime()
            let firstManager = makeManager(domainRuntime: runtime)
            let secondManager = makeManager(domainRuntime: runtime)
            await firstManager.awaitInitialized()
            await secondManager.awaitInitialized()
            let folder = try makeFolder(named: "ConcurrentProject")
            let barrier = TwoPartyAsyncBarrier()
            firstManager.setPersistentFolderOpenDidSnapshotHandlerForTesting {
                await barrier.arriveAndWait()
            }
            secondManager.setPersistentFolderOpenDidSnapshotHandlerForTesting {
                await barrier.arriveAndWait()
            }

            async let firstOpen: Void = firstManager.openWorkspace(
                fromFolderURL: folder,
                behavior: .createNewWorkspace
            )
            async let secondOpen: Void = secondManager.openWorkspace(
                fromFolderURL: folder,
                behavior: .createNewWorkspace
            )
            _ = try await (firstOpen, secondOpen)

            let snapshot = await firstManager.workspaceRoutingCatalogSnapshot()
            let routingSnapshot = try XCTUnwrap(snapshot)
            let matches = routingSnapshot.filter {
                WorkspaceFolderOpenResolver.containsExactRoot(folder.path, in: $0)
            }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(firstManager.activeWorkspaceID, matches.first?.id)
            XCTAssertEqual(secondManager.activeWorkspaceID, matches.first?.id)
            XCTAssertEqual(
                firstManager.workspaces.count(where: {
                    WorkspaceFolderOpenResolver.containsExactRoot(folder.path, in: $0)
                }),
                1
            )
            XCTAssertEqual(
                secondManager.workspaces.count(where: {
                    WorkspaceFolderOpenResolver.containsExactRoot(folder.path, in: $0)
                }),
                1
            )
        }

        func testUnrelatedCatalogConflictRetriesWithFreshRevision() async throws {
            let runtime = try await makeDomainRuntime()
            let openingManager = makeManager(domainRuntime: runtime)
            let mutatingManager = makeManager(domainRuntime: runtime)
            await openingManager.awaitInitialized()
            await mutatingManager.awaitInitialized()
            let requestedFolder = try makeFolder(named: "RequestedAfterConflict")
            let unrelatedFolder = try makeFolder(named: "UnrelatedCatalogMutation")
            openingManager.setPersistentFolderOpenDidSnapshotHandlerForTesting {
                _ = try? await mutatingManager.resolveOrCreatePersistentWorkspace(
                    fromFolderURL: unrelatedFolder
                )
            }

            try await openingManager.openWorkspace(
                fromFolderURL: requestedFolder,
                behavior: .createNewWorkspace
            )

            let snapshot = await openingManager.workspaceRoutingCatalogSnapshot()
            let routingSnapshot = try XCTUnwrap(snapshot)
            XCTAssertEqual(
                routingSnapshot.count(where: {
                    WorkspaceFolderOpenResolver.containsExactRoot(requestedFolder.path, in: $0)
                }),
                1
            )
            XCTAssertEqual(
                routingSnapshot.count(where: {
                    WorkspaceFolderOpenResolver.containsExactRoot(unrelatedFolder.path, in: $0)
                }),
                1
            )
            XCTAssertTrue(
                try WorkspaceFolderOpenResolver.containsExactRoot(
                    requestedFolder.path,
                    in: XCTUnwrap(openingManager.activeWorkspace)
                )
            )
        }

        func testConcurrentRootAdditionIsReusedInsteadOfCreatingDuplicateWorkspace() async throws {
            let runtime = try await makeDomainRuntime()
            let openingManager = makeManager(domainRuntime: runtime)
            let mutatingManager = makeManager(domainRuntime: runtime)
            await openingManager.awaitInitialized()
            await mutatingManager.awaitInitialized()
            let existingFolder = try makeFolder(named: "ExistingBeforeRootAddition")
            let requestedFolder = try makeFolder(named: "AddedDuringFolderOpen")
            let existing = mutatingManager.createWorkspace(
                name: "Existing Root Receiver",
                repoPaths: [existingFolder.path]
            )
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            var existingIsAuthoritative = false
            while clock.now < deadline {
                let snapshot = await mutatingManager.workspaceRoutingCatalogSnapshot()
                existingIsAuthoritative = snapshot?.contains(where: { $0.id == existing.id }) == true
                if existingIsAuthoritative { break }
                try await clock.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(existingIsAuthoritative)
            let mutationGate = WorkspaceRootMutationTestGate()
            await runtime.workspaceStore.testSetAfterWorkspaceMutationGateAcquired { workspaceID in
                guard workspaceID == existing.id else { return }
                await mutationGate.pauseUntilReleased()
            }
            defer {
                Task {
                    await runtime.workspaceStore.testSetAfterWorkspaceMutationGateAcquired(nil)
                }
            }

            async let rootAddition: Void = mutatingManager.addFolder(requestedFolder, to: existing)
            await mutationGate.waitUntilPaused()
            async let folderOpen: Void = openingManager.openWorkspace(
                fromFolderURL: requestedFolder,
                behavior: .createNewWorkspace
            )
            await Task.yield()
            await mutationGate.release()
            _ = try await (rootAddition, folderOpen)

            let catalogSnapshot = await openingManager.workspaceRoutingCatalogSnapshot()
            let snapshot = try XCTUnwrap(catalogSnapshot)
            let matches = snapshot.filter {
                WorkspaceFolderOpenResolver.containsExactRoot(requestedFolder.path, in: $0)
            }
            XCTAssertEqual(matches.map(\.id), [existing.id])
            XCTAssertEqual(openingManager.activeWorkspaceID, existing.id)
        }

        func testReplayedResolveOrCreateReturnsOriginalReusedWorkspace() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "ResolveOrCreateReplay")
            let existing = manager.createWorkspace(name: "Replay Winner", repoPaths: [folder.path])
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while clock.now < deadline {
                let snapshot = await manager.workspaceRoutingCatalogSnapshot()
                if snapshot?.contains(where: { $0.id == existing.id }) == true { break }
                try await clock.sleep(for: .milliseconds(10))
            }
            let client = DomainWorkspaceAuthorityClient(
                store: runtime.workspaceStore,
                windowID: -1301
            )
            let proposed = WorkspaceModel(name: "Replay Proposed", repoPaths: [folder.path])
            let proposedFileURL = storageRoot.appendingPathComponent("\(proposed.id.uuidString).json")
            let canonicalRootPath = try XCTUnwrap(
                WorkspaceRootSetKey(paths: [folder.path]).normalizedPaths.first
            ).lowercased()
            let operationID = UUID()

            let first = try await client.resolveOrCreatePersistentWorkspace(
                proposed,
                fileURL: proposedFileURL,
                canonicalRootPath: canonicalRootPath,
                preferredWorkspaceIDs: [existing.id],
                operationID: operationID
            )
            let replay = try await client.resolveOrCreatePersistentWorkspace(
                proposed,
                fileURL: proposedFileURL,
                canonicalRootPath: canonicalRootPath,
                preferredWorkspaceIDs: [existing.id],
                operationID: operationID
            )

            XCTAssertEqual(first.disposition, .unchanged)
            XCTAssertEqual(first.workspace?.document.workspaceID, existing.id)
            XCTAssertEqual(replay.disposition, .deduplicated)
            XCTAssertEqual(replay.workspace?.document.workspaceID, existing.id)
        }

        func testConcurrentReplaceRetriesRecheckOperationIDAfterMutationGate() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "ReplaceRetryGate")
            let existing = manager.createWorkspace(name: "Replace Original", repoPaths: [folder.path])
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            var authoritativeWorkspace: DomainWorkspaceSnapshot?
            while clock.now < deadline {
                authoritativeWorkspace = await runtime.workspaceStore.workspaceSnapshot(existing.id)
                if authoritativeWorkspace != nil { break }
                try await clock.sleep(for: .milliseconds(10))
            }
            let authoritative = try XCTUnwrap(authoritativeWorkspace)
            let client = DomainWorkspaceAuthorityClient(
                store: runtime.workspaceStore,
                windowID: -1302
            )
            var update = existing
            update.name = "Replace Applied"
            var conflictingUpdate = update
            conflictingUpdate.name = "Replace Collision"
            let operationID = UUID()
            let mutationGate = WorkspaceRootMutationTestGate()
            await runtime.workspaceStore.testSetAfterWorkspaceMutationGateAcquired { workspaceID in
                guard workspaceID == existing.id else { return }
                await mutationGate.pauseUntilReleased()
            }
            defer {
                Task {
                    await runtime.workspaceStore.testSetAfterWorkspaceMutationGateAcquired(nil)
                }
            }

            async let first = client.replaceWorking(
                update,
                fileURL: authoritative.document.fileURL,
                expectedWorkspaceRevision: authoritative.revisions.workingRevision,
                operationID: operationID
            )
            await mutationGate.waitUntilPaused()
            async let retry = client.replaceWorking(
                update,
                fileURL: authoritative.document.fileURL,
                expectedWorkspaceRevision: authoritative.revisions.workingRevision,
                operationID: operationID
            )
            await mutationGate.release()
            let (firstOutcome, retryOutcome) = try await (first, retry)
            let collision = try await client.replaceWorking(
                conflictingUpdate,
                fileURL: authoritative.document.fileURL,
                expectedWorkspaceRevision: authoritative.revisions.workingRevision,
                operationID: operationID
            )

            XCTAssertEqual(firstOutcome.disposition, .applied)
            XCTAssertEqual(retryOutcome.disposition, .deduplicated)
            XCTAssertEqual(collision.disposition, .invalid)
            XCTAssertEqual(collision.errorCode, .operationIDCollision)
        }

        func testExplicitCreationStillAllowsPersistentDuplicateRoots() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "IntentionalDuplicateRoot")
            let first = manager.createWorkspace(name: "Intentional One", repoPaths: [folder.path])
            let second = manager.createWorkspace(name: "Intentional Two", repoPaths: [folder.path])
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            var matches: [WorkspaceModel] = []

            while clock.now < deadline {
                if let snapshot = await manager.workspaceRoutingCatalogSnapshot() {
                    matches = snapshot.filter {
                        WorkspaceFolderOpenResolver.containsExactRoot(folder.path, in: $0)
                    }
                    if matches.count == 2 { break }
                }
                try await clock.sleep(for: .milliseconds(10))
            }

            XCTAssertEqual(Set(matches.map(\.id)), [first.id, second.id])
        }

        func testReopeningExistingWorkspacePreservesStateAndInventory() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "ExistingProject")
            let selectedFile = folder.appendingPathComponent("README.md").path
            let preservedTab = ComposeTabState(
                name: "Review",
                selection: StoredSelection(selectedPaths: [selectedFile]),
                promptText: "Preserve this prompt"
            )
            let secondaryTab = ComposeTabState(name: "Follow-up", promptText: "Second tab")
            let preset = WorkspacePreset(
                name: "Review preset",
                selectedFilePaths: [selectedFile]
            )
            let copyPresetID = UUID()
            let existing = WorkspaceModel(
                name: "Existing Project",
                repoPaths: [folder.path],
                presets: [preset],
                activePresetID: preset.id,
                currentPromptText: preservedTab.promptText,
                copyPresetId: copyPresetID,
                composeTabs: [preservedTab, secondaryTab],
                activeComposeTabID: preservedTab.id
            )
            let workspaceFile = try manager.saveWorkspaceToFile(existing)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: workspaceFile)
            manager.workspaces.append(WorkspaceModel(
                id: existing.id,
                dateModified: existing.dateModified,
                name: existing.name,
                repoPaths: existing.repoPaths
            ))
            XCTAssertNotEqual(manager.activeWorkspaceID, existing.id)
            let countBeforeOpen = manager.workspaces.count
            let normalizedVariant = URL(
                fileURLWithPath: folder.path + "/../ExistingProject/"
            )

            try await manager.openWorkspace(
                fromFolderURL: normalizedVariant,
                behavior: .createNewWorkspace
            )

            let reopened = try XCTUnwrap(manager.activeWorkspace)
            XCTAssertEqual(reopened.id, existing.id)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
            XCTAssertEqual(reopened.composeTabs, [preservedTab, secondaryTab])
            XCTAssertEqual(reopened.activeComposeTabID, preservedTab.id)
            XCTAssertEqual(reopened.composeTabs.first?.selection.selectedPaths, [selectedFile])
            XCTAssertEqual(reopened.composeTabs.first?.promptText, "Preserve this prompt")
            XCTAssertEqual(reopened.currentPromptText, "Preserve this prompt")
            XCTAssertEqual(reopened.presets, [preset])
            XCTAssertEqual(reopened.activePresetID, preset.id)
            XCTAssertEqual(reopened.copyPresetId, copyPresetID)
        }

        func testReopeningExistingWorkspacePreservesStateThroughDomainAuthority() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "DomainExistingProject")
            let selectedFile = folder.appendingPathComponent("README.md").path
            let preservedTab = ComposeTabState(
                name: "Review",
                selection: StoredSelection(selectedPaths: [selectedFile]),
                promptText: "Preserve this prompt"
            )
            let secondaryTab = ComposeTabState(name: "Follow-up", promptText: "Second tab")
            let preset = WorkspacePreset(
                name: "Review preset",
                selectedFilePaths: [selectedFile]
            )
            let copyPresetID = UUID()
            let existing = WorkspaceModel(
                name: "Domain Existing Project",
                repoPaths: [folder.path],
                presets: [preset],
                activePresetID: preset.id,
                currentPromptText: preservedTab.promptText,
                copyPresetId: copyPresetID,
                composeTabs: [preservedTab, secondaryTab],
                activeComposeTabID: preservedTab.id
            )

            _ = try await manager.saveWorkspaceToFileAsync(existing)
            try await waitUntil {
                manager.workspace(withID: existing.id)?.composeTabs == [preservedTab, secondaryTab]
            }
            XCTAssertNotEqual(manager.activeWorkspaceID, existing.id)
            let countBeforeOpen = manager.workspaces.count

            try await manager.openWorkspace(
                fromFolderURL: folder,
                behavior: .createNewWorkspace
            )

            let reopened = try XCTUnwrap(manager.activeWorkspace)
            XCTAssertEqual(reopened.id, existing.id)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
            XCTAssertEqual(reopened.composeTabs, [preservedTab, secondaryTab])
            XCTAssertEqual(reopened.activeComposeTabID, preservedTab.id)
            XCTAssertEqual(reopened.composeTabs.first?.selection.selectedPaths, [selectedFile])
            XCTAssertEqual(reopened.composeTabs.first?.promptText, "Preserve this prompt")
            XCTAssertEqual(reopened.currentPromptText, "Preserve this prompt")
            XCTAssertEqual(reopened.presets, [preset])
            XCTAssertEqual(reopened.activePresetID, preset.id)
            XCTAssertEqual(reopened.copyPresetId, copyPresetID)
        }

        func testInteractiveReuseReloadsStaleActiveAuthorityProjection() async throws {
            let runtime = try await makeDomainRuntime()
            let authorityManager = makeManager(domainRuntime: runtime)
            let targetManager = makeManager(domainRuntime: runtime)
            let targetBridge = try XCTUnwrap(domainBridges.last)
            await authorityManager.awaitInitialized()
            await targetManager.awaitInitialized()
            let originalFolder = try makeFolder(named: "InteractiveStaleOriginal")
            let requestedFolder = try makeFolder(named: "InteractiveStaleRequested")
            let workspace = WorkspaceModel(
                name: "Interactive Stale",
                repoPaths: [originalFolder.path]
            )
            _ = try await authorityManager.saveWorkspaceToFileAsync(workspace)
            try await waitUntil {
                targetManager.workspace(withID: workspace.id)?.repoPaths == [originalFolder.path]
            }
            let projectedWorkspace = try XCTUnwrap(targetManager.workspace(withID: workspace.id))
            let initialSwitch = await targetManager.switchWorkspace(
                to: projectedWorkspace,
                saveState: false,
                reason: "interactiveStaleFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            targetBridge.stop()
            var replacement = workspace
            replacement.repoPaths = [requestedFolder.path]
            replacement.dateModified = Date()
            _ = try await authorityManager.saveWorkspaceToFileAsync(replacement)
            XCTAssertEqual(targetManager.activeWorkspace?.repoPaths, [originalFolder.path])

            try await targetManager.openWorkspace(
                fromFolderURL: requestedFolder,
                behavior: .createNewWorkspace
            )

            XCTAssertEqual(targetManager.activeWorkspaceID, workspace.id)
            XCTAssertEqual(targetManager.activeWorkspace?.repoPaths, [requestedFolder.path])
        }

        func testActiveMatchedWorkspaceIsSilentNoOp() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "ActiveProject")
            let existing = manager.createWorkspace(
                name: "Active Project",
                repoPaths: [folder.path]
            )
            let initialSwitch = await manager.switchWorkspace(
                to: existing,
                saveState: false,
                reason: "openFolderActiveFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            let countBeforeOpen = manager.workspaces.count

            try await manager.openWorkspace(
                fromFolderURL: folder,
                behavior: .createNewWorkspace
            )

            XCTAssertEqual(manager.activeWorkspaceID, existing.id)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
            XCTAssertNil(manager.pendingWorkspaceSwitchBlockedNotice)
        }

        func testCancelledMatchedSwitchDoesNotCreateReplacement() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "CancelledProject")
            _ = manager.createWorkspace(
                name: "Cancelled Project",
                repoPaths: [folder.path]
            )
            let activeIDBeforeOpen = manager.activeWorkspaceID
            let countBeforeOpen = manager.workspaces.count
            let sessionProvider = OpenFolderWorkspaceSwitchSessionProvider()
            manager.registerSwitchSessionProvider(sessionProvider)

            let openTask = Task {
                try await manager.openWorkspace(
                    fromFolderURL: folder,
                    behavior: .createNewWorkspace
                )
            }
            let confirmation = try await waitForPendingSwitchConfirmation(in: manager)
            manager.resolveSwitchConfirmation(id: confirmation.id, allow: false)
            try await openTask.value

            XCTAssertEqual(manager.activeWorkspaceID, activeIDBeforeOpen)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
            XCTAssertNil(manager.pendingSwitchConfirmation)
            XCTAssertNil(manager.pendingWorkspaceSwitchBlockedNotice)
        }

        func testBlockedMatchedSwitchDoesNotCreateReplacement() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "BlockedProject")
            _ = manager.createWorkspace(
                name: "Blocked Project",
                repoPaths: [folder.path]
            )
            let activeIDBeforeOpen = manager.activeWorkspaceID
            let countBeforeOpen = manager.workspaces.count
            manager.isRefreshing = true
            defer { manager.isRefreshing = false }

            try await manager.openWorkspace(
                fromFolderURL: folder,
                behavior: .createNewWorkspace
            )

            XCTAssertEqual(manager.activeWorkspaceID, activeIDBeforeOpen)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
            XCTAssertEqual(
                manager.pendingWorkspaceSwitchBlockedNotice?.message,
                "Cannot switch workspaces while refresh is in progress."
            )
        }

        func testRankedDuplicateMatchIsActivatedWithoutCreation() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
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
            manager.workspaces.append(contentsOf: [older, newest])
            let countBeforeOpen = manager.workspaces.count

            try await manager.openWorkspace(
                fromFolderURL: folder,
                behavior: .createNewWorkspace
            )

            XCTAssertEqual(manager.activeWorkspaceID, newest.id)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
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
            throw WorkspaceOpenFolderOrchestrationTestError.confirmationTimedOut
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
            throw WorkspaceOpenFolderOrchestrationTestError.conditionTimedOut
        }

        private func makeFolder(named name: String) throws -> URL {
            let folder = storageRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        private func makeDomainRuntime() async throws -> MCPDomainRuntime {
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-open-folder-\(UUID().uuidString)",
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

        private func makeManager(domainRuntime: MCPDomainRuntime? = nil) -> WorkspaceManagerViewModel {
            let composition = WindowStateCompositionFactory.make(
                windowID: -1300 - Int.random(in: 1 ... 99),
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                domainRuntime: domainRuntime
            )
            managers.append(composition.workspaceManager)
            if let domainWorkspacePresentationBridge = composition.domainWorkspacePresentationBridge {
                domainBridges.append(domainWorkspacePresentationBridge)
            }
            return composition.workspaceManager
        }
    }

    private actor WorkspaceRootMutationTestGate {
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

    private actor TwoPartyAsyncBarrier {
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
    private final class OpenFolderWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
        func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
            [WorkspaceSwitchSessionItem(
                id: "open-folder-orchestration",
                count: 1,
                singularLabel: "active session",
                pluralLabel: "active sessions"
            )]
        }

        func cancelSwitchSessions() async {}
    }

    private enum WorkspaceOpenFolderOrchestrationTestError: Error {
        case confirmationTimedOut
        case conditionTimedOut
    }
#endif
