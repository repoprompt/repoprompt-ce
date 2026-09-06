import CoreServices
import Dispatch
import Foundation
@testable import RepoPromptApp
import XCTest

final class FileSystemLivenessCorrectionTests: XCTestCase {
    func testMailboxRejectsCapturedCallbackFromPriorIngressGenerationAfterRestart() {
        let mailbox = FileSystemWatcherIngressMailbox(maxQueuedRawEntries: 10)
        let oldGeneration: UInt64 = 11
        let newGeneration: UInt64 = 12
        let oldPayload = payload(path: "/fixture/old.swift", eventID: 100)
        let newPayload = payload(path: "/fixture/new.swift", eventID: 1)

        mailbox.startAccepting(for: oldGeneration)
        XCTAssertNotNil(
            mailbox.accept(
                oldPayload,
                ingressGeneration: oldGeneration,
                lifecycleCorrelation: nil,
                scheduleDrain: nil
            )
        )

        mailbox.stopAcceptingAndDiscardPending()
        mailbox.startAccepting(for: newGeneration)

        XCTAssertNil(
            mailbox.accept(
                oldPayload,
                ingressGeneration: oldGeneration,
                lifecycleCorrelation: nil,
                scheduleDrain: nil
            )
        )
        guard let acceptedNew = mailbox.accept(
            newPayload,
            ingressGeneration: newGeneration,
            lifecycleCorrelation: nil,
            scheduleDrain: nil
        ) else {
            return XCTFail("Expected the current-generation callback to be accepted")
        }

        guard let retained = mailbox.takeNextAcceptedPayload() else {
            return XCTFail("Expected the current-generation payload to remain queued")
        }
        XCTAssertEqual(retained.ingressGeneration, newGeneration)
        XCTAssertEqual(retained.acceptedHighWatermark, acceptedNew)
    }

    func testWrappedCutCannotUseOldHighWatermarkAndOnlyFreshGenerationRecovers() async throws {
        let barrier = FSEventAsyncDeliveryBarrier(
            scheduleDeadline: { _, action in action() }
        )
        let oldGeneration = barrier.currentGeneration
        barrier.recordDelivered(eventIDs: [100], generation: oldGeneration)

        let newGeneration = barrier.reset(ifCurrent: oldGeneration)
        XCTAssertNotNil(newGeneration)
        let staleGenerationDelivered = await barrier.waitUntilDelivered(
            5,
            generation: oldGeneration
        )
        XCTAssertFalse(staleGenerationDelivered)

        barrier.recordDelivered(eventIDs: [5], generation: oldGeneration)
        let oldWatermarkDeliveredToReplacement = try await barrier.waitUntilDelivered(
            5,
            generation: XCTUnwrap(newGeneration)
        )
        XCTAssertFalse(oldWatermarkDeliveredToReplacement)

        try barrier.recordDelivered(eventIDs: [5], generation: XCTUnwrap(newGeneration))
        let freshGenerationDelivered = try await barrier.waitUntilDelivered(
            5,
            generation: XCTUnwrap(newGeneration)
        )
        XCTAssertTrue(freshGenerationDelivered)
    }

    func testFileSystemWrappedStreamFailsClosedInsteadOfRestartingWithOldCut() async throws {
        let root = try makeTestDirectory(name: "FileSystemWrappedStream")
        let service = try await FileSystemService(
            path: root.path,
            respectRepoIgnore: false,
            respectCursorignore: false,
            skipSymlinks: true,
            isTestMode: true
        )
        let deliveryGeneration = service.fseventDeliveryBarrier.currentGeneration
        let streamGeneration = await service.fseventStreamGenerationForTesting()
        let ingressGeneration = await service.watcherIngressGenerationForTesting()

        await service.handleFSEventIDsWrappedForTesting(
            streamGeneration: streamGeneration,
            ingressGeneration: ingressGeneration,
            deliveryGeneration: deliveryGeneration
        )

        let recoveryRequired = await service.fseventRecoveryRequiredForTesting()
        XCTAssertTrue(recoveryRequired)
        XCTAssertNotEqual(service.fseventDeliveryBarrier.currentGeneration, deliveryGeneration)
        do {
            try await service.startWatchingForChanges()
            XCTFail("A wrapped stream must remain unavailable until fresh root recovery")
        } catch let error as FileSystemWatcherActivationError {
            XCTAssertEqual(error, .eventIDsWrapped(path: root.path))
        }
    }

    func testCallbackObservedWrapRemainsStickyAcrossStopBeforeActorHandlerRestart() async throws {
        let root = try makeTestDirectory(name: "FileSystemCallbackWrapRestart")
        let service = try await FileSystemService(
            path: root.path,
            respectRepoIgnore: false,
            respectCursorignore: false,
            skipSymlinks: true,
            isTestMode: true
        )
        let deliveryGeneration = service.fseventDeliveryBarrier.currentGeneration

        await service.markFSEventIDsWrappedAtCallbackForTesting(deliveryGeneration: deliveryGeneration)
        await service.stopWatchingForChanges()

        let actorRecoveryRequired = await service.fseventRecoveryRequiredForTesting()
        XCTAssertFalse(actorRecoveryRequired, "The actor handler has not run in this interleaving")
        do {
            try await service.startWatchingForChanges()
            XCTFail("Callback-observed wrap must block restart before the actor handler runs")
        } catch let error as FileSystemWatcherActivationError {
            XCTAssertEqual(error, .eventIDsWrapped(path: root.path))
        } catch {
            XCTFail("Expected a wrapped-stream activation error, got: \(error)")
        }
    }

    func testActiveLoadedRootAutomaticallyReplacesWrappedServiceAndDeliversSubsequentMutation() async throws {
        let rootURL = try makeTestDirectory(name: "FileSystemActiveOwnerRecovery")
        try write("initial", to: rootURL.appendingPathComponent("Initial.swift"))
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(
            path: rootURL.path,
            respectRepoIgnore: false,
            respectCursorignore: false
        )
        let (publisherOpenings, publisherOpeningContinuation) = AsyncStream<Void>.makeStream()
        var publisherOpeningIterator = publisherOpenings.makeAsyncIterator()
        await store.setWatcherPublisherIngressDidOpenHandler { _, _ in
            publisherOpeningContinuation.yield(())
        }
        try await store.startWatchingRoot(id: root.id)
        guard await publisherOpeningIterator.next() != nil else {
            return XCTFail("Expected the active root publisher ingress to open")
        }
        guard let oldService = await store.fileSystemServiceForTesting(rootID: root.id) else {
            return XCTFail("Expected the demanded root to own a filesystem service")
        }
        let deliveryGeneration = oldService.fseventDeliveryBarrier.currentGeneration
        let streamGeneration = await oldService.fseventStreamGenerationForTesting()
        let ingressGeneration = await oldService.watcherIngressGenerationForTesting()

        await oldService.handleFSEventIDsWrappedForTesting(
            streamGeneration: streamGeneration,
            ingressGeneration: ingressGeneration,
            deliveryGeneration: deliveryGeneration
        )

        guard await publisherOpeningIterator.next() != nil else {
            return XCTFail("Expected callback-observed wrap to reopen publisher ingress automatically")
        }
        guard let recoveredService = await store.fileSystemServiceForTesting(rootID: root.id) else {
            return XCTFail("Expected the active root to retain a recovered filesystem service")
        }
        XCTAssertFalse(oldService === recoveredService)
        let recoveredFlag = await recoveredService.fseventRecoveryRequiredForTesting()
        XCTAssertFalse(recoveredFlag)

        let deltaEvents = await store.fileSystemDeltaEvents()
        var iterator = deltaEvents.makeAsyncIterator()
        let addedURL = rootURL.appendingPathComponent("AfterActiveRecovery.swift")
        try write("after recovery", to: addedURL)
        let accepted = try await store.acceptWatcherPayloadForTesting(
            rootID: root.id,
            events: [(
                absolutePath: addedURL.path,
                flags: FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
                ),
                eventId: 1
            )],
            scheduleDrain: false
        )
        guard let accepted else {
            return XCTFail("Expected a current-generation mutation after owner recovery")
        }
        let publicationSequence = await recoveredService.flushPendingEventsNow(
            throughAcceptedWatcherWatermark: accepted
        )
        await store.waitUntilPublisherIngressAppliedForTesting(
            rootID: root.id,
            servicePublicationSequence: publicationSequence
        )
        let event = await iterator.next()
        XCTAssertEqual(event?.delta, .fileAdded("AfterActiveRecovery.swift"))
        await store.stopWatchingRoot(id: root.id)
        await store.setWatcherPublisherIngressDidOpenHandler(nil)
        publisherOpeningContinuation.finish()
    }

    func testWrappedRecoveryRetainsManagedIgnoredFileForMutationAndDeletion() async throws {
        let rootURL = try makeTestDirectory(name: "FileSystemManagedIgnoredRecovery")
        let ignoredPath = "ManagedIgnored.swift"
        let postSnapshotIgnoredPath = "ManagedIgnoredAfterSnapshot.swift"
        let managedDirectoryPath = "ManagedIgnoredDirectoryAfterSnapshot.swift"
        try write(
            "ManagedIgnored.swift\nManagedIgnoredAfterSnapshot.swift\nManagedIgnoredDirectoryAfterSnapshot.swift\n",
            to: rootURL.appendingPathComponent(".gitignore")
        )
        try write("initial", to: rootURL.appendingPathComponent(ignoredPath))
        try write("initial directory candidate", to: rootURL.appendingPathComponent(managedDirectoryPath))
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(
            path: rootURL.path,
            respectRepoIgnore: true,
            respectCursorignore: false
        )
        let (publisherOpenings, publisherOpeningContinuation) = AsyncStream<Void>.makeStream()
        var publisherOpeningIterator = publisherOpenings.makeAsyncIterator()
        await store.setWatcherPublisherIngressDidOpenHandler { _, _ in
            publisherOpeningContinuation.yield(())
        }
        try await store.startWatchingRoot(id: root.id)
        guard await publisherOpeningIterator.next() != nil else {
            return XCTFail("Expected the managed-only test root publisher ingress to open")
        }
        let initialMaterialization = try await materializeManagedIgnoredFile(
            store: store,
            rootID: root.id,
            relativePath: ignoredPath
        )
        XCTAssertNotNil(initialMaterialization.file)
        let initialDirectoryMaterialization = try await materializeManagedIgnoredFile(
            store: store,
            rootID: root.id,
            relativePath: managedDirectoryPath
        )
        XCTAssertNotNil(initialDirectoryMaterialization.file)
        guard let oldService = await store.fileSystemServiceForTesting(rootID: root.id) else {
            return XCTFail("Expected the managed-only root to own a filesystem service")
        }
        let deliveryGeneration = oldService.fseventDeliveryBarrier.currentGeneration
        let streamGeneration = await oldService.fseventStreamGenerationForTesting()
        let ingressGeneration = await oldService.watcherIngressGenerationForTesting()

        try await withManagedOnlyRecoverySnapshotSuspension(store: store) { suspension in
            await oldService.handleFSEventIDsWrappedForTesting(
                streamGeneration: streamGeneration,
                ingressGeneration: ingressGeneration,
                deliveryGeneration: deliveryGeneration
            )
            guard await suspension.waitUntilReached() else {
                return
            }
            guard let currentService = await store.fileSystemServiceForTesting(rootID: root.id),
                  currentService === oldService
            else {
                XCTFail("Recovery must still own the old service at the inventory snapshot")
                return
            }
            let setupFlightCount = await store.watcherInfrastructureFlightCountForTesting(rootID: root.id)
            XCTAssertEqual(setupFlightCount, 1, "The active owner recovery must be the current setup flight")

            try write(
                "during recovery",
                to: rootURL.appendingPathComponent(postSnapshotIgnoredPath)
            )
            let racedMaterialization = try await materializeManagedIgnoredFile(
                store: store,
                rootID: root.id,
                relativePath: postSnapshotIgnoredPath
            )
            XCTAssertNotNil(racedMaterialization.file)
            let managedDirectoryURL = rootURL.appendingPathComponent(managedDirectoryPath)
            try FileManager.default.removeItem(at: managedDirectoryURL)
            try FileManager.default.createDirectory(
                at: managedDirectoryURL,
                withIntermediateDirectories: false
            )
            suspension.release()

            guard await publisherOpeningIterator.next() != nil else {
                XCTFail("Expected managed-only recovery to reopen publisher ingress")
                return
            }
            guard let recoveredService = await store.fileSystemServiceForTesting(rootID: root.id) else {
                XCTFail("Expected the managed-only root to retain a recovered service")
                return
            }
            let recoveredState = await recoveredService.getTestState()
            XCTAssertTrue(
                recoveredState.visitedItems[managedDirectoryPath] == true,
                "Replacement crawl must retain the managed path as a directory"
            )

            for (pathIndex, managedPath) in [ignoredPath, postSnapshotIgnoredPath].enumerated() {
                let managedURL = rootURL.appendingPathComponent(managedPath)
                let modifiedAccepted = try await store.acceptWatcherPayloadForTesting(
                    rootID: root.id,
                    events: [(
                        absolutePath: managedURL.path,
                        flags: FSEventStreamEventFlags(
                            kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile
                        ),
                        eventId: UInt64(2 + pathIndex * 2)
                    )],
                    scheduleDrain: false
                )
                guard let modifiedAccepted else {
                    XCTFail("Managed-only mutation must remain visible to the replacement filter: \(managedPath)")
                    return
                }
                let modifiedPublicationSequence = await recoveredService.flushPendingEventsNow(
                    throughAcceptedWatcherWatermark: modifiedAccepted
                )
                await store.waitUntilPublisherIngressAppliedForTesting(
                    rootID: root.id,
                    servicePublicationSequence: modifiedPublicationSequence
                )
                let retainedAfterMutation = await store.lookupPath(
                    rootID: root.id,
                    relativePath: managedPath
                )
                XCTAssertNotNil(retainedAfterMutation?.file)

                try FileManager.default.removeItem(at: managedURL)
                let removedAccepted = try await store.acceptWatcherPayloadForTesting(
                    rootID: root.id,
                    events: [(
                        absolutePath: managedURL.path,
                        flags: FSEventStreamEventFlags(
                            kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile
                        ),
                        eventId: UInt64(3 + pathIndex * 2)
                    )],
                    scheduleDrain: false
                )
                guard let removedAccepted else {
                    XCTFail("Managed-only deletion must remain visible to the replacement filter")
                    return
                }
                let removedPublicationSequence = await recoveredService.flushPendingEventsNow(
                    throughAcceptedWatcherWatermark: removedAccepted
                )
                await store.waitUntilPublisherIngressAppliedForTesting(
                    rootID: root.id,
                    servicePublicationSequence: removedPublicationSequence
                )
                let removedRecord = await store.lookupPath(
                    rootID: root.id,
                    relativePath: managedPath
                )
                XCTAssertNil(removedRecord?.file)
                // Recovery removed the old file exemption when this managed path became a directory.
                let staleFormerFileEvent = try await store.acceptWatcherPayloadForTesting(
                    rootID: root.id,
                    events: [(
                        absolutePath: rootURL.appendingPathComponent(managedDirectoryPath).path,
                        flags: FSEventStreamEventFlags(
                            kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile
                        ),
                        eventId: UInt64(3 + pathIndex * 2)
                    )],
                    scheduleDrain: false
                )
                XCTAssertNil(staleFormerFileEvent, "A stale event for the former ignored file can be filtered after directory recovery")
            }
        }

        await store.stopWatchingRoot(id: root.id)
        await store.setWatcherPublisherIngressDidOpenHandler(nil)
        publisherOpeningContinuation.finish()
    }

    func testPostWriteRegistrationReroutesAcrossWrappedServiceReplacement() async throws {
        let rootURL = try makeTestDirectory(name: "FileSystemStalePostWriteRegistration")
        let ignoredPath = "ManagedIgnoredAfterRegistration.swift"
        try write(
            "ManagedIgnoredAfterRegistration.swift\n",
            to: rootURL.appendingPathComponent(".gitignore")
        )
        try write("initial", to: rootURL.appendingPathComponent(ignoredPath))
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(
            path: rootURL.path,
            respectRepoIgnore: true,
            respectCursorignore: false
        )
        let (publisherOpenings, publisherOpeningContinuation) = AsyncStream<Void>.makeStream()
        var publisherOpeningIterator = publisherOpenings.makeAsyncIterator()
        await store.setWatcherPublisherIngressDidOpenHandler { _, _ in
            publisherOpeningContinuation.yield(())
        }
        try await store.startWatchingRoot(id: root.id)
        guard await publisherOpeningIterator.next() != nil else {
            return XCTFail("Expected the stale-registration root publisher ingress to open")
        }
        guard let oldService = await store.fileSystemServiceForTesting(rootID: root.id) else {
            return XCTFail("Expected the stale-registration root to own a filesystem service")
        }
        let deliveryGeneration = oldService.fseventDeliveryBarrier.currentGeneration
        let streamGeneration = await oldService.fseventStreamGenerationForTesting()
        let ingressGeneration = await oldService.watcherIngressGenerationForTesting()

        try await withManagedOnlyRecoveryAndPostWriteRegistrationSuspensions(store: store) {
            registrationSuspension, recoverySuspension, finalRestoreSuspension in
            let materializationTask = Task {
                try await store.materializeCatalogFileAfterDiskWrite(
                    rootID: root.id,
                    relativePath: ignoredPath
                )
            }
            guard await registrationSuspension.waitUntilReached() else {
                materializationTask.cancel()
                registrationSuspension.release()
                return
            }

            await oldService.handleFSEventIDsWrappedForTesting(
                streamGeneration: streamGeneration,
                ingressGeneration: ingressGeneration,
                deliveryGeneration: deliveryGeneration
            )
            guard await recoverySuspension.waitUntilReached() else {
                materializationTask.cancel()
                registrationSuspension.release()
                recoverySuspension.release()
                return
            }
            await store.setPostWriteCatalogRegistrationDidReturnHandlerForTesting(nil)
            recoverySuspension.release()

            guard await finalRestoreSuspension.waitUntilReached() else {
                XCTFail("Expected recovery to suspend before final ownership restore")
                materializationTask.cancel()
                registrationSuspension.release()
                finalRestoreSuspension.release()
                return
            }
            guard let replacementBeforeRestore = await store.fileSystemServiceForTesting(rootID: root.id) else {
                XCTFail("Expected wrapped recovery to install a replacement service before restore")
                materializationTask.cancel()
                registrationSuspension.release()
                finalRestoreSuspension.release()
                return
            }
            XCTAssertFalse(oldService === replacementBeforeRestore)
            registrationSuspension.release()

            // The replacement registration completes while final restore is held;
            // its path is intentionally absent from the captured recovery set.
            let materialization = try await materializationTask.value
            XCTAssertNotNil(materialization.file)
            finalRestoreSuspension.release()

            guard await publisherOpeningIterator.next() != nil else {
                XCTFail("Expected wrapped recovery to publish replacement ingress")
                return
            }
            guard let recoveredService = await store.fileSystemServiceForTesting(rootID: root.id) else {
                XCTFail("Expected wrapped recovery to retain the replacement service")
                return
            }
            XCTAssertTrue(replacementBeforeRestore === recoveredService)
            let accepted = try await store.acceptWatcherPayloadForTesting(
                rootID: root.id,
                events: [(
                    absolutePath: rootURL.appendingPathComponent(ignoredPath).path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile
                    ),
                    eventId: 1
                )],
                scheduleDrain: false
            )
            XCTAssertNotNil(accepted, "The rerouted registration must own the replacement filter")
        }

        await store.stopWatchingRoot(id: root.id)
        await store.setWatcherPublisherIngressDidOpenHandler(nil)
        publisherOpeningContinuation.finish()
    }

    func testCancelledPostWriteRegistrationCompletesAfterRegistrationGate() async throws {
        let rootURL = try makeTestDirectory(name: "FileSystemCancelledPostWriteRegistration")
        let ignoredPath = "ManagedIgnoredAfterCancellation.swift"
        let ignoredURL = rootURL.appendingPathComponent(ignoredPath)
        try write(
            "ManagedIgnoredAfterCancellation.swift\n",
            to: rootURL.appendingPathComponent(".gitignore")
        )
        try write("initial", to: ignoredURL)
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(
            path: rootURL.path,
            respectRepoIgnore: true,
            respectCursorignore: false
        )
        try await store.startWatchingRoot(id: root.id)

        try await withManagedOnlyRecoveryAndPostWriteRegistrationSuspensions(store: store) {
            registrationSuspension, _, _ in
            let materializationTask = Task {
                try await store.materializeCatalogFileAfterDiskWrite(
                    rootID: root.id,
                    relativePath: ignoredPath
                )
            }
            guard await registrationSuspension.waitUntilReached() else {
                XCTFail("Expected post-write registration to reach its return gate")
                materializationTask.cancel()
                registrationSuspension.release()
                return
            }

            materializationTask.cancel()
            registrationSuspension.release()
            let materialization = try await materializationTask.value
            guard let materializedFile = materialization.file else {
                return XCTFail("Cancellation must not discard post-write catalog materialization")
            }
            XCTAssertEqual(try String(contentsOf: ignoredURL, encoding: .utf8), "initial")
            guard let catalogFile = await store.lookupPath(
                rootID: root.id,
                relativePath: ignoredPath
            )?.file else {
                return XCTFail("Cancelled post-write must leave a current Store catalog file")
            }
            XCTAssertEqual(catalogFile.id, materializedFile.id)
            guard await store.fileSystemServiceForTesting(rootID: root.id) != nil else {
                return XCTFail("Cancelled post-write must retain the current filesystem owner")
            }
            let accepted = try await store.acceptWatcherPayloadForTesting(
                rootID: root.id,
                events: [(
                    absolutePath: ignoredURL.path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile
                    ),
                    eventId: 1
                )],
                scheduleDrain: false
            )
            XCTAssertNotNil(accepted, "Current owner must retain managed post-write ownership")
        }

        await store.stopWatchingRoot(id: root.id)
    }

    func testRecoveryRestorePreservesPendingIgnoredOwnerAfterRollback() async throws {
        let rootURL = try makeTestDirectory(name: "FileSystemRestoredPendingOwner")
        let restoredPath = "RestoredManagedIgnored.swift"
        let controlPath = "UnrestoredManagedIgnored.swift"
        try write(
            "\(restoredPath)\n\(controlPath)\n",
            to: rootURL.appendingPathComponent(".gitignore")
        )
        let restoredURL = rootURL.appendingPathComponent(restoredPath)
        let controlURL = rootURL.appendingPathComponent(controlPath)
        try write("restored durable file\n", to: restoredURL)
        try write("ordinary pending file\n", to: controlURL)

        let service = try await FileSystemService(
            path: rootURL.path,
            respectRepoIgnore: true,
            respectCursorignore: false,
            skipSymlinks: true,
            isTestMode: true
        )

        let restoredRegistration = await service.beginExplicitlyManagedRegularFileRegistration(
            relativePath: restoredPath
        )
        guard case .ineligible(.ignored) = restoredRegistration.eligibility else {
            return XCTFail("Expected the restored path to be ignored")
        }
        let restoredToken = try XCTUnwrap(restoredRegistration.token)
        let restoredPending = await service.explicitlyManagedIgnoredRegistrationSnapshotForTesting(
            relativePath: restoredPath
        )
        XCTAssertEqual(restoredPending.pendingOwnerCount, 1)
        XCTAssertFalse(restoredPending.hasCommittedOwner)
        XCTAssertTrue(restoredPending.isRegistered)
        XCTAssertTrue(restoredPending.watcherExemptsPath)

        await service.restoreExplicitlyManagedIgnoredFilePathsForRecovery([restoredPath])
        let restoredAfterRestore = await service.explicitlyManagedIgnoredRegistrationSnapshotForTesting(
            relativePath: restoredPath
        )
        XCTAssertEqual(restoredAfterRestore.pendingOwnerCount, 1)
        XCTAssertTrue(
            restoredAfterRestore.hasCommittedOwner,
            "Recovery ownership must become durable without settling the pending registration"
        )
        XCTAssertTrue(restoredAfterRestore.isRegistered)
        XCTAssertTrue(restoredAfterRestore.watcherExemptsPath)

        let restoredRollbackSucceeded = await service.rollbackExplicitlyManagedRegularFileRegistration(restoredToken)
        XCTAssertTrue(restoredRollbackSucceeded)
        let restoredAfterRollback = await service.explicitlyManagedIgnoredRegistrationSnapshotForTesting(
            relativePath: restoredPath
        )
        XCTAssertEqual(restoredAfterRollback.pendingOwnerCount, 0)
        XCTAssertTrue(restoredAfterRollback.hasCommittedOwner)
        XCTAssertEqual(restoredAfterRollback.visitedItem, false)
        XCTAssertTrue(restoredAfterRollback.isVisited)
        XCTAssertTrue(restoredAfterRollback.isRegistered)
        XCTAssertTrue(restoredAfterRollback.watcherExemptsPath)

        try FileManager.default.removeItem(at: restoredURL)
        let acceptedDeletion = await service.acceptWatcherPayloadForTesting(
            [(
                absolutePath: restoredURL.path,
                flags: FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile
                ),
                eventId: 1
            )],
            scheduleDrain: false
        )
        XCTAssertNotNil(
            acceptedDeletion,
            "A restored managed owner must keep deletion ingress visible after rollback"
        )

        let controlRegistration = await service.beginExplicitlyManagedRegularFileRegistration(
            relativePath: controlPath
        )
        guard case .ineligible(.ignored) = controlRegistration.eligibility else {
            return XCTFail("Expected the control path to be ignored")
        }
        let controlToken = try XCTUnwrap(controlRegistration.token)
        let controlPending = await service.explicitlyManagedIgnoredRegistrationSnapshotForTesting(
            relativePath: controlPath
        )
        XCTAssertEqual(controlPending.pendingOwnerCount, 1)
        XCTAssertFalse(controlPending.hasCommittedOwner)

        let controlRollbackSucceeded = await service.rollbackExplicitlyManagedRegularFileRegistration(controlToken)
        XCTAssertTrue(controlRollbackSucceeded)
        let controlAfterRollback = await service.explicitlyManagedIgnoredRegistrationSnapshotForTesting(
            relativePath: controlPath
        )
        XCTAssertEqual(controlAfterRollback.pendingOwnerCount, 0)
        XCTAssertFalse(controlAfterRollback.hasCommittedOwner)
        XCTAssertNil(controlAfterRollback.visitedItem)
        XCTAssertFalse(controlAfterRollback.isVisited)
        XCTAssertFalse(controlAfterRollback.isRegistered)
        XCTAssertFalse(controlAfterRollback.watcherExemptsPath)

        try FileManager.default.removeItem(at: controlURL)
        let filteredControlDeletion = await service.acceptWatcherPayloadForTesting(
            [(
                absolutePath: controlURL.path,
                flags: FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile
                ),
                eventId: 2
            )],
            scheduleDrain: false
        )
        XCTAssertNil(
            filteredControlDeletion,
            "An ordinary rolled-back ignored owner must remain filtered"
        )
    }

    func testLoadedRootReplacesWrappedServiceAndDeliversSubsequentMutation() async throws {
        let rootURL = try makeTestDirectory(name: "FileSystemOwnerRecovery")
        try write("initial", to: rootURL.appendingPathComponent("Initial.swift"))
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(
            path: rootURL.path,
            respectRepoIgnore: false,
            respectCursorignore: false
        )
        guard let oldService = await store.fileSystemServiceForTesting(rootID: root.id) else {
            return XCTFail("Expected the loaded root to own a filesystem service")
        }
        let deliveryGeneration = oldService.fseventDeliveryBarrier.currentGeneration
        let streamGeneration = await oldService.fseventStreamGenerationForTesting()
        let ingressGeneration = await oldService.watcherIngressGenerationForTesting()
        await oldService.handleFSEventIDsWrappedForTesting(
            streamGeneration: streamGeneration,
            ingressGeneration: ingressGeneration,
            deliveryGeneration: deliveryGeneration
        )

        try await store.startWatchingRoot(id: root.id)
        guard let recoveredService = await store.fileSystemServiceForTesting(rootID: root.id) else {
            return XCTFail("Expected the recovered root to retain a filesystem service")
        }
        XCTAssertFalse(oldService === recoveredService)
        let recoveredFlag = await recoveredService.fseventRecoveryRequiredForTesting()
        XCTAssertFalse(recoveredFlag)
        let watcherIsActive = try await store.rootWatcherIsActiveForTesting(rootID: root.id)
        XCTAssertTrue(watcherIsActive)

        let deltaEvents = await store.fileSystemDeltaEvents()
        var iterator = deltaEvents.makeAsyncIterator()
        let addedURL = rootURL.appendingPathComponent("AfterRecovery.swift")
        try write("after recovery", to: addedURL)
        let accepted = try await store.acceptWatcherPayloadForTesting(
            rootID: root.id,
            events: [(
                absolutePath: addedURL.path,
                flags: FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
                ),
                eventId: 1
            )],
            scheduleDrain: false
        )
        XCTAssertNotNil(accepted)
        guard let accepted else {
            return XCTFail("Expected a current-generation mutation after explicit recovery")
        }
        let publicationSequence = await recoveredService.flushPendingEventsNow(
            throughAcceptedWatcherWatermark: accepted
        )
        await store.waitUntilPublisherIngressAppliedForTesting(
            rootID: root.id,
            servicePublicationSequence: publicationSequence
        )
        let event = await iterator.next()
        XCTAssertEqual(event?.delta, .fileAdded("AfterRecovery.swift"))
        await recoveredService.stopWatchingForChanges()
    }

    func testSeededPublicationPermitLinearizesCallbackWrapAfterAssignment() async throws {
        let (service, initializationID) = try await makeSeededServiceReadyForPublication(
            name: "FileSystemSeededPublicationPermit"
        )
        guard let proof = await service.activateSeededPublication(initializationID: initializationID) else {
            await service.abortSeededPreparation(initializationID: initializationID)
            return XCTFail("Expected a ready seeded service to activate")
        }

        let callbackReady = DispatchSemaphore(value: 0)
        let callbackMayProceed = DispatchSemaphore(value: 0)
        let callbackFinished = DispatchSemaphore(value: 0)
        let publicationCompleted = LivenessLockedValue(false)
        let callbackObservedPublication = LivenessLockedValue(false)
        let ownerRecoverySignaled = LivenessLockedValue(false)
        service.fseventRecoverySignal.install {
            ownerRecoverySignaled.set(true)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            callbackReady.signal()
            guard callbackMayProceed.wait(timeout: .now() + 5) == .success else {
                callbackFinished.signal()
                return
            }
            service.markFSEventIDsWrappedAtPublicationPermitForTesting(
                deliveryGeneration: proof.deliveryGeneration
            )
            callbackObservedPublication.set(publicationCompleted.value)
            callbackFinished.signal()
        }
        XCTAssertEqual(callbackReady.wait(timeout: .now() + 5), .success)

        let result = service.withSeededPublicationRecoveryPermitForTesting(
            proof,
            onAcquired: {
                callbackMayProceed.signal()
            },
            body: {
                publicationCompleted.set(true)
                return true
            }
        )
        // Keep the callback teardown bounded even if permit acquisition fails
        // before the interleaving hook is reached.
        callbackMayProceed.signal()
        XCTAssertEqual(result, true)
        XCTAssertEqual(callbackFinished.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(callbackObservedPublication.value)
        XCTAssertTrue(ownerRecoverySignaled.value)
        XCTAssertTrue(service.fseventRecoveryGate.isRequired)

        let finalized = await service.finalizeSeededPublication(proof)
        XCTAssertFalse(finalized, "A post-linearization wrap must route to recovery, not stale publication")
        await service.abortSeededPreparation(initializationID: initializationID)
        service.fseventRecoverySignal.clear()
        await service.stopWatchingForChanges()
    }

    func testSeededPublicationRejectsWrapBeforeActivation() async throws {
        let (service, initializationID) = try await makeSeededServiceReadyForPublication(
            name: "FileSystemSeededWrapBeforeActivation"
        )
        let deliveryGeneration = service.fseventDeliveryBarrier.currentGeneration
        let streamGeneration = await service.fseventStreamGenerationForTesting()
        let ingressGeneration = await service.watcherIngressGenerationForTesting()
        await service.handleFSEventIDsWrappedForTesting(
            streamGeneration: streamGeneration,
            ingressGeneration: ingressGeneration,
            deliveryGeneration: deliveryGeneration
        )

        let proof = await service.activateSeededPublication(initializationID: initializationID)
        XCTAssertNil(proof, "A callback-observed wrap must block seeded activation")
        let recoveryRequired = await service.fseventRecoveryRequiredForTesting()
        XCTAssertTrue(recoveryRequired)
        await service.abortSeededPreparation(initializationID: initializationID)
    }

    func testSeededPublicationFinalizationRejectsWrapAfterActivationBeforePublication() async throws {
        let (service, initializationID) = try await makeSeededServiceReadyForPublication(
            name: "FileSystemSeededWrapBeforeFinalization"
        )
        guard let proof = await service.activateSeededPublication(initializationID: initializationID) else {
            await service.abortSeededPreparation(initializationID: initializationID)
            return XCTFail("Expected a ready seeded service to activate")
        }
        let deliveryGeneration = service.fseventDeliveryBarrier.currentGeneration
        let streamGeneration = await service.fseventStreamGenerationForTesting()
        let ingressGeneration = await service.watcherIngressGenerationForTesting()
        await service.handleFSEventIDsWrappedForTesting(
            streamGeneration: streamGeneration,
            ingressGeneration: ingressGeneration,
            deliveryGeneration: deliveryGeneration
        )

        let activationIsCurrent = await service.seededPublicationActivationIsCurrent(proof)
        XCTAssertFalse(activationIsCurrent)
        let finalized = await service.finalizeSeededPublication(proof)
        XCTAssertFalse(finalized)
        await service.abortSeededPreparation(initializationID: initializationID)
        await service.stopWatchingForChanges()
    }

    private func materializeManagedIgnoredFile(
        store: WorkspaceFileContextStore,
        rootID: UUID,
        relativePath: String
    ) async throws -> WorkspaceFileCatalogMaterializationResult {
        try await store.materializeCatalogFileAfterDiskWrite(
            rootID: rootID,
            relativePath: relativePath
        )
    }

    private func withManagedOnlyRecoverySnapshotSuspension<T>(
        store: WorkspaceFileContextStore,
        operation: (ManagedOnlyRecoverySnapshotSuspension) async throws -> T
    ) async throws -> T {
        let suspension = ManagedOnlyRecoverySnapshotSuspension()
        await store.setWrappedWatcherRecoveryDidSnapshotManagedOnlyIgnoredFilePathsHandlerForTesting { _ in
            await suspension.suspend()
        }
        do {
            let result = try await operation(suspension)
            suspension.finish()
            await store.setWrappedWatcherRecoveryDidSnapshotManagedOnlyIgnoredFilePathsHandlerForTesting(nil)
            return result
        } catch {
            suspension.finish()
            await store.setWrappedWatcherRecoveryDidSnapshotManagedOnlyIgnoredFilePathsHandlerForTesting(nil)
            throw error
        }
    }

    private func withManagedOnlyRecoveryAndPostWriteRegistrationSuspensions<T>(
        store: WorkspaceFileContextStore,
        operation: (
            ManagedOnlyRecoverySnapshotSuspension,
            ManagedOnlyRecoverySnapshotSuspension,
            ManagedOnlyRecoverySnapshotSuspension
        ) async throws -> T
    ) async throws -> T {
        let registrationSuspension = ManagedOnlyRecoverySnapshotSuspension()
        let recoverySuspension = ManagedOnlyRecoverySnapshotSuspension()
        let finalRestoreSuspension = ManagedOnlyRecoverySnapshotSuspension()
        await store.setPostWriteCatalogRegistrationDidReturnHandlerForTesting { _, _ in
            await registrationSuspension.suspend()
        }
        await store.setWrappedWatcherRecoveryDidSnapshotManagedOnlyIgnoredFilePathsHandlerForTesting { _ in
            await recoverySuspension.suspend()
        }
        await store.setWrappedWatcherRecoveryWillRestoreLatestManagedOnlyIgnoredFilePathsHandlerForTesting { _ in
            await finalRestoreSuspension.suspend()
        }
        do {
            let result = try await operation(
                registrationSuspension,
                recoverySuspension,
                finalRestoreSuspension
            )
            registrationSuspension.finish()
            recoverySuspension.finish()
            finalRestoreSuspension.finish()
            await store.setPostWriteCatalogRegistrationDidReturnHandlerForTesting(nil)
            await store.setWrappedWatcherRecoveryDidSnapshotManagedOnlyIgnoredFilePathsHandlerForTesting(nil)
            await store.setWrappedWatcherRecoveryWillRestoreLatestManagedOnlyIgnoredFilePathsHandlerForTesting(nil)
            return result
        } catch {
            registrationSuspension.finish()
            recoverySuspension.finish()
            finalRestoreSuspension.finish()
            await store.setPostWriteCatalogRegistrationDidReturnHandlerForTesting(nil)
            await store.setWrappedWatcherRecoveryDidSnapshotManagedOnlyIgnoredFilePathsHandlerForTesting(nil)
            await store.setWrappedWatcherRecoveryWillRestoreLatestManagedOnlyIgnoredFilePathsHandlerForTesting(nil)
            throw error
        }
    }

    private func makeSeededServiceReadyForPublication(
        name: String
    ) async throws -> (FileSystemService, FileSystemSeedInitializationID) {
        let root = try makeTestDirectory(name: name)
        let service = try await FileSystemService(
            path: root.path,
            respectRepoIgnore: false,
            respectCursorignore: false,
            skipSymlinks: true,
            isTestMode: true
        )
        let initializationID = FileSystemSeedInitializationID()
        _ = try await service.startWatchingForSeedPreparation(
            since: FileSystemSeedReplayJournalCut(fseventID: 1),
            initializationID: initializationID
        )
        let preparation = try await service.prepareSeededInventoryForTesting(
            relativeFilePaths: [],
            relativeFolderPaths: [],
            initializationID: initializationID
        )
        try await service.installSeededInventory(preparation)
        let replayCut = try await service.captureSeedReplayAcceptedWatermark(
            initializationID: initializationID
        )
        _ = try await service.flushSeedReplay(
            through: replayCut,
            initializationID: initializationID
        )
        return (service, initializationID)
    }

    private func payload(path: String, eventID: FSEventStreamEventId) -> FSEventCallbackPayload {
        FSEventCallbackPayload(entries: [
            FSEventCallbackEntry(
                path: path,
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                id: eventID
            )
        ])
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private final class ManagedOnlyRecoverySnapshotSuspension: @unchecked Sendable {
    private let reachedStream: AsyncStream<Void>
    private let reachedContinuation: AsyncStream<Void>.Continuation
    private let releaseStream: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        let reached = AsyncStream<Void>.makeStream()
        reachedStream = reached.stream
        reachedContinuation = reached.continuation
        let release = AsyncStream<Void>.makeStream()
        releaseStream = release.stream
        releaseContinuation = release.continuation
    }

    func waitUntilReached() async -> Bool {
        var iterator = reachedStream.makeAsyncIterator()
        return await iterator.next() != nil
    }

    func suspend() async {
        reachedContinuation.yield(())
        var iterator = releaseStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        releaseContinuation.yield(())
    }

    func finish() {
        releaseContinuation.finish()
        reachedContinuation.finish()
    }
}

private final class LivenessLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
