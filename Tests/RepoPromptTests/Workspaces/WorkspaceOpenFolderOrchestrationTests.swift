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

        func testInteractiveOpenUsesCurrentAuthorityRecentOrderingAfterSnapshot() async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1301)
            let requestedFolder = try makeFolder(named: "CurrentAuthorityOrdering")
            let secondaryFolder = try makeFolder(named: "CurrentAuthorityOrderingSecondary")
            let older = try WorkspaceModel(
                id: workspaceID(10),
                dateModified: Date(timeIntervalSinceReferenceDate: 100),
                name: "Older",
                repoPaths: [requestedFolder.path]
            )
            try await createAuthorityWorkspace(older, using: client)

            let openingManager = makeManager(domainRuntime: runtime)
            await openingManager.awaitInitialized()

            let commonDate = Date(timeIntervalSinceReferenceDate: 200)
            let hidden = try WorkspaceModel(
                id: workspaceID(7),
                dateModified: Date(timeIntervalSinceReferenceDate: 400),
                name: "Hidden",
                repoPaths: [requestedFolder.path],
                isHiddenInMenus: true
            )
            let system = try WorkspaceModel(
                id: workspaceID(6),
                dateModified: Date(timeIntervalSinceReferenceDate: 300),
                name: "System",
                repoPaths: [requestedFolder.path],
                isSystemWorkspace: true
            )
            let foldedNameLater = try WorkspaceModel(
                id: workspaceID(5),
                dateModified: commonDate,
                name: "beta",
                repoPaths: [requestedFolder.path]
            )
            let exactNameLater = try WorkspaceModel(
                id: workspaceID(4),
                dateModified: commonDate,
                name: "alpha",
                repoPaths: [requestedFolder.path]
            )
            let uuidLater = try WorkspaceModel(
                id: workspaceID(2),
                dateModified: commonDate,
                name: "Alpha",
                repoPaths: [requestedFolder.path]
            )
            let expectedWinner = try WorkspaceModel(
                id: workspaceID(1),
                dateModified: commonDate,
                name: "Alpha",
                repoPaths: [secondaryFolder.path, requestedFolder.path]
            )
            let insertedAfterSnapshot = [
                hidden,
                system,
                foldedNameLater,
                exactNameLater,
                uuidLater,
                expectedWinner
            ]
            openingManager.setPersistentFolderOpenDidSnapshotHandlerForTesting {
                for workspace in insertedAfterSnapshot {
                    _ = try? await client.create(
                        workspace,
                        fileURL: self.authorityWorkspaceFileURL(workspace.id)
                    )
                }
            }

            try await openingManager.openWorkspace(
                fromFolderURL: requestedFolder,
                behavior: .createNewWorkspace
            )

            let catalogSnapshot = await openingManager.workspaceRoutingCatalogSnapshot()
            let snapshot = try XCTUnwrap(catalogSnapshot)
            let exactRootMatches = snapshot.filter {
                WorkspaceFolderOpenResolver.containsExactRoot(requestedFolder.path, in: $0)
            }
            XCTAssertEqual(
                Set(exactRootMatches.map(\.id)),
                Set(([older] + insertedAfterSnapshot).map(\.id)),
                "Folder-open reuse must not create a third workspace from the stale caller snapshot"
            )
            XCTAssertEqual(openingManager.activeWorkspaceID, expectedWinner.id)
            XCTAssertEqual(
                WorkspaceFolderOpenResolver.bestEligibleMatch(
                    forFolderPath: requestedFolder.path,
                    in: exactRootMatches
                )?.id,
                expectedWinner.id,
                "The runtime winner must match the complete Recent Workspaces ordering"
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

        func testResolveOrCreateExcludesVisibleRetiredWorkspaceAndReplaysCreatedProvenance() async throws {
            let profileIdentifier = "workspace-open-folder-created-provenance-\(UUID().uuidString)"
            let runtime = try await makeDomainRuntime(profileIdentifier: profileIdentifier)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1310)
            let folder = try makeFolder(named: "VisibleRetiredExactRoot")
            let retired = try WorkspaceModel(
                id: workspaceID(20),
                dateModified: Date(timeIntervalSinceReferenceDate: 200),
                name: "Visible Retired",
                repoPaths: [folder.path],
                consolidatedIntoWorkspaceID: workspaceID(999)
            )
            try await createAuthorityWorkspace(retired, using: client)
            let proposed = try WorkspaceModel(
                id: workspaceID(21),
                dateModified: Date(timeIntervalSinceReferenceDate: 100),
                name: "Replacement",
                repoPaths: [folder.path]
            )
            let envelope = try resolveOrCreateEnvelope(
                proposed,
                canonicalRootPath: canonicalRootPath(folder),
                operationID: UUID(),
                windowID: -1310
            )

            let first = await runtime.workspaceStore.execute(envelope)
            let replay = await runtime.workspaceStore.execute(envelope)
            let snapshot = await runtime.workspaceStore.snapshot()

            XCTAssertEqual(first.disposition, .applied)
            XCTAssertEqual(first.exactRootResolution, .created)
            XCTAssertEqual(first.workspace?.document.workspaceID, proposed.id)
            XCTAssertEqual(replay.disposition, .deduplicated)
            XCTAssertEqual(replay.exactRootResolution, .created)
            XCTAssertEqual(replay.workspace?.document.workspaceID, proposed.id)
            XCTAssertTrue(snapshot.workspaces.contains(where: {
                $0.document.workspaceID == retired.id
            }))
            XCTAssertTrue(snapshot.workspaces.contains(where: {
                $0.document.workspaceID == proposed.id
            }))

            _ = await runtime.shutdown()
            domainRuntimes.removeAll { $0 === runtime }
            let restarted = try await makeDomainRuntime(profileIdentifier: profileIdentifier)
            let replayAfterRestart = await restarted.workspaceStore.execute(envelope)

            XCTAssertEqual(replayAfterRestart.disposition, .deduplicated)
            XCTAssertEqual(replayAfterRestart.exactRootResolution, .created)
            XCTAssertEqual(replayAfterRestart.workspace?.document.workspaceID, proposed.id)
        }

        func testResolveOrCreateRejectsRetiredWorkspaceIDCollision() async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1321)
            let folder = try makeFolder(named: "RetiredExactRootIDCollision")
            let retired = try WorkspaceModel(
                id: workspaceID(22),
                name: "Retired Collision",
                repoPaths: [folder.path],
                consolidatedIntoWorkspaceID: workspaceID(999)
            )
            try await createAuthorityWorkspace(retired, using: client)
            let envelope = try resolveOrCreateEnvelope(
                retired,
                canonicalRootPath: canonicalRootPath(folder),
                operationID: UUID(),
                windowID: -1321
            )

            let first = await runtime.workspaceStore.execute(envelope)
            let replay = await runtime.workspaceStore.execute(envelope)
            let snapshot = await runtime.workspaceStore.snapshot()

            XCTAssertEqual(first.disposition, .conflict)
            XCTAssertEqual(first.errorCode, .stateConflict)
            XCTAssertEqual(first.diagnostic, "exact_root_workspace_id_collision")
            XCTAssertNil(first.exactRootResolution)
            XCTAssertEqual(first.workspace?.document.workspaceID, retired.id)
            XCTAssertEqual(replay.disposition, .deduplicated)
            XCTAssertEqual(replay.errorCode, .stateConflict)
            XCTAssertEqual(replay.diagnostic, "exact_root_workspace_id_collision")
            XCTAssertNil(replay.exactRootResolution)
            XCTAssertEqual(snapshot.workspaces.count(where: {
                $0.document.workspaceID == retired.id
            }), 1)
        }

        func testResolveOrCreateBlocksIncompleteWorkingOnlyRestoreAndReplaysRecoveryProvenance() async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1311)
            let folder = try makeFolder(named: "IncompleteWorkingOnlyRestore")
            let retired = try WorkspaceModel(
                id: workspaceID(30),
                dateModified: Date(timeIntervalSinceReferenceDate: 200),
                name: "Incomplete Restore",
                repoPaths: [folder.path],
                isHiddenInMenus: true,
                consolidatedIntoWorkspaceID: workspaceID(999)
            )
            try await createAuthorityWorkspace(retired, using: client)
            let retiredAuthoritySnapshot = await client.workspaceSnapshot(retired.id)
            let retiredSnapshot = try XCTUnwrap(retiredAuthoritySnapshot)
            var restoredWorking = retired
            restoredWorking.isHiddenInMenus = false
            restoredWorking.consolidatedIntoWorkspaceID = nil
            let working = try await client.replaceWorking(
                restoredWorking,
                fileURL: retiredSnapshot.document.fileURL,
                expectedWorkspaceRevision: retiredSnapshot.revisions.workingRevision
            )
            XCTAssertEqual(working.disposition, .applied)
            XCTAssertNotNil(working.after?.dirtyRevision)

            let proposed = try WorkspaceModel(
                id: workspaceID(31),
                name: "Must Not Be Created",
                repoPaths: [folder.path]
            )
            let envelope = try resolveOrCreateEnvelope(
                proposed,
                canonicalRootPath: canonicalRootPath(folder),
                operationID: UUID(),
                windowID: -1311
            )
            let selection = try await client.exactRootSelection(canonicalRootPath: canonicalRootPath(folder))
            XCTAssertEqual(selection, .recoveryBlocked)

            let first = await runtime.workspaceStore.execute(envelope)
            let replay = await runtime.workspaceStore.execute(envelope)
            let snapshot = await runtime.workspaceStore.snapshot()

            XCTAssertEqual(first.disposition, .conflict)
            XCTAssertEqual(first.errorCode, .stateConflict)
            XCTAssertEqual(first.diagnostic, "exact_root_restoration_incomplete")
            XCTAssertEqual(first.exactRootResolution, .recoveryBlocked)
            XCTAssertNil(first.workspace)
            XCTAssertEqual(replay.disposition, .deduplicated)
            XCTAssertEqual(replay.errorCode, .stateConflict)
            XCTAssertEqual(replay.diagnostic, "exact_root_restoration_incomplete")
            XCTAssertEqual(replay.exactRootResolution, .recoveryBlocked)
            XCTAssertNil(replay.workspace)
            XCTAssertFalse(snapshot.workspaces.contains(where: {
                $0.document.workspaceID == proposed.id
            }))
        }

        func testResolveOrCreateBlocksDirtyMatchWhenSavedDocumentIsUnreadable() async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1313)
            let folder = try makeFolder(named: "UnreadableSavedExactRoot")
            let existing = try WorkspaceModel(
                id: workspaceID(35),
                name: "Unreadable Saved Match",
                repoPaths: [folder.path]
            )
            try await createAuthorityWorkspace(existing, using: client)
            let authoritySnapshot = await client.workspaceSnapshot(existing.id)
            let existingSnapshot = try XCTUnwrap(authoritySnapshot)
            var dirtyWorking = existing
            dirtyWorking.name = "Unreadable Saved Match Updated"
            let dirtyOutcome = try await client.replaceWorking(
                dirtyWorking,
                fileURL: existingSnapshot.document.fileURL,
                expectedWorkspaceRevision: existingSnapshot.revisions.workingRevision
            )
            XCTAssertEqual(dirtyOutcome.disposition, .applied)
            XCTAssertNotNil(dirtyOutcome.after?.dirtyRevision)
            try FileManager.default.removeItem(at: existingSnapshot.document.fileURL)

            let proposed = try WorkspaceModel(
                id: workspaceID(36),
                name: "Must Not Be Created",
                repoPaths: [folder.path]
            )
            let envelope = try resolveOrCreateEnvelope(
                proposed,
                canonicalRootPath: canonicalRootPath(folder),
                operationID: UUID(),
                windowID: -1313
            )
            let selection = try await client.exactRootSelection(canonicalRootPath: canonicalRootPath(folder))
            XCTAssertEqual(selection, .recoveryBlocked)

            let first = await runtime.workspaceStore.execute(envelope)
            let replay = await runtime.workspaceStore.execute(envelope)
            let snapshot = await runtime.workspaceStore.snapshot()

            XCTAssertEqual(first.disposition, .conflict)
            XCTAssertEqual(first.errorCode, .stateConflict)
            XCTAssertEqual(first.diagnostic, "exact_root_restoration_incomplete")
            XCTAssertEqual(first.exactRootResolution, .recoveryBlocked)
            XCTAssertEqual(replay.disposition, .deduplicated)
            XCTAssertEqual(replay.exactRootResolution, .recoveryBlocked)
            XCTAssertFalse(snapshot.workspaces.contains(where: {
                $0.document.workspaceID == proposed.id
            }))
        }

        func testResolveOrCreatePrefersOrdinaryDirtyMatchOverNewerIncompleteRestore() async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1312)
            let folder = try makeFolder(named: "DirtyAlternativeToIncompleteRestore")
            let retired = try WorkspaceModel(
                id: workspaceID(40),
                dateModified: Date(timeIntervalSinceReferenceDate: 300),
                name: "Newer Incomplete Restore",
                repoPaths: [folder.path],
                isHiddenInMenus: true,
                consolidatedIntoWorkspaceID: workspaceID(999)
            )
            try await createAuthorityWorkspace(retired, using: client)
            let retiredAuthoritySnapshot = await client.workspaceSnapshot(retired.id)
            let retiredSnapshot = try XCTUnwrap(retiredAuthoritySnapshot)
            var restoredWorking = retired
            restoredWorking.isHiddenInMenus = false
            restoredWorking.consolidatedIntoWorkspaceID = nil
            let restoredOutcome = try await client.replaceWorking(
                restoredWorking,
                fileURL: retiredSnapshot.document.fileURL,
                expectedWorkspaceRevision: retiredSnapshot.revisions.workingRevision
            )
            XCTAssertEqual(restoredOutcome.disposition, .applied)

            let ordinary = try WorkspaceModel(
                id: workspaceID(41),
                dateModified: Date(timeIntervalSinceReferenceDate: 100),
                name: "Ordinary Dirty Match",
                repoPaths: [folder.path]
            )
            try await createAuthorityWorkspace(ordinary, using: client)
            let ordinaryAuthoritySnapshot = await client.workspaceSnapshot(ordinary.id)
            let ordinarySnapshot = try XCTUnwrap(ordinaryAuthoritySnapshot)
            var dirtyOrdinary = ordinary
            dirtyOrdinary.name = "Ordinary Dirty Match Updated"
            dirtyOrdinary.dateModified = Date(timeIntervalSinceReferenceDate: 200)
            let dirtyOutcome = try await client.replaceWorking(
                dirtyOrdinary,
                fileURL: ordinarySnapshot.document.fileURL,
                expectedWorkspaceRevision: ordinarySnapshot.revisions.workingRevision
            )
            XCTAssertEqual(dirtyOutcome.disposition, .applied)
            XCTAssertNotNil(dirtyOutcome.after?.dirtyRevision)

            let proposed = try WorkspaceModel(
                id: workspaceID(42),
                name: "Must Not Be Created",
                repoPaths: [folder.path]
            )
            let envelope = try resolveOrCreateEnvelope(
                proposed,
                canonicalRootPath: canonicalRootPath(folder),
                operationID: UUID(),
                windowID: -1312
            )
            let selection = try await client.exactRootSelection(canonicalRootPath: canonicalRootPath(folder))
            guard case let .matched(selected) = selection else {
                return XCTFail("Expected the ordinary dirty workspace to remain eligible")
            }
            XCTAssertEqual(selected.document.workspaceID, ordinary.id)

            let first = await runtime.workspaceStore.execute(envelope)
            let replay = await runtime.workspaceStore.execute(envelope)
            let snapshot = await runtime.workspaceStore.snapshot()

            XCTAssertEqual(first.disposition, .unchanged)
            XCTAssertEqual(first.exactRootResolution, .reused)
            XCTAssertEqual(first.workspace?.document.workspaceID, ordinary.id)
            XCTAssertEqual(replay.disposition, .deduplicated)
            XCTAssertEqual(replay.exactRootResolution, .reused)
            XCTAssertEqual(replay.workspace?.document.workspaceID, ordinary.id)
            XCTAssertFalse(snapshot.workspaces.contains(where: {
                $0.document.workspaceID == proposed.id
            }))
        }

        func testExactRootSelectionNoMatchDoesNotCreateWorkspace() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "ReadOnlyNoMatch")
            let before = await runtime.workspaceStore.snapshot()
            let localCount = manager.workspaces.count

            let selection = try await manager.persistentFolderOpenSelection(forFolderPath: folder.path)

            guard case .noMatch = selection else { return XCTFail("Expected no match") }
            let after = await runtime.workspaceStore.snapshot()
            XCTAssertEqual(after, before)
            XCTAssertEqual(manager.workspaces.count, localCount)
        }

        func testExactRootReadAndResolutionDetectSaveDuringEligibilityInspection() async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1314)
            let folder = try makeFolder(named: "EligibilitySaveInterleaving")
            let existing = WorkspaceModel(name: "Save interleaving", repoPaths: [folder.path])
            try await createAuthorityWorkspace(existing, using: client)
            let proposed = WorkspaceModel(name: "Must not create", repoPaths: [folder.path])
            let initial = await client.snapshot()
            for resolveCommand in [false, true] {
                let currentSnapshot = await client.canonicalWorkspaceSnapshot(existing.id)
                let current = try XCTUnwrap(currentSnapshot)
                var working = existing
                working.name = "Dirty \(resolveCommand)"
                let dirty = try await client.replaceWorking(
                    working,
                    fileURL: current.document.fileURL,
                    expectedWorkspaceRevision: current.revisions.workingRevision
                )
                XCTAssertEqual(dirty.disposition, .applied)
                let dirtySnapshot = try XCTUnwrap(dirty.workspace)
                // Save does not take the catalog gate. This is a real reentrant mutation, not
                // a synthetic revision bump: the saved eligibility baseline changes under the read.
                await runtime.workspaceStore.testSetAfterExactRootSavedMarkerRead { workspaceID in
                    guard workspaceID == existing.id else { return }
                    await runtime.workspaceStore.testSetAfterExactRootSavedMarkerRead(nil)
                    let saved = await runtime.workspaceStore.execute(.init(
                        operationID: UUID(),
                        expectedWorkspaceRevision: dirtySnapshot.revisions.workingRevision,
                        origin: .appPresentation(windowID: -1314),
                        command: .saveWorkspaceDocument(workspaceID: existing.id)
                    ))
                    XCTAssertEqual(saved.disposition, .applied)
                }
                if resolveCommand {
                    let outcome = try await client.resolveOrCreatePersistentWorkspace(
                        proposed,
                        fileURL: storageRoot.appendingPathComponent("MustNotCreate.json"),
                        canonicalRootPath: canonicalRootPath(folder)
                    )
                    XCTAssertEqual(outcome.disposition, .conflict)
                    XCTAssertEqual(outcome.diagnostic, "exact_root_selection_changed")
                    XCTAssertNil(outcome.workspace)
                } else {
                    let selection = try await client.exactRootSelection(canonicalRootPath: canonicalRootPath(folder))
                    XCTAssertEqual(selection, .changed)
                }
                await runtime.workspaceStore.testSetAfterExactRootSavedMarkerRead(nil)
                let stable = try await client.exactRootSelection(canonicalRootPath: canonicalRootPath(folder))
                guard case let .matched(selected) = stable else { return XCTFail("Expected stable saved match") }
                XCTAssertEqual(selected.document.workspaceID, existing.id)
            }
            let final = await client.snapshot()
            XCTAssertEqual(
                Set(final.workspaces.map(\.document.workspaceID)),
                Set(initial.workspaces.map(\.document.workspaceID))
            )
        }

        func testReplayedResolveOrCreateReturnsOriginalWorkspaceAfterResultDigestChanges() async throws {
            let profileIdentifier = "workspace-open-folder-reused-provenance-\(UUID().uuidString)"
            let runtime = try await makeDomainRuntime(profileIdentifier: profileIdentifier)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1302)
            let folder = try makeFolder(named: "ResolveOrCreateReplayMutation")
            let existing = WorkspaceModel(name: "Replay Winner", repoPaths: [folder.path])
            try await createAuthorityWorkspace(existing, using: client)
            let proposed = WorkspaceModel(name: "Replay Proposed", repoPaths: [folder.path])
            let canonicalRootPath = try canonicalRootPath(folder)
            let operationID = UUID()
            let envelope = try resolveOrCreateEnvelope(
                proposed,
                canonicalRootPath: canonicalRootPath,
                operationID: operationID,
                windowID: -1302
            )

            let first = await runtime.workspaceStore.execute(envelope)
            let originalDigest = try XCTUnwrap(first.resultingDigest)
            let currentSnapshot = await runtime.workspaceStore.workspaceSnapshot(existing.id)
            let current = try XCTUnwrap(currentSnapshot)
            var updated = existing
            updated.name = "Replay Winner Updated"
            updated.dateModified = Date()
            let mutation = try await client.replaceWorking(
                updated,
                fileURL: current.document.fileURL,
                expectedWorkspaceRevision: current.revisions.workingRevision
            )
            XCTAssertEqual(mutation.disposition, .applied)
            XCTAssertNotEqual(mutation.resultingDigest, originalDigest)

            let replay = await runtime.workspaceStore.execute(envelope)

            XCTAssertEqual(first.disposition, .unchanged)
            XCTAssertEqual(first.exactRootResolution, .reused)
            XCTAssertEqual(first.workspace?.document.workspaceID, existing.id)
            XCTAssertEqual(replay.disposition, .deduplicated)
            XCTAssertEqual(replay.exactRootResolution, .reused)
            XCTAssertEqual(replay.workspace?.document.workspaceID, existing.id)
            XCTAssertEqual(replay.workspace?.document.contentDigest, mutation.resultingDigest)
            XCTAssertEqual(replay.resultingDigest, originalDigest)

            _ = await runtime.shutdown()
            domainRuntimes.removeAll { $0 === runtime }
            let restarted = try await makeDomainRuntime(profileIdentifier: profileIdentifier)
            let replayAfterRestart = await restarted.workspaceStore.execute(envelope)

            XCTAssertEqual(replayAfterRestart.disposition, .deduplicated)
            XCTAssertEqual(replayAfterRestart.exactRootResolution, .reused)
            XCTAssertEqual(replayAfterRestart.workspace?.document.workspaceID, existing.id)
            XCTAssertEqual(replayAfterRestart.workspace?.document.contentDigest, mutation.resultingDigest)
            XCTAssertEqual(replayAfterRestart.resultingDigest, originalDigest)
        }

        func testReplayedResolveOrCreateReturnsWorkspaceUnavailableAfterResultDeletion() async throws {
            let profileIdentifier = "workspace-open-folder-deleted-replay-\(UUID().uuidString)"
            let runtime = try await makeDomainRuntime(profileIdentifier: profileIdentifier)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1303)
            let folder = try makeFolder(named: "ResolveOrCreateReplayDeletion")
            let existing = WorkspaceModel(name: "Deleted Replay Winner", repoPaths: [folder.path])
            try await createAuthorityWorkspace(existing, using: client)
            let proposed = WorkspaceModel(name: "Deleted Replay Proposed", repoPaths: [folder.path])
            let canonicalRootPath = try canonicalRootPath(folder)
            let operationID = UUID()
            let envelope = try resolveOrCreateEnvelope(
                proposed,
                canonicalRootPath: canonicalRootPath,
                operationID: operationID,
                windowID: -1303
            )

            let first = await runtime.workspaceStore.execute(envelope)
            let currentSnapshot = await runtime.workspaceStore.workspaceSnapshot(existing.id)
            let current = try XCTUnwrap(currentSnapshot)
            let catalog = await client.snapshot()
            let deletion = await client.delete(
                workspaceID: existing.id,
                expectedCatalogRevision: catalog.catalogRevision,
                expectedWorkspaceRevision: current.revisions.workingRevision
            )
            XCTAssertEqual(deletion.disposition, .applied)

            let replay = await runtime.workspaceStore.execute(envelope)
            let replayAgain = await runtime.workspaceStore.execute(envelope)

            XCTAssertEqual(replay.disposition, .failed)
            XCTAssertEqual(replay.errorCode, .workspaceUnavailable)
            XCTAssertEqual(replay.diagnostic, "recorded_result_workspace_deleted")
            XCTAssertNil(replay.workspace)
            XCTAssertEqual(replay.resultingDigest, first.resultingDigest)
            XCTAssertEqual(replayAgain, replay, "Unavailable replay must not overwrite the original successful operation")

            _ = await runtime.shutdown()
            domainRuntimes.removeAll { $0 === runtime }
            let restarted = try await makeDomainRuntime(profileIdentifier: profileIdentifier)
            let replayAfterRestart = await restarted.workspaceStore.execute(envelope)
            let restartedCatalog = await restarted.workspaceStore.snapshot()

            XCTAssertEqual(replayAfterRestart.disposition, .failed)
            XCTAssertEqual(replayAfterRestart.errorCode, .workspaceUnavailable)
            XCTAssertEqual(replayAfterRestart.diagnostic, "recorded_result_workspace_deleted")
            XCTAssertNil(replayAfterRestart.workspace)
            XCTAssertFalse(restartedCatalog.workspaces.contains(where: {
                $0.document.workspaceID == proposed.id
            }))
        }

        func testLegacyResolveOrCreateReplayUsesDigestFallbackWhenResultIdentityIsMissing() async throws {
            let profileIdentifier = "workspace-open-folder-legacy-\(UUID().uuidString)"
            let runtime = try await makeDomainRuntime(profileIdentifier: profileIdentifier)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1304)
            let folder = try makeFolder(named: "ResolveOrCreateLegacyReplay")
            let existing = WorkspaceModel(name: "Legacy Replay Winner", repoPaths: [folder.path])
            try await createAuthorityWorkspace(existing, using: client)
            let proposed = WorkspaceModel(name: "Legacy Replay Proposed", repoPaths: [folder.path])
            let canonicalRootPath = try canonicalRootPath(folder)
            let operationID = UUID()
            let envelope = try resolveOrCreateEnvelope(
                proposed,
                canonicalRootPath: canonicalRootPath,
                operationID: operationID,
                windowID: -1304
            )

            let first = await runtime.workspaceStore.execute(envelope)
            XCTAssertEqual(first.workspace?.document.workspaceID, existing.id)
            let journalURL = try workingJournalURL(workspaceID: existing.id)
            _ = await runtime.shutdown()
            domainRuntimes.removeAll { $0 === runtime }
            try removeResultingWorkspaceID(
                operationID: operationID,
                expectedWorkspaceID: existing.id,
                from: journalURL
            )

            let restarted = try await makeDomainRuntime(profileIdentifier: profileIdentifier)
            let replay = await restarted.workspaceStore.execute(envelope)

            XCTAssertEqual(replay.disposition, .deduplicated)
            XCTAssertEqual(replay.workspace?.document.workspaceID, existing.id)
            XCTAssertEqual(replay.resultingDigest, first.resultingDigest)
        }

        func testAuthorityClientDeterministicWorkspaceEncodingDeduplicatesEqualModelsAndRejectsChangedModel() async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1305)
            let folder = try makeFolder(named: "DeterministicAuthorityEncoding")
            let stableWorkspaceID = try workspaceID(1305)
            let seed = WorkspaceModel(
                id: stableWorkspaceID,
                name: "Deterministic Seed",
                repoPaths: [folder.path]
            )
            try await createAuthorityWorkspace(seed, using: client)
            let authoritativeSnapshot = await runtime.workspaceStore.workspaceSnapshot(stableWorkspaceID)
            let authoritative = try XCTUnwrap(authoritativeSnapshot)

            let sliceEntries = [
                ("alpha.swift", [LineRange(start: 1, end: 3, description: "alpha")]),
                ("beta.swift", [LineRange(start: 5, end: 8, description: "beta")]),
                ("gamma.swift", [LineRange(start: 13, end: 21, description: "gamma")]),
                ("zeta.swift", [LineRange(start: 34, end: 55, description: "zeta")])
            ]
            var firstSlices: [String: [LineRange]] = [:]
            for (path, ranges) in sliceEntries.reversed() {
                firstSlices[path] = ranges
            }
            var secondSlices: [String: [LineRange]] = [:]
            for (path, ranges) in sliceEntries {
                secondSlices[path] = ranges
            }

            let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
            let tabID = try XCTUnwrap(
                UUID(uuidString: "33333333-3333-3333-3333-333333333333")
            )
            let selectedPromptID = try XCTUnwrap(
                UUID(uuidString: "44444444-4444-4444-4444-444444444444")
            )
            func replacementWorkspace(slices: [String: [LineRange]]) -> WorkspaceModel {
                let tab = ComposeTabState(
                    id: tabID,
                    name: "T1",
                    lastModified: fixedDate,
                    selection: StoredSelection(slices: slices),
                    promptText: "stable prompt",
                    selectedMetaPromptIDs: [selectedPromptID]
                )
                return WorkspaceModel(
                    id: stableWorkspaceID,
                    dateModified: fixedDate,
                    name: "Deterministic Replacement",
                    repoPaths: [folder.path],
                    lastUsed: fixedDate,
                    currentPromptText: "stable prompt",
                    selectedMetaPromptIDs: [selectedPromptID],
                    composeTabs: [tab],
                    activeComposeTabID: tabID
                )
            }

            let firstModel = replacementWorkspace(slices: firstSlices)
            let equalModel = replacementWorkspace(slices: secondSlices)
            XCTAssertEqual(firstModel, equalModel, "The fixture must construct equal models independently")

            let operationID = UUID()
            let expectedRevision = authoritative.revisions.workingRevision
            let mutationGate = WorkspaceRootMutationTestGate()
            await runtime.workspaceStore.testSetAfterWorkspaceMutationGateAcquired { workspaceID in
                guard workspaceID == stableWorkspaceID else { return }
                await mutationGate.pauseUntilReleased()
            }
            defer {
                Task {
                    await runtime.workspaceStore.testSetAfterWorkspaceMutationGateAcquired(nil)
                }
            }

            async let firstRequest = client.replaceWorking(
                firstModel,
                fileURL: authoritative.document.fileURL,
                expectedWorkspaceRevision: expectedRevision,
                operationID: operationID
            )
            await mutationGate.waitUntilPaused()
            async let replayRequest = client.replaceWorking(
                equalModel,
                fileURL: authoritative.document.fileURL,
                expectedWorkspaceRevision: expectedRevision,
                operationID: operationID
            )
            await Task.yield()
            await mutationGate.release()
            let (first, replay) = try await (firstRequest, replayRequest)
            let mutationGateEntryCount = await mutationGate.entryCount()

            func sortedWorkspaceBytes(_ workspace: WorkspaceModel) throws -> Data {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                return try encoder.encode(workspace)
            }
            let expectedFirstBytes = try sortedWorkspaceBytes(firstModel)
            let expectedEqualBytes = try sortedWorkspaceBytes(equalModel)
            let expectedDocument = try DomainWorkspaceDocument.decode(
                documentBytes: expectedFirstBytes,
                fileURL: authoritative.document.fileURL
            )
            let actualDocument = try XCTUnwrap(first.workspace?.document)
            let serializedDocument = String(decoding: actualDocument.documentBytes, as: UTF8.self)
            let alphaIndex = try XCTUnwrap(serializedDocument.range(of: "\"alpha.swift\"")?.lowerBound)
            let betaIndex = try XCTUnwrap(serializedDocument.range(of: "\"beta.swift\"")?.lowerBound)
            let gammaIndex = try XCTUnwrap(serializedDocument.range(of: "\"gamma.swift\"")?.lowerBound)
            let zetaIndex = try XCTUnwrap(serializedDocument.range(of: "\"zeta.swift\"")?.lowerBound)

            XCTAssertEqual(expectedFirstBytes, expectedEqualBytes)
            XCTAssertEqual(actualDocument.documentBytes, expectedFirstBytes)
            XCTAssertLessThan(alphaIndex, betaIndex)
            XCTAssertLessThan(betaIndex, gammaIndex)
            XCTAssertLessThan(gammaIndex, zetaIndex)
            XCTAssertEqual(first.disposition, .applied)
            XCTAssertEqual(first.resultingDigest, expectedDocument.contentDigest)
            XCTAssertEqual(actualDocument.contentDigest, expectedDocument.contentDigest)
            XCTAssertEqual(replay.disposition, .deduplicated)
            XCTAssertEqual(replay.resultingDigest, first.resultingDigest)
            XCTAssertEqual(replay.workspace?.document.contentDigest, first.resultingDigest)
            XCTAssertEqual(
                mutationGateEntryCount,
                2,
                "Both equal replacements must reach the mutation gate before replay deduplication"
            )

            var changedModel = firstModel
            changedModel.name = "Changed Replacement"
            let collision = try await client.replaceWorking(
                changedModel,
                fileURL: authoritative.document.fileURL,
                expectedWorkspaceRevision: expectedRevision,
                operationID: operationID
            )
            XCTAssertEqual(collision.disposition, .invalid)
            XCTAssertEqual(collision.errorCode, .operationIDCollision)
            XCTAssertEqual(collision.diagnostic, "operation_id_reused_with_different_command")
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
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1306)
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

            try await saveAuthoritativeWorkspace(existing, using: client)
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
            try await assertInteractiveStaleActivation(metadataPublished: false, refreshBlocked: false)
        }

        func testInteractiveReuseReloadsStaleLoadedRootsWithCurrentMetadata() async throws {
            try await assertInteractiveStaleActivation(metadataPublished: true, refreshBlocked: false)
        }

        func testInteractiveStaleSameIDActivationReportsRefreshBlockWithoutDuplicate() async throws {
            try await assertInteractiveStaleActivation(metadataPublished: false, refreshBlocked: true)
        }

        private func assertInteractiveStaleActivation(metadataPublished: Bool, refreshBlocked: Bool) async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1307)
            let authorityManager = makeManager(domainRuntime: runtime)
            let targetManager = makeManager(domainRuntime: runtime)
            let targetBridge = try XCTUnwrap(domainBridges.last)
            await authorityManager.awaitInitialized()
            await targetManager.awaitInitialized()
            let originalFolder = try makeFolder(named: "InteractiveStaleOriginal")
            let requestedFolder = try makeFolder(named: "InteractiveStaleRequested")
            let originalFile = originalFolder.appendingPathComponent("Original.swift")
            let requestedFile = requestedFolder.appendingPathComponent("Requested.swift")
            try Data("let original = true\n".utf8).write(to: originalFile)
            try Data("let requested = true\n".utf8).write(to: requestedFile)
            let workspace = WorkspaceModel(
                name: "Interactive Stale",
                repoPaths: [originalFolder.path]
            )
            try await saveAuthoritativeWorkspace(workspace, using: client)
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
            // File view models are lazy; query the loaded workspace index before checking the UI projection.
            let loadedOriginal = await targetManager.fileManager.findFile(atPath: originalFile.path)
            XCTAssertNotNil(loadedOriginal)
            let countBeforeOpen = targetManager.workspaces.count
            let catalogBeforeOpen = await client.snapshot()
            targetBridge.stop()
            var replacement = workspace
            replacement.repoPaths = [requestedFolder.path]
            replacement.dateModified = Date()
            try await saveAuthoritativeWorkspace(replacement, using: client)
            XCTAssertEqual(targetManager.activeWorkspace?.repoPaths, [originalFolder.path])

            if metadataPublished {
                let index = try XCTUnwrap(targetManager.workspaces.firstIndex { $0.id == workspace.id })
                targetManager.workspaces[index] = replacement
            }
            XCTAssertTrue(targetManager.fileManager.rootFolders.contains { $0.fullPath == originalFolder.path })
            targetManager.isRefreshing = refreshBlocked
            defer { targetManager.isRefreshing = false }
            do {
                try await targetManager.openWorkspace(
                    fromFolderURL: requestedFolder,
                    behavior: .createNewWorkspace
                )
                XCTAssertFalse(refreshBlocked, "Stale same-ID activation must report the refresh block")
            } catch let WorkspaceOpenError.activationBlocked(workspaceID, creationCommitted, reason) {
                XCTAssertTrue(refreshBlocked)
                XCTAssertEqual(workspaceID, workspace.id)
                XCTAssertFalse(creationCommitted)
                XCTAssertEqual(reason, "Cannot reload the active workspace while refresh is in progress.")
            }

            XCTAssertEqual(targetManager.activeWorkspaceID, workspace.id)
            XCTAssertEqual(targetManager.activeWorkspace?.repoPaths, [requestedFolder.path])
            XCTAssertEqual(targetManager.workspaces.count, countBeforeOpen)
            let catalogAfterOpen = await client.snapshot()
            XCTAssertEqual(catalogAfterOpen.workspaces.count, catalogBeforeOpen.workspaces.count)
            XCTAssertEqual(catalogAfterOpen.workspaces.count(where: { $0.document.workspaceID == workspace.id }), 1)
            if refreshBlocked {
                XCTAssertTrue(targetManager.fileManager.rootFolders.contains { $0.fullPath == originalFolder.path })
                XCTAssertFalse(targetManager.fileManager.rootFolders.contains { $0.fullPath == requestedFolder.path })
                XCTAssertNotNil(targetManager.fileManager.findFileByFullPath(originalFile.path))
                XCTAssertNil(targetManager.fileManager.findFileByFullPath(requestedFile.path))
                return
            }
            XCTAssertTrue(targetManager.fileManager.rootFolders.contains { $0.fullPath == requestedFolder.path })
            XCTAssertFalse(targetManager.fileManager.rootFolders.contains { $0.fullPath == originalFolder.path })
            let loadedRequested = await targetManager.fileManager.findFile(atPath: requestedFile.path)
            XCTAssertNotNil(loadedRequested)
            XCTAssertNil(targetManager.fileManager.findFileByFullPath(originalFile.path))
            await targetManager.fileManager.selectFiles(withPaths: [requestedFile.path])
            XCTAssertEqual(targetManager.fileManager.selectedFiles.map(\.fullPath), [requestedFile.path])
        }

        func testManagerResolutionExposesCreatedAndReusedProvenance() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "ManagerResolutionProvenance")

            let created = try await manager.resolveOrCreatePersistentWorkspaceWithProvenance(
                fromFolderURL: folder
            )
            let reused = try await manager.resolveOrCreatePersistentWorkspaceWithProvenance(
                fromFolderURL: folder
            )

            XCTAssertEqual(created.provenance, .created)
            XCTAssertTrue(created.creationCommitted)
            XCTAssertEqual(reused.provenance, .reused)
            XCTAssertFalse(reused.creationCommitted)
            XCTAssertEqual(reused.workspace.id, created.workspace.id)
            XCTAssertNotEqual(reused.operationID, created.operationID)
        }

        func testManagerDecodesRecoveryBlockedResolution() async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1320)
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "ManagerRecoveryBlocked")
            let retired = try WorkspaceModel(
                id: workspaceID(50),
                name: "Manager Incomplete Restore",
                repoPaths: [folder.path],
                isHiddenInMenus: true,
                consolidatedIntoWorkspaceID: workspaceID(999)
            )
            try await createAuthorityWorkspace(retired, using: client)
            let authoritySnapshot = await client.workspaceSnapshot(retired.id)
            let retiredSnapshot = try XCTUnwrap(authoritySnapshot)
            var restoredWorking = retired
            restoredWorking.isHiddenInMenus = false
            restoredWorking.consolidatedIntoWorkspaceID = nil
            let working = try await client.replaceWorking(
                restoredWorking,
                fileURL: retiredSnapshot.document.fileURL,
                expectedWorkspaceRevision: retiredSnapshot.revisions.workingRevision
            )
            XCTAssertEqual(working.disposition, .applied)

            do {
                _ = try await manager.resolveOrCreatePersistentWorkspaceWithProvenance(
                    fromFolderURL: folder
                )
                XCTFail("Expected the incomplete restore to block manager resolution")
            } catch let error as DomainWorkspaceAuthorityOperationError {
                XCTAssertEqual(error.outcome.disposition, .conflict)
                XCTAssertEqual(error.outcome.errorCode, .stateConflict)
                XCTAssertEqual(error.outcome.exactRootResolution, .recoveryBlocked)
                XCTAssertEqual(error.outcome.diagnostic, "exact_root_restoration_incomplete")
            }
            XCTAssertEqual(
                manager.domainWorkspaceAuthorityIssue?.diagnostic,
                "exact_root_restoration_incomplete"
            )
        }

        func testCreatedWorkspaceActivationBlockReportsCommittedCreationWithoutRollback() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "CreatedThenBlocked")
            let activeIDBeforeOpen = manager.activeWorkspaceID
            manager.isRefreshing = true
            defer { manager.isRefreshing = false }
            var createdWorkspaceID: UUID?

            do {
                try await manager.openWorkspace(
                    fromFolderURL: folder,
                    behavior: .createNewWorkspace
                )
                XCTFail("Expected activation to be blocked after creation")
            } catch let WorkspaceOpenError.activationBlocked(workspaceID, creationCommitted, reason) {
                createdWorkspaceID = workspaceID
                XCTAssertTrue(creationCommitted)
                XCTAssertEqual(reason, "Cannot switch workspaces while refresh is in progress.")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            let workspaceID = try XCTUnwrap(createdWorkspaceID)
            let snapshot = await runtime.workspaceStore.snapshot()
            XCTAssertTrue(snapshot.workspaces.contains(where: {
                $0.document.workspaceID == workspaceID
            }))
            XCTAssertTrue(manager.workspaces.contains(where: { $0.id == workspaceID }))
            XCTAssertEqual(manager.activeWorkspaceID, activeIDBeforeOpen)
        }

        func testDirectAddFolderCreationBlockReportsCommittedCreation() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "DirectAddFolderCreatedThenBlocked")
            manager.isRefreshing = true
            defer { manager.isRefreshing = false }
            var createdWorkspaceID: UUID?

            do {
                try await manager.addFolder(folder)
                XCTFail("Expected direct add-folder activation to be blocked after creation")
            } catch let WorkspaceOpenError.activationBlocked(workspaceID, creationCommitted, reason) {
                createdWorkspaceID = workspaceID
                XCTAssertTrue(creationCommitted)
                XCTAssertEqual(reason, "Cannot switch workspaces while refresh is in progress.")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            let workspaceID = try XCTUnwrap(createdWorkspaceID)
            let snapshot = await runtime.workspaceStore.snapshot()
            XCTAssertTrue(snapshot.workspaces.contains(where: {
                $0.document.workspaceID == workspaceID
            }))
            XCTAssertNotEqual(manager.activeWorkspaceID, workspaceID)
        }

        func testLegacyCreatedWorkspaceActivationBlockDoesNotClaimCommittedCreation() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "LegacyCreatedThenBlocked")
            manager.isRefreshing = true
            defer { manager.isRefreshing = false }

            do {
                try await manager.openWorkspace(
                    fromFolderURL: folder,
                    behavior: .createNewWorkspace
                )
                XCTFail("Expected activation to be blocked after legacy creation")
            } catch let WorkspaceOpenError.activationBlocked(_, creationCommitted, reason) {
                XCTAssertFalse(creationCommitted)
                XCTAssertEqual(reason, "Cannot switch workspaces while refresh is in progress.")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        func testPersistentUnownedWorkspaceIsRejectedForActivation() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "PersistentUnownedActivation")
            let unowned = WorkspaceModel(
                name: "Persistent Unowned",
                repoPaths: [folder.path]
            )
            manager.workspaces.append(unowned)
            let activeIDBeforeSwitch = manager.activeWorkspaceID

            let result = await manager.switchWorkspace(
                to: unowned,
                saveState: false,
                reason: "persistentUnownedFixture"
            )

            guard case let .blocked(reason) = result else {
                return XCTFail("Expected authority-absent persistent activation to be blocked")
            }
            XCTAssertTrue(reason.contains("could not be verified for activation"))
            XCTAssertEqual(manager.activeWorkspaceID, activeIDBeforeSwitch)
        }

        func testRootlessPersistentCreationWaitsForPublicationBeforeActivation() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let gate = WorkspaceRootMutationTestGate()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { _, _, _ in
                await gate.pauseUntilReleased()
            }
            defer { manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil) }

            let workspace = manager.createWorkspace(
                name: "Rootless Pending Publication",
                repoPaths: []
            )
            await gate.waitUntilPaused()
            let switchTask = Task {
                await manager.switchWorkspace(
                    to: workspace,
                    saveState: false,
                    reason: "rootlessPendingPublicationFixture"
                )
            }
            await Task.yield()
            XCTAssertNotEqual(manager.activeWorkspaceID, workspace.id)

            await gate.release()
            let result = await switchTask.value

            XCTAssertEqual(result, .switched)
            XCTAssertEqual(manager.activeWorkspaceID, workspace.id)
            let snapshot = await runtime.workspaceStore.snapshot()
            XCTAssertTrue(snapshot.workspaces.contains(where: {
                $0.document.workspaceID == workspace.id
            }))
        }

        func testPendingPersistentPublicationCoversEveryRootAndCleansUpAfterJoin() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let firstFolder = try makeFolder(named: "PendingPublicationFirst")
            let secondFolder = try makeFolder(named: "PendingPublicationSecond")
            let gate = WorkspaceRootMutationTestGate()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { _, _, _ in
                await gate.pauseUntilReleased()
            }
            defer { manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil) }

            let workspace = manager.createWorkspace(
                name: "Pending Publication",
                repoPaths: [firstFolder.path, secondFolder.path]
            )
            await gate.waitUntilPaused()
            let firstRoot = WorkspaceRootSetKey(paths: [firstFolder.path])
            let secondRoot = WorkspaceRootSetKey(paths: [secondFolder.path])
            let firstToken = try XCTUnwrap(manager.pendingPersistentWorkspacePublication(
                workspaceID: workspace.id,
                exactRoot: firstRoot
            ))
            let secondToken = try XCTUnwrap(manager.pendingPersistentWorkspacePublication(
                workspaceID: workspace.id,
                exactRoot: secondRoot
            ))

            XCTAssertEqual(firstToken.operationID, secondToken.operationID)
            XCTAssertEqual(firstToken.expectedRoot, firstRoot)
            XCTAssertEqual(secondToken.expectedRoot, secondRoot)
            XCTAssertNil(manager.pendingPersistentWorkspacePublication(
                workspaceID: workspace.id,
                exactRoot: WorkspaceRootSetKey(paths: ["/tmp/not-this-root"])
            ))
            let beforePublication = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(beforePublication.workspaces.contains(where: {
                $0.document.workspaceID == workspace.id
            }))

            let cancelledJoin = Task {
                try await firstToken.join()
            }
            await Task.yield()
            cancelledJoin.cancel()
            do {
                _ = try await cancelledJoin.value
                XCTFail("Expected the individual publication join to be cancelled")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertNotNil(manager.pendingPersistentWorkspacePublication(
                workspaceID: workspace.id,
                exactRoot: firstRoot
            ))

            await gate.release()
            let firstOutcome = try await firstToken.join()
            let secondOutcome = try await secondToken.join()

            XCTAssertEqual(firstOutcome.operationID, firstToken.operationID)
            XCTAssertEqual(firstOutcome.disposition, .applied)
            XCTAssertEqual(secondOutcome, firstOutcome)
            try await waitUntil {
                manager.pendingPersistentWorkspacePublication(
                    workspaceID: workspace.id,
                    exactRoot: firstRoot
                ) == nil && manager.pendingPersistentWorkspacePublication(
                    workspaceID: workspace.id,
                    exactRoot: secondRoot
                ) == nil
            }
        }

        func testPendingPersistentPublicationTokenSurvivesRegistryDropOnWindowClose() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "PendingPublicationWindowClose")
            let gate = WorkspaceRootMutationTestGate()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { _, _, _ in
                await gate.pauseUntilReleased()
            }

            let workspace = manager.createWorkspace(
                name: "Pending Publication Close",
                repoPaths: [folder.path]
            )
            await gate.waitUntilPaused()
            let root = WorkspaceRootSetKey(paths: [folder.path])
            let token = try XCTUnwrap(manager.pendingPersistentWorkspacePublication(
                workspaceID: workspace.id,
                exactRoot: root
            ))

            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            manager.prepareForWindowClose()
            XCTAssertNil(manager.pendingPersistentWorkspacePublication(
                workspaceID: workspace.id,
                exactRoot: root
            ))

            await gate.release()
            let outcome = try await token.join()
            XCTAssertEqual(outcome.operationID, token.operationID)
            XCTAssertEqual(outcome.disposition, .applied)
            let snapshot = await runtime.workspaceStore.snapshot()
            XCTAssertTrue(snapshot.workspaces.contains(where: {
                $0.document.workspaceID == workspace.id
            }))
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
            manager.isRefreshing = true
            defer { manager.isRefreshing = false }

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
            do {
                try await openTask.value
                XCTFail("Expected cancelled activation to be observable")
            } catch let WorkspaceOpenError.activationCancelled(workspaceID, creationCommitted, reason) {
                XCTAssertFalse(creationCommitted)
                XCTAssertEqual(workspaceID, manager.workspaces.first(where: {
                    WorkspaceFolderOpenResolver.containsExactRoot(folder.path, in: $0)
                })?.id)
                XCTAssertFalse(reason.isEmpty)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(manager.activeWorkspaceID, activeIDBeforeOpen)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
            XCTAssertNil(manager.pendingSwitchConfirmation)
            XCTAssertNil(manager.pendingWorkspaceSwitchBlockedNotice)
        }

        func testLastRootRemovalPublishesMissingDefaultBeforeActivation() async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1322)
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let initialDefault = try XCTUnwrap(manager.workspaces.first(where: { $0.isSystemWorkspace }))
            let folder = try makeFolder(named: "LastRootMissingDefault")
            let workspace = WorkspaceModel(
                name: "Last Root Workspace",
                repoPaths: [folder.path]
            )
            try await createAuthorityWorkspace(workspace, using: client)
            try await waitUntil {
                manager.workspace(withID: workspace.id) != nil
            }
            let projectedWorkspace = try XCTUnwrap(manager.workspace(withID: workspace.id))
            let initialSwitch = await manager.switchWorkspace(
                to: projectedWorkspace,
                saveState: false,
                reason: "lastRootMissingDefaultFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)

            let beforeDelete = await client.snapshot()
            let authoritativeDefault = try XCTUnwrap(beforeDelete.workspaces.first(where: {
                $0.document.workspaceID == initialDefault.id
            }))
            let deleteOutcome = await client.delete(
                workspaceID: initialDefault.id,
                expectedCatalogRevision: beforeDelete.catalogRevision,
                expectedWorkspaceRevision: authoritativeDefault.revisions.workingRevision
            )
            XCTAssertEqual(deleteOutcome.disposition, .applied)
            try await waitUntil {
                manager.workspace(withID: initialDefault.id) == nil
            }

            let publicationGate = WorkspaceRootMutationTestGate()
            manager.setSystemWorkspaceCreationWillPublishHandlerForTesting { _ in
                await publicationGate.pauseUntilReleased()
            }
            defer {
                manager.setSystemWorkspaceCreationWillPublishHandlerForTesting(nil)
            }
            let removal = Task {
                await manager.removeFolder(folder.path, from: projectedWorkspace)
            }
            await publicationGate.waitUntilPaused()
            XCTAssertEqual(manager.activeWorkspaceID, workspace.id)

            await publicationGate.release()
            await removal.value

            let activatedDefault = try XCTUnwrap(manager.activeWorkspace)
            XCTAssertTrue(activatedDefault.isSystemWorkspace)
            XCTAssertEqual(activatedDefault.name, "Default")
            XCTAssertTrue(activatedDefault.repoPaths.isEmpty)
            XCTAssertNotEqual(activatedDefault.id, initialDefault.id)
            let authoritativeCreatedDefault = await client.canonicalWorkspaceSnapshot(activatedDefault.id)
            XCTAssertNotNil(authoritativeCreatedDefault)
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

            do {
                try await manager.openWorkspace(
                    fromFolderURL: folder,
                    behavior: .createNewWorkspace
                )
                XCTFail("Expected blocked activation to be observable")
            } catch let WorkspaceOpenError.activationBlocked(workspaceID, creationCommitted, reason) {
                XCTAssertFalse(creationCommitted)
                XCTAssertEqual(workspaceID, manager.workspaces.first(where: {
                    WorkspaceFolderOpenResolver.containsExactRoot(folder.path, in: $0)
                })?.id)
                XCTAssertEqual(reason, "Cannot switch workspaces while refresh is in progress.")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

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

        private func workspaceID(_ suffix: Int) throws -> UUID {
            try XCTUnwrap(UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                suffix
            )))
        }

        private func canonicalRootPath(_ folder: URL) throws -> String {
            try XCTUnwrap(
                WorkspaceRootSetKey(paths: [folder.path]).normalizedPaths.first
            ).lowercased()
        }

        private func authorityWorkspaceFileURL(_ workspaceID: UUID) -> URL {
            storageRoot.appendingPathComponent("\(workspaceID.uuidString).json")
        }

        private func resolveOrCreateEnvelope(
            _ workspace: WorkspaceModel,
            canonicalRootPath: String,
            operationID: UUID,
            windowID: Int
        ) throws -> DomainWorkspaceCommandEnvelope {
            let document = try DomainWorkspaceDocument.decode(
                documentBytes: JSONEncoder().encode(workspace),
                fileURL: authorityWorkspaceFileURL(workspace.id)
            )
            return DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedWorkspaceRevision: 0,
                origin: .appPresentation(windowID: windowID),
                command: .resolveOrCreateWorkspaceForExactRoot(
                    document: document,
                    canonicalRootPath: canonicalRootPath
                )
            )
        }

        private func createAuthorityWorkspace(
            _ workspace: WorkspaceModel,
            using client: DomainWorkspaceAuthorityClient
        ) async throws {
            let outcome = try await client.create(
                workspace,
                fileURL: authorityWorkspaceFileURL(workspace.id)
            )
            XCTAssertEqual(outcome.disposition, .applied)
            XCTAssertEqual(outcome.workspace?.document.workspaceID, workspace.id)
        }

        private func saveAuthoritativeWorkspace(
            _ workspace: WorkspaceModel,
            using client: DomainWorkspaceAuthorityClient
        ) async throws {
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
                    fileURL: authorityWorkspaceFileURL(workspace.id)
                )
            }
            guard outcome.disposition == .applied
                || outcome.disposition == .unchanged
                || outcome.disposition == .deduplicated
            else {
                throw DomainWorkspaceAuthorityOperationError(outcome: outcome)
            }
        }

        private func workingJournalURL(workspaceID: UUID) throws -> URL {
            let runtimeState = storageRoot.appendingPathComponent("runtime-state", isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: runtimeState,
                includingPropertiesForKeys: nil
            ) else {
                throw WorkspaceOpenFolderOrchestrationTestError.journalNotFound
            }
            for case let url as URL in enumerator
                where url.lastPathComponent == "\(workspaceID.uuidString).json"
                && url.deletingLastPathComponent().lastPathComponent == "working-journals"
            {
                return url
            }
            throw WorkspaceOpenFolderOrchestrationTestError.journalNotFound
        }

        private func removeResultingWorkspaceID(
            operationID: UUID,
            expectedWorkspaceID: UUID,
            from journalURL: URL
        ) throws {
            let data = try Data(contentsOf: journalURL)
            var journal = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            var operations = try XCTUnwrap(journal["operations"] as? [[String: Any]])
            let operationIndex = try XCTUnwrap(operations.firstIndex(where: {
                $0["operationID"] as? String == operationID.uuidString
            }))
            XCTAssertEqual(
                operations[operationIndex]["resultingWorkspaceID"] as? String,
                expectedWorkspaceID.uuidString,
                "New operation records must persist the stable result identity"
            )
            operations[operationIndex].removeValue(forKey: "resultingWorkspaceID")
            journal["operations"] = operations
            let legacyData = try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
            try legacyData.write(to: journalURL, options: .atomic)
        }

        private func makeDomainRuntime(
            profileIdentifier: String = "workspace-open-folder-\(UUID().uuidString)"
        ) async throws -> MCPDomainRuntime {
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: profileIdentifier,
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
        private var entries = 0

        func pauseUntilReleased() async {
            entries += 1
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

        func entryCount() -> Int {
            entries
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
        case journalNotFound
    }
#endif
