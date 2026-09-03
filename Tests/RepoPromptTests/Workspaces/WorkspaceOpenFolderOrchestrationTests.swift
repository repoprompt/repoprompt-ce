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

        func testReplayedResolveOrCreateReturnsOriginalWorkspaceAfterResultDigestChanges() async throws {
            let runtime = try await makeDomainRuntime()
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
            XCTAssertEqual(first.workspace?.document.workspaceID, existing.id)
            XCTAssertEqual(replay.disposition, .deduplicated)
            XCTAssertEqual(replay.workspace?.document.workspaceID, existing.id)
            XCTAssertEqual(replay.workspace?.document.contentDigest, mutation.resultingDigest)
            XCTAssertEqual(replay.resultingDigest, originalDigest)
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

        func testLegacyRawDocumentFingerprintReplaysAfterRestart() async throws {
            let goldenWorkspaceID = try XCTUnwrap(
                UUID(uuidString: "22222222-2222-2222-2222-222222222222")
            )
            let goldenOperationID = try XCTUnwrap(
                UUID(uuidString: "11111111-1111-1111-1111-111111111111")
            )
            let goldenBytes = Data(
                "{\"id\":\"22222222-2222-2222-2222-222222222222\",\"schemaVersion\":1,\"name\":\"Legacy Golden\",\"repoPaths\":[]}".utf8
            )
            let goldenDocument = try DomainWorkspaceDocument.decode(
                documentBytes: goldenBytes,
                fileURL: URL(fileURLWithPath: "/tmp/legacy-fingerprint-workspace.json")
            )
            let goldenEnvelope = replaceEnvelope(
                document: goldenDocument,
                expectedWorkspaceRevision: 7,
                operationID: goldenOperationID,
                windowID: -1305
            )
            XCTAssertEqual(
                goldenEnvelope.legacyFingerprint,
                "285208fcaa7ab0c042f79a56455492edcf22a09fd8548de3079d4e1a4e7c29f8",
                "The compatibility fingerprint must remain byte-for-byte identical to the pre-change algorithm"
            )
            XCTAssertEqual(goldenDocument.workspaceID, goldenWorkspaceID)

            let profileIdentifier = "workspace-open-folder-legacy-fingerprint-\(UUID().uuidString)"
            let runtime = try await makeDomainRuntime(profileIdentifier: profileIdentifier)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1305)
            let folder = try makeFolder(named: "ResolveOrCreateLegacyFingerprintReplay")
            let existing = WorkspaceModel(name: "Legacy Fingerprint Winner", repoPaths: [folder.path])
            try await createAuthorityWorkspace(existing, using: client)
            let proposed = WorkspaceModel(name: "Legacy Fingerprint Proposed", repoPaths: [folder.path])
            let operationID = UUID()
            let envelope = try resolveOrCreateEnvelope(
                proposed,
                canonicalRootPath: canonicalRootPath(folder),
                operationID: operationID,
                windowID: -1305
            )
            XCTAssertNotEqual(
                envelope.fingerprint,
                envelope.legacyFingerprint,
                "The compatibility fixture must distinguish canonical and legacy fingerprint formats"
            )

            let first = await runtime.workspaceStore.execute(envelope)
            XCTAssertEqual(first.disposition, .unchanged)
            XCTAssertEqual(first.workspace?.document.workspaceID, existing.id)
            let journalURL = try workingJournalURL(workspaceID: existing.id)
            _ = await runtime.shutdown()
            domainRuntimes.removeAll { $0 === runtime }
            try replaceOperationFingerprint(
                operationID: operationID,
                expectedFingerprint: envelope.fingerprint,
                replacementFingerprint: envelope.legacyFingerprint,
                in: journalURL
            )

            let restarted = try await makeDomainRuntime(profileIdentifier: profileIdentifier)
            let replay = await restarted.workspaceStore.execute(envelope)
            let diagnostics = """
            canonicalFingerprint=\(envelope.fingerprint)
            legacyFingerprint=\(envelope.legacyFingerprint)
            documentIdentity=\(envelope.documentIdentity ?? "nil")
            replay=\(describe(replay))
            """

            XCTAssertEqual(replay.disposition, .deduplicated, diagnostics)
            XCTAssertEqual(replay.workspace?.document.workspaceID, existing.id, diagnostics)
            XCTAssertEqual(replay.resultingDigest, first.resultingDigest, diagnostics)
        }

        func testConcurrentSemanticReplaceRetriesDeduplicateAfterMutationGate() async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1302)
            let folder = try makeFolder(named: "ReplaceRetryGate")
            let existing = WorkspaceModel(name: "Replace Original", repoPaths: [folder.path])
            try await createAuthorityWorkspace(existing, using: client)
            let snapshot = await runtime.workspaceStore.workspaceSnapshot(existing.id)
            let authoritative = try XCTUnwrap(snapshot)
            let operationID = UUID()
            let firstDocument = try orderedDocument(
                workspaceID: existing.id,
                name: "Replace Applied",
                fileURL: authoritative.document.fileURL,
                idFirst: true
            )
            let retryDocument = try orderedDocument(
                workspaceID: existing.id,
                name: "Replace Applied",
                fileURL: authoritative.document.fileURL,
                idFirst: false
            )
            let collisionDocument = try orderedDocument(
                workspaceID: existing.id,
                name: "Replace Collision",
                fileURL: authoritative.document.fileURL,
                idFirst: false
            )
            let firstEnvelope = replaceEnvelope(
                document: firstDocument,
                expectedWorkspaceRevision: authoritative.revisions.workingRevision,
                operationID: operationID
            )
            let retryEnvelope = replaceEnvelope(
                document: retryDocument,
                expectedWorkspaceRevision: authoritative.revisions.workingRevision,
                operationID: operationID
            )
            let collisionEnvelope = replaceEnvelope(
                document: collisionDocument,
                expectedWorkspaceRevision: authoritative.revisions.workingRevision,
                operationID: operationID
            )
            let identityDiagnostics = """
            operationID=\(operationID.uuidString)
            firstFingerprint=\(firstEnvelope.fingerprint)
            retryFingerprint=\(retryEnvelope.fingerprint)
            collisionFingerprint=\(collisionEnvelope.fingerprint)
            firstDocumentIdentity=\(firstEnvelope.documentIdentity ?? "nil")
            retryDocumentIdentity=\(retryEnvelope.documentIdentity ?? "nil")
            collisionDocumentIdentity=\(collisionEnvelope.documentIdentity ?? "nil")
            firstRawDigest=\(firstDocument.contentDigest)
            retryRawDigest=\(retryDocument.contentDigest)
            collisionRawDigest=\(collisionDocument.contentDigest)
            """
            XCTAssertNotEqual(
                firstDocument.contentDigest,
                retryDocument.contentDigest,
                "Test inputs must use distinct JSON byte orderings.\n\(identityDiagnostics)"
            )
            XCTAssertEqual(
                firstEnvelope.documentIdentity,
                retryEnvelope.documentIdentity,
                "Equivalent JSON documents must have one semantic identity.\n\(identityDiagnostics)"
            )
            XCTAssertEqual(
                firstEnvelope.fingerprint,
                retryEnvelope.fingerprint,
                "Equivalent retry envelopes must have one canonical fingerprint.\n\(identityDiagnostics)"
            )
            XCTAssertNotEqual(
                firstEnvelope.documentIdentity,
                collisionEnvelope.documentIdentity,
                "A semantic document change must change document identity.\n\(identityDiagnostics)"
            )
            XCTAssertNotEqual(
                firstEnvelope.fingerprint,
                collisionEnvelope.fingerprint,
                "A semantic document change must remain an operation-ID collision.\n\(identityDiagnostics)"
            )

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

            async let first = runtime.workspaceStore.execute(firstEnvelope)
            await mutationGate.waitUntilPaused()
            async let retry = runtime.workspaceStore.execute(retryEnvelope)
            await mutationGate.release()
            let (firstOutcome, retryOutcome) = await (first, retry)
            let collision = await runtime.workspaceStore.execute(collisionEnvelope)
            let outcomeDiagnostics = """
            \(identityDiagnostics)
            firstOutcome=\(describe(firstOutcome))
            retryOutcome=\(describe(retryOutcome))
            collisionOutcome=\(describe(collision))
            """

            XCTAssertEqual(firstOutcome.disposition, .applied, outcomeDiagnostics)
            XCTAssertEqual(retryOutcome.disposition, .deduplicated, outcomeDiagnostics)
            XCTAssertEqual(retryOutcome.resultingDigest, firstOutcome.resultingDigest, outcomeDiagnostics)
            XCTAssertEqual(collision.disposition, .invalid, outcomeDiagnostics)
            XCTAssertEqual(collision.errorCode, .operationIDCollision, outcomeDiagnostics)
            XCTAssertEqual(collision.diagnostic, "operation_id_reused_with_different_command", outcomeDiagnostics)
        }

        func testDistinctArbitraryPrecisionNumbersRemainOperationIDCollisions() async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1303)
            let folder = try makeFolder(named: "ArbitraryPrecisionNumberCollision")
            let existing = WorkspaceModel(name: "Number Original", repoPaths: [folder.path])
            try await createAuthorityWorkspace(existing, using: client)

            let cases = [
                (
                    label: "outside Decimal exponent range",
                    first: "1e128",
                    second: "2e128"
                ),
                (
                    label: "beyond Decimal coefficient precision",
                    first: "12345678901234567890123456789012345678901",
                    second: "12345678901234567890123456789012345678902"
                )
            ]

            for testCase in cases {
                let snapshot = await runtime.workspaceStore.workspaceSnapshot(existing.id)
                let authoritative = try XCTUnwrap(snapshot)
                let operationID = UUID()
                let firstDocument = try numberedDocument(
                    workspaceID: existing.id,
                    name: testCase.label,
                    fileURL: authoritative.document.fileURL,
                    numberToken: testCase.first
                )
                let collisionDocument = try numberedDocument(
                    workspaceID: existing.id,
                    name: testCase.label,
                    fileURL: authoritative.document.fileURL,
                    numberToken: testCase.second
                )
                let firstEnvelope = replaceEnvelope(
                    document: firstDocument,
                    expectedWorkspaceRevision: authoritative.revisions.workingRevision,
                    operationID: operationID
                )
                let collisionEnvelope = replaceEnvelope(
                    document: collisionDocument,
                    expectedWorkspaceRevision: authoritative.revisions.workingRevision,
                    operationID: operationID
                )
                let identityDiagnostics = """
                case=\(testCase.label)
                firstNumber=\(testCase.first)
                secondNumber=\(testCase.second)
                firstDocumentIdentity=\(firstEnvelope.documentIdentity ?? "nil")
                secondDocumentIdentity=\(collisionEnvelope.documentIdentity ?? "nil")
                firstFingerprint=\(firstEnvelope.fingerprint)
                secondFingerprint=\(collisionEnvelope.fingerprint)
                """
                XCTAssertNotEqual(
                    firstEnvelope.documentIdentity,
                    collisionEnvelope.documentIdentity,
                    "Distinct arbitrary-precision values must not collapse.\n\(identityDiagnostics)"
                )
                XCTAssertNotEqual(
                    firstEnvelope.fingerprint,
                    collisionEnvelope.fingerprint,
                    "Distinct arbitrary-precision values must retain collision detection.\n\(identityDiagnostics)"
                )

                let first = await runtime.workspaceStore.execute(firstEnvelope)
                let collision = await runtime.workspaceStore.execute(collisionEnvelope)
                let outcomeDiagnostics = """
                \(identityDiagnostics)
                firstOutcome=\(describe(first))
                collisionOutcome=\(describe(collision))
                """
                XCTAssertEqual(first.disposition, .applied, outcomeDiagnostics)
                XCTAssertEqual(collision.disposition, .invalid, outcomeDiagnostics)
                XCTAssertEqual(collision.errorCode, .operationIDCollision, outcomeDiagnostics)
                XCTAssertEqual(
                    collision.diagnostic,
                    "operation_id_reused_with_different_command",
                    outcomeDiagnostics
                )
            }
        }

        func testDuplicateJSONMembersRemainOperationIDCollisions() async throws {
            let runtime = try await makeDomainRuntime()
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1304)
            let folder = try makeFolder(named: "DuplicateJSONMemberCollision")
            let existing = WorkspaceModel(name: "Duplicate Member Original", repoPaths: [folder.path])
            try await createAuthorityWorkspace(existing, using: client)
            let snapshot = await runtime.workspaceStore.workspaceSnapshot(existing.id)
            let authoritative = try XCTUnwrap(snapshot)
            let operationID = UUID()
            let duplicateDocument = try duplicatedMemberDocument(
                workspaceID: existing.id,
                fileURL: authoritative.document.fileURL,
                includesDuplicate: true
            )
            let singleDocument = try duplicatedMemberDocument(
                workspaceID: existing.id,
                fileURL: authoritative.document.fileURL,
                includesDuplicate: false
            )
            let duplicateEnvelope = replaceEnvelope(
                document: duplicateDocument,
                expectedWorkspaceRevision: authoritative.revisions.workingRevision,
                operationID: operationID,
                windowID: -1304
            )
            let singleEnvelope = replaceEnvelope(
                document: singleDocument,
                expectedWorkspaceRevision: authoritative.revisions.workingRevision,
                operationID: operationID,
                windowID: -1304
            )
            let diagnostics = """
            duplicateDocumentIdentity=\(duplicateEnvelope.documentIdentity ?? "nil")
            singleDocumentIdentity=\(singleEnvelope.documentIdentity ?? "nil")
            duplicateFingerprint=\(duplicateEnvelope.fingerprint)
            singleFingerprint=\(singleEnvelope.fingerprint)
            duplicateRawDigest=\(duplicateDocument.contentDigest)
            singleRawDigest=\(singleDocument.contentDigest)
            """

            XCTAssertNotEqual(duplicateDocument.contentDigest, singleDocument.contentDigest, diagnostics)
            XCTAssertNotEqual(duplicateEnvelope.documentIdentity, singleEnvelope.documentIdentity, diagnostics)
            XCTAssertNotEqual(duplicateEnvelope.fingerprint, singleEnvelope.fingerprint, diagnostics)

            let first = await runtime.workspaceStore.execute(duplicateEnvelope)
            let collision = await runtime.workspaceStore.execute(singleEnvelope)
            let outcomeDiagnostics = """
            \(diagnostics)
            firstOutcome=\(describe(first))
            collisionOutcome=\(describe(collision))
            """
            XCTAssertEqual(first.disposition, .applied, outcomeDiagnostics)
            XCTAssertEqual(collision.disposition, .invalid, outcomeDiagnostics)
            XCTAssertEqual(collision.errorCode, .operationIDCollision, outcomeDiagnostics)
            XCTAssertEqual(
                collision.diagnostic,
                "operation_id_reused_with_different_command",
                outcomeDiagnostics
            )
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

        private func orderedDocument(
            workspaceID: UUID,
            name: String,
            fileURL: URL,
            idFirst: Bool
        ) throws -> DomainWorkspaceDocument {
            let encodedName = try String(decoding: JSONEncoder().encode(name), as: UTF8.self)
            let json = if idFirst {
                "{\"id\":\"\(workspaceID.uuidString)\",\"schemaVersion\":1,\"name\":\(encodedName),\"repoPaths\":[],\"semanticProbe\":{\"number\":1.0,\"text\":\"line\\nquote\\\"\",\"nested\":{\"b\":true,\"a\":null}}}"
            } else {
                "{\"semanticProbe\":{\"nested\":{\"a\":null,\"b\":true},\"text\":\"line\\u000Aquote\\\"\",\"number\":1e0},\"repoPaths\":[],\"name\":\(encodedName),\"schemaVersion\":1,\"id\":\"\(workspaceID.uuidString)\"}"
            }
            return try DomainWorkspaceDocument.decode(
                documentBytes: Data(json.utf8),
                fileURL: fileURL
            )
        }

        private func numberedDocument(
            workspaceID: UUID,
            name: String,
            fileURL: URL,
            numberToken: String
        ) throws -> DomainWorkspaceDocument {
            let encodedName = try String(decoding: JSONEncoder().encode(name), as: UTF8.self)
            let json = "{\"id\":\"\(workspaceID.uuidString)\",\"schemaVersion\":1,\"name\":\(encodedName),\"repoPaths\":[],\"semanticProbe\":{\"number\":\(numberToken)}}"
            return try DomainWorkspaceDocument.decode(
                documentBytes: Data(json.utf8),
                fileURL: fileURL
            )
        }

        private func duplicatedMemberDocument(
            workspaceID: UUID,
            fileURL: URL,
            includesDuplicate: Bool
        ) throws -> DomainWorkspaceDocument {
            let semanticProbe = includesDuplicate
                ? "{\"number\":1,\"number\":2}"
                : "{\"number\":2}"
            let json = "{\"id\":\"\(workspaceID.uuidString)\",\"schemaVersion\":1,\"name\":\"Duplicate Member Applied\",\"repoPaths\":[],\"semanticProbe\":\(semanticProbe)}"
            return try DomainWorkspaceDocument.decode(
                documentBytes: Data(json.utf8),
                fileURL: fileURL
            )
        }

        private func replaceEnvelope(
            document: DomainWorkspaceDocument,
            expectedWorkspaceRevision: UInt64,
            operationID: UUID,
            windowID: Int = -1302
        ) -> DomainWorkspaceCommandEnvelope {
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedWorkspaceRevision: expectedWorkspaceRevision,
                origin: .appPresentation(windowID: windowID),
                command: .replaceWorkingDocument(document)
            )
        }

        private func describe(_ outcome: DomainCommandOutcome) -> String {
            "disposition=\(outcome.disposition.rawValue),error=\(outcome.errorCode?.rawValue ?? "nil"),diagnostic=\(outcome.diagnostic ?? "nil"),digest=\(outcome.resultingDigest ?? "nil")"
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

        private func replaceOperationFingerprint(
            operationID: UUID,
            expectedFingerprint: String,
            replacementFingerprint: String,
            in journalURL: URL
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
                operations[operationIndex]["fingerprint"] as? String,
                expectedFingerprint,
                "The fixture must rewrite the intended canonical operation record"
            )
            operations[operationIndex]["fingerprint"] = replacementFingerprint
            journal["operations"] = operations
            let legacyData = try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
            try legacyData.write(to: journalURL, options: .atomic)
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
        case journalNotFound
    }
#endif
