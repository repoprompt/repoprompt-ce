@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceEphemeralPersistenceTests: XCTestCase {
        private var originalMCPAutoStart = false
        private var originalStoragePath: String?
        private var storageRoot: URL!
        private var managers: [WorkspaceManagerViewModel] = []

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceEphemeralPersistenceTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        }

        override func tearDown() async throws {
            managers.forEach { $0.prepareForWindowClose() }
            managers.removeAll()
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

        func testLibraryRecencyIgnoresBackgroundSavesAndGroupsTemporaryWork() throws {
            let manager = makeManager(windowID: -799)
            let recent = WorkspaceModel(dateModified: .distantPast, name: "Recent project", repoPaths: ["/projects/recent"], lastUsed: Date(timeIntervalSince1970: 200))
            let background = WorkspaceModel(dateModified: .distantFuture, name: "Background save", repoPaths: ["/projects/background"], lastUsed: Date(timeIntervalSince1970: 100))
            let automation = WorkspaceModel(name: "Agent review", repoPaths: ["/projects/recent"], isSavedWorkspace: false)
            let scratch = WorkspaceModel(name: "Old scratch", repoPaths: ["/tmp/review-checkout"])
            let deliberatelySaved = WorkspaceModel(name: "Saved scratch", repoPaths: ["/tmp/my-project"], lastUsed: .distantPast, isSavedWorkspace: true)
            manager.workspaces = [background, automation, scratch, deliberatelySaved, recent]
            XCTAssertEqual(manager.workspacesForMenu().map(\.id), [recent.id, background.id, deliberatelySaved.id])
            XCTAssertEqual(Set(manager.workspacesForMenu(.init(includeTemporary: true)).map(\.id)), Set(manager.workspaces.map(\.id)))
            let decoded = try JSONDecoder().decode(WorkspaceModel.self, from: JSONEncoder().encode(deliberatelySaved))
            XCTAssertEqual(decoded.isSavedWorkspace, true)
            XCTAssertFalse(decoded.isTemporaryWorkspace)
            XCTAssertNil(scratch.isSavedWorkspace, "Legacy grouping must not rewrite provenance")
        }

        func testNewWorkspaceWaitsForItsOwnSaveWithoutBlockingOtherOpens() async throws {
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-creation-ordering-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }
            let manager = makeManager(
                windowID: -796,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -796)
            )
            await manager.awaitInitialized()
            let savePrepared = expectation(description: "creation save prepared")
            let gate = WorkspaceDeleteSuspensionGate()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { _, _, _ in
                savePrepared.fulfill()
                await gate.wait()
            }
            let created = manager.createWorkspace(name: "New saved project", repoPaths: [])
            await fulfillment(of: [savePrepared], timeout: 3)
            let opening = Task { await manager.switchWorkspace(to: created, saveState: false) }
            await Task.yield()
            XCTAssertFalse(manager.isSwitchingWorkspace, "A pending creation must not own the window's switch")
            let temporary = manager.createEphemeralWorkspace(name: "Other workspace", repoPaths: [])
            let otherOpen = await manager.switchWorkspace(to: temporary, saveState: false)
            XCTAssertTrue(otherOpen.didSwitch)
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            await gate.open()
            let opened = await opening.value
            XCTAssertTrue(opened.didSwitch)
            XCTAssertTrue(FileManager.default.fileExists(atPath: manager.workspaceFileURL(for: created).path))
        }

        func testExplicitLibraryChoicePersistsAcrossReload() async throws {
            let workspace = WorkspaceModel(name: "Automation project", repoPaths: [], isSavedWorkspace: false)
            try writeWorkspace(workspace)
            try writeLegacyIndex([workspace])
            let manager = makeManager(windowID: -798)
            await manager.awaitInitialized()
            await manager.setWorkspaceLibraryMembership(workspace, saved: true)
            let url = manager.workspaceFileURL(for: workspace)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: url)
            let saved = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: url))
            XCTAssertEqual(saved.isSavedWorkspace, true)
            XCTAssertFalse(saved.isTemporaryWorkspace)
        }

        func testExplicitSaveAPIsRejectEphemeralWorkspaceWithoutSideEffects() async throws {
            let manager = makeManager(windowID: -772)
            await manager.awaitInitialized()
            let workspace = manager.createEphemeralWorkspace(
                name: "Explicit Save Rejection",
                repoPaths: []
            )
            let workspaceFile = manager.workspaceFileURL(for: workspace)
            let alternateRoot = storageRoot.appendingPathComponent(
                "ExplicitSaveAlternateRoot",
                isDirectory: true
            )

            do {
                _ = try await manager.saveWorkspaceToFileAsync(workspace)
                XCTFail("Explicit async save must reject an ephemeral workspace")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Ephemeral workspaces cannot be persisted.")
            }
            do {
                _ = try await manager.saveWorkspaceToFileAsync(
                    workspace,
                    baseRoot: alternateRoot
                )
                XCTFail("Explicit base-root save must reject an ephemeral workspace")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Ephemeral workspaces cannot be persisted.")
            }
            XCTAssertThrowsError(try manager.saveWorkspaceToFile(workspace)) { error in
                XCTAssertEqual(error.localizedDescription, "Ephemeral workspaces cannot be persisted.")
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceFile.path))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: workspaceFile.deletingLastPathComponent().path)
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: alternateRoot.path))
        }

        func testBulkAndSingleDeleteRemoveLocalEphemeralWorkspacesMissingFromRuntimeCatalog() async throws {
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "local-ephemeral-bulk-delete-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let manager = makeManager(
                windowID: -773,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -773
                )
            )
            await manager.awaitInitialized()
            let bulkWorkspace = manager.createEphemeralWorkspace(
                name: "Bulk Temporary Workspace",
                repoPaths: []
            )
            let singleWorkspace = manager.createEphemeralWorkspace(
                name: "Single Temporary Workspace",
                repoPaths: []
            )

            func materializeLocalArtifacts(for workspace: WorkspaceModel) throws -> URL {
                let directory = manager.workspaceFileURL(for: workspace).deletingLastPathComponent()
                let gitData = directory.appendingPathComponent("_git_data", isDirectory: true)
                try FileManager.default.createDirectory(at: gitData, withIntermediateDirectories: true)
                try Data("artifact".utf8).write(to: gitData.appendingPathComponent("marker"))
                return directory
            }

            let bulkDirectory = try materializeLocalArtifacts(for: bulkWorkspace)
            let singleDirectory = try materializeLocalArtifacts(for: singleWorkspace)
            let before = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(before.workspaces.contains {
                $0.document.workspaceID == bulkWorkspace.id
                    || $0.document.workspaceID == singleWorkspace.id
            })

            let result = await manager.deleteWorkspacesAsync(workspaceIDs: [bulkWorkspace.id])

            XCTAssertEqual(result.deletedWorkspaceIDs, [bulkWorkspace.id])
            XCTAssertTrue(result.alreadyAbsentWorkspaceIDs.isEmpty)
            XCTAssertTrue(result.skippedReasonsByWorkspaceID.isEmpty)
            XCTAssertTrue(result.failedReasonsByWorkspaceID.isEmpty)
            XCTAssertNil(manager.workspace(withID: bulkWorkspace.id))
            XCTAssertNotNil(manager.workspace(withID: singleWorkspace.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: bulkDirectory.path))

            let singleDeleted = await manager.deleteWorkspaceAsync(singleWorkspace)
            XCTAssertTrue(singleDeleted)
            XCTAssertNil(manager.workspace(withID: singleWorkspace.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: singleDirectory.path))

            let after = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(after.workspaces.contains {
                $0.document.workspaceID == bulkWorkspace.id
                    || $0.document.workspaceID == singleWorkspace.id
            })
        }

        func testAuthorityProjectionPreservesActiveLocalEphemeralWorkspace() async {
            let manager = makeManager(windowID: -771)
            await manager.awaitInitialized()
            let persistedProjection = manager.workspaces.filter { !$0.isEphemeral }
            let ephemeral = manager.createEphemeralWorkspace(
                name: "Temporary Projection",
                repoPaths: []
            )
            let switchResult = await manager.switchWorkspace(to: ephemeral, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)

            manager.applyDomainWorkspaceProjection(
                persistedProjection,
                fileURLsByWorkspaceID: [:],
                revisionsByWorkspaceID: [:],
                digestsByWorkspaceID: [:],
                healthByWorkspaceID: [:],
                catalogRevision: 1,
                preferredActiveWorkspaceID: ephemeral.id,
                publicationSequence: 1
            )

            XCTAssertEqual(manager.activeWorkspaceID, ephemeral.id)
            XCTAssertEqual(manager.workspace(withID: ephemeral.id)?.name, ephemeral.name)
            XCTAssertTrue(manager.workspace(withID: ephemeral.id)?.isEphemeral == true)
        }

        func testIndexedPersistedEphemeralWorkspaceIsExcludedWithoutDeletingLegacyFiles() async throws {
            let workspace = WorkspaceModel(
                name: "Legacy Temporary",
                repoPaths: ["/tmp/legacy-ephemeral"],
                ephemeralFlag: true
            )
            let directory = storageRoot.appendingPathComponent(
                DomainWorkspaceStoragePath.directoryName(name: workspace.name, id: workspace.id),
                isDirectory: true
            )
            let workspaceFile = directory.appendingPathComponent("workspace.json")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(workspace).write(to: workspaceFile, options: .atomic)
            let indexURL = storageRoot.appendingPathComponent("workspacesIndex.json")
            try JSONEncoder().encode([
                WorkspaceIndexEntry(
                    id: workspace.id,
                    name: workspace.name,
                    customStoragePath: nil,
                    isSystemWorkspace: false,
                    isHiddenInMenus: false
                )
            ]).write(to: indexURL, options: .atomic)

            let manager = makeManager(windowID: -762)
            await manager.awaitInitialized()

            XCTAssertFalse(manager.workspaces.contains { $0.id == workspace.id })
            let legacySnapshot = await manager.loadWorkspaceSnapshotFromDisk()
            XCTAssertFalse(legacySnapshot.contains { $0.id == workspace.id })
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceFile.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        }

        func testExplicitDeleteAllowsSavedSessionReferencesAndPinnedTabs() async throws {
            let pinnedWorkspace = WorkspaceModel(
                name: "Pinned Agent Workspace",
                repoPaths: [storageRoot.appendingPathComponent("pinned-repo").path],
                stashedTabs: [
                    StashedTab(tab: ComposeTabState(name: "Pinned", isPinned: true, activeAgentSessionID: UUID()))
                ]
            )
            try writeWorkspace(pinnedWorkspace)
            try writeLegacyIndex([pinnedWorkspace])

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-single-delete-protection-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let manager = makeManager(
                windowID: -767,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -767
                )
            )
            await manager.awaitInitialized()

            let didDelete = await manager.deleteWorkspaceAsync(pinnedWorkspace)
            XCTAssertTrue(didDelete)
            let authoritativeAfter = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(authoritativeAfter.workspaces.contains {
                $0.document.workspaceID == pinnedWorkspace.id
            })
        }

        func testConfirmedDeleteClosesAnOpenWorkspaceAndKeepsProjectFiles() async throws {
            let pinnedWorkspace = WorkspaceModel(
                name: "Pinned Agent Workspace",
                repoPaths: [storageRoot.appendingPathComponent("pinned-repo").path],
                stashedTabs: [
                    StashedTab(tab: ComposeTabState(name: "Pinned", isPinned: true, activeAgentSessionID: UUID()))
                ]
            )
            let projectURL = URL(fileURLWithPath: pinnedWorkspace.repoPaths[0])
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            let projectFile = projectURL.appendingPathComponent("keep.txt")
            try Data("user project".utf8).write(to: projectFile)
            try writeWorkspace(pinnedWorkspace)
            try writeLegacyIndex([pinnedWorkspace])

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-single-delete-protection-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let manager = makeManager(
                windowID: -767,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -767
                )
            )
            await manager.awaitInitialized()

            let activation = await manager.switchWorkspace(to: pinnedWorkspace, saveState: false)
            XCTAssertTrue(activation.didSwitch)
            let sessions = DeletionSessionProvider()
            manager.registerSwitchSessionProvider(sessions)
            let pendingSaveURL = manager.workspaceFileURL(for: pinnedWorkspace)
            manager.setWorkspaceDeleteWillExecuteHandlerForTesting { workspaceID in
                guard workspaceID == pinnedWorkspace.id else { return }
                var finalSave = pinnedWorkspace
                finalSave.name = "Final background save"
                let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -767)
                do {
                    let saved = try await client.replaceWorking(
                        finalSave,
                        fileURL: pendingSaveURL,
                        expectedWorkspaceRevision: nil
                    )
                    XCTAssertEqual(saved.disposition, .applied)
                } catch {
                    XCTFail("Could not publish the pending workspace save: \(error)")
                }
            }
            let deletion = await manager.deleteWorkspacesAsync(
                workspaceIDs: [pinnedWorkspace.id], closeOpenWorkspaces: true
            )
            manager.setWorkspaceDeleteWillExecuteHandlerForTesting(nil)
            XCTAssertEqual(deletion.deletedWorkspaceIDs, [pinnedWorkspace.id], "\(deletion)")
            XCTAssertTrue(manager.activeWorkspace?.isSystemWorkspace == true)
            XCTAssertTrue(sessions.wasCancelled)
            XCTAssertFalse(manager.hasPendingSwitchConfirmation)
            XCTAssertEqual(try String(contentsOf: projectFile, encoding: .utf8), "user project")
            let authoritativeAfter = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(authoritativeAfter.workspaces.contains {
                $0.document.workspaceID == pinnedWorkspace.id
            })
        }

        func testConfirmedDeleteBoundsPendingWorkspaceCreationAndReleasesLease() async throws {
            let runtime = try await makeRuntime(profileIdentifier: "workspace-delete-creation-timeout")
            defer { Task { _ = await runtime.shutdown() } }

            let coordinator = WorkspaceActivityCoordinator(confirmedDeletionTimeout: .milliseconds(100))
            let manager = makeManager(
                windowID: -764,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -764
                ),
                workspaceActivityCoordinator: coordinator
            )
            await manager.awaitInitialized()

            let created = manager.createWorkspace(name: "Pending deletion", repoPaths: [])
            let createdID = created.id
            let savePrepared = expectation(description: "creation save prepared")
            let gate = WorkspaceDeleteSuspensionGate()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, _, _ in
                guard workspaceID == createdID else { return }
                savePrepared.fulfill()
                await gate.wait()
            }
            await fulfillment(of: [savePrepared], timeout: 2)

            let deletionFinished = expectation(description: "confirmed deletion returns after timeout")
            let deletionTask = Task {
                defer { deletionFinished.fulfill() }
                return await manager.deleteWorkspacesAsync(
                    workspaceIDs: [created.id],
                    closeOpenWorkspaces: true
                )
            }
            await fulfillment(of: [deletionFinished], timeout: 2)
            await gate.open()
            let deletion = await deletionTask.value
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            XCTAssertTrue(deletion.deletedWorkspaceIDs.isEmpty, "A timed-out creation must not be deleted")
            XCTAssertTrue(
                deletion.skippedReasonsByWorkspaceID[created.id]?.contains("timeout") == true,
                "Expected a bounded deletion failure, got \(deletion)"
            )

            await manager.finishWorkspaceCreation(workspaceIDs: [created.id])
            let authoritativeAfterCreation = await runtime.workspaceStore.snapshot()
            XCTAssertTrue(authoritativeAfterCreation.workspaces.contains {
                $0.document.workspaceID == created.id
            })
            let retry = await manager.deleteWorkspacesAsync(
                workspaceIDs: [created.id],
                closeOpenWorkspaces: true
            )
            XCTAssertEqual(retry.deletedWorkspaceIDs, [created.id], "The timed-out claim must permit a confirmed retry")
        }

        func testConfirmedDeleteTimeoutCannotCloseAWorkspaceAfterLateSessionCancellation() async throws {
            let target = WorkspaceModel(
                name: "Gated deletion target",
                repoPaths: [storageRoot.appendingPathComponent("gated-repo").path]
            )
            try writeWorkspace(target)
            try writeLegacyIndex([target])

            let runtime = try await makeRuntime(profileIdentifier: "workspace-delete-session-timeout")
            defer { Task { _ = await runtime.shutdown() } }

            let coordinator = WorkspaceActivityCoordinator(confirmedDeletionTimeout: .milliseconds(100))
            let manager = makeManager(
                windowID: -763,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -763
                ),
                workspaceActivityCoordinator: coordinator
            )
            await manager.awaitInitialized()
            let targetInManager = try XCTUnwrap(manager.workspace(withID: target.id))
            let activation = await manager.switchWorkspace(to: targetInManager, saveState: false)
            XCTAssertTrue(activation.didSwitch, "Expected the deletion target to be active")

            let gate = WorkspaceDeleteSuspensionGate()
            let sessions = GatedDeletionSessionProvider(gate: gate)
            manager.registerSwitchSessionProvider(sessions)

            let deletionFinished = expectation(description: "confirmed deletion returns while provider is gated")
            let deletionTask = Task {
                defer { deletionFinished.fulfill() }
                return await manager.deleteWorkspacesAsync(
                    workspaceIDs: [target.id],
                    closeOpenWorkspaces: true
                )
            }
            await fulfillment(of: [sessions.cancellationStarted], timeout: 2)
            await fulfillment(of: [deletionFinished], timeout: 2)
            XCTAssertFalse(sessions.wasCancelled, "The gated provider must still be suspended at timeout")

            let unrelated = manager.createEphemeralWorkspace(name: "Unrelated workspace", repoPaths: [])
            let unrelatedSwitch = await manager.switchWorkspace(to: unrelated, saveState: false)
            XCTAssertTrue(unrelatedSwitch.didSwitch, "The timed-out delete must release the window for a new switch")

            let retry = await manager.deleteWorkspacesAsync(
                workspaceIDs: [target.id],
                closeOpenWorkspaces: true
            )
            XCTAssertEqual(retry.deletedWorkspaceIDs, [target.id])

            await gate.open()
            let deletion = await deletionTask.value
            XCTAssertTrue(deletion.deletedWorkspaceIDs.isEmpty)
            XCTAssertTrue(deletion.skippedReasonsByWorkspaceID[target.id]?.contains("timeout") == true)
            await fulfillment(of: [sessions.cancellationFinished], timeout: 2)
            XCTAssertEqual(manager.activeWorkspaceID, unrelated.id)
            let authoritativeAfter = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(authoritativeAfter.workspaces.contains {
                $0.document.workspaceID == target.id
            })
        }

        func testConfirmedDeleteTimeoutCannotPublishALateFallbackWorkspace() async throws {
            let target = WorkspaceModel(
                name: "Late fallback target",
                repoPaths: [storageRoot.appendingPathComponent("late-fallback-repo").path]
            )
            try writeWorkspace(target)
            try writeLegacyIndex([target])

            let runtime = try await makeRuntime(profileIdentifier: "workspace-delete-late-fallback")
            defer { Task { _ = await runtime.shutdown() } }

            let coordinator = WorkspaceActivityCoordinator(confirmedDeletionTimeout: .milliseconds(100))
            let manager = makeManager(
                windowID: -760,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -760
                ),
                workspaceActivityCoordinator: coordinator
            )
            await manager.awaitInitialized()
            let targetInManager = try XCTUnwrap(manager.workspace(withID: target.id))
            let activation = await manager.switchWorkspace(to: targetInManager, saveState: false)
            XCTAssertTrue(activation.didSwitch, "Expected the deletion target to be active")
            let fallback = manager.getOrCreateSystemWorkspace()

            var publishedWorkspaceIDs: [UUID] = []
            let listenerToken = manager.addWorkspaceDidSwitchListener(label: "late-fallback-test") { workspace in
                if let workspace {
                    publishedWorkspaceIDs.append(workspace.id)
                }
            }
            defer { manager.removeWorkspaceDidSwitchListener(listenerToken) }

            let fallbackLoadStarted = expectation(description: "fallback reached publication gate")
            let fallbackSwitchFinished = expectation(description: "late fallback operation finished")
            let gate = WorkspaceDeleteSuspensionGate()
            manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting { workspaceID in
                guard workspaceID == fallback.id else { return }
                fallbackLoadStarted.fulfill()
                await gate.wait()
            }
            manager.setWorkspaceSwitchDidFinishHandlerForTesting { _ in
                fallbackSwitchFinished.fulfill()
            }

            let deletionFinished = expectation(description: "confirmed deletion returns after fallback timeout")
            let deletionTask = Task {
                defer { deletionFinished.fulfill() }
                return await manager.deleteWorkspacesAsync(
                    workspaceIDs: [target.id],
                    closeOpenWorkspaces: true
                )
            }
            await fulfillment(of: [fallbackLoadStarted, deletionFinished], timeout: 2)
            let deletion = await deletionTask.value
            XCTAssertTrue(deletion.deletedWorkspaceIDs.isEmpty, "\(deletion)")
            XCTAssertTrue(
                deletion.skippedReasonsByWorkspaceID[target.id]?.contains("timeout") == true,
                "Expected the fallback switch to time out, got \(deletion)"
            )
            XCTAssertEqual(manager.activeWorkspaceID, target.id)

            await gate.open()
            await fulfillment(of: [fallbackSwitchFinished], timeout: 2)
            manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting(nil)
            manager.setWorkspaceSwitchDidFinishHandlerForTesting(nil)

            XCTAssertEqual(manager.activeWorkspaceID, target.id)
            XCTAssertFalse(
                publishedWorkspaceIDs.contains(fallback.id),
                "A timed-out deletion must not publish a late fallback activation"
            )
            let authoritativeAfter = await runtime.workspaceStore.snapshot()
            XCTAssertTrue(authoritativeAfter.workspaces.contains {
                $0.document.workspaceID == target.id
            })
        }

        func testConfirmedDeleteReturnsRetryableBusyForAnAlreadyRunningSwitch() async throws {
            let previous = WorkspaceModel(
                name: "Previous workspace",
                repoPaths: [storageRoot.appendingPathComponent("previous-repo").path]
            )
            let target = WorkspaceModel(
                name: "Cancelled switch target",
                repoPaths: [storageRoot.appendingPathComponent("cancelled-switch-repo").path]
            )
            try writeWorkspace(previous)
            try writeWorkspace(target)
            try writeLegacyIndex([previous, target])

            let runtime = try await makeRuntime(profileIdentifier: "workspace-delete-cancelled-switch")
            defer { Task { _ = await runtime.shutdown() } }

            let coordinator = WorkspaceActivityCoordinator(confirmedDeletionTimeout: .milliseconds(100))
            let manager = makeManager(
                windowID: -759,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -759
                ),
                workspaceActivityCoordinator: coordinator
            )
            await manager.awaitInitialized()
            let previousInManager = try XCTUnwrap(manager.workspace(withID: previous.id))
            let targetInManager = try XCTUnwrap(manager.workspace(withID: target.id))
            let previousActivation = await manager.switchWorkspace(to: previousInManager, saveState: false)
            XCTAssertTrue(previousActivation.didSwitch, "Expected the previous workspace to be active")

            let targetPublicationStarted = expectation(description: "target switch reached publication gate")
            let targetPublicationGate = WorkspaceDeleteSuspensionGate()
            manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting { workspaceID in
                guard workspaceID == target.id else { return }
                targetPublicationStarted.fulfill()
                await targetPublicationGate.wait()
            }

            let switchTask = Task {
                await manager.switchWorkspace(to: targetInManager, saveState: false)
            }
            await fulfillment(of: [targetPublicationStarted], timeout: 2)

            let deletionFinished = expectation(description: "deletion returns while switch is active")
            let deletionTask = Task {
                defer { deletionFinished.fulfill() }
                return await manager.deleteWorkspacesAsync(
                    workspaceIDs: [target.id],
                    closeOpenWorkspaces: true
                )
            }
            await fulfillment(of: [deletionFinished], timeout: 2)
            let deletion = await deletionTask.value
            XCTAssertTrue(deletion.deletedWorkspaceIDs.isEmpty, "\(deletion)")
            XCTAssertTrue(
                deletion.skippedReasonsByWorkspaceID[target.id]?.contains("in progress") == true,
                "Expected a retryable busy result, got \(deletion)"
            )
            XCTAssertEqual(manager.activeWorkspaceID, previous.id)
            XCTAssertEqual(manager.activeWorkspaceSwitch?.targetWorkspaceID, target.id)

            await targetPublicationGate.open()
            let switchResult = await switchTask.value
            manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting(nil)

            XCTAssertTrue(switchResult.didSwitch, "Deletion must not cancel the user's switch")
            XCTAssertEqual(manager.activeWorkspaceID, target.id)
            let authoritativeAfter = await runtime.workspaceStore.snapshot()
            XCTAssertTrue(authoritativeAfter.workspaces.contains {
                $0.document.workspaceID == target.id
            })
        }

        func testDirectSaveRejectsDeletionObservedAfterAuthoritySnapshot() async throws {
            let target = WorkspaceModel(
                name: "Stale rename target",
                repoPaths: [storageRoot.appendingPathComponent("stale-rename-repo").path]
            )
            try writeWorkspace(target)
            try writeLegacyIndex([target])

            let runtime = try await makeRuntime(profileIdentifier: "workspace-stale-direct-save")
            defer { Task { _ = await runtime.shutdown() } }

            let manager = makeManager(
                windowID: -761,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -761
                )
            )
            await manager.awaitInitialized()
            let targetInManager = try XCTUnwrap(manager.workspace(withID: target.id))
            var staleRename = targetInManager
            staleRename.name = "Stale rename after deletion"

            let snapshotCaptured = expectation(description: "direct save observed the authority snapshot")
            let gate = WorkspaceDeleteSuspensionGate()
            manager.setWorkspaceSaveAfterAuthoritySnapshotHandlerForTesting { workspaceID in
                guard workspaceID == target.id else { return }
                snapshotCaptured.fulfill()
                await gate.wait()
            }
            let saveTask = Task { () -> String? in
                do {
                    _ = try await manager.saveWorkspaceToFileAsync(
                        staleRename,
                        source: .renameWorkspace
                    )
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            await fulfillment(of: [snapshotCaptured], timeout: 2)

            let deletion = await manager.deleteWorkspacesAsync(workspaceIDs: [target.id])
            XCTAssertEqual(deletion.deletedWorkspaceIDs, [target.id])

            await gate.open()
            let saveError = await saveTask.value
            manager.setWorkspaceSaveAfterAuthoritySnapshotHandlerForTesting(nil)
            XCTAssertEqual(saveError, "The workspace is no longer available for persistence.")

            let authoritativeAfter = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(authoritativeAfter.workspaces.contains {
                $0.document.workspaceID == target.id
            })
            XCTAssertFalse(FileManager.default.fileExists(atPath: manager.workspaceFileURL(for: staleRename).path))
        }

        func testActivationLeaseBlocksDeletionClaimUntilSwitchCompletes() async throws {
            let workspace = leakedFixtureWorkspace()
            try writeWorkspace(workspace)
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: workspace.repoPaths[0]),
                withIntermediateDirectories: true
            )
            try writeLegacyIndex([workspace])

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-activation-lease-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let coordinator = WorkspaceActivityCoordinator()
            let activationManager = makeManager(
                windowID: -768,
                workspaceActivityCoordinator: coordinator
            )
            let deletionManager = makeManager(
                windowID: -769,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -769
                ),
                workspaceActivityCoordinator: coordinator
            )
            await activationManager.awaitInitialized()
            await deletionManager.awaitInitialized()

            let activationLeaseAcquired = expectation(description: "activation lease acquired")
            let gate = WorkspaceDeleteSuspensionGate()
            var didSuspend = false
            activationManager.setWorkspaceActivationLeaseDidAcquireHandlerForTesting { workspaceID in
                guard workspaceID == workspace.id, !didSuspend else { return }
                didSuspend = true
                activationLeaseAcquired.fulfill()
                await gate.wait()
            }

            let activationTask = Task {
                await activationManager.switchWorkspace(to: workspace, saveState: false)
            }
            await fulfillment(of: [activationLeaseAcquired], timeout: 2)

            let deletion = await deletionManager.deleteWorkspacesAsync(
                workspaceIDs: [workspace.id],
                leakedTestFixtureWorkspaceIDs: [workspace.id]
            )
            XCTAssertEqual(
                deletion.skippedReasonsByWorkspaceID[workspace.id],
                "Workspace is being activated in another window."
            )
            XCTAssertTrue(deletion.deletedWorkspaceIDs.isEmpty)
            let authoritativeDuringActivation = await runtime.workspaceStore.snapshot()
            XCTAssertTrue(authoritativeDuringActivation.workspaces.contains {
                $0.document.workspaceID == workspace.id
            })

            await gate.open()
            let activation = await activationTask.value
            activationManager.setWorkspaceActivationLeaseDidAcquireHandlerForTesting(nil)
            XCTAssertTrue(activation.didSwitch)
        }

        func testDeletionLeaseRejectsActivationOfLaterBatchWorkspaceWhileFirstDeleteIsSuspended() async throws {
            let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let laterID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            let first = leakedFixtureWorkspace(id: firstID)
            let later = leakedFixtureWorkspace(id: laterID)
            for workspace in [first, later] {
                try writeWorkspace(workspace)
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: workspace.repoPaths[0]),
                    withIntermediateDirectories: true
                )
            }
            try writeLegacyIndex([first, later])

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-delete-lease-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let coordinator = WorkspaceActivityCoordinator()
            let deletionManager = makeManager(
                windowID: -765,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -765
                ),
                workspaceActivityCoordinator: coordinator
            )
            let activationManager = makeManager(
                windowID: -766,
                workspaceActivityCoordinator: coordinator
            )
            await deletionManager.awaitInitialized()
            await activationManager.awaitInitialized()

            let firstDeleteStarted = expectation(description: "first deletion suspended")
            let gate = WorkspaceDeleteSuspensionGate()
            deletionManager.setWorkspaceDeleteWillExecuteHandlerForTesting { workspaceID in
                guard workspaceID == firstID else { return }
                firstDeleteStarted.fulfill()
                await gate.wait()
            }

            let deletionTask = Task {
                await deletionManager.deleteWorkspacesAsync(
                    workspaceIDs: [firstID, laterID],
                    leakedTestFixtureWorkspaceIDs: [firstID, laterID]
                )
            }
            await fulfillment(of: [firstDeleteStarted], timeout: 2)

            let activation = await activationManager.switchWorkspace(to: later, saveState: false)
            XCTAssertFalse(activation.didSwitch)
            if case let .blocked(message) = activation {
                XCTAssertTrue(message.contains("being deleted"), message)
            } else {
                XCTFail("Expected deletion lease to reject activation, got \(activation)")
            }

            await gate.open()
            let result = await deletionTask.value
            deletionManager.setWorkspaceDeleteWillExecuteHandlerForTesting(nil)

            XCTAssertEqual(Set(result.deletedWorkspaceIDs), [firstID, laterID])
            XCTAssertTrue(result.skippedReasonsByWorkspaceID.isEmpty)
            let authoritativeAfter = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(authoritativeAfter.workspaces.contains { $0.document.workspaceID == laterID })
        }

        func testBulkDeleteRefreshesWorkspaceRevisionAfterSuccessfulDeletion() async throws {
            let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let laterID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            let first = WorkspaceModel(id: firstID, name: "First", repoPaths: ["/tmp/first"])
            let later = WorkspaceModel(id: laterID, name: "Later", repoPaths: ["/tmp/later"])
            for workspace in [first, later] {
                try writeWorkspace(workspace)
            }
            try writeLegacyIndex([first, later])

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-delete-refresh-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -770)
            let manager = makeManager(
                windowID: -770,
                domainWorkspaceAuthorityClient: client
            )
            await manager.awaitInitialized()

            let initialLaterSnapshot = await client.canonicalWorkspaceSnapshot(laterID)
            let initialLater = try XCTUnwrap(initialLaterSnapshot)
            var revisedLater = later
            revisedLater.name = "Later Revised"
            var revisionOutcome: DomainCommandOutcome?
            var revisionError: Error?
            manager.setWorkspaceDeleteWillExecuteHandlerForTesting { workspaceID in
                guard workspaceID == firstID else { return }
                do {
                    revisionOutcome = try await client.replaceWorking(
                        revisedLater,
                        fileURL: initialLater.document.fileURL,
                        expectedWorkspaceRevision: initialLater.revisions.workingRevision
                    )
                } catch {
                    revisionError = error
                }
            }

            let result = await manager.deleteWorkspacesAsync(workspaceIDs: [firstID, laterID])
            manager.setWorkspaceDeleteWillExecuteHandlerForTesting(nil)

            XCTAssertNil(revisionError)
            XCTAssertEqual(revisionOutcome?.disposition, .applied)
            XCTAssertEqual(Set(result.deletedWorkspaceIDs), [firstID, laterID])
            XCTAssertTrue(result.failedReasonsByWorkspaceID.isEmpty)
        }

        private func leakedFixtureWorkspace(id: UUID = UUID()) -> WorkspaceModel {
            WorkspaceModel(
                id: id,
                name: "Agent Mode Chat Switch \(UUID().uuidString.prefix(8))",
                repoPaths: [
                    storageRoot
                        .appendingPathComponent("AgentModeChatSwitchActivationTests-\(UUID().uuidString)", isDirectory: true)
                        .appendingPathComponent("repo", isDirectory: true)
                        .path
                ],
                ephemeralFlag: true
            )
        }

        private func persistentReadFixtureWorkspace(id: UUID = UUID()) -> WorkspaceModel {
            WorkspaceModel(
                id: id,
                name: "Persistent Agent Mode MCP Read",
                repoPaths: [
                    storageRoot
                        .appendingPathComponent("PersistentAgentModeMCPReadFileConnectionTests", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        .path
                ],
                ephemeralFlag: true
            )
        }

        private func makeRuntime(profileIdentifier: String) async throws -> MCPDomainRuntime {
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "\(profileIdentifier)-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            return runtime
        }

        private func writeWorkspace(_ workspace: WorkspaceModel) throws {
            let fileURL = workspaceFileURL(for: workspace)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(workspace).write(to: fileURL, options: .atomic)
        }

        private func workspaceFileURL(for workspace: WorkspaceModel) -> URL {
            storageRoot
                .appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(name: workspace.name, id: workspace.id),
                    isDirectory: true
                )
                .appendingPathComponent("workspace.json")
        }

        private func writeLegacyIndex(_ workspaces: [WorkspaceModel]) throws {
            let entries = workspaces.map {
                WorkspaceIndexEntry(
                    id: $0.id,
                    name: $0.name,
                    customStoragePath: $0.customStoragePath,
                    isSystemWorkspace: $0.isSystemWorkspace,
                    isHiddenInMenus: $0.isHiddenInMenus
                )
            }
            try JSONEncoder().encode(entries).write(
                to: storageRoot.appendingPathComponent("workspacesIndex.json"),
                options: .atomic
            )
        }

        private func makeManager(
            windowID: Int,
            domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient? = nil,
            workspaceActivityCoordinator: WorkspaceActivityCoordinator? = nil
        ) -> WorkspaceManagerViewModel {
            let keyManager = KeyManager(
                secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
            )
            let aiQueriesService = AIQueriesService(keyManager: keyManager)
            let fileManager = WorkspaceFilesViewModel()
            let apiSettings = APISettingsViewModel(
                aiQueriesService: aiQueriesService,
                keyManager: keyManager,
                loadStoredDataOnInit: false
            )
            let prompt = PromptViewModel(
                fileManager: fileManager,
                apiSettingsViewModel: apiSettings,
                windowID: windowID,
                settingsManager: WindowSettingsManager(windowID: windowID)
            )
            let manager = WorkspaceManagerViewModel(
                fileManager: fileManager,
                promptViewModel: prompt,
                domainWorkspaceAuthorityClient: domainWorkspaceAuthorityClient,
                workspaceActivityCoordinator: workspaceActivityCoordinator
                    ?? WindowStatesManager.shared.workspaceActivityCoordinator,
                performInitialWorkspaceActivation: false
            )
            managers.append(manager)
            return manager
        }
    }

    @MainActor
    private final class DeletionSessionProvider: WorkspaceSwitchSessionProvider {
        var wasCancelled = false
        func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
            wasCancelled ? [] : [.init(id: "test-agent", count: 1, singularLabel: "agent", pluralLabel: "agents")]
        }

        func cancelSwitchSessions() async {
            wasCancelled = true
        }
    }

    @MainActor
    private final class GatedDeletionSessionProvider: WorkspaceSwitchSessionProvider {
        let cancellationStarted = XCTestExpectation(description: "session cancellation started")
        let cancellationFinished = XCTestExpectation(description: "session cancellation finished")
        private let gate: WorkspaceDeleteSuspensionGate
        private(set) var wasCancelled = false

        init(gate: WorkspaceDeleteSuspensionGate) {
            self.gate = gate
        }

        func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
            wasCancelled
                ? []
                : [.init(id: "gated-agent", count: 1, singularLabel: "agent", pluralLabel: "agents")]
        }

        func cancelSwitchSessions() async {
            cancellationStarted.fulfill()
            await gate.wait()
            wasCancelled = true
            cancellationFinished.fulfill()
        }
    }

    private actor WorkspaceDeleteSuspensionGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }
#endif
