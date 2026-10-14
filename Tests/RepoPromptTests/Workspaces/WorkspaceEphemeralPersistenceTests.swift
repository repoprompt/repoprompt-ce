import Combine
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFileSystem
import RepoPromptSecureStorage
import RepoPromptSettingsCore
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
            await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
        }

        override func tearDown() async throws {
            managers.forEach { $0.prepareForWindowClose() }
            managers.removeAll()
            await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
            try? FileManager.default.removeItem(at: storageRoot)
            if let originalStoragePath {
                UserDefaults.standard.set(originalStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
            }
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try await super.tearDown()
        }

        func testPersistedInitializationBuildsLifecycleIndexBeforeAnyModelMutation() throws {
            let sessionID = UUID()
            let sharedTab = ComposeTabState(name: "Shared binding", activeAgentSessionID: sessionID)
            let laterTab = ComposeTabState(name: "Later exact binding", activeAgentSessionID: sessionID)
            var otherBinding = laterTab
            otherBinding.activeAgentSessionID = UUID()
            let first = WorkspaceModel(
                name: "First persisted", repoPaths: [],
                composeTabs: [otherBinding, sharedTab], activeComposeTabID: sharedTab.id
            )
            let second = WorkspaceModel(
                name: "Second persisted", repoPaths: [],
                composeTabs: [laterTab, sharedTab], activeComposeTabID: laterTab.id
            )
            try writeWorkspace(first)
            try writeWorkspace(second)
            try writeLegacyIndex([first, second])

            // Read immediately after the real initializer's direct `workspaces = loaded`, without
            // activation, an await, or any post-init workspace assignment repairing the indexes.
            let manager = makeManager(windowID: -795)
            XCTAssertEqual(manager.workspaces.map(\.id), [first.id, second.id])
            XCTAssertNil(manager.activeWorkspaceID)
            manager.test_lifecycleBindingTabValidationCount = 0
            for tab in first.composeTabs + second.composeTabs {
                let expectedSessionID = try XCTUnwrap(tab.activeAgentSessionID)
                let scan = manager.workspaces.first { workspace in
                    workspace.composeTabs.contains {
                        $0.id == tab.id && $0.activeAgentSessionID == expectedSessionID
                    }
                }
                XCTAssertEqual(manager.agentSessionLifecycleWorkspaceID(
                    tabID: tab.id, sessionID: expectedSessionID
                ), try XCTUnwrap(scan).id)
            }
            XCTAssertEqual(manager.test_lifecycleBindingTabValidationCount, 4)
            XCTAssertNil(manager.agentSessionLifecycleWorkspaceID(tabID: laterTab.id, sessionID: UUID()))
            // Selecting only changes activeWorkspaceID; it never rebuilds metadata indexes.
            // Query before any await or workspaces/tab mutation can repair an initialization gap.
            manager.activeWorkspace = first
            XCTAssertEqual(manager.agentSessionLifecycleTabs(workspaceID: first.id, sessionID: sessionID), [sharedTab])
            manager.activeWorkspace = second
            XCTAssertEqual(manager.agentSessionLifecycleTabs(workspaceID: second.id, sessionID: sessionID), [laterTab, sharedTab])
            XCTAssertEqual(manager.workspaces.map(\.id), [first.id, second.id])
        }

        func testDirectTabSwitchPreservesDraftAndPersistsSelectionWithoutUnrelatedCarrierRebuilds() async throws {
            for unrelatedCount in [0, 4000] {
                var source = ComposeTabState(name: "Source", activeAgentSessionID: UUID())
                source.promptText = "Previously saved source draft"
                var target = ComposeTabState(name: "Target", activeAgentSessionID: UUID())
                target.promptText = "Target draft"
                let seed = WorkspaceModel(
                    dateModified: .distantPast, name: "Direct switch \(unrelatedCount)", repoPaths: [],
                    composeTabs: [source, target], activeComposeTabID: source.id
                )
                try writeWorkspace(seed)
                try writeLegacyIndex([seed])
                let manager = makeManager(windowID: -17840 - unrelatedCount)
                await manager.awaitInitialized()
                let workspace = try XCTUnwrap(manager.workspace(withID: seed.id))
                let unrelated = WorkspaceModel(
                    name: "Unrelated retained carriers", repoPaths: [], ephemeralFlag: true,
                    composeTabs: (0 ..< unrelatedCount).map {
                        ComposeTabState(name: "Unrelated \($0)", activeAgentSessionID: UUID())
                    }
                )
                manager.workspaces.append(unrelated)
                manager.activeWorkspace = workspace
                let prompt = manager.promptViewModel
                prompt.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
                prompt.promptText = "Unsaved source draft"
                let dirtyVersion = manager.debugStateVersionForWorkspace(seed.id)
                let rebuilds = manager.test_sessionCarrierIndexRebuildCount
                manager.test_sessionCarrierIndexMaintenanceRowsVisited = 0

                // Exercise the real direct selection and heavy-apply completion. This manager-only
                // fixture intentionally excludes Oracle's separate first-Chat-session creation.
                await prompt.switchComposeTab(target.id)
                let switched = try XCTUnwrap(manager.workspace(withID: seed.id))
                XCTAssertEqual(manager.activeWorkspaceID, seed.id)
                XCTAssertEqual(switched.activeComposeTabID, target.id)
                XCTAssertEqual(prompt.activeComposeTabID, target.id)
                XCTAssertEqual(prompt.promptText, target.promptText)
                XCTAssertEqual(switched.composeTabs.first { $0.id == source.id }?.promptText, "Unsaved source draft")
                XCTAssertGreaterThan(switched.dateModified, workspace.dateModified)
                XCTAssertGreaterThan(manager.debugStateVersionForWorkspace(seed.id), dirtyVersion)
                XCTAssertEqual(manager.test_sessionCarrierIndexRebuildCount, rebuilds)
                XCTAssertEqual(manager.test_sessionCarrierIndexMaintenanceRowsVisited, 0)
                XCTAssertEqual(manager.workspace(withID: unrelated.id), unrelated)

                // Join only the save already scheduled by switch completion; do not issue a
                // compensating poll/save. The file is the direct switch's actual durable result.
                await manager.debugDrainScheduledSaves()
                // The scheduled save enqueues physical I/O. Join that existing write without
                // submitting another workspace payload or triggering another UI capture.
                await manager.workspaceDiskWriter.flush(url: workspaceFileURL(for: seed))
                let disk = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: workspaceFileURL(for: seed)))
                XCTAssertEqual(disk.activeComposeTabID, target.id)
                XCTAssertEqual(disk.composeTabs.first { $0.id == source.id }?.promptText, "Unsaved source draft")
                XCTAssertEqual(disk.composeTabs.first { $0.id == target.id }?.promptText, target.promptText)
                XCTAssertGreaterThan(disk.dateModified, workspace.dateModified)
                XCTAssertEqual(manager.test_sessionCarrierIndexRebuildCount, rebuilds)
                XCTAssertEqual(manager.test_sessionCarrierIndexMaintenanceRowsVisited, 0)
                manager.prepareForWindowClose()
            }
        }

        func testDirectTabSwitchDoesNotApplyItsTargetAfterSynchronousWorkspaceSelectionChange() async {
            let source = ComposeTabState(name: "Source")
            var target = ComposeTabState(name: "Target")
            target.promptText = "Target must not reach the newly selected workspace"
            let workspace = WorkspaceModel(
                name: "Original owner", repoPaths: [], ephemeralFlag: true,
                composeTabs: [source, target], activeComposeTabID: source.id
            )
            var replacementTab = ComposeTabState(name: "New owner")
            replacementTab.promptText = "New owner draft"
            let replacement = WorkspaceModel(
                name: "Reentrant owner", repoPaths: [], ephemeralFlag: true,
                composeTabs: [replacementTab], activeComposeTabID: replacementTab.id
            )
            let manager = makeManager(windowID: -17839)
            await manager.awaitInitialized()
            manager.workspaces = [workspace, replacement]
            manager.activeWorkspace = workspace
            let prompt = manager.promptViewModel
            prompt.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
            var interrupted = false
            let subscription = manager.$workspaces.sink { models in
                guard !interrupted,
                      models.first(where: { $0.id == workspace.id })?.activeComposeTabID == target.id
                else { return }
                interrupted = true
                manager.activeWorkspace = replacement
                prompt.loadComposeTabsFromWorkspace(replacement, syncPromptText: true)
            }
            defer { subscription.cancel() }
            await prompt.switchComposeTab(target.id)
            XCTAssertTrue(interrupted)
            XCTAssertEqual(manager.activeWorkspaceID, replacement.id)
            XCTAssertEqual(prompt.activeComposeTabID, replacementTab.id)
            XCTAssertEqual(prompt.promptText, replacementTab.promptText)
            XCTAssertFalse(prompt.isSwitchingComposeTab)
            XCTAssertEqual(manager.workspace(withID: replacement.id), replacement)
        }

        func testRefusedDirectTabSwitchPreservesAnOlderApplyAndDoesNotSelectARemovedTarget() async throws {
            for reselectFirst in [false, true] {
                let source = ComposeTabState(name: "Source")
                let first = ComposeTabState(name: "First target")
                let removed = ComposeTabState(name: "Removed second target")
                let workspace = WorkspaceModel(
                    name: "Interrupted switch owner", repoPaths: [], ephemeralFlag: true,
                    composeTabs: [source, first, removed], activeComposeTabID: source.id
                )
                let manager = makeManager(windowID: reselectFirst ? -17837 : -17838)
                await manager.awaitInitialized()
                manager.workspaces = [workspace]
                manager.activeWorkspace = workspace
                let prompt = manager.promptViewModel
                prompt.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
                let entered = expectation(description: "older switch reached its actual fast-apply boundary")
                let gate = WorkspaceDeleteSuspensionGate()
                manager.setComposeTabFastStateDidApplyHandlerForTesting { tabID in
                    guard tabID == first.id else { return }
                    entered.fulfill()
                    await gate.wait()
                }
                let removedID = reselectFirst ? first.id : removed.id
                let olderSwitch = Task { await prompt.switchComposeTab(first.id) }
                do {
                    try await awaitSaveCheckpoint(entered)
                    XCTAssertTrue(prompt.isSwitchingComposeTab)
                    let token = NotificationCenter.default.addObserver(forName: .willSwitchComposeTab, object: nil, queue: nil) { notification in
                        MainActor.assumeIsolated {
                            guard notification.userInfo?["windowID"] as? Int == prompt.windowID,
                                  let current = manager.composeTabCarrierWorkspace(workspaceID: workspace.id)
                            else { return }
                            _ = manager.replaceComposeTabCarriers(
                                workspaceID: workspace.id,
                                composeTabs: current.workspace.composeTabs.filter { $0.id != removedID },
                                stashedTabs: current.workspace.stashedTabs
                            )
                        }
                    }
                    defer { NotificationCenter.default.removeObserver(token) }
                    await prompt.switchComposeTab(removedID)
                    XCTAssertFalse(try XCTUnwrap(manager.workspace(withID: workspace.id)).composeTabs.contains { $0.id == removedID })
                    XCTAssertEqual(manager.workspace(withID: workspace.id)?.activeComposeTabID, first.id)
                    XCTAssertEqual(prompt.activeComposeTabID, first.id)
                    XCTAssertTrue(prompt.isSwitchingComposeTab, "the older switch still owns an in-flight apply")
                    manager.setComposeTabFastStateDidApplyHandlerForTesting(nil)
                    await gate.open()
                    await olderSwitch.value
                    XCTAssertFalse(prompt.isSwitchingComposeTab)
                } catch {
                    manager.setComposeTabFastStateDidApplyHandlerForTesting(nil)
                    await gate.open()
                    await olderSwitch.value
                    throw error
                }
            }
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

        func testLegacyLastUsedDecodeUsesPersistedModificationDateDeterministically() throws {
            let workspaceID = UUID()
            var object: [String: Any] = [
                "id": workspaceID.uuidString,
                "name": "Legacy",
                "repoPaths": [],
                "dateModified": 0
            ]

            var decoded = try decodeWorkspace(object)
            XCTAssertEqual(decoded.lastUsed, Date(timeIntervalSinceReferenceDate: 0))

            object["dateModified"] = 1
            object["lastUsed"] = true
            decoded = try decodeWorkspace(object)
            XCTAssertEqual(decoded.lastUsed, Date(timeIntervalSinceReferenceDate: 1))

            object["lastUsed"] = 0
            decoded = try decodeWorkspace(object)
            XCTAssertEqual(decoded.lastUsed, Date(timeIntervalSinceReferenceDate: 0))

            object["dateModified"] = "invalid"
            object["lastUsed"] = "invalid"
            decoded = try decodeWorkspace(object)
            XCTAssertEqual(decoded.lastUsed, .distantPast)
        }

        private func decodeWorkspace(_ object: [String: Any]) throws -> WorkspaceModel {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try JSONDecoder().decode(WorkspaceModel.self, from: data)
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
            await WorkspaceDiskWriterComposition.processWriter.flush(url: url)
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

            // The gate makes the first deletion time out regardless of machine load.
            // The same coordinator must then have enough time for a real confirmed retry.
            let coordinator = WorkspaceActivityCoordinator(confirmedDeletionTimeout: .seconds(2))
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
            await fulfillment(of: [deletionFinished], timeout: 4)
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
            XCTAssertEqual(retry.deletedWorkspaceIDs, [created.id], "The timed-out claim must permit a confirmed retry: \(retry)")
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
            let saveTask = Task {
                () -> (
                    succeeded: Bool,
                    authorityOutcome: DomainCommandOutcome?,
                    workingCommitted: Bool,
                    localProjectionPresentAtFailure: Bool,
                    errorDescription: String?
                ) in
                do {
                    _ = try await manager.saveWorkspaceToFileAsync(
                        staleRename,
                        source: .renameWorkspace
                    )
                    return (true, nil, false, false, nil)
                } catch let error as DomainWorkspaceAuthorityOperationError {
                    return (
                        false,
                        error.outcome,
                        error.workingCommitted,
                        manager.workspace(withID: target.id) != nil,
                        nil
                    )
                } catch {
                    return (
                        false,
                        nil,
                        false,
                        manager.workspace(withID: target.id) != nil,
                        error.localizedDescription
                    )
                }
            }
            await fulfillment(of: [snapshotCaptured], timeout: 2)
            XCTAssertNotNil(
                manager.workspace(withID: target.id),
                "The save must retain its local projection while the authority snapshot is suspended."
            )

            let deletion = await manager.deleteWorkspacesAsync(workspaceIDs: [target.id])
            XCTAssertEqual(deletion.deletedWorkspaceIDs, [target.id])

            await gate.open()
            let saveResult = await saveTask.value
            manager.setWorkspaceSaveAfterAuthoritySnapshotHandlerForTesting(nil)
            XCTAssertFalse(
                saveResult.succeeded,
                "The stale direct save unexpectedly succeeded after confirmed deletion."
            )
            if let saveOutcome = saveResult.authorityOutcome {
                XCTAssertEqual(saveOutcome.disposition, .invalid)
                XCTAssertEqual(saveOutcome.errorCode, .workspaceUnavailable)
                XCTAssertFalse(saveResult.workingCommitted)
                XCTAssertEqual(
                    WorkspacePersistenceFailureCategory.classify(domainErrorCode: saveOutcome.errorCode),
                    .workspaceChanged
                )
            } else {
                // WorkspaceDirectWriteError is file-private; its exact localized error is the
                // only observable signal for the local-projection guard.
                XCTAssertFalse(
                    saveResult.localProjectionPresentAtFailure,
                    "A local unavailable error must follow removal of the manager projection."
                )
                XCTAssertEqual(
                    saveResult.errorDescription,
                    "The workspace is no longer available for persistence."
                )
            }

            let authoritativeAfter = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(authoritativeAfter.workspaces.contains {
                $0.document.workspaceID == target.id
            })
            XCTAssertFalse(FileManager.default.fileExists(atPath: manager.workspaceFileURL(for: staleRename).path))
        }

        func testAwaitedAndScheduledSavesShareOwnerOrderingAndCancellationOnlyWithdrawsTheWaiter() async throws {
            for (label, publicFirst, cancelWaitingPublic) in [
                ("scheduled then awaited", false, false),
                ("awaited then scheduled", true, false),
                ("cancel awaited behind scheduled", false, true)
            ] {
                let commandEntered = expectation(description: "\(label): predecessor reached real authority command")
                let successorRegistered = expectation(description: "\(label): successor registered behind predecessor")
                let cancelledWaiterFinished = cancelWaitingPublic
                    ? expectation(description: "\(label): cancelled waiter completed while predecessor remains held")
                    : nil
                let commandGate = WorkspaceDeleteSuspensionGate()
                let commands = WorkspaceOrderedSaveCommands()
                try await withProjectionSaveFixture(configureClient: { client in
                    client.commandWillExecuteForTesting = { envelope in
                        guard case let .replaceWorkingDocument(document) = envelope.command else { return }
                        let submitted = try? JSONDecoder().decode(WorkspaceModel.self, from: document.documentBytes)
                        let pinned = submitted?.composeTabs.first?.isPinned
                        XCTAssertNotNil(pinned)
                        let position = await commands.record(pinned ?? false)
                        if position == 1 {
                            commandEntered.fulfill()
                            await commandGate.wait()
                            XCTAssertFalse(Task.isCancelled, "Cancelling an acknowledgement must not cancel its predecessor")
                        }
                    }
                }) { fixture in
                    let manager = fixture.manager
                    await fixture.bridge.stopAndJoinForTesting()
                    manager.activeWorkspace = try XCTUnwrap(manager.workspace(withID: fixture.workspace.id))
                    let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspace.id })
                    manager.workspaces[index].composeTabs[0].isPinned = true
                    manager.markWorkspaceDirty(workspaceID: fixture.workspace.id)
                    var firstPublic: Task<WorkspacePersistenceOutcome, Never>?
                    var secondPublic: Task<WorkspacePersistenceOutcome, Never>?
                    if publicFirst {
                        firstPublic = Task { await manager.pollAndSaveStateWithOutcomeAsync(workspaceID: fixture.workspace.id) }
                    } else {
                        // This public entry schedules an owning save without also arming
                        // poll capture's separate coalesced working-document publisher.
                        manager.updatePromptText("Scheduled predecessor")
                    }
                    do {
                        try await self.awaitSaveCheckpoint(commandEntered)
                        let beforeValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                        let before = try XCTUnwrap(beforeValue)
                        let beforeModel = try JSONDecoder().decode(WorkspaceModel.self, from: before.document.documentBytes)
                        XCTAssertFalse(beforeModel.composeTabs[0].isPinned, "The command gate precedes the real first write")

                        manager.workspaces[index].composeTabs[0].isPinned = false
                        manager.markWorkspaceDirty(workspaceID: fixture.workspace.id)
                        var predecessorsAtAdmission: Int?
                        manager.ownSaveDidRegisterHandlerForTesting = { workspaceID, predecessorCount in
                            guard workspaceID == fixture.workspace.id else { return }
                            predecessorsAtAdmission = predecessorCount
                            successorRegistered.fulfill()
                        }
                        if publicFirst {
                            manager.updatePromptText("Scheduled successor")
                        } else {
                            secondPublic = Task {
                                defer { cancelledWaiterFinished?.fulfill() }
                                return await manager.pollAndSaveStateWithOutcomeAsync(workspaceID: fixture.workspace.id)
                            }
                        }
                        try await self.awaitSaveCheckpoint(successorRegistered)
                        manager.ownSaveDidRegisterHandlerForTesting = nil
                        XCTAssertEqual(predecessorsAtAdmission, 1, "The actual successor admission must join the held owning save")
                        let heldCommands = await commands.pinnedValues
                        XCTAssertEqual(heldCommands, [true], "No successor authority command may bypass its predecessor")
                        let stillHeldValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                        let stillHeld = try XCTUnwrap(stillHeldValue)
                        XCTAssertEqual(stillHeld.revisions, before.revisions)
                        XCTAssertEqual(stillHeld.document.contentDigest, before.document.contentDigest)

                        if cancelWaitingPublic {
                            let waiter = try XCTUnwrap(secondPublic)
                            waiter.cancel()
                            try await self.awaitSaveCheckpoint(XCTUnwrap(cancelledWaiterFinished))
                            let cancelled = await waiter.value
                            XCTAssertFalse(cancelled.acceptedForLifecycleAdmission)
                            let commandsAfterCancellation = await commands.pinnedValues
                            XCTAssertEqual(commandsAfterCancellation, [true])
                        }
                        await commandGate.open()
                        if let firstPublic {
                            let first = await firstPublic.value
                            XCTAssertTrue(first.acceptedForLifecycleAdmission, "\(label): \(first)")
                        }
                        if let secondPublic, !cancelWaitingPublic {
                            let second = await secondPublic.value
                            XCTAssertTrue(second.acceptedForLifecycleAdmission, "\(label): \(second)")
                        }
                        // This joins the scheduled half of the test, not a compensating save.
                        await manager.debugDrainScheduledSaves()
                        let finalValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                        let final = try XCTUnwrap(finalValue)
                        let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: final.document.documentBytes)
                        let disk = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: final.document.fileURL))
                        XCTAssertNil(final.revisions.dirtyRevision)
                        XCTAssertEqual(canonical.composeTabs[0].isPinned, cancelWaitingPublic)
                        XCTAssertEqual(disk.composeTabs[0].isPinned, cancelWaitingPublic)
                        XCTAssertFalse(
                            try XCTUnwrap(manager.workspace(withID: fixture.workspace.id)).composeTabs[0].isPinned,
                            "Cancellation keeps the unsaved local successor; it cannot roll back the user's edit"
                        )
                        let completedCommands = await commands.pinnedValues
                        XCTAssertEqual(completedCommands, cancelWaitingPublic ? [true] : [true, false])
                        try await self.assertCanonicalAndDiskRemain(final, in: fixture)
                    } catch {
                        manager.ownSaveDidRegisterHandlerForTesting = nil
                        await commandGate.open()
                        if let firstPublic { _ = await firstPublic.value }
                        if let secondPublic { _ = await secondPublic.value }
                        await manager.debugDrainScheduledSaves()
                        throw error
                    }
                }
            }
        }

        func testUnchangedPollCapturePreservesExpansionOrderTimestampsAndCanonicalRevision() async throws {
            try await withProjectionSaveFixture { fixture in
                let manager = fixture.manager
                let folders = ["First", "Second"].map { name in
                    let path = self.storageRoot.appendingPathComponent(name, isDirectory: true).path
                    return FolderViewModel(
                        folder: Folder(name: name, path: path, modificationDate: .distantPast),
                        rootPath: path,
                        isExpanded: true
                    )
                }
                folders.forEach { manager.fileManager.addRootFolder($0) }
                _ = try await self.establishActiveCaptureBaseline(fixture)
                let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspace.id })
                let liveOrder = manager.fileManager.snapshotExpandedFolderFullPaths()
                XCTAssertEqual(liveOrder.count, 2)
                manager.workspaces[index].composeTabs[0].expandedFolders = Array(liveOrder.reversed())
                manager.markWorkspaceDirty(workspaceID: fixture.workspace.id)
                let reorderSave = await manager.pollAndSaveStateWithOutcomeAsync()
                XCTAssertTrue(reorderSave.acceptedForLifecycleAdmission, "\(reorderSave)")
                let baseline = try XCTUnwrap(manager.workspace(withID: fixture.workspace.id))
                XCTAssertNotEqual(baseline.composeTabs[0].expandedFolders, liveOrder)
                let beforeValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(baseline.id)
                let before = try XCTUnwrap(beforeValue)
                XCTAssertNil(before.revisions.dirtyRevision)
                manager.resetWorkspaceSaveDiagnosticsForTesting()
                var captureEmissions = 0
                let observation = manager.composeTabSnapshotPublisher().sink { _ in captureEmissions += 1 }
                defer { observation.cancel() }

                // An equal observer emission can dirty the version without changing content.
                // Exercise the admitted timer path, not only its already-clean early return.
                manager.markWorkspaceDirty(workspaceID: baseline.id)
                await manager.debugPerformPollTimerSave()
                await manager.debugPerformPollTimerSave()

                XCTAssertEqual(manager.workspace(withID: baseline.id), baseline)
                XCTAssertEqual(captureEmissions, 0, "A no-op capture must not invalidate tab consumers")
                XCTAssertEqual(manager.workspaceSaveDiagnosticsForTesting(workspaceID: baseline.id).capturePublicationCount, 0)
                XCTAssertEqual(manager.debugLastSavedVersionForWorkspace(baseline.id), manager.debugStateVersionForWorkspace(baseline.id))
                XCTAssertFalse(manager.debugHasUnsavedWorkingPublication(baseline.id))
                try await self.assertCanonicalAndDiskRemain(before, in: fixture)

                // Membership changes remain real content, even though ordering-only changes do not.
                folders[0].isExpanded = false
                let changed = await manager.pollAndSaveStateWithOutcomeAsync()
                XCTAssertTrue(changed.acceptedForLifecycleAdmission, "\(changed)")
                let afterValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(baseline.id)
                let after = try XCTUnwrap(afterValue)
                let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: after.document.documentBytes)
                XCTAssertEqual(Set(canonical.composeTabs[0].expandedFolders), Set([folders[1].standardizedFullPath]))
                XCTAssertGreaterThan(canonical.composeTabs[0].lastModified, baseline.composeTabs[0].lastModified)
                XCTAssertGreaterThan(canonical.dateModified, baseline.dateModified)
                XCTAssertGreaterThan(after.revisions.workingRevision, before.revisions.workingRevision)
                XCTAssertNil(after.revisions.dirtyRevision)
                XCTAssertEqual(manager.workspaceSaveDiagnosticsForTesting(workspaceID: baseline.id).capturePublicationCount, 1)
                try await self.assertCanonicalAndDiskRemain(after, in: fixture)
            }
        }

        func testUnchangedCaptureStillPersistsAnEarlierStoredMetadataEdit() async throws {
            try await withProjectionSaveFixture { fixture in
                let manager = fixture.manager
                let baseline = try await self.establishActiveCaptureBaseline(fixture)
                let beforeValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(baseline.id)
                let before = try XCTUnwrap(beforeValue)
                let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == baseline.id })
                manager.workspaces[index].composeTabs[0].isPinned = true
                manager.markWorkspaceDirty(workspaceID: baseline.id)
                manager.resetWorkspaceSaveDiagnosticsForTesting()

                let result = await manager.pollAndSaveStateWithOutcomeAsync()

                XCTAssertTrue(result.acceptedForLifecycleAdmission, "\(result)")
                let afterValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(baseline.id)
                let after = try XCTUnwrap(afterValue)
                let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: after.document.documentBytes)
                XCTAssertTrue(canonical.composeTabs[0].isPinned)
                XCTAssertEqual(canonical.composeTabs[0].lastModified, baseline.composeTabs[0].lastModified)
                XCTAssertEqual(canonical.dateModified, baseline.dateModified)
                XCTAssertGreaterThan(after.revisions.workingRevision, before.revisions.workingRevision)
                XCTAssertNil(after.revisions.dirtyRevision)
                XCTAssertEqual(manager.workspaceSaveDiagnosticsForTesting(workspaceID: baseline.id).capturePublicationCount, 0)
                try await self.assertCanonicalAndDiskRemain(after, in: fixture)
            }
        }

        func testSaveCaptureIncludesBeforeSaveEditsBeforeDecidingItIsUnchanged() async throws {
            try await withProjectionSaveFixture { fixture in
                let manager = fixture.manager
                let baseline = try await self.establishActiveCaptureBaseline(fixture)
                var callbackCount = 0
                let listener = manager.addBeforeSaveListener { workspace in
                    XCTAssertEqual(workspace.id, baseline.id)
                    callbackCount += 1
                    manager.promptViewModel.promptText = "Pending editor text flushed by its owner"
                }
                defer { manager.removeBeforeSaveListener(listener) }
                manager.markWorkspaceDirty(workspaceID: baseline.id)
                manager.resetWorkspaceSaveDiagnosticsForTesting()

                let result = await manager.pollAndSaveStateWithOutcomeAsync()

                XCTAssertTrue(result.acceptedForLifecycleAdmission, "\(result)")
                XCTAssertEqual(callbackCount, 1)
                let afterValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(baseline.id)
                let after = try XCTUnwrap(afterValue)
                let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: after.document.documentBytes)
                XCTAssertEqual(canonical.composeTabs[0].promptText, "Pending editor text flushed by its owner")
                XCTAssertEqual(canonical.currentPromptText, canonical.composeTabs[0].promptText)
                XCTAssertGreaterThan(canonical.composeTabs[0].lastModified, baseline.composeTabs[0].lastModified)
                XCTAssertGreaterThan(canonical.dateModified, baseline.dateModified)
                XCTAssertNil(after.revisions.dirtyRevision)
                XCTAssertEqual(manager.workspaceSaveDiagnosticsForTesting(workspaceID: baseline.id).capturePublicationCount, 1)
                try await self.assertCanonicalAndDiskRemain(after, in: fixture)
            }
        }

        func testUnchangedRefreshProtectsSelectionAndReleasesOnlyItsOwnSnapshotSuspension() async throws {
            for preexistingSuspension in [false, true] {
                try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A"]) { fixture in
                    let manager = try XCTUnwrap(fixture.manager)
                    let workspace = try XCTUnwrap(manager.workspace(withID: fixture.workspace.id))
                    manager.promptViewModel.loadComposeTabsFromWorkspace(workspace)
                    let selectedPath = fixture.rootPaths[0] + "/README.md"
                    try await fixture.selectFixtureFiles([selectedPath])
                    let baseline = try XCTUnwrap(manager.workspace(withID: workspace.id))
                    let tabID = try XCTUnwrap(baseline.activeComposeTabID)
                    let savedSelection = try XCTUnwrap(manager.composeTabSnapshot(for: tabID)).selection
                    XCTAssertEqual(savedSelection.selectedPaths, [selectedPath])
                    XCTAssertEqual(fixture.files.snapshotSelection(), savedSelection)
                    manager.resetWorkspaceSaveDiagnosticsForTesting()
                    if preexistingSuspension {
                        manager.setSnapshotsSuspended(true, forTabID: tabID)
                    }
                    defer {
                        manager.rootReconciliationGateForTesting = nil
                        manager.setSnapshotsSuspended(false, forTabID: tabID)
                    }

                    let entered = XCTestExpectation(description: "refresh held after unchanged capture")
                    let gate = fixture.makeGate()
                    var held = false
                    manager.rootReconciliationGateForTesting = { event in
                        guard event.ticket.workspaceID == workspace.id,
                              event.phase == .beforeCompletion, !held else { return }
                        held = true
                        entered.fulfill()
                        await gate.wait()
                    }
                    let refresh = fixture.startOwnedTask {
                        await manager.refreshWorkspace(soft: true, for: baseline)
                    }
                    try await fixture.awaitGateEvent(entered)
                    XCTAssertTrue(manager.isRefreshing)
                    XCTAssertEqual(manager.workspaceSaveDiagnosticsForTesting(workspaceID: workspace.id).capturePublicationCount, 0)

                    // Exercise the real snapshot publisher with refresh's temporary empty UI state.
                    let selectedFile = try XCTUnwrap(fixture.files.selectedFiles.first { $0.fullPath == selectedPath })
                    fixture.files.setFileToggled(selectedFile, isToggled: false)
                    XCTAssertTrue(fixture.files.snapshotSelection().selectedPaths.isEmpty)
                    manager.publishActiveComposeTabSnapshot()
                    XCTAssertEqual(manager.composeTabSnapshot(for: tabID)?.selection, savedSelection)

                    if preexistingSuspension {
                        // Exit before nested restore owners run: this refresh must not release a
                        // suspension that the original owner installed before refresh began.
                        refresh.cancel()
                    }
                    gate.release()
                    try await fixture.perform("refresh releases its snapshot ownership") { await refresh.value }
                    XCTAssertFalse(manager.isRefreshing)
                    try await fixture.settle()
                    let after = try await fixture.capturePassive()
                    let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: after.canonical.document.documentBytes)
                    XCTAssertEqual(after.model.composeTabs.first { $0.id == tabID }?.selection, savedSelection)
                    XCTAssertEqual(canonical.composeTabs.first { $0.id == tabID }?.selection, savedSelection)
                    XCTAssertEqual(after.disk.composeTabs.first { $0.id == tabID }?.selection, savedSelection)

                    if !preexistingSuspension {
                        XCTAssertEqual(after.selection, savedSelection, "Completed refresh restores the selected file")
                        let restoredFile = try XCTUnwrap(fixture.files.selectedFiles.first { $0.fullPath == selectedPath })
                        fixture.files.setFileToggled(restoredFile, isToggled: false)
                    }
                    XCTAssertTrue(fixture.files.snapshotSelection().selectedPaths.isEmpty)
                    manager.publishActiveComposeTabSnapshot()
                    if preexistingSuspension {
                        XCTAssertEqual(manager.composeTabSnapshot(for: tabID)?.selection, savedSelection)
                        manager.setSnapshotsSuspended(false, forTabID: tabID)
                        manager.publishActiveComposeTabSnapshot()
                    }
                    XCTAssertEqual(manager.composeTabSnapshot(for: tabID)?.selection.selectedPaths, [])
                }
            }
        }

        private func establishActiveCaptureBaseline(_ fixture: ProjectionSaveFixture) async throws -> WorkspaceModel {
            await fixture.bridge.stopAndJoinForTesting()
            let manager = fixture.manager
            let workspace = try XCTUnwrap(manager.workspace(withID: fixture.workspace.id))
            manager.activeWorkspace = workspace
            manager.promptViewModel.loadComposeTabsFromWorkspace(workspace)
            manager.markWorkspaceDirty(workspaceID: workspace.id)
            let outcome = await manager.pollAndSaveStateWithOutcomeAsync()
            XCTAssertTrue(outcome.acceptedForLifecycleAdmission, "\(outcome)")
            XCTAssertFalse(manager.debugHasUnsavedWorkingPublication(workspace.id))
            return try XCTUnwrap(manager.workspace(withID: workspace.id))
        }

        func testCurrentModelSaveRecapturesRestoredProjectionWithoutDirtyVersionChange() async throws {
            try await assertSaveAfterRestoredProjection(explicitProposal: false)
        }

        func testOwnWholeModelReceiptsAuthorizeLaterEditsWithoutProjection() async throws {
            try await withProjectionSaveFixture { fixture in
                await fixture.bridge.stopAndJoinForTesting()
                let generation = fixture.bridge.projectionObservationStateForTesting.generation
                let manager = fixture.manager
                let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspace.id })
                let initial = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                var previousRevision = try XCTUnwrap(initial).revisions.workingRevision
                for (step, prompt) in ["Working one", "Saved two", "Working three", "Saved four"].enumerated() {
                    manager.workspaces[index].composeTabs[0].promptText = prompt
                    manager.markWorkspaceDirty(workspaceID: fixture.workspace.id)
                    let local = manager.workspaces[index]
                    if step.isMultiple(of: 2) {
                        await manager.debugPublishWorkingDocumentToDomainAuthority(local)
                    } else {
                        _ = try await manager.saveWorkspaceToFileAsync(local)
                    }
                    let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                    let current = try XCTUnwrap(snapshot)
                    let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: current.document.documentBytes)
                    XCTAssertGreaterThan(current.revisions.workingRevision, previousRevision)
                    XCTAssertEqual(canonical.composeTabs[0].promptText, prompt)
                    XCTAssertEqual(manager.debugDomainAuthorityBaseline(for: fixture.workspace.id).digest, current.document.contentDigest)
                    if !step.isMultiple(of: 2) {
                        XCTAssertNil(current.revisions.dirtyRevision)
                        try await self.assertCanonicalAndDiskRemain(current, in: fixture)
                    }
                    previousRevision = current.revisions.workingRevision
                }
                XCTAssertEqual(
                    fixture.bridge.projectionObservationStateForTesting.generation,
                    generation,
                    "Own write receipts must advance lineage without a presentation projection"
                )
            }
        }

        func testSaveJoinsCancelledOwnPublisherAndPersistsItsNewerLocalDescendant() async throws {
            let authorityCommitted = expectation(description: "predecessor committed before its response")
            let publisherCancelled = expectation(description: "ordinary save cancels and joins its predecessor")
            let responseGate = WorkspaceDeleteSuspensionGate()
            let counter = WorkspaceSavePreparationCounter()
            try await withProjectionSaveFixture(configureClient: { client in
                let store = client.store
                client.commandWillExecuteForTesting = { envelope in
                    guard case .replaceWorkingDocument = envelope.command else { return }
                    guard await counter.increment() == 1 else { return }
                    let outcome = await store.execute(envelope)
                    XCTAssertEqual(outcome.disposition, .applied)
                    await withTaskCancellationHandler {
                        authorityCommitted.fulfill()
                        await responseGate.wait()
                        XCTAssertTrue(Task.isCancelled, "The save must cancel its still-held predecessor")
                        let replay = await store.execute(envelope)
                        XCTAssertEqual(replay.disposition, .deduplicated)
                    } onCancel: {
                        publisherCancelled.fulfill()
                    }
                }
            }) { fixture in
                let manager = fixture.manager
                await fixture.bridge.stopAndJoinForTesting()
                let generation = fixture.bridge.projectionObservationStateForTesting.generation
                let baseline = manager.debugDomainAuthorityBaseline(for: fixture.workspace.id)
                let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspace.id })
                manager.workspaces[index].composeTabs[0].promptText = "Committed predecessor B"
                manager.markWorkspaceDirty(workspaceID: fixture.workspace.id)
                let submitted = manager.workspaces[index]
                let publication = Task { await manager.debugPublishWorkingDocumentToDomainAuthority(submitted) }
                var successorSave: Task<URL, Error>?
                do {
                    try await self.awaitSaveCheckpoint(authorityCommitted)
                    let committedValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                    let committed = try XCTUnwrap(committedValue)
                    let canonicalB = try JSONDecoder().decode(WorkspaceModel.self, from: committed.document.documentBytes)
                    XCTAssertEqual(canonicalB.composeTabs[0].promptText, submitted.composeTabs[0].promptText)
                    XCTAssertNotNil(committed.revisions.dirtyRevision)
                    XCTAssertGreaterThan(committed.revisions.workingRevision, try XCTUnwrap(baseline.revisions).workingRevision)
                    XCTAssertEqual(manager.debugDomainAuthorityBaseline(for: fixture.workspace.id).revisions, baseline.revisions)
                    XCTAssertEqual(manager.debugDomainAuthorityBaseline(for: fixture.workspace.id).digest, baseline.digest)

                    manager.workspaces[index].composeTabs[0].promptText = "Newer local descendant C"
                    manager.markWorkspaceDirty(workspaceID: fixture.workspace.id)
                    let newer = manager.workspaces[index]
                    manager.resetWorkspaceSaveDiagnosticsForTesting()
                    let save = Task { try await manager.saveWorkspaceToFileAsync(newer) }
                    successorSave = save
                    try await self.awaitSaveCheckpoint(publisherCancelled)
                    XCTAssertEqual(manager.debugDomainAuthorityBaseline(for: fixture.workspace.id).digest, baseline.digest)
                    await responseGate.open()
                    let url = try await save.value
                    await publication.value

                    let savedValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                    let saved = try XCTUnwrap(savedValue)
                    let canonicalC = try JSONDecoder().decode(WorkspaceModel.self, from: saved.document.documentBytes)
                    XCTAssertEqual(url, saved.document.fileURL)
                    XCTAssertEqual(canonicalC.composeTabs[0].promptText, newer.composeTabs[0].promptText)
                    XCTAssertEqual(manager.workspace(withID: fixture.workspace.id), newer)
                    XCTAssertGreaterThan(saved.revisions.workingRevision, committed.revisions.workingRevision)
                    XCTAssertNil(saved.revisions.dirtyRevision)
                    XCTAssertEqual(
                        manager.workspaceSaveDiagnosticsForTesting(workspaceID: fixture.workspace.id).attemptCount,
                        1,
                        "Joining the predecessor needs one recaptured serialization attempt"
                    )
                    XCTAssertFalse(fixture.bridge.hasActiveSubscriptionForTesting)
                    XCTAssertEqual(fixture.bridge.projectionObservationStateForTesting.generation, generation)
                    try await self.assertCanonicalAndDiskRemain(saved, in: fixture)
                } catch {
                    await responseGate.open()
                    await publication.value
                    if let successorSave { _ = await successorSave.result }
                    throw error
                }
            }
        }

        func testEarlyOwnWorkingEventPreservesNewerLocalEditBeforeCommandResponse() async throws {
            let commandEntered = expectation(description: "own command held before authority execution")
            let authorityCommitted = expectation(description: "own event published before command response")
            let executeGate = WorkspaceDeleteSuspensionGate()
            let responseGate = WorkspaceDeleteSuspensionGate()
            let counter = WorkspaceSavePreparationCounter()
            try await withProjectionSaveFixture(configureClient: { client in
                let store = client.store
                client.commandWillExecuteForTesting = { envelope in
                    guard case .replaceWorkingDocument = envelope.command else { return }
                    guard await counter.increment() == 1 else { return }
                    commandEntered.fulfill()
                    await executeGate.wait()
                    // Execute the exact real envelope once; the client's later execution must
                    // deduplicate this operation rather than manufacturing a receipt or event.
                    let outcome = await store.execute(envelope)
                    XCTAssertEqual(outcome.disposition, .applied)
                    authorityCommitted.fulfill()
                    await responseGate.wait()
                }
            }) { fixture in
                let manager = fixture.manager
                let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspace.id })
                manager.workspaces[index].composeTabs[0].promptText = "Submitted working edit"
                manager.markWorkspaceDirty(workspaceID: fixture.workspace.id)
                let submitted = manager.workspaces[index]
                let publication = Task { await manager.debugPublishWorkingDocumentToDomainAuthority(submitted) }
                do {
                    try await self.awaitSaveCheckpoint(commandEntered)
                    manager.workspaces[index].composeTabs[0].promptText = "Newer local edit before response"
                    manager.markWorkspaceDirty(workspaceID: fixture.workspace.id)
                    let newer = manager.workspaces[index]
                    let generation = fixture.bridge.projectionObservationStateForTesting.generation
                    await executeGate.open()
                    try await self.awaitSaveCheckpoint(authorityCommitted)
                    let catalog = await fixture.runtime.workspaceStore.snapshot()
                    let checkpoint = await fixture.observer.waitForProjection(
                        afterGeneration: generation, through: catalog.publicationSequence
                    )
                    XCTAssertEqual(try XCTUnwrap(checkpoint).application, .selfEchoBaseline)
                    XCTAssertEqual(
                        manager.workspace(withID: fixture.workspace.id),
                        newer,
                        "An early own event must not overwrite a newer local edit"
                    )
                    let committed = try XCTUnwrap(catalog.workspaces.first { $0.document.workspaceID == fixture.workspace.id })
                    let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: committed.document.documentBytes)
                    XCTAssertEqual(canonical.composeTabs[0].promptText, submitted.composeTabs[0].promptText)
                    XCTAssertNotNil(committed.revisions.dirtyRevision)
                    await responseGate.open()
                    await publication.value
                    XCTAssertEqual(manager.workspace(withID: fixture.workspace.id), newer)
                    _ = try await manager.saveWorkspaceToFileAsync(newer)
                    let final = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                    let saved = try XCTUnwrap(final)
                    let disk = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: saved.document.fileURL))
                    XCTAssertEqual(disk.composeTabs[0].promptText, newer.composeTabs[0].promptText)
                    XCTAssertNil(saved.revisions.dirtyRevision)
                    try await self.assertCanonicalAndDiskRemain(saved, in: fixture)
                } catch {
                    await executeGate.open()
                    await responseGate.open()
                    await publication.value
                    throw error
                }
            }
        }

        func testSameBaselineFullProjectionInvalidatesPendingWholeModelReceipt() async throws {
            let commandEntered = expectation(description: "own publication held before same-baseline projection")
            let executeGate = WorkspaceDeleteSuspensionGate()
            let counter = WorkspaceSavePreparationCounter()
            try await withProjectionSaveFixture(configureClient: { client in
                client.commandWillExecuteForTesting = { envelope in
                    guard case .replaceWorkingDocument = envelope.command else { return }
                    guard await counter.increment() == 1 else { return }
                    commandEntered.fulfill()
                    await executeGate.wait()
                }
            }) { fixture in
                let manager = fixture.manager
                await fixture.bridge.stopAndJoinForTesting()
                let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspace.id })
                let baseline = manager.workspaces[index]
                let diskBefore = try Data(contentsOf: manager.workspaceFileURL(for: baseline))
                manager.workspaces[index].composeTabs[0].promptText = "Pending whole-model edit"
                manager.markWorkspaceDirty(workspaceID: fixture.workspace.id)
                let submitted = manager.workspaces[index]
                let version = manager.debugStateVersionForWorkspace(fixture.workspace.id)
                let publication = Task { await manager.debugPublishWorkingDocumentToDomainAuthority(submitted) }
                do {
                    try await self.awaitSaveCheckpoint(commandEntered)
                    let catalog = await fixture.runtime.workspaceStore.snapshot()
                    let decoded = try catalog.workspaces.map {
                        try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                            documentBytes: $0.document.documentBytes, fileURL: $0.document.fileURL
                        )
                    }
                    let receipt = manager.applyDomainWorkspaceCatalog(
                        catalog, projection: .full(decoded), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                    ).receipt
                    XCTAssertEqual(try XCTUnwrap(receipt).kind, .full)
                    XCTAssertEqual(manager.workspace(withID: fixture.workspace.id), baseline)
                    XCTAssertEqual(
                        manager.debugStateVersionForWorkspace(fixture.workspace.id),
                        version,
                        "Full adoption can replace bytes without changing the local dirty counter"
                    )
                    await executeGate.open()
                    await publication.value
                    let committedValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                    let committed = try XCTUnwrap(committedValue)
                    let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: committed.document.documentBytes)
                    XCTAssertEqual(canonical.composeTabs[0].promptText, submitted.composeTabs[0].promptText)
                    XCTAssertNotNil(committed.revisions.dirtyRevision)
                    XCTAssertEqual(manager.workspace(withID: fixture.workspace.id), baseline)

                    do {
                        _ = try await manager.saveWorkspaceToFileAsync(baseline)
                        XCTFail("A late receipt from the replaced adoption generation must not authorize the baseline model")
                    } catch {}
                    let afterValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                    let after = try XCTUnwrap(afterValue)
                    XCTAssertEqual(after.document.documentBytes, committed.document.documentBytes)
                    XCTAssertEqual(after.revisions, committed.revisions)
                    XCTAssertEqual(after.contexts, committed.contexts)
                    XCTAssertEqual(try Data(contentsOf: committed.document.fileURL), diskBefore)
                } catch {
                    await executeGate.open()
                    await publication.value
                    throw error
                }
            }
        }

        private func awaitSaveCheckpoint(_ expectation: XCTestExpectation) async throws {
            let reached = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
            XCTAssertEqual(reached, .completed)
            guard reached == .completed else { throw SaveInterleavingFailure.checkpointTimedOut }
        }

        func testExplicitProposalReceiptCannotAuthorizeUnrepresentedLocalDescendant() async throws {
            let commandEntered = expectation(description: "explicit proposal held before authority execution")
            let executeGate = WorkspaceDeleteSuspensionGate()
            let counter = WorkspaceSavePreparationCounter()
            try await withProjectionSaveFixture(configureClient: { client in
                client.commandWillExecuteForTesting = { envelope in
                    guard case .replaceWorkingDocument = envelope.command else { return }
                    guard await counter.increment() == 1 else { return }
                    commandEntered.fulfill()
                    await executeGate.wait()
                }
            }) { fixture in
                let manager = fixture.manager
                await fixture.bridge.stopAndJoinForTesting()
                let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspace.id })
                let baseline = manager.workspaces[index]
                var proposal = baseline
                // Keep the file path unchanged so rejection must come from model provenance,
                // rather than a workspace rename independently changing its destination.
                proposal.composeTabs[0].name = "Explicit tab rename"
                let directSave = Task { try await manager.saveWorkspaceToFileAsync(proposal) }
                do {
                    try await self.awaitSaveCheckpoint(commandEntered)
                    manager.workspaces[index].composeTabs[0].promptText = "Unrelated local draft after submission"
                    manager.markWorkspaceDirty(workspaceID: fixture.workspace.id)
                    let retained = manager.workspaces[index]
                    await executeGate.open()
                    let url = try await directSave.value
                    let savedValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                    let saved = try XCTUnwrap(savedValue)
                    let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: saved.document.documentBytes)
                    XCTAssertEqual(url, saved.document.fileURL)
                    XCTAssertNil(saved.revisions.dirtyRevision)
                    XCTAssertEqual(canonical.composeTabs[0].name, proposal.composeTabs[0].name)
                    XCTAssertEqual(canonical.composeTabs[0].promptText, baseline.composeTabs[0].promptText)
                    XCTAssertEqual(manager.workspace(withID: fixture.workspace.id), retained)
                    try await self.assertCanonicalAndDiskRemain(saved, in: fixture)

                    do {
                        _ = try await manager.saveWorkspaceToFileAsync(retained)
                        XCTFail("The unrepresented explicit proposal must not authorize its retained local predecessor")
                    } catch {}
                    XCTAssertEqual(manager.workspace(withID: fixture.workspace.id), retained)
                    try await self.assertCanonicalAndDiskRemain(saved, in: fixture)
                } catch {
                    await executeGate.open()
                    _ = await directSave.result
                    throw error
                }
            }
        }

        func testStaleCapturedPublicationDoesNotRefreshCatalogAfterNewerFullAdoption() async throws {
            let captured = expectation(description: "coalesced publisher captured its old full-document baseline")
            let finished = expectation(description: "stale captured publication returned")
            let captureGate = WorkspaceDeleteSuspensionGate()
            let commands = WorkspaceSavePreparationCounter()
            try await withProjectionSaveFixture(configureClient: { client in
                client.commandWillExecuteForTesting = { envelope in
                    guard case .replaceWorkingDocument = envelope.command else { return }
                    _ = await commands.increment()
                }
            }) { fixture in
                let manager = fixture.manager
                await fixture.bridge.stopAndJoinForTesting()
                let initialIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspace.id })
                manager.workspaces[initialIndex].composeTabs[0].promptText = "Pending coalesced local edit"
                manager.markWorkspaceDirty(workspaceID: fixture.workspace.id)
                let old = try XCTUnwrap(manager.workspace(withID: fixture.workspace.id))
                let oldBaseline = manager.debugDomainAuthorityBaseline(for: old.id)
                var refreshRequests: [Bool] = []
                manager.installDomainCatalogRefresh(request: { refreshRequests.append($0) }, cancel: {})
                manager.workingPublicationDidCaptureForTesting = { id in
                    guard id == old.id else { return }
                    captured.fulfill()
                    await captureGate.wait()
                }
                defer {
                    manager.workingPublicationDidCaptureForTesting = nil
                    manager.installDomainCatalogRefresh(request: { _ in }, cancel: {})
                }
                let publication = Task {
                    defer { finished.fulfill() }
                    await manager.debugPublishWorkingDocumentToDomainAuthority(old)
                }
                do {
                    try await self.awaitSaveCheckpoint(captured)
                    let restored = try await self.restoreArchivedTabRemotely(in: fixture)
                    XCTAssertGreaterThan(restored.revisions.workingRevision, try XCTUnwrap(oldBaseline.revisions).workingRevision)
                    let catalog = await fixture.runtime.workspaceStore.snapshot()
                    let decoded = try catalog.workspaces.map { try manager.decodeDomainWorkspaceCatalogRecord($0) }
                    let receipt = manager.applyDomainWorkspaceCatalog(
                        catalog, projection: .full(decoded), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                    ).receipt
                    XCTAssertEqual(try XCTUnwrap(receipt).kind, .full)
                    XCTAssertEqual(manager.debugDomainAuthorityBaseline(for: old.id).revisions, restored.revisions)
                    XCTAssertEqual(manager.debugDomainAuthorityBaseline(for: old.id).digest, restored.document.contentDigest)
                    XCTAssertTrue(manager.hasAdoptedFullDocumentBaseline(workspaceID: old.id, contentDigest: restored.document.contentDigest))
                    let adopted = try XCTUnwrap(manager.workspace(withID: old.id))
                    XCTAssertNotEqual(adopted.composeTabs[0].promptText, old.composeTabs[0].promptText)
                    XCTAssertTrue(adopted.composeTabs.contains { $0.id == fixture.restoredTab.id })
                    XCTAssertFalse(adopted.stashedTabs.contains { $0.tab.id == fixture.restoredTab.id })
                    XCTAssertNil(manager.domainWorkspaceAuthorityIssue)

                    // The captured publisher must reach its provenance refusal after the real
                    // full projection, without sending an authority command or requesting a scan.
                    manager.workingPublicationDidCaptureForTesting = nil
                    await captureGate.open()
                    try await self.awaitSaveCheckpoint(finished)
                    await publication.value
                    let refusedCommandCount = await commands.value
                    XCTAssertEqual(refusedCommandCount, 0)
                    XCTAssertEqual(refreshRequests, [])
                    XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.kind, .commandFailure)
                    XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.operation, "working_commit")
                    XCTAssertEqual(manager.workspace(withID: old.id), adopted)
                    try await self.assertCanonicalAndDiskRemain(restored, in: fixture)

                    // Keep the bridge stopped: the existing newer witness itself must authorize
                    // the next current-model save, with no intervening adoption or reload.
                    let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == old.id })
                    manager.workspaces[index].composeTabs[0].promptText = "Legitimate edit after stale publication refusal"
                    manager.markWorkspaceDirty(workspaceID: old.id)
                    let current = manager.workspaces[index]
                    let url = try await manager.saveWorkspaceToFileAsync(current)
                    let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(old.id)
                    let saved = try XCTUnwrap(snapshot)
                    let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: saved.document.documentBytes)
                    let savedCommandCount = await commands.value
                    XCTAssertEqual(savedCommandCount, 1)
                    XCTAssertEqual(refreshRequests, [])
                    XCTAssertEqual(url, saved.document.fileURL)
                    XCTAssertNil(saved.revisions.dirtyRevision)
                    XCTAssertEqual(canonical.composeTabs[0].promptText, current.composeTabs[0].promptText)
                    XCTAssertTrue(canonical.composeTabs.contains { $0.id == fixture.restoredTab.id })
                    XCTAssertFalse(canonical.stashedTabs.contains { $0.tab.id == fixture.restoredTab.id })
                    try await self.assertCanonicalAndDiskRemain(saved, in: fixture)
                } catch {
                    manager.workingPublicationDidCaptureForTesting = nil
                    await captureGate.open()
                    await publication.value
                    throw error
                }
            }
        }

        func testRejectedPublicationCannotAuthorizeASecondStalePublication() async throws {
            try await assertRejectedPublicationCannotAuthorizeStaleWrite(useOrdinarySave: false)
        }

        func testRejectedPublicationCannotAuthorizeAnOrdinaryStaleSave() async throws {
            try await assertRejectedPublicationCannotAuthorizeStaleWrite(useOrdinarySave: true)
        }

        private func assertRejectedPublicationCannotAuthorizeStaleWrite(useOrdinarySave: Bool) async throws {
            try await withProjectionSaveFixture { fixture in
                let manager = fixture.manager
                let old = try XCTUnwrap(manager.workspace(withID: fixture.workspace.id))
                let baseline = manager.debugDomainAuthorityBaseline(for: old.id)
                await fixture.bridge.stopAndJoinForTesting()
                var refreshRequests: [Bool] = []
                manager.installDomainCatalogRefresh(request: { refreshRequests.append($0) }, cancel: {})
                defer { manager.installDomainCatalogRefresh(request: { _ in }, cancel: {}) }
                let restored = try await self.restoreArchivedTabRemotely(in: fixture)
                XCTAssertGreaterThan(restored.revisions.workingRevision, try XCTUnwrap(baseline.revisions).workingRevision)

                // The real first publication conflicts. Its outcome advances observed authority
                // metadata while the stopped presentation bridge leaves the local bytes old.
                await manager.debugPublishWorkingDocumentToDomainAuthority(old)
                XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.kind, .commandFailure)
                XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.operation, "working_commit")
                XCTAssertEqual(manager.workspace(withID: old.id), old)
                XCTAssertEqual(manager.debugDomainAuthorityBaseline(for: old.id).revisions, restored.revisions)
                XCTAssertEqual(manager.debugDomainAuthorityBaseline(for: old.id).digest, restored.document.contentDigest)
                XCTAssertEqual(refreshRequests, [])
                try await self.assertCanonicalAndDiskRemain(restored, in: fixture)

                if useOrdinarySave {
                    do {
                        _ = try await manager.saveWorkspaceToFileAsync(old)
                        XCTFail("Conflict metadata must not authorize saving the unprojected old model")
                    } catch {}
                } else {
                    await manager.debugPublishWorkingDocumentToDomainAuthority(old)
                    XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.kind, .commandFailure)
                }
                XCTAssertEqual(manager.workspace(withID: old.id), old)
                XCTAssertEqual(refreshRequests, [false], "Unadopted conflict metadata still needs one full-adoption request")
                try await self.assertCanonicalAndDiskRemain(restored, in: fixture)
                try await self.assertFullProjectionReauthorizesLocalSave(in: fixture)
            }
        }

        func testRootOnlySuccessCannotAuthorizeSavingUnprojectedSessionState() async throws {
            try await withProjectionSaveFixture { fixture in
                let manager = fixture.manager
                let old = try XCTUnwrap(manager.workspace(withID: fixture.workspace.id))
                await fixture.bridge.stopAndJoinForTesting()
                let restored = try await self.restoreArchivedTabRemotely(in: fixture)
                let root = self.storageRoot.appendingPathComponent("root-only-edit", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

                // A root edit owns only roots; its actual success must retain canonical session
                // state without claiming that the old local session fields have been projected.
                try await manager.addFolder(root, to: old)
                let rootSnapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(old.id)
                let rooted = try XCTUnwrap(rootSnapshot)
                let rootedModel = try JSONDecoder().decode(WorkspaceModel.self, from: rooted.document.documentBytes)
                let local = try XCTUnwrap(manager.workspace(withID: old.id))
                XCTAssertGreaterThan(rooted.revisions.workingRevision, restored.revisions.workingRevision)
                XCTAssertEqual(rootedModel.repoPaths, [root.path])
                XCTAssertEqual(local.repoPaths, rootedModel.repoPaths)
                XCTAssertTrue(rootedModel.composeTabs.contains { $0.id == fixture.restoredTab.id })
                XCTAssertFalse(rootedModel.stashedTabs.contains { $0.tab.id == fixture.restoredTab.id })
                XCTAssertFalse(local.composeTabs.contains { $0.id == fixture.restoredTab.id })
                XCTAssertTrue(local.stashedTabs.contains { $0.tab.id == fixture.restoredTab.id })
                XCTAssertEqual(manager.debugDomainAuthorityBaseline(for: old.id).revisions, rooted.revisions)
                XCTAssertEqual(manager.debugDomainAuthorityBaseline(for: old.id).digest, rooted.document.contentDigest)
                try await self.assertCanonicalAndDiskRemain(rooted, in: fixture)

                do {
                    _ = try await manager.saveWorkspaceToFileAsync(local)
                    XCTFail("A root-only receipt must not authorize overwriting unprojected session fields")
                } catch {}
                XCTAssertEqual(manager.workspace(withID: old.id), local)
                try await self.assertCanonicalAndDiskRemain(rooted, in: fixture)
                try await self.assertFullProjectionReauthorizesLocalSave(in: fixture)
            }
        }

        private func restoreArchivedTabRemotely(in fixture: ProjectionSaveFixture) async throws -> DomainWorkspaceSnapshot {
            let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
            let before = try XCTUnwrap(snapshot)
            var restored = try JSONDecoder().decode(WorkspaceModel.self, from: before.document.documentBytes)
            let stash = try XCTUnwrap(restored.stashedTabs.first { $0.tab.id == fixture.restoredTab.id })
            restored.stashedTabs.removeAll { $0.id == stash.id }
            restored.composeTabs.append(stash.tab)
            let author = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -758)
            let result = try await author.saveFailClosed(
                restored, fileURL: before.document.fileURL,
                expectedWorkspaceRevision: before.revisions.workingRevision,
                expectedContentDigest: before.document.contentDigest
            )
            XCTAssertEqual(result.working?.disposition, .applied)
            XCTAssertEqual(result.saved?.disposition, .applied)
            let after = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
            return try XCTUnwrap(after)
        }

        private func assertCanonicalAndDiskRemain(
            _ expected: DomainWorkspaceSnapshot,
            in fixture: ProjectionSaveFixture
        ) async throws {
            let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
            let actual = try XCTUnwrap(snapshot)
            XCTAssertEqual(actual.document.documentBytes, expected.document.documentBytes)
            XCTAssertEqual(actual.revisions, expected.revisions)
            XCTAssertEqual(actual.contexts, expected.contexts)
            let disk = try Data(contentsOf: expected.document.fileURL)
            XCTAssertEqual(DomainContentDigest.sha256(disk), expected.document.contentDigest)
        }

        private func assertFullProjectionReauthorizesLocalSave(in fixture: ProjectionSaveFixture) async throws {
            let generation = fixture.bridge.projectionObservationStateForTesting.generation
            let catalog = await fixture.runtime.workspaceStore.snapshot()
            fixture.bridge.start()
            let checkpoint = await fixture.observer.waitForProjection(
                afterGeneration: generation, through: catalog.publicationSequence, requireCatalogApplication: true
            )
            XCTAssertEqual(try XCTUnwrap(checkpoint).catalogReceipt?.kind, .full)
            let index = try XCTUnwrap(fixture.manager.workspaces.firstIndex { $0.id == fixture.workspace.id })
            XCTAssertTrue(fixture.manager.workspaces[index].composeTabs.contains { $0.id == fixture.restoredTab.id })
            XCTAssertFalse(fixture.manager.workspaces[index].stashedTabs.contains { $0.tab.id == fixture.restoredTab.id })
            fixture.manager.workspaces[index].composeTabs[0].promptText = "Local edit after real full projection"
            fixture.manager.markWorkspaceDirty(workspaceID: fixture.workspace.id)
            let local = fixture.manager.workspaces[index]
            let url = try await fixture.manager.saveWorkspaceToFileAsync(local)
            let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
            let after = try XCTUnwrap(snapshot)
            XCTAssertEqual(url, after.document.fileURL)
            XCTAssertNil(after.revisions.dirtyRevision)
            let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: after.document.documentBytes)
            XCTAssertEqual(canonical.composeTabs[0].promptText, local.composeTabs[0].promptText)
            XCTAssertTrue(canonical.composeTabs.contains { $0.id == fixture.restoredTab.id })
            XCTAssertFalse(canonical.stashedTabs.contains { $0.tab.id == fixture.restoredTab.id })
            try await assertCanonicalAndDiskRemain(after, in: fixture)
        }

        func testExplicitProposalFailsWhenRestoredProjectionSupersedesItsCapture() async throws {
            try await assertSaveAfterRestoredProjection(explicitProposal: true)
        }

        func testCurrentModelSaveRejectsStaleLocalOverlayAfterAuthorityAdvance() async throws {
            try await assertSaveAfterRestoredProjection(explicitProposal: false, retainStaleLocalOverlay: true)
        }

        private func assertSaveAfterRestoredProjection(
            explicitProposal: Bool,
            retainStaleLocalOverlay: Bool = false
        ) async throws {
            try await withProjectionSaveFixture { fixture in
                let manager = fixture.manager
                let observed = try XCTUnwrap(manager.workspace(withID: fixture.workspace.id))
                var proposal = observed
                if explicitProposal { proposal.composeTabs[0].name = "Uncommitted explicit rename" }
                let version = manager.debugStateVersionForWorkspace(observed.id)
                let snapshotCaptured = self.expectation(description: "old archived save captured authority")
                let gate = WorkspaceDeleteSuspensionGate()
                manager.setWorkspaceSaveAfterAuthoritySnapshotHandlerForTesting { id in
                    guard id == observed.id else { return }
                    snapshotCaptured.fulfill()
                    await gate.wait()
                }
                let save = Task { try await manager.saveWorkspaceToFileAsync(proposal) }
                do {
                    let reached = await XCTWaiter.fulfillment(of: [snapshotCaptured], timeout: 5)
                    XCTAssertEqual(reached, .completed)
                    guard reached == .completed else { throw SaveInterleavingFailure.checkpointTimedOut }

                    let before = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(observed.id)
                    let baseline = try XCTUnwrap(before)
                    var restored = try JSONDecoder().decode(WorkspaceModel.self, from: baseline.document.documentBytes)
                    let stash = try XCTUnwrap(restored.stashedTabs.first { $0.tab.id == fixture.restoredTab.id })
                    restored.stashedTabs.removeAll { $0.id == stash.id }
                    restored.composeTabs.append(stash.tab)
                    // Working and saved events can produce full then metadata receipts. Keep
                    // the actual target adoption evidence before the latest checkpoint advances.
                    let observation = fixture.bridge.projectionObservationStateForTesting
                    var fullProjectionEvidence: [(revision: UInt64, digest: String)] = []
                    let projectionToken = fixture.bridge.projectionObservationPublisherForTesting.sink { event in
                        guard case let .applied(checkpoint) = event,
                              checkpoint.runID == observation.runID,
                              checkpoint.generation > observation.generation,
                              checkpoint.catalogReceipt?.kind == .full,
                              let projected = manager.workspace(withID: observed.id),
                              projected.composeTabs.map(\.id) == restored.composeTabs.map(\.id),
                              !projected.stashedTabs.contains(where: { $0.tab.id == fixture.restoredTab.id })
                        else { return }
                        let baseline = manager.debugDomainAuthorityBaseline(for: observed.id)
                        if let revision = baseline.revisions?.workingRevision, let digest = baseline.digest {
                            fullProjectionEvidence.append((revision, digest))
                        }
                    }
                    defer { projectionToken.cancel() }
                    let author = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -758)
                    let remote = try await author.saveFailClosed(
                        restored, fileURL: baseline.document.fileURL,
                        expectedWorkspaceRevision: baseline.revisions.workingRevision,
                        expectedContentDigest: baseline.document.contentDigest
                    )
                    XCTAssertEqual(remote.working?.disposition, .applied)
                    XCTAssertEqual(remote.saved?.disposition, .applied)
                    let restoredSnapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(observed.id)
                    let accepted = try XCTUnwrap(restoredSnapshot)
                    let catalog = await fixture.runtime.workspaceStore.snapshot()
                    let checkpoint = await fixture.observer.waitForProjection(
                        afterGeneration: observation.generation, through: catalog.publicationSequence, requireCatalogApplication: true
                    )
                    _ = try XCTUnwrap(checkpoint)
                    XCTAssertTrue(fullProjectionEvidence.contains {
                        $0.revision == accepted.revisions.workingRevision && $0.digest == accepted.document.contentDigest
                    }, "The restored target must have been adopted by an accepted full projection")
                    XCTAssertEqual(manager.workspace(withID: observed.id)?.composeTabs.map(\.id), restored.composeTabs.map(\.id))
                    XCTAssertEqual(
                        manager.debugStateVersionForWorkspace(observed.id),
                        version,
                        "A canonical projection changes bytes without bumping local dirty tracking"
                    )

                    var retainedOverlay: WorkspaceModel?
                    if retainStaleLocalOverlay {
                        XCTAssertNotEqual(accepted.revisions.workingRevision, baseline.revisions.workingRevision)
                        XCTAssertNotEqual(accepted.document.contentDigest, baseline.document.contentDigest)
                        // Model an unrelated local edit retaining the old archived carrier after
                        // the real projection has advanced the manager's authority baseline.
                        var overlay = observed
                        overlay.composeTabs[0].promptText = "Unrelated local draft"
                        let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == observed.id })
                        manager.workspaces[index] = overlay
                        manager.markWorkspaceDirty(workspaceID: observed.id)
                        retainedOverlay = overlay
                        XCTAssertNotEqual(overlay, observed)
                    }

                    manager.setWorkspaceSaveAfterAuthoritySnapshotHandlerForTesting(nil)
                    await gate.open()
                    let result = await save.result
                    if explicitProposal || retainStaleLocalOverlay {
                        if case .success = result { XCTFail("A stale proposal or local overlay must not report a successful save") }
                    } else {
                        XCTAssertEqual(try result.get(), baseline.document.fileURL)
                    }

                    // No compensating save or flush: these are the bytes left by the returned save.
                    let afterSnapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(observed.id)
                    let after = try XCTUnwrap(afterSnapshot)
                    let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: after.document.documentBytes)
                    let diskBytes = try Data(contentsOf: baseline.document.fileURL)
                    let disk = try JSONDecoder().decode(WorkspaceModel.self, from: diskBytes)
                    var restoredModels = [canonical, disk]
                    if let retainedOverlay {
                        XCTAssertEqual(
                            manager.workspace(withID: observed.id),
                            retainedOverlay,
                            "Refusing the stale save must preserve the unrelated local edit"
                        )
                    } else {
                        try restoredModels.append(XCTUnwrap(manager.workspace(withID: observed.id)))
                    }
                    for workspace in restoredModels {
                        XCTAssertTrue(workspace.composeTabs.contains { $0.id == fixture.restoredTab.id })
                        XCTAssertFalse(workspace.stashedTabs.contains { $0.tab.id == fixture.restoredTab.id })
                        XCTAssertEqual(workspace.composeTabs.first?.name, observed.composeTabs.first?.name)
                        XCTAssertEqual(workspace.composeTabs.first?.promptText, observed.composeTabs.first?.promptText)
                    }
                    XCTAssertEqual(after.revisions, accepted.revisions, "The old save must not create a new removal revision")
                    XCTAssertEqual(after.contexts, accepted.contexts, "The restored context must not acquire a new tombstone")
                    XCTAssertEqual(DomainContentDigest.sha256(diskBytes), after.document.contentDigest)
                } catch {
                    manager.setWorkspaceSaveAfterAuthoritySnapshotHandlerForTesting(nil)
                    await gate.open()
                    _ = await save.result
                    throw error
                }
            }
        }

        func testPreparationDriftRecapturesOnceAndPersistsTheLatestModel() async throws {
            try await assertPreparationDrift(changeCount: 1)
        }

        func testRepeatedPreparationDriftExhaustsWithoutWritingEitherStaleModel() async throws {
            try await assertPreparationDrift(changeCount: 2)
        }

        private func assertPreparationDrift(changeCount: Int) async throws {
            try await withProjectionSaveFixture { fixture in
                let manager = fixture.manager
                let initial = try XCTUnwrap(manager.workspace(withID: fixture.workspace.id))
                let beforeSnapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(initial.id)
                let before = try XCTUnwrap(beforeSnapshot)
                let counter = WorkspaceSavePreparationCounter()
                manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { id, _, _ in
                    guard id == initial.id else { return }
                    let attempt = await counter.increment()
                    guard attempt <= changeCount else { return }
                    await MainActor.run {
                        guard let index = manager.workspaces.firstIndex(where: { $0.id == id }) else { return }
                        manager.workspaces[index].composeTabs[0].promptText = "Local edit \(attempt)"
                        manager.markWorkspaceDirty(workspaceID: id)
                    }
                }
                defer { manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil) }
                let result: Result<URL, Error>
                do { result = try await .success(manager.saveWorkspaceToFileAsync(initial)) }
                catch { result = .failure(error) }
                let preparationCount = await counter.value
                XCTAssertEqual(preparationCount, 2, "Only one complete recapture is allowed")
                let afterSnapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(initial.id)
                let after = try XCTUnwrap(afterSnapshot)
                let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: after.document.documentBytes)
                let diskBytes = try Data(contentsOf: before.document.fileURL)
                let disk = try JSONDecoder().decode(WorkspaceModel.self, from: diskBytes)
                if changeCount == 1 {
                    XCTAssertEqual(try result.get(), before.document.fileURL)
                    XCTAssertEqual(canonical.composeTabs[0].promptText, "Local edit 1")
                    XCTAssertEqual(disk.composeTabs[0].promptText, "Local edit 1")
                    XCTAssertNil(after.revisions.dirtyRevision)
                } else {
                    if case .success = result { XCTFail("Repeated drift must exhaust instead of writing a stale payload") }
                    XCTAssertEqual(after.revisions, before.revisions)
                    XCTAssertEqual(after.document.contentDigest, before.document.contentDigest)
                    XCTAssertEqual(canonical.composeTabs[0].promptText, initial.composeTabs[0].promptText)
                    XCTAssertEqual(disk.composeTabs[0].promptText, initial.composeTabs[0].promptText)
                    XCTAssertEqual(manager.workspace(withID: initial.id)?.composeTabs[0].promptText, "Local edit 2")
                }
                XCTAssertEqual(DomainContentDigest.sha256(diskBytes), after.document.contentDigest)
            }
        }

        private struct ProjectionSaveFixture {
            let runtime: MCPDomainRuntime
            let manager: WorkspaceManagerViewModel
            let bridge: DomainWorkspacePresentationBridge
            let observer: DomainWorkspaceProjectionObserver
            let workspace: WorkspaceModel
            let restoredTab: ComposeTabState
        }

        private enum SaveInterleavingFailure: Error {
            case checkpointTimedOut
        }

        private func withProjectionSaveFixture(
            configureClient: (@MainActor (inout DomainWorkspaceAuthorityClient) -> Void)? = nil,
            _ body: @MainActor (ProjectionSaveFixture) async throws -> Void
        ) async throws {
            let fallback = ComposeTabState(name: "Current tab")
            let restoredTab = ComposeTabState(name: "Archived session", activeAgentSessionID: UUID())
            var workspace = WorkspaceModel(
                name: "Projection save target", repoPaths: [],
                composeTabs: [fallback], activeComposeTabID: fallback.id
            )
            workspace.stashedTabs = [StashedTab(tab: restoredTab)]
            try writeWorkspace(workspace)
            try writeLegacyIndex([workspace])
            let runtime = try await makeRuntime(profileIdentifier: "workspace-projection-save")
            var client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -759)
            configureClient?(&client)
            let manager = makeManager(windowID: -759, domainWorkspaceAuthorityClient: client)
            let bridge = DomainWorkspacePresentationBridge(workspaceManager: manager, client: client)
            let observer = DomainWorkspaceProjectionObserver(bridge: bridge)
            do {
                await manager.awaitInitialized()
                bridge.start()
                let catalog = await runtime.workspaceStore.snapshot()
                let initial = await observer.waitForProjection(
                    afterGeneration: 0, through: catalog.publicationSequence, requireCatalogApplication: true
                )
                _ = try XCTUnwrap(initial)
                try await body(.init(runtime: runtime, manager: manager, bridge: bridge, observer: observer, workspace: workspace, restoredTab: restoredTab))
                await bridge.stopAndJoinForTesting()
                manager.prepareForWindowClose()
                _ = await runtime.shutdown()
            } catch {
                await bridge.stopAndJoinForTesting()
                manager.prepareForWindowClose()
                _ = await runtime.shutdown()
                throw error
            }
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

    private actor WorkspaceOrderedSaveCommands {
        private(set) var pinnedValues: [Bool] = []

        func record(_ pinned: Bool) -> Int {
            pinnedValues.append(pinned)
            return pinnedValues.count
        }
    }

    private actor WorkspaceSavePreparationCounter {
        private(set) var value = 0

        func increment() -> Int {
            value += 1
            return value
        }
    }
#endif
