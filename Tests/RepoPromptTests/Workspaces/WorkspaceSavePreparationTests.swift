@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceSavePreparationTests: XCTestCase {
        private var originalMCPAutoStart = false
        private var savePreparationGates: [WorkspaceSavePreparationGate] = []
        private var saveTasks: [Task<Void, Never>] = []
        private var managersWithSavePreparationHooks: [WorkspaceManagerViewModel] = []
        private var retainedWorkspaceManagers: [WorkspaceManagerViewModel] = []
        private var temporaryDirectories: [URL] = []

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        }

        override func tearDown() async throws {
            for managersWithSavePreparationHook in managersWithSavePreparationHooks {
                managersWithSavePreparationHook.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            }
            savePreparationGates.forEach { $0.cancel() }
            saveTasks.forEach { $0.cancel() }
            for saveTask in saveTasks {
                await saveTask.value
            }
            managersWithSavePreparationHooks.removeAll()
            savePreparationGates.removeAll()
            saveTasks.removeAll()
            for manager in retainedWorkspaceManagers {
                manager.prepareForWindowClose()
            }
            retainedWorkspaceManagers.removeAll()
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
            for directory in temporaryDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            temporaryDirectories.removeAll()
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try await super.tearDown()
        }

        func testSaveKeepsCapturedWorkspaceIdentityAndURLAcrossReorderAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "IdentityURL")
            let composition = makeComposition(windowID: -981)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspaceA = makeWorkspace(name: "A", storage: storageRoot.appendingPathComponent("A"))
            let workspaceB = makeWorkspace(name: "B", storage: storageRoot.appendingPathComponent("B"))
            manager.workspaces.append(contentsOf: [workspaceA, workspaceB])
            let switchResult = await manager.switchWorkspace(to: workspaceA, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            await manager.waitUntilPostSwitchGitDataLoadComplete()
            manager.markWorkspaceDirty()

            let gate = WorkspaceSavePreparationGate()
            savePreparationGates.append(gate)
            managersWithSavePreparationHooks.append(manager)
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, fileURL, _ in
                await gate.arriveAndWait(workspaceID: workspaceID, fileURL: fileURL)
            }
            let saveTask = Task { @MainActor in
                await manager.pollAndSaveStateAsync()
            }
            saveTasks.append(saveTask)
            let arrival = try await gate.waitUntilArrivedAndBlocked()
            XCTAssertEqual(arrival.workspaceID, workspaceA.id)
            XCTAssertEqual(arrival.fileURL, manager.workspaceFileURL(for: workspaceA))
            try manager.workspaces.swapAt(
                XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceA.id }),
                XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceB.id })
            )
            gate.release()
            await saveTask.value
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            let savedA = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: arrival.fileURL, scheduleNormalizationWriteback: false)
            XCTAssertEqual(savedA.id, workspaceA.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: manager.workspaceFileURL(for: workspaceB).path))
        }

        func testDomainReadRegistrationCacheSkipsUnchangedStateAndInvalidatesOnDirtyOrRelocation() async throws {
            let storageRoot = try temporaryDirectory(named: "ReadRegistrationCache")
            let composition = makeComposition(windowID: -991)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(
                name: "ReadCache",
                storage: storageRoot.appendingPathComponent("ReadCache")
            )
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            await manager.waitUntilPostSwitchGitDataLoadComplete()
            let fileURL = manager.workspaceFileURL(for: workspace)

            // First scoped read must register and, once confirmed, unchanged state is an O(1) skip.
            let first = try XCTUnwrap(manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL))
            XCTAssertEqual(first.workspaceID, workspace.id)
            manager.confirmDomainReadRegistration(first)
            XCTAssertNil(
                manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL),
                "Consecutive reads over unchanged working state must skip re-registration."
            )

            // A relocated workspace file is a different registration even at the same state version.
            let relocatedURL = storageRoot.appendingPathComponent("Relocated/workspace.json")
            XCTAssertNotNil(
                manager.domainReadRegistrationToken(for: workspace, fileURL: relocatedURL),
                "A changed target file URL must invalidate the cached registration."
            )

            // Any dirty-tracking bump requires a fresh registration.
            manager.markWorkspaceDirty()
            let afterDirty = try XCTUnwrap(
                manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL),
                "A working-state mutation must invalidate the cached registration."
            )
            XCTAssertNotEqual(afterDirty.stateVersion, first.stateVersion)

            // A mutation racing the awaited registration must not confirm the stale token.
            manager.markWorkspaceDirty()
            manager.confirmDomainReadRegistration(afterDirty)
            XCTAssertNotNil(
                manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL),
                "A token issued before a racing mutation must not satisfy the next read."
            )
        }

        func testDomainProjectionInvalidatesConfirmedReadRegistrationCache() async throws {
            let storageRoot = try temporaryDirectory(named: "ProjectionReadCache")
            let composition = makeComposition(windowID: -992)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(
                name: "Projected",
                storage: storageRoot.appendingPathComponent("Projected")
            )
            manager.workspaces.append(workspace)
            let fileURL = manager.workspaceFileURL(for: workspace)

            func confirmRegistration() throws {
                let token = try XCTUnwrap(
                    manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL)
                )
                manager.confirmDomainReadRegistration(token)
                XCTAssertNil(manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL))
            }

            // An unchanged projected digest keeps the confirmed registration cached.
            try confirmRegistration()
            manager.invalidateConfirmedDomainReadRegistrations(
                previousDigestsByWorkspaceID: [workspace.id: "digest-a"],
                projectedDigestsByWorkspaceID: [workspace.id: "digest-a"]
            )
            XCTAssertNil(
                manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL),
                "An unchanged projected digest must not invalidate the confirmed registration."
            )

            // A moved projected digest (external reload, cross-window commit) forces the next
            // scoped read to re-register.
            manager.invalidateConfirmedDomainReadRegistrations(
                previousDigestsByWorkspaceID: [workspace.id: "digest-a"],
                projectedDigestsByWorkspaceID: [workspace.id: "digest-b"]
            )
            XCTAssertNotNil(
                manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL),
                "A changed projected digest must invalidate the confirmed registration."
            )

            // A workspace removed from the projected catalog also drops its registration.
            try confirmRegistration()
            manager.invalidateConfirmedDomainReadRegistrations(
                previousDigestsByWorkspaceID: [workspace.id: "digest-b"],
                projectedDigestsByWorkspaceID: [:]
            )
            XCTAssertNotNil(
                manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL),
                "A removed projected workspace must invalidate the confirmed registration."
            )

            // End-to-end: a domain projection publication re-validates the cache through the same
            // seam. Without an authority client this composition conservatively clears it.
            try confirmRegistration()
            manager.reportDomainProjectionFailure(NSError(
                domain: "WorkspaceSavePreparationTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "transient projection failure"]
            ))
            XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.kind, .projectionFailure)
            manager.applyDomainWorkspaceProjection(
                [workspace],
                fileURLsByWorkspaceID: [workspace.id: fileURL],
                revisionsByWorkspaceID: [:],
                digestsByWorkspaceID: [workspace.id: "digest-c"],
                healthByWorkspaceID: [workspace.id: .writable],
                catalogRevision: 1,
                preferredActiveWorkspaceID: workspace.id,
                publicationSequence: 1
            )
            XCTAssertNotNil(
                manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL),
                "A projected catalog publication must invalidate confirmed read registrations."
            )
            XCTAssertNil(
                manager.domainWorkspaceAuthorityIssue,
                "A successful full-model projection must clear its stale projection failure."
            )
        }

        func testProjectionInvalidationFencesInFlightReadRegistrationToken() async throws {
            let storageRoot = try temporaryDirectory(named: "ReadRegistrationFence")
            let composition = makeComposition(windowID: -993)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(
                name: "Fenced",
                storage: storageRoot.appendingPathComponent("Fenced")
            )
            manager.workspaces.append(workspace)
            let fileURL = manager.workspaceFileURL(for: workspace)

            // Deterministic race: the token is issued (the awaited registerForRead begins), then a
            // projected digest change invalidates the workspace before the registration confirms.
            // Projections do not move dirty-tracking state versions, so only the pending-attempt
            // fence can reject this token.
            let inFlight = try XCTUnwrap(
                manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL)
            )
            manager.invalidateConfirmedDomainReadRegistrations(
                previousDigestsByWorkspaceID: [workspace.id: "digest-a"],
                projectedDigestsByWorkspaceID: [workspace.id: "digest-b"]
            )
            manager.confirmDomainReadRegistration(inFlight)
            XCTAssertNotNil(
                manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL),
                "A token issued before a projection invalidation must not be confirmable after it."
            )

            // The same fence applies when the workspace disappears from the projected catalog.
            let secondInFlight = try XCTUnwrap(
                manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL)
            )
            manager.invalidateConfirmedDomainReadRegistrations(
                previousDigestsByWorkspaceID: [workspace.id: "digest-b"],
                projectedDigestsByWorkspaceID: [:]
            )
            manager.confirmDomainReadRegistration(secondInFlight)
            XCTAssertFalse(
                manager.debugDomainReadRegistrationStateExistsForWorkspace(workspace.id),
                "An invalidated/removed workspace must retain no registration state — no tombstones."
            )
            XCTAssertNotNil(
                manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL),
                "A token issued before a projected removal must not be confirmable after it."
            )

            // A fresh post-projection token confirms normally and restores the O(1) skip.
            let fresh = try XCTUnwrap(
                manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL)
            )
            XCTAssertNotEqual(fresh.attemptID, inFlight.attemptID)
            manager.confirmDomainReadRegistration(fresh)
            XCTAssertNil(manager.domainReadRegistrationToken(for: workspace, fileURL: fileURL))
        }

        func testSaveBailsWithoutEnqueueOrAcknowledgementWhenWorkspaceRemovedAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "Removal")
            let composition = makeComposition(windowID: -982)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(name: "Removed", storage: storageRoot.appendingPathComponent("Removed"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            await manager.waitUntilPostSwitchGitDataLoadComplete()
            manager.markWorkspaceDirty()
            let expectedURL = manager.workspaceFileURL(for: workspace)

            let gate = WorkspaceSavePreparationGate()
            savePreparationGates.append(gate)
            managersWithSavePreparationHooks.append(manager)
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, fileURL, _ in
                await gate.arriveAndWait(workspaceID: workspaceID, fileURL: fileURL)
            }
            let saveTask = Task { @MainActor in
                await manager.pollAndSaveStateAsync()
            }
            saveTasks.append(saveTask)
            _ = try await gate.waitUntilArrivedAndBlocked()
            manager.workspaces.removeAll { $0.id == workspace.id }
            gate.release()
            await saveTask.value
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            XCTAssertFalse(FileManager.default.fileExists(atPath: expectedURL.path))
            XCTAssertNil(manager.debugLastSavedVersionForWorkspace(workspace.id))
        }

        func testSaveRetriesSameIdentityOnceWhenStateChangesAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "Retry")
            let composition = makeComposition(windowID: -983)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(name: "Retry", storage: storageRoot.appendingPathComponent("Retry"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            await manager.waitUntilPostSwitchGitDataLoadComplete()
            manager.markWorkspaceDirty()
            manager.resetWorkspaceSaveDiagnosticsForTesting()

            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, _, remainingRetryCount in
                guard remainingRetryCount == 1 else { return }
                await MainActor.run {
                    guard let index = manager.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
                    manager.workspaces[index].currentPromptText = "newer state"
                    manager.markWorkspaceDirty()
                }
            }
            await manager.pollAndSaveStateAsync()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            let diagnostics = manager.workspaceSaveDiagnosticsForTesting(workspaceID: workspace.id)
            XCTAssertEqual(diagnostics.attemptCount, 2)
            let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: manager.workspaceFileURL(for: workspace),
                scheduleNormalizationWriteback: false
            )
            XCTAssertEqual(saved.currentPromptText, "newer state")
            XCTAssertEqual(
                manager.debugLastSavedVersionForWorkspace(workspace.id),
                manager.debugStateVersionForWorkspace(workspace.id)
            )
        }

        func testPreparationFailureDoesNotAdvanceLastSavedVersion() async throws {
            let storageRoot = try temporaryDirectory(named: "Failure")
            let blockingFile = storageRoot.appendingPathComponent("not-a-directory")
            try Data("block".utf8).write(to: blockingFile)
            let composition = makeComposition(windowID: -984)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(name: "Failure", storage: blockingFile)
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            await manager.waitUntilPostSwitchGitDataLoadComplete()
            manager.markWorkspaceDirty()

            await manager.pollAndSaveStateAsync()

            XCTAssertGreaterThan(manager.debugStateVersionForWorkspace(workspace.id), 0)
            XCTAssertNil(manager.debugLastSavedVersionForWorkspace(workspace.id))
        }

        func testQuiescentCapturePublishesWorkspaceOnceWithoutReloadingComposeTabs() async throws {
            let storageRoot = try temporaryDirectory(named: "Publication")
            let composition = makeComposition(windowID: -985)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(name: "Publication", storage: storageRoot.appendingPathComponent("Publication"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            await manager.waitUntilPostSwitchGitDataLoadComplete()
            manager.markWorkspaceDirty()
            manager.resetWorkspaceSaveDiagnosticsForTesting()

            await manager.pollAndSaveStateAsync()

            let diagnostics = manager.workspaceSaveDiagnosticsForTesting(workspaceID: workspace.id)
            XCTAssertEqual(diagnostics.capturePublicationCount, 1)
            XCTAssertEqual(diagnostics.composeTabReloadCount, 0)
        }

        func testDomainProjectionUsesCanonicalComposeTabNormalization() throws {
            let workspace = makeWorkspace(
                name: "Canonical",
                storage: FileManager.default.temporaryDirectory
            )
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any]
            )
            object["composeTabs"] = []
            object["activeComposeTabID"] = UUID().uuidString
            let bytes = try JSONSerialization.data(withJSONObject: object)

            let decoded = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: bytes,
                fileURL: URL(fileURLWithPath: "/tmp/canonical-workspace.json")
            )

            XCTAssertEqual(decoded.composeTabs.count, 1)
            XCTAssertEqual(decoded.activeComposeTabID, decoded.composeTabs.first?.id)
            XCTAssertTrue(decoded.normalizationRequiresSave)
        }

        func testDomainOwnedLoadSuppressesLegacyNormalizationWriteback() throws {
            let root = try temporaryDirectory(named: "DomainOwnedNormalization")
            let fileURL = root.appendingPathComponent("workspace.json")
            let workspace = makeWorkspace(name: "Domain owned", storage: root)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any]
            )
            object["composeTabs"] = []
            object["activeComposeTabID"] = UUID().uuidString
            let originalBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try originalBytes.write(to: fileURL, options: .atomic)

            let loaded = try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(
                at: fileURL,
                scheduleNormalizationWriteback: false
            )

            XCTAssertTrue(loaded.normalizationRequiresSave)
            XCTAssertNil(loaded.normalizationSaveTask)
            XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
        }

        func testConcurrentDistinctDomainCreatesBothCommit() async throws {
            let root = try temporaryDirectory(named: "ConcurrentDomainCreates")
            let workspaceRoot = root.appendingPathComponent("Workspaces", isDirectory: true)
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "concurrent-domain-creates-\(UUID().uuidString)",
                storageDirectory: root,
                workspaceStorageDirectory: workspaceRoot,
                eventDirectory: root.appendingPathComponent("events"),
                temporaryDirectory: root.appendingPathComponent("tmp"),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let firstWorkspace = WorkspaceModel(name: "Concurrent A", repoPaths: ["/tmp/a"])
            let secondWorkspace = WorkspaceModel(name: "Concurrent B", repoPaths: ["/tmp/b"])
            let firstURL = workspaceRoot
                .appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(
                        name: firstWorkspace.name,
                        id: firstWorkspace.id
                    ),
                    isDirectory: true
                )
                .appendingPathComponent("workspace.json")
            let secondURL = workspaceRoot
                .appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(
                        name: secondWorkspace.name,
                        id: secondWorkspace.id
                    ),
                    isDirectory: true
                )
                .appendingPathComponent("workspace.json")
            let firstClient = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1001)
            let secondClient = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1002)
            let firstTask = Task { @MainActor in
                try await firstClient.create(firstWorkspace, fileURL: firstURL)
            }
            let secondTask = Task { @MainActor in
                try await secondClient.create(secondWorkspace, fileURL: secondURL)
            }

            let firstOutcome = try await firstTask.value
            let secondOutcome = try await secondTask.value
            XCTAssertTrue([.applied, .unchanged, .deduplicated].contains(firstOutcome.disposition))
            XCTAssertTrue([.applied, .unchanged, .deduplicated].contains(secondOutcome.disposition))
            let catalog = await runtime.workspaceStore.snapshot()
            XCTAssertEqual(
                Set(catalog.workspaces.map(\.document.workspaceID)),
                [firstWorkspace.id, secondWorkspace.id]
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))

            let collisionOperationID = UUID()
            let collisionA = WorkspaceModel(name: "Collision A", repoPaths: ["/tmp/collision-a"])
            let collisionB = WorkspaceModel(name: "Collision B", repoPaths: ["/tmp/collision-b"])
            let collisionAURL = workspaceRoot
                .appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(name: collisionA.name, id: collisionA.id),
                    isDirectory: true
                )
                .appendingPathComponent("workspace.json")
            let collisionBURL = workspaceRoot
                .appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(name: collisionB.name, id: collisionB.id),
                    isDirectory: true
                )
                .appendingPathComponent("workspace.json")
            let collisionATask = Task { @MainActor in
                try await firstClient.create(
                    collisionA,
                    fileURL: collisionAURL,
                    operationID: collisionOperationID
                )
            }
            let collisionBTask = Task { @MainActor in
                try await secondClient.create(
                    collisionB,
                    fileURL: collisionBURL,
                    operationID: collisionOperationID
                )
            }
            let collisionAOutcome = try await collisionATask.value
            let collisionBOutcome = try await collisionBTask.value
            let collisionOutcomes = [collisionAOutcome, collisionBOutcome]
            XCTAssertEqual(
                collisionOutcomes.count(where: {
                    [.applied, .unchanged, .deduplicated].contains($0.disposition)
                }),
                1
            )
            XCTAssertEqual(
                collisionOutcomes.count(where: { $0.errorCode == .operationIDCollision }),
                1
            )
            let afterCollision = await runtime.workspaceStore.snapshot()
            XCTAssertEqual(
                afterCollision.workspaces.count(where: {
                    $0.document.workspaceID == collisionA.id || $0.document.workspaceID == collisionB.id
                }),
                1
            )
            XCTAssertEqual(
                [collisionAURL, collisionBURL].count(where: {
                    FileManager.default.fileExists(atPath: $0.path)
                }),
                1
            )
        }

        func testDomainAuthoritySaveRetainsRetryBaselineAndIgnoresStaleLegacyList() async throws {
            let root = try temporaryDirectory(named: "DomainSaveInvariants")
            defer { try? FileManager.default.removeItem(at: root) }
            let defaults = UserDefaults.standard
            let priorStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
            defaults.set(
                root.appendingPathComponent("Workspaces", isDirectory: true).path,
                forKey: "GlobalCustomStorageURL"
            )
            defer {
                if let priorStoragePath {
                    defaults.set(priorStoragePath, forKey: "GlobalCustomStorageURL")
                } else {
                    defaults.removeObject(forKey: "GlobalCustomStorageURL")
                }
            }

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "app-save-invariants-\(UUID().uuidString)",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("events"),
                temporaryDirectory: root.appendingPathComponent("tmp"),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }
            let composition = WindowStateCompositionFactory.make(
                windowID: -991,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                domainRuntime: runtime,
                workspaceFileContextStore: WorkspaceFileContextStore()
            )
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let authoritative = try await waitForDomainWorkspace(runtime)
            let workspaceID = authoritative.document.workspaceID
            let presentationBridge = try XCTUnwrap(composition.domainWorkspacePresentationBridge)
            let initialCatalog = await runtime.workspaceStore.snapshot()
            let initialProjectionCompleted = await presentationBridge.waitUntilProjected(
                through: initialCatalog.publicationSequence
            )
            XCTAssertTrue(initialProjectionCompleted)
            manager.resetWorkspaceSaveDiagnosticsForTesting()
            managersWithSavePreparationHooks.append(manager)
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { id, _, remainingRetryCount in
                guard id == workspaceID, remainingRetryCount == 1 else { return }
                await MainActor.run {
                    guard let index = manager.workspaces.firstIndex(where: { $0.id == id }) else { return }
                    manager.workspaces[index].currentPromptText = "newer runtime state"
                    manager.markWorkspaceDirty()
                }
            }
            guard let index = manager.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                return XCTFail("Bootstrapped runtime workspace was not projected")
            }
            manager.workspaces[index].repoPaths = ["/tmp/runtime-baseline"]
            manager.workspaces[index].currentPromptText = "captured runtime state"
            manager.markWorkspaceDirty()
            let stateVersionBeforeRetry = manager.debugStateVersionForWorkspace(workspaceID)

            await manager.pollAndSaveStateAsync()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            let diagnostics = manager.workspaceSaveDiagnosticsForTesting(workspaceID: workspaceID)
            XCTAssertEqual(diagnostics.attemptCount, 2)
            XCTAssertEqual(manager.debugRepoPathBaselineForWorkspace(workspaceID), ["/tmp/runtime-baseline"])
            let savedStateVersion = try XCTUnwrap(manager.debugLastSavedVersionForWorkspace(workspaceID))
            XCTAssertGreaterThan(savedStateVersion, stateVersionBeforeRetry)
            XCTAssertGreaterThanOrEqual(
                manager.debugStateVersionForWorkspace(workspaceID),
                savedStateVersion
            )
            let savedDocument = try await waitForDomainWorkspace(
                runtime,
                workspaceID: workspaceID,
                description: "authoritative retry winner save"
            ) { snapshot in
                guard snapshot.revisions.dirtyRevision == nil,
                      snapshot.revisions.savedRevision == snapshot.revisions.workingRevision,
                      snapshot.revisions.workingRevision > authoritative.revisions.workingRevision
                else { return false }
                let projected = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: snapshot.document.documentBytes,
                    fileURL: snapshot.document.fileURL
                )
                return projected.currentPromptText == "newer runtime state"
                    && projected.repoPaths == ["/tmp/runtime-baseline"]
            }
            XCTAssertGreaterThan(
                savedDocument.revisions.workingRevision,
                authoritative.revisions.workingRevision
            )
            XCTAssertEqual(
                savedDocument.revisions.savedRevision,
                savedDocument.revisions.workingRevision
            )
            XCTAssertNil(savedDocument.revisions.dirtyRevision)
            let savedCatalog = await runtime.workspaceStore.snapshot()
            let savedProjectionCompleted = await presentationBridge.waitUntilProjected(
                through: savedCatalog.publicationSequence
            )
            XCTAssertTrue(savedProjectionCompleted)
            let decoded = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: savedDocument.document.documentBytes,
                fileURL: savedDocument.document.fileURL
            )
            XCTAssertEqual(decoded.currentPromptText, "newer runtime state")
            XCTAssertEqual(decoded.repoPaths, ["/tmp/runtime-baseline"])

            let deniedDirectWriteRoot = root.appendingPathComponent("DeniedDirectWrite", isDirectory: true)
            do {
                _ = try await manager.saveWorkspaceToFileAsync(decoded, baseRoot: deniedDirectWriteRoot)
                XCTFail("A domain-owned workspace must reject the legacy direct writer")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("domain workspace authority"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: deniedDirectWriteRoot.path))

            let staleID = UUID()
            let staleIndex: [[String: Any]] = [[
                "id": staleID.uuidString,
                "name": "Stale legacy only",
                "customStoragePath": NSNull(),
                "isSystemWorkspace": false,
                "isHiddenInMenus": false
            ]]
            let staleIndexData = try JSONSerialization.data(withJSONObject: staleIndex)
            try staleIndexData.write(
                to: root.appendingPathComponent("Workspaces/workspacesIndex.json"),
                options: .atomic
            )
            manager.reloadWorkspacesFromDisk()
            try await waitForCondition("domain projection to ignore stale legacy index") {
                manager.workspaces.contains { $0.id == workspaceID }
                    && !manager.workspaces.contains { $0.id == staleID }
            }

            guard let localIndex = manager.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                return XCTFail("Runtime workspace disappeared before external reconciliation")
            }
            manager.workspaces[localIndex].currentPromptText = "local working state preserved"
            manager.markWorkspaceDirty()
            let localDirty = manager.workspaces[localIndex]
            await manager.debugPublishWorkingDocumentToDomainAuthority(localDirty)
            let dirtySnapshot = try await waitForDomainWorkspace(
                runtime,
                workspaceID: workspaceID,
                description: "dirty working revision publication"
            ) { snapshot in
                guard snapshot.revisions.dirtyRevision != nil else { return false }
                let projected = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: snapshot.document.documentBytes,
                    fileURL: snapshot.document.fileURL
                )
                return projected.currentPromptText == "local working state preserved"
            }
            XCTAssertGreaterThan(dirtySnapshot.revisions.workingRevision, dirtySnapshot.revisions.savedRevision)
            XCTAssertEqual(dirtySnapshot.revisions.dirtyRevision, dirtySnapshot.revisions.workingRevision)

            var external = decoded
            external.currentPromptText = "external saved baseline"
            try JSONEncoder().encode(external).write(
                to: savedDocument.document.fileURL,
                options: .atomic
            )
            let reloadActivity = await runtime.workspaceStore.reloadExternalChanges()
            XCTAssertEqual(reloadActivity, .changed)
            let reconciledCatalog = await runtime.workspaceStore.snapshot()
            let reconciliationProjectionCompleted = await presentationBridge.waitUntilProjected(
                through: reconciledCatalog.publicationSequence
            )
            XCTAssertTrue(reconciliationProjectionCompleted)
            let resolved = try await waitForDomainWorkspace(
                runtime,
                workspaceID: workspaceID,
                description: "automatic dirty external reconciliation"
            ) { snapshot in
                guard snapshot.health == .writable,
                      snapshot.revisions.dirtyRevision != nil
                else { return false }
                let projected = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: snapshot.document.documentBytes,
                    fileURL: snapshot.document.fileURL
                )
                return projected.currentPromptText == "local working state preserved"
            }
            XCTAssertEqual(resolved.health, .writable)
            XCTAssertNotNil(resolved.revisions.dirtyRevision)
            XCTAssertNil(manager.domainWorkspaceAuthorityIssue)

            let canonicalBaseline = manager.debugDomainAuthorityBaseline(for: workspaceID)
            XCTAssertEqual(canonicalBaseline.revisions, resolved.revisions)
            XCTAssertEqual(canonicalBaseline.digest, resolved.document.contentDigest)
            XCTAssertEqual(canonicalBaseline.health, .writable)
            let admissionIssue = await manager.domainAuthorityAdmissionIssue(for: workspaceID)
            XCTAssertNil(admissionIssue)

            let accepted = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: resolved.document.documentBytes,
                fileURL: resolved.document.fileURL
            )
            XCTAssertEqual(accepted.currentPromptText, "local working state preserved")

            let authoritativeURL = resolved.document.fileURL
            let authoritativeDirectory = authoritativeURL.deletingLastPathComponent().standardizedFileURL
            let indexURL = root.appendingPathComponent("Workspaces/workspacesIndex.json")
            let distractor = manager.createWorkspace(
                name: "Deferred persistence distractor",
                repoPaths: ["/tmp/distractor"]
            )
            let distractorURL = manager.workspaceFileURL(for: distractor)
            let distractorPersistedNotification = expectation(
                description: "distractor persistence publishes workspace list change"
            )
            let distractorPersistedObserver = NotificationCenter.default.addObserver(
                forName: .workspaceListDidChange,
                object: nil,
                queue: .main
            ) { _ in
                guard FileManager.default.fileExists(atPath: distractorURL.path) else { return }
                distractorPersistedNotification.fulfill()
            }
            _ = try await waitForDomainWorkspace(
                runtime,
                workspaceID: distractor.id,
                description: "deferred persistence distractor creation"
            )
            let distractorCatalog = await runtime.workspaceStore.snapshot()
            let distractorProjectionCompleted = await presentationBridge.waitUntilProjected(
                through: distractorCatalog.publicationSequence
            )
            XCTAssertTrue(distractorProjectionCompleted)
            await fulfillment(of: [distractorPersistedNotification], timeout: 5)
            NotificationCenter.default.removeObserver(distractorPersistedObserver)
            let renamedNotification = expectation(description: "rename publishes workspace list change after persistence")
            let renamedObserver = NotificationCenter.default.addObserver(
                forName: .workspaceListDidChange,
                object: nil,
                queue: .main
            ) { _ in
                guard
                    let data = try? Data(contentsOf: authoritativeURL),
                    let persisted = try? WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                        documentBytes: data,
                        fileURL: authoritativeURL
                    ),
                    persisted.name == "Runtime Renamed"
                else { return }
                renamedNotification.fulfill()
            }
            defer { NotificationCenter.default.removeObserver(renamedObserver) }
            manager.renameWorkspace(accepted, newName: "  Runtime Renamed  ")
            let renameTargetIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceID })
            let renameDistractorIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == distractor.id })
            manager.workspaces[renameTargetIndex].name = accepted.name
            manager.workspaces.swapAt(renameTargetIndex, renameDistractorIndex)
            let renamed = try await waitForDomainWorkspace(
                runtime,
                workspaceID: workspaceID,
                description: "production rename command publication"
            ) { snapshot in
                let projected = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: snapshot.document.documentBytes,
                    fileURL: snapshot.document.fileURL
                )
                return projected.name == "Runtime Renamed"
                    && snapshot.revisions.dirtyRevision == nil
            }
            await fulfillment(of: [renamedNotification], timeout: 5)
            NotificationCenter.default.removeObserver(renamedObserver)

            XCTAssertEqual(renamed.document.fileURL, authoritativeURL)
            XCTAssertEqual(
                renamed.document.fileURL.deletingLastPathComponent().standardizedFileURL,
                authoritativeDirectory
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: authoritativeURL.path))
            let legacyRenamedDirectory = root
                .appendingPathComponent("Workspaces", isDirectory: true)
                .appendingPathComponent("Workspace-Runtime Renamed-\(workspaceID.uuidString)", isDirectory: true)
                .standardizedFileURL
            if legacyRenamedDirectory != authoritativeDirectory {
                XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRenamedDirectory.path))
            }
            let renamedModel = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: renamed.document.documentBytes,
                fileURL: renamed.document.fileURL
            )
            XCTAssertEqual(renamedModel.name, "Runtime Renamed")

            let hiddenNotification = expectation(description: "hidden state publishes workspace list change after persistence")
            let hiddenObserver = NotificationCenter.default.addObserver(
                forName: .workspaceListDidChange,
                object: nil,
                queue: .main
            ) { _ in
                guard
                    let data = try? Data(contentsOf: authoritativeURL),
                    let persisted = try? WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                        documentBytes: data,
                        fileURL: authoritativeURL
                    ),
                    persisted.isHiddenInMenus
                else { return }
                hiddenNotification.fulfill()
            }
            manager.setWorkspaceHidden(renamedModel, hidden: true)
            let hiddenTargetIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceID })
            let hiddenDistractorIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == distractor.id })
            manager.workspaces[hiddenTargetIndex].isHiddenInMenus = false
            manager.workspaces.swapAt(hiddenTargetIndex, hiddenDistractorIndex)
            let hidden = try await waitForDomainWorkspace(
                runtime,
                workspaceID: workspaceID,
                description: "hidden-state publication after workspace reorder"
            ) { snapshot in
                snapshot.document.metadata.isHiddenInMenus
            }
            await fulfillment(of: [hiddenNotification], timeout: 5)
            NotificationCenter.default.removeObserver(hiddenObserver)
            XCTAssertTrue(hidden.document.metadata.isHiddenInMenus)
            let distractorAfterDeferredMutations = try await waitForDomainWorkspace(
                runtime,
                workspaceID: distractor.id,
                description: "distractor remains unchanged"
            )
            XCTAssertEqual(distractorAfterDeferredMutations.document.metadata.name, distractor.name)
            XCTAssertFalse(distractorAfterDeferredMutations.document.metadata.isHiddenInMenus)

            let indexData = try Data(contentsOf: indexURL)
            let indexEntries = try JSONDecoder().decode([WorkspaceIndexEntry].self, from: indexData)
            XCTAssertEqual(indexData, staleIndexData)
            XCTAssertNil(indexEntries.first { $0.id == workspaceID })
            XCTAssertTrue(indexEntries.contains { $0.id == staleID })

            let beforeEmptyRename = await runtime.workspaceStore.snapshot()
            let emptyRenameNotification = expectation(description: "empty rename remains a no-op")
            emptyRenameNotification.isInverted = true
            let emptyRenameObserver = NotificationCenter.default.addObserver(
                forName: .workspaceListDidChange,
                object: nil,
                queue: .main
            ) { _ in
                emptyRenameNotification.fulfill()
            }
            defer { NotificationCenter.default.removeObserver(emptyRenameObserver) }
            manager.renameWorkspace(renamedModel, newName: "  \t  ")
            await fulfillment(of: [emptyRenameNotification], timeout: 0.1)
            NotificationCenter.default.removeObserver(emptyRenameObserver)
            let afterEmptyRename = await runtime.workspaceStore.snapshot()
            XCTAssertEqual(afterEmptyRename.publicationSequence, beforeEmptyRename.publicationSequence)
            XCTAssertEqual(manager.workspace(withID: workspaceID)?.name, "Runtime Renamed")

            let deleteModel = try XCTUnwrap(manager.workspace(withID: workspaceID))
            let deleteSucceeded = await manager.deleteWorkspaceAsync(deleteModel)
            XCTAssertTrue(deleteSucceeded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: authoritativeDirectory.path))
            let afterDelete = await runtime.workspaceStore.snapshot()
            let recreated = await runtime.workspaceStore.execute(.init(
                operationID: UUID(),
                expectedCatalogRevision: afterDelete.catalogRevision,
                expectedWorkspaceRevision: 0,
                origin: .standalone,
                command: .createWorkspace(hidden.document)
            ))
            XCTAssertEqual(recreated.disposition, .applied)
            XCTAssertTrue(FileManager.default.fileExists(atPath: authoritativeURL.path))
        }

        func testCancelledWorkingCommitAdoptsAuthorityBaselineForNextSave() async throws {
            let root = try temporaryDirectory(named: "CancelledDomainWorkingCommit")
            let defaults = UserDefaults.standard
            let priorStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
            defaults.set(
                root.appendingPathComponent("Workspaces", isDirectory: true).path,
                forKey: "GlobalCustomStorageURL"
            )
            defer {
                if let priorStoragePath {
                    defaults.set(priorStoragePath, forKey: "GlobalCustomStorageURL")
                } else {
                    defaults.removeObject(forKey: "GlobalCustomStorageURL")
                }
            }

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "cancelled-working-commit-\(UUID().uuidString)",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("events"),
                temporaryDirectory: root.appendingPathComponent("tmp"),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }
            let composition = WindowStateCompositionFactory.make(
                windowID: -992,
                deferredInitialAgentSystemWorkspaceRefresh: false,
                sharedMCPService: MCPService(),
                domainRuntime: runtime,
                workspaceFileContextStore: WorkspaceFileContextStore()
            )
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let initial = try await waitForDomainWorkspace(runtime)
            let workspaceID = initial.document.workspaceID
            let bridge = try XCTUnwrap(composition.domainWorkspacePresentationBridge)
            let initialCatalog = await runtime.workspaceStore.snapshot()
            let initialProjectionCompleted = await bridge.waitUntilProjected(
                through: initialCatalog.publicationSequence
            )
            XCTAssertTrue(initialProjectionCompleted)

            var firstCapture = try XCTUnwrap(manager.workspace(withID: workspaceID))
            firstCapture.currentPromptText = "durable despite cancelled presentation task"
            guard let managerIndex = manager.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                return XCTFail("Runtime workspace disappeared before the cancelled presentation task")
            }
            manager.workspaces[managerIndex] = firstCapture
            manager.cancelNextWorkingCommitAfterAuthorityOutcomeForTesting(workspaceID: workspaceID)
            await manager.debugPublishWorkingDocumentToDomainAuthority(firstCapture)
            let cancelledTaskCommit = try await waitForDomainWorkspace(
                runtime,
                workspaceID: workspaceID,
                description: "durable working commit after presentation cancellation"
            ) { snapshot in
                guard snapshot.revisions.dirtyRevision != nil else { return false }
                let projected = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: snapshot.document.documentBytes,
                    fileURL: snapshot.document.fileURL
                )
                return projected.currentPromptText == "durable despite cancelled presentation task"
            }

            manager.markWorkspaceDirty()
            await manager.pollAndSaveStateAsync()

            let afterSave = await runtime.workspaceStore.snapshot()
            let saved = try XCTUnwrap(afterSave.workspaces.first { $0.document.workspaceID == workspaceID })
            let savedProjection = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: saved.document.documentBytes,
                fileURL: saved.document.fileURL
            )
            XCTAssertNil(saved.revisions.dirtyRevision)
            XCTAssertEqual(savedProjection.id, workspaceID)
            XCTAssertGreaterThan(
                saved.revisions.workingRevision,
                cancelledTaskCommit.revisions.workingRevision
            )
            XCTAssertEqual(saved.revisions.savedRevision, saved.revisions.workingRevision)
            XCTAssertNil(manager.domainWorkspaceAuthorityIssue)
        }

        func testCompositionUsesExplicitDomainRuntimeOwnershipOnlyWhenInjected() async throws {
            let legacy = makeComposition(windowID: -989)
            XCTAssertNil(legacy.domainWorkspacePresentationBridge)

            let root = try temporaryDirectory(named: "DomainOwnership")
            defer { try? FileManager.default.removeItem(at: root) }
            let defaults = UserDefaults.standard
            let priorStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
            defaults.set(
                root.appendingPathComponent("Workspaces", isDirectory: true).path,
                forKey: "GlobalCustomStorageURL"
            )
            defer {
                if let priorStoragePath {
                    defaults.set(priorStoragePath, forKey: "GlobalCustomStorageURL")
                } else {
                    defaults.removeObject(forKey: "GlobalCustomStorageURL")
                }
            }
            let workspaceRoot = root.appendingPathComponent("Workspaces", isDirectory: true)
            let legacyStorage = workspaceRoot.appendingPathComponent("Legacy", isDirectory: true)
            try FileManager.default.createDirectory(at: legacyStorage, withIntermediateDirectories: true)
            let legacyWorkspace = makeWorkspace(name: "Legacy survives", storage: legacyStorage)
            try JSONEncoder().encode(legacyWorkspace).write(
                to: legacyStorage.appendingPathComponent("workspace.json")
            )
            try JSONEncoder().encode([WorkspaceIndexEntry(
                id: legacyWorkspace.id,
                name: legacyWorkspace.name,
                customStoragePath: legacyStorage,
                isSystemWorkspace: false,
                isHiddenInMenus: false
            )]).write(to: workspaceRoot.appendingPathComponent("workspacesIndex.json"))

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "app-bridge-test",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("events"),
                temporaryDirectory: root.appendingPathComponent("tmp"),
                externalReloadInterval: nil
            ))
            // Deliberately do not start the runtime first. The store/bridge readiness contract
            // must bootstrap before its first projection and preserve the legacy-loaded list.
            let owned = WindowStateCompositionFactory.make(
                windowID: -990,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                domainRuntime: runtime,
                workspaceFileContextStore: WorkspaceFileContextStore()
            )
            let presentationBridge = try XCTUnwrap(owned.domainWorkspacePresentationBridge)
            XCTAssertTrue(presentationBridge.hasActiveSubscriptionForTesting)
            XCTAssertNotNil(owned.mcpServer.domainRoutingCoordinator)
            await owned.workspaceManager.awaitInitialized()
            _ = try await waitForDomainWorkspace(runtime)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(owned.workspaceManager.workspaces.contains { $0.id == legacyWorkspace.id })
            XCTAssertFalse(owned.workspaceManager.workspaces.isEmpty)
            let registeredRouting = await runtime.routingCoordinator.snapshot()
            XCTAssertTrue(registeredRouting.windows.contains { $0.windowID == -990 })
            presentationBridge.stop()
            XCTAssertFalse(presentationBridge.hasActiveSubscriptionForTesting)
            await owned.mcpServer.unregisterDomainRoutingWindow()
            let unregisteredRouting = await runtime.routingCoordinator.snapshot()
            XCTAssertFalse(unregisteredRouting.windows.contains { $0.windowID == -990 })
            _ = await runtime.shutdown()
        }

        private func waitForDomainWorkspace(
            _ runtime: MCPDomainRuntime,
            workspaceID: UUID? = nil,
            description: String = "runtime workspace creation",
            timeout: Duration = .seconds(5),
            matching predicate: (DomainWorkspaceSnapshot) throws -> Bool = { _ in true }
        ) async throws -> DomainWorkspaceSnapshot {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            repeat {
                let snapshot = await runtime.workspaceStore.snapshot()
                if let workspace = snapshot.workspaces.first(where: { workspace in
                    workspaceID == nil || workspace.document.workspaceID == workspaceID
                }), try predicate(workspace) {
                    return workspace
                }
                try await Task.sleep(for: .milliseconds(10))
            } while clock.now < deadline
            throw NSError(
                domain: "WorkspaceSavePreparationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(description)"]
            )
        }

        private func waitForCondition(
            _ description: String,
            timeout: Duration = .seconds(5),
            condition: () -> Bool
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            repeat {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            } while clock.now < deadline
            throw NSError(
                domain: "WorkspaceSavePreparationTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(description)"]
            )
        }

        private func makeComposition(windowID: Int) -> WindowStateComposition {
            let composition = WindowStateCompositionFactory.make(
                windowID: windowID,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                workspaceFileContextStore: WorkspaceFileContextStore()
            )
            retainedWorkspaceManagers.append(composition.workspaceManager)
            return composition
        }

        private func makeWorkspace(name: String, storage: URL) -> WorkspaceModel {
            let tab = ComposeTabState(name: name)
            return WorkspaceModel(
                name: name,
                repoPaths: [],
                customStoragePath: storage,
                composeTabs: [tab],
                activeComposeTabID: tab.id
            )
        }

        private func temporaryDirectory(named name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceSavePreparationTests-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            temporaryDirectories.append(url)
            return url
        }
    }

    private final class WorkspaceSavePreparationGate: @unchecked Sendable {
        struct Arrival {
            let workspaceID: UUID
            let fileURL: URL
        }

        private let condition = NSCondition()
        private let releaseFence = TestReleaseFence(name: "workspace save preparation gate")
        private var arrival: Arrival?
        private var arrivalWaiters: [UUID: CheckedContinuation<Arrival?, Never>] = [:]
        private var cancelledArrivalWaiters = Set<UUID>()
        private var isCancelled = false

        func arriveAndWait(workspaceID: UUID, fileURL: URL) async {
            recordArrival(Arrival(workspaceID: workspaceID, fileURL: fileURL))
            await releaseFence.enterAndWait()
        }

        func waitUntilArrivedAndBlocked() async throws -> Arrival {
            guard let arrival = await waitUntilArrived() else {
                throw CancellationError()
            }
            guard await releaseFence.waitUntilEntered() else {
                throw CancellationError()
            }
            return arrival
        }

        func release() {
            releaseFence.release()
        }

        func cancel() {
            condition.lock()
            isCancelled = true
            let pending = Array(arrivalWaiters.values)
            arrivalWaiters.removeAll()
            cancelledArrivalWaiters.removeAll()
            condition.broadcast()
            condition.unlock()
            pending.forEach { $0.resume(returning: nil) }
            releaseFence.release()
        }

        private func waitUntilArrived() async -> Arrival? {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    registerArrivalWaiter(continuation, waiterID: waiterID)
                }
            } onCancel: {
                cancelArrivalWaiter(waiterID)
            }
        }

        private func recordArrival(_ value: Arrival) {
            condition.lock()
            guard !isCancelled else {
                condition.unlock()
                return
            }
            arrival = value
            let pending = Array(arrivalWaiters.values)
            arrivalWaiters.removeAll()
            cancelledArrivalWaiters.removeAll()
            condition.broadcast()
            condition.unlock()
            pending.forEach { $0.resume(returning: value) }
        }

        private func registerArrivalWaiter(
            _ continuation: CheckedContinuation<Arrival?, Never>,
            waiterID: UUID
        ) {
            condition.lock()
            if let arrival {
                condition.unlock()
                continuation.resume(returning: arrival)
            } else if isCancelled || Task.isCancelled || cancelledArrivalWaiters.remove(waiterID) != nil {
                condition.unlock()
                continuation.resume(returning: nil)
            } else {
                arrivalWaiters[waiterID] = continuation
                condition.unlock()
            }
        }

        private func cancelArrivalWaiter(_ waiterID: UUID) {
            condition.lock()
            let continuation = arrivalWaiters.removeValue(forKey: waiterID)
            if continuation == nil {
                cancelledArrivalWaiters.insert(waiterID)
            }
            condition.broadcast()
            condition.unlock()
            continuation?.resume(returning: nil)
        }
    }

#endif
