import Darwin
import Foundation
import MCP
@testable import RepoPrompt
import RepoPromptShared
import XCTest

final class MCPSocketDescriptorHardeningTests: XCTestCase {
    func testSharedHelperSetsAndPreservesDescriptorFlags() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        defer {
            Self.closeIfOpen(descriptors[0])
            Self.closeIfOpen(descriptors[1])
        }

        let before = fcntl(descriptors[0], F_GETFD)
        XCTAssertGreaterThanOrEqual(before, 0)

        try POSIXDescriptorSupport.setCloseOnExec(descriptors[0])

        let after = fcntl(descriptors[0], F_GETFD)
        XCTAssertGreaterThanOrEqual(after, 0)
        XCTAssertNotEqual(after & FD_CLOEXEC, 0)
        XCTAssertEqual(after & ~FD_CLOEXEC, before & ~FD_CLOEXEC)

        XCTAssertThrowsError(try POSIXDescriptorSupport.setCloseOnExec(-1)) { error in
            XCTAssertEqual(error as? POSIXDescriptorConfigurationError, .invalidFileDescriptor(fd: -1))
        }
    }

    @MainActor
    func testExternalEventsWatcherOpenerSetsCloseOnExec() throws {
        let fixture = try TemporarySocketFixture.make(prefix: "watcher")
        defer { fixture.removeOwnedDirectory() }

        let fd = try MCPExternalEventsMonitor.openDirectoryWatcherFD(at: fixture.directoryURL)
        defer { Self.closeIfOpen(fd) }

        XCTAssertTrue(Self.hasCloseOnExec(fd))
    }

    func testBootstrapListenerAndAcceptedSocketSetCloseOnExec() async throws {
        #if DEBUG
            let fixture = try TemporarySocketFixture.make(prefix: "listener")
            defer { fixture.removeOwnedDirectory() }
            let server = BootstrapSocketServer(socketURL: fixture.socketURL)
            let acceptedFlag = OptionalBoolRecorder()

            try await server.start { fd, _, _, _ in
                await acceptedFlag.record(Self.hasCloseOnExec(fd))
                return .reject()
            }
            do {
                let listenerHasCloseOnExec = await server.debugListenerHasCloseOnExec()
                XCTAssertEqual(listenerHasCloseOnExec, true)

                let clientFD = try Self.connectRawUnixClient(to: fixture.socketURL)
                defer { Self.closeIfOpen(clientFD) }
                try Self.writeBootstrapRequest(to: clientFD)

                let recorded = await Self.waitUntil { await acceptedFlag.value != nil }
                XCTAssertTrue(recorded)
                let acceptedHasCloseOnExec = await acceptedFlag.value
                XCTAssertEqual(acceptedHasCloseOnExec, true)

                await server.stop()
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
            } catch {
                await server.stop()
                throw error
            }
        #else
            throw XCTSkip("Bootstrap socket listener descriptor seam is DEBUG-only")
        #endif
    }

    func testSuccessiveSameSessionBootstrapAdmissionsDoNotDoubleDiscountReplacement() async throws {
        #if DEBUG
            try await Self.withIsolatedManagerSocket(prefix: "same-token-reservation") { manager, socketURL in
                await manager.setConnectionApprovalHandler { _, _ in true }
                await manager.start()
                let listenerReady = await Self.waitForCurrentBootstrapListener(manager, at: socketURL)
                XCTAssertTrue(listenerReady)

                let sessionToken = "same-token-reservation-\(UUID().uuidString)"
                let replacementID = UUID()
                let unrelatedID = UUID()
                let replacementStopGate = SuspendedAdmissionGate()
                await manager.debugConfigureGlobalAdmissionForTesting(
                    maxGlobalConnections: 2,
                    preserveOnePerClient: false
                )
                await manager.debugInstallAdmissionEvictionCandidateForTesting(
                    connectionID: replacementID,
                    connection: BootstrapAdmissionTestConnection(
                        idleSeconds: 180,
                        stopGate: replacementStopGate
                    ),
                    clientID: "same-token-replacement",
                    totalToolCalls: 0,
                    createdAt: .distantPast
                )
                await manager.debugInstallAdmissionEvictionCandidateForTesting(
                    connectionID: unrelatedID,
                    connection: BootstrapAdmissionTestConnection(idleSeconds: 60),
                    clientID: "same-token-unrelated",
                    totalToolCalls: 1,
                    createdAt: Date()
                )
                await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: replacementID)

                let firstFD = try Self.connectRawUnixClient(to: socketURL)
                defer { Self.closeIfOpen(firstFD) }
                let secondFD = try Self.connectRawUnixClient(to: socketURL)
                defer { Self.closeIfOpen(secondFD) }

                do {
                    try Self.writeBootstrapRequest(
                        to: firstFD,
                        sessionToken: sessionToken,
                        clientName: "same-token-first"
                    )
                    let firstResponse = try Self.readBootstrapResponse(from: firstFD)
                    let replacementRemovalStarted = await Self.waitUntil { await replacementStopGate.hasEntered }
                    let firstCommitCompleted = await Self.waitUntil {
                        await manager.debugBootstrapReservationCount() == 0
                    }
                    XCTAssertEqual(firstResponse.type, "accepted")
                    XCTAssertTrue(replacementRemovalStarted)
                    XCTAssertTrue(firstCommitCompleted)

                    try Self.writeBootstrapRequest(
                        to: secondFD,
                        sessionToken: sessionToken,
                        clientName: "same-token-second"
                    )
                    let secondResponse = try Self.readBootstrapResponse(from: secondFD)
                    let unrelatedRetained = await manager.debugContainsConnection(unrelatedID)
                    let secondCommitCompleted = await Self.waitUntil {
                        await manager.debugBootstrapReservationCount() == 0
                    }
                    let reservationCountAfterSecondAdmission = await manager.debugBootstrapReservationCount()
                    let effectiveConnectionCount = await manager.debugEffectiveRegisteredConnectionCountForTesting()
                    XCTAssertEqual(secondResponse.type, "accepted")
                    XCTAssertTrue(
                        unrelatedRetained,
                        "A successive admission for the same durable token must not evict an unrelated client"
                    )
                    XCTAssertTrue(secondCommitCompleted)
                    XCTAssertEqual(reservationCountAfterSecondAdmission, 0)
                    XCTAssertEqual(
                        effectiveConnectionCount,
                        2,
                        "Only the latest same-session successor and unrelated connection may remain logically registered"
                    )
                } catch {
                    await replacementStopGate.release()
                    throw error
                }

                await replacementStopGate.release()
                let reservationDrained = await Self.waitUntil {
                    await manager.debugBootstrapReservationCount() == 0
                }
                XCTAssertTrue(reservationDrained)
                await manager.debugRemoveConnection(unrelatedID)
                await manager.debugRemoveConnection(replacementID)
                await manager.debugConfigureGlobalAdmissionForTesting(
                    maxGlobalConnections: nil,
                    preserveOnePerClient: nil
                )
            }
        #else
            throw XCTSkip("Bootstrap admission reservation seam is DEBUG-only")
        #endif
    }

    func testBootstrapReplacementPublishesSuccessorBeforeHungPredecessorStop() async throws {
        #if DEBUG
            try await Self.withIsolatedManagerSocket(prefix: "replacement-commit-expiry") { manager, _ in
                await manager.setConnectionApprovalHandler { _, _ in true }
                await manager.start()
                let sessionToken = "replacement-commit-expiry-\(UUID().uuidString)"
                let predecessorID = UUID()
                let replacementID = UUID()
                let predecessorStopGate = SuspendedAdmissionGate()
                let predecessorStopDeadlineGate = SuspendedAdmissionGate()
                await manager.debugSetBootstrapPredecessorStopGraceSleepForTesting { _ in
                    await predecessorStopDeadlineGate.suspendUntilReleased()
                }
                await manager.debugInstallAdmissionEvictionCandidateForTesting(
                    connectionID: predecessorID,
                    connection: BootstrapAdmissionTestConnection(
                        idleSeconds: 120,
                        stopGate: predecessorStopGate
                    ),
                    clientID: "replacement-commit-expiry-predecessor",
                    totalToolCalls: 0,
                    createdAt: .distantPast
                )
                await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)

                let descriptors = try Self.makeSocketPair()
                defer { Self.closeIfOpen(descriptors[1]) }
                let optionalAdmission = await manager.debugMakeReservedBootstrapAdmissionForShutdownTest(
                    connectionID: replacementID,
                    sessionToken: sessionToken,
                    clientPid: Int(getpid()),
                    clientName: "replacement-commit-expiry-successor",
                    clientFD: descriptors[0]
                )
                let admission = try XCTUnwrap(optionalAdmission)
                let commitCompleted = OptionalBoolRecorder()
                let commitTask = Task {
                    await admission.postAccept?()
                    await commitCompleted.record(true)
                }

                let predecessorStopStarted = await Self.waitUntil {
                    await predecessorStopGate.hasEntered
                }
                XCTAssertTrue(predecessorStopStarted)

                let commitFinishedWhilePredecessorStopWasBlocked = await Self.waitUntil {
                    await commitCompleted.value == true
                }
                let predecessorStillTracked = await manager.debugContainsConnection(predecessorID)
                let replacementRegistered = await manager.debugContainsConnection(replacementID)
                let boundConnectionID = await manager.debugConnectionIDForSessionTokenForTesting(sessionToken)
                let reservationCountDuringCleanup = await manager.debugBootstrapReservationCount()
                let transferredCountDuringCleanup = await manager.debugTransferredBootstrapSocketCountForShutdownTest()
                XCTAssertTrue(
                    commitFinishedWhilePredecessorStopWasBlocked,
                    "A hung predecessor stop must not keep post-accept commit suspended"
                )
                XCTAssertTrue(
                    predecessorStillTracked,
                    "The exact predecessor may remain tracked only while identity-fenced cleanup is pending"
                )
                XCTAssertTrue(
                    replacementRegistered,
                    "The successor must register before awaiting predecessor cleanup"
                )
                XCTAssertEqual(boundConnectionID, replacementID)
                XCTAssertEqual(
                    reservationCountDuringCleanup,
                    0,
                    "Published successors must not retain a permanent committing reservation"
                )
                XCTAssertEqual(transferredCountDuringCleanup, 0)
                XCTAssertFalse(
                    Self.isClosed(descriptors[0]),
                    "The registered successor must retain ownership of its transferred descriptor"
                )

                let predecessorStopDeadlineStarted = await Self.waitUntil {
                    await predecessorStopDeadlineGate.hasEntered
                }
                XCTAssertTrue(predecessorStopDeadlineStarted)
                await predecessorStopDeadlineGate.release()
                let predecessorRemovedBeforeStopReturned = await Self.waitUntil {
                    await manager.debugContainsConnection(predecessorID) == false
                }
                XCTAssertTrue(
                    predecessorRemovedBeforeStopReturned,
                    "The bounded handoff grace must detach exact predecessor state even if stop remains hung"
                )
                let predecessorStopStillBlocked = await predecessorStopGate.hasEntered
                XCTAssertTrue(predecessorStopStillBlocked)

                await predecessorStopGate.release()
                await commitTask.value
                await manager.debugSetBootstrapPredecessorStopGraceSleepForTesting(nil)
                await manager.debugRemoveConnection(replacementID)
                await manager.debugRemoveConnection(predecessorID)
            }
        #else
            throw XCTSkip("Bootstrap replacement commit seam is DEBUG-only")
        #endif
    }

    func testBootstrapReplacementPreparationFailurePreservesUsablePredecessor() async throws {
        #if DEBUG
            try await Self.withIsolatedManagerSocket(prefix: "replacement-prepare-rollback") { manager, _ in
                await manager.start()
                let sessionToken = "replacement-prepare-rollback-\(UUID().uuidString)"
                let predecessorID = UUID()
                let replacementID = UUID()
                await manager.debugInstallAdmissionEvictionCandidateForTesting(
                    connectionID: predecessorID,
                    connection: BootstrapAdmissionTestConnection(idleSeconds: 120),
                    clientID: "replacement-prepare-rollback-predecessor",
                    totalToolCalls: 0,
                    createdAt: .distantPast
                )
                await manager.debugBindSessionTokenForAdmissionTesting(sessionToken, to: predecessorID)

                let optionalAdmission = await manager.debugMakeReservedBootstrapAdmissionForShutdownTest(
                    connectionID: replacementID,
                    sessionToken: sessionToken,
                    clientPid: Int(getpid()),
                    clientName: "replacement-prepare-rollback-successor",
                    clientFD: -1
                )
                let admission = try XCTUnwrap(optionalAdmission)
                await admission.postAccept?()

                let predecessorRetained = await manager.debugContainsConnection(predecessorID)
                let replacementRegistered = await manager.debugContainsConnection(replacementID)
                let reservationCount = await manager.debugBootstrapReservationCount()
                let transferredCount = await manager.debugTransferredBootstrapSocketCountForShutdownTest()
                XCTAssertTrue(
                    predecessorRetained,
                    "Successor preparation must fail before disconnecting the predecessor"
                )
                XCTAssertFalse(replacementRegistered)
                XCTAssertEqual(reservationCount, 0)
                XCTAssertEqual(transferredCount, 0)

                let predecessorCallRan = AsyncCounter()
                try await manager.withConnectionCallPermitForTesting(
                    connectionID: predecessorID,
                    lane: .ordinary
                ) {
                    await predecessorCallRan.increment()
                }
                let callCount = await predecessorCallRan.value
                XCTAssertEqual(callCount, 1, "Rollback must leave the predecessor usable")

                await manager.debugRemoveConnection(predecessorID)
            }
        #else
            throw XCTSkip("Bootstrap replacement rollback seam is DEBUG-only")
        #endif
    }

    func testBootstrapSilentRawSocketBurstRecordsBoundedSerialQueueAttributionAndStopsCleanly() async throws {
        #if DEBUG
            EditFlowPerf.resetDebugCaptureForTesting()
            defer { EditFlowPerf.resetDebugCaptureForTesting() }
            switch EditFlowPerf.beginDebugCapture(label: "bootstrap-silent-raw-burst", maxSamples: 500) {
            case .started:
                break
            case .busy:
                XCTFail("Bootstrap attribution capture should start")
            }

            let fixture = try TemporarySocketFixture.make(prefix: "silent-burst")
            defer { fixture.removeOwnedDirectory() }
            let server = BootstrapSocketServer(socketURL: fixture.socketURL)
            let admissionCount = AsyncCounter()
            var clientFDs: [Int32] = []
            defer { clientFDs.forEach(Self.closeIfOpen) }

            try await server.start { _, _, _, _ in
                await admissionCount.increment()
                return .reject()
            }
            do {
                let maxInFlight = await server.diagnostics().maxInFlightHandshakes
                for _ in 0 ..< maxInFlight {
                    try clientFDs.append(Self.connectRawUnixClient(to: fixture.socketURL))
                }
                let saturated = await Self.waitUntil {
                    let diagnostics = await server.diagnostics()
                    let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: false)
                    let queuedCount = snapshot.lifecycleEvents.count(where: { $0.eventName == "Bootstrap.HandshakeIOQueued" })
                    let beganCount = snapshot.lifecycleEvents.count(where: { $0.eventName == "Bootstrap.HandshakeIOBegan" })
                    let endedCount = snapshot.lifecycleEvents.count(where: { $0.eventName == "Bootstrap.HandshakeIOEnded" })
                    return diagnostics.inFlightHandshakes == maxInFlight
                        && diagnostics.acceptSuspendedForBackpressure
                        && queuedCount == maxInFlight
                        && beganCount == 1
                        && endedCount == 0
                }
                XCTAssertTrue(saturated)
                let admissionCountWhileSaturated = await admissionCount.value
                XCTAssertEqual(admissionCountWhileSaturated, 0)

                await server.stop()
                let drained = await Self.waitUntil {
                    EditFlowPerf.debugCaptureSnapshot(finish: false).lifecycleEvents
                        .count(where: { $0.eventName == "Bootstrap.HandshakeIOEnded" }) == maxInFlight
                }
                XCTAssertTrue(drained)
                let diagnostics = await server.diagnostics()
                XCTAssertEqual(diagnostics.inFlightHandshakes, 0)
                XCTAssertFalse(diagnostics.acceptSuspendedForBackpressure)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))

                let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
                XCTAssertEqual(snapshot.lifecycleEvents.count(where: { $0.eventName == "Bootstrap.SocketAccepted" }), maxInFlight)
                XCTAssertEqual(snapshot.lifecycleEvents.count(where: { $0.eventName == "Bootstrap.HandshakeIOQueued" }), maxInFlight)
                XCTAssertEqual(snapshot.lifecycleEvents.count(where: { $0.eventName == "Bootstrap.HandshakeIOBegan" }), maxInFlight)
                XCTAssertEqual(snapshot.lifecycleEvents.count(where: { $0.eventName == "Bootstrap.HandshakeIOEnded" }), maxInFlight)
                XCTAssertEqual(snapshot.lifecycleEvents.count(where: { $0.eventName == "Bootstrap.AdmissionBegan" }), 0)
                XCTAssertEqual(snapshot.stages.filter { $0.stageName == "EditFlow.Bootstrap.HandshakeIOQueueEnvelope" }.reduce(0) { $0 + $1.sampleCount }, maxInFlight)
                XCTAssertEqual(snapshot.stages.filter { $0.stageName == "EditFlow.Bootstrap.HandshakeIOBlockingRead" }.reduce(0) { $0 + $1.sampleCount }, maxInFlight)
                for dimensions in snapshot.lifecycleEvents.map(\.sanitizedDimensions) + snapshot.stages.map(\.sanitizedDimensions) {
                    XCTAssertFalse(dimensions.contains("/"))
                    XCTAssertFalse(dimensions.contains("fd-hardening"))
                    XCTAssertFalse(dimensions.contains("silent-burst"))
                    XCTAssertFalse(dimensions.contains("session"))
                    XCTAssertFalse(dimensions.contains("client"))
                }
            } catch {
                await server.stop()
                throw error
            }
        #else
            throw XCTSkip("Bootstrap handshake attribution seam is DEBUG-only")
        #endif
    }

    func testAppTransportSetsCloseOnExecOnAdoptedSocket() async throws {
        #if DEBUG
            let descriptors = try Self.makeSocketPair()
            defer { Self.closeIfOpen(descriptors[1]) }

            let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
            let socketHasCloseOnExec = await transport.debugSocketHasCloseOnExec()
            XCTAssertEqual(socketHasCloseOnExec, true)
            await transport.disconnect()
        #else
            throw XCTSkip("App transport descriptor seam is DEBUG-only")
        #endif
    }

    func testAppTransportSetsCloseOnExecOnOutboundSocket() async throws {
        #if DEBUG
            let fixture = try TemporarySocketFixture.make(prefix: "outbound")
            defer { fixture.removeOwnedDirectory() }
            let listenerFD = try Self.makeUnixListener(at: fixture.socketURL)
            defer {
                POSIXDescriptorSupport.shutdownSocketReadWrite(listenerFD)
                Self.closeIfOpen(listenerFD)
            }

            let transport = UnixSocketMCPTransport(socketURL: fixture.socketURL)
            try await transport.connect()
            let acceptedFD = Darwin.accept(listenerFD, nil, nil)
            XCTAssertGreaterThanOrEqual(acceptedFD, 0)
            defer { Self.closeIfOpen(acceptedFD) }

            let socketHasCloseOnExec = await transport.debugSocketHasCloseOnExec()
            XCTAssertEqual(socketHasCloseOnExec, true)
            await transport.disconnect()
            XCTAssertTrue(Self.peerObservedEOF(on: acceptedFD))
        #else
            throw XCTSkip("App transport descriptor seam is DEBUG-only")
        #endif
    }

    func testDisconnectBeforeReaderOwnershipClosesAdoptedSocket() async throws {
        let descriptors = try Self.makeSocketPair()
        defer { Self.closeIfOpen(descriptors[1]) }

        let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
        await transport.disconnect()

        XCTAssertTrue(Self.isClosed(descriptors[0]))
        XCTAssertTrue(Self.peerObservedEOF(on: descriptors[1]))
    }

    func testExistingFDStartupFailureClosesAdoptedSocket() async throws {
        #if DEBUG
            let descriptors = try Self.makeSocketPair()
            defer { Self.closeIfOpen(descriptors[1]) }

            let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
            await transport.debugFailNextExistingFDConnectBeforeReaderStart()

            do {
                try await transport.connect()
                XCTFail("Expected forced existing-FD startup failure")
            } catch {}

            XCTAssertTrue(Self.isClosed(descriptors[0]))
            XCTAssertTrue(Self.peerObservedEOF(on: descriptors[1]))
        #else
            throw XCTSkip("App transport startup-failure seam is DEBUG-only")
        #endif
    }

    func testHandshakeIOLeaseReleaseRacingShutdownClosesOnlyAfterShutdownInitiates() throws {
        #if DEBUG
            let result = try BootstrapSocketServer.debugExerciseHandshakeIOLeaseReleaseRacingShutdown()
            XCTAssertTrue(result.remainedOpenUntilInitiatingShutdown)
            XCTAssertTrue(result.closedAfterShutdownFinished)
            XCTAssertTrue(result.peerObservedEOF)
        #else
            throw XCTSkip("Bootstrap handshake I/O lease seam is DEBUG-only")
        #endif
    }

    func testBootstrapServerStopBeforeStartTombstonesListenerAndNeverBinds() async throws {
        let fixture = try TemporarySocketFixture.make(prefix: "tombstone")
        defer { fixture.removeOwnedDirectory() }
        let server = BootstrapSocketServer(socketURL: fixture.socketURL)

        await server.stop()
        do {
            try await server.start { _, _, _, _ in .reject() }
            XCTFail("Expected tombstoned bootstrap listener start to fail")
        } catch BootstrapSocketError.startCancelled {} catch {
            XCTFail("Unexpected tombstoned listener start error: \(error)")
        }

        let isListening = await server.isListening()
        XCTAssertFalse(isListening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    func testFullStopTombstonesPublishedChildListenerBeforeQueuedStartCanBind() async throws {
        #if DEBUG
            try await Self.withIsolatedManagerSocket(prefix: "published-tombstone") { manager, socketURL in
                await manager.debugSuspendNextLifecycleFenceCheckpoint(.listenerPublishedBeforeStartInvocation)
                let staleStartTask = Task { await manager.start() }
                let listenerPublished = await Self.waitUntil {
                    await manager.debugIsLifecycleFenceCheckpointSuspended(.listenerPublishedBeforeStartInvocation)
                }
                XCTAssertTrue(listenerPublished)
                XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))

                await manager.stop()
                await manager.debugResumeLifecycleFenceCheckpoint(.listenerPublishedBeforeStartInvocation)
                await staleStartTask.value

                let runningAfterStaleStart = await manager.isRunning()
                XCTAssertFalse(runningAfterStaleStart)
                XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))

                await manager.start()
                let replacementListenerReady = await Self.waitForCurrentBootstrapListener(manager, at: socketURL)
                XCTAssertTrue(replacementListenerReady)
                try Self.assertBootstrapAdmissionAccepted(at: socketURL)
            }
        #else
            throw XCTSkip("Bootstrap manager lifecycle fence seams are DEBUG-only")
        #endif
    }

    func testBootstrapStopFencesSuspendedAdmissionAndClosesAcceptedSocket() async throws {
        let fixture = try TemporarySocketFixture.make(prefix: "suspended")
        defer { fixture.removeOwnedDirectory() }
        let server = BootstrapSocketServer(socketURL: fixture.socketURL)
        let gate = SuspendedAdmissionGate()
        let postAcceptCount = AsyncCounter()
        let abortCount = AsyncCounter()
        let transferredFDs = SynchronousFDRecorder()
        defer { transferredFDs.closeAll() }

        try await server.start { _, _, _, _ in
            await gate.suspendUntilReleased()
            return .accept(
                publishTransferredFD: { transferredFDs.record($0) },
                postAccept: { await postAcceptCount.increment() },
                onAcceptAborted: { await abortCount.increment() }
            )
        }
        do {
            let clientFD = try Self.connectRawUnixClient(to: fixture.socketURL)
            defer { Self.closeIfOpen(clientFD) }
            try Self.writeBootstrapRequest(to: clientFD)
            let admissionSuspended = await Self.waitUntil { await gate.hasEntered }
            XCTAssertTrue(admissionSuspended)

            await server.stop()
            await gate.release()

            let aborted = await Self.waitUntil { await abortCount.value == 1 }
            XCTAssertTrue(aborted)
            let observedAbortCount = await abortCount.value
            let observedPostAcceptCount = await postAcceptCount.value
            XCTAssertEqual(observedAbortCount, 1)
            XCTAssertEqual(observedPostAcceptCount, 0)
            XCTAssertTrue(Self.peerObservedEOF(on: clientFD))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        } catch {
            await gate.release()
            await server.stop()
            throw error
        }
    }

    func testStaleDeferredManagerCommitCannotRegisterAfterFullStop() async throws {
        #if DEBUG
            try await Self.withIsolatedManagerSocket(prefix: "stale-commit") { manager, socketURL in
                await manager.start()
                let descriptors = try Self.makeSocketPair()
                defer { Self.closeIfOpen(descriptors[1]) }
                let connectionID = UUID()
                let optionalAdmission = await manager.debugMakeReservedBootstrapAdmissionForShutdownTest(
                    connectionID: connectionID,
                    sessionToken: "stale-deferred-\(UUID().uuidString)",
                    clientPid: Int(getpid()),
                    clientName: "stale-deferred-test",
                    clientFD: descriptors[0]
                )
                let admission = try XCTUnwrap(optionalAdmission)

                let reservationCountBeforeStop = await manager.debugBootstrapReservationCount()
                let transferredSocketCountBeforeStop = await manager.debugTransferredBootstrapSocketCountForShutdownTest()
                XCTAssertEqual(reservationCountBeforeStop, 1)
                XCTAssertEqual(transferredSocketCountBeforeStop, 1)

                await manager.stop()
                let transferredSocketCountAfterStop = await manager.debugTransferredBootstrapSocketCountForShutdownTest()
                XCTAssertEqual(transferredSocketCountAfterStop, 0)
                XCTAssertTrue(Self.isClosed(descriptors[0]))
                XCTAssertTrue(Self.peerObservedEOF(on: descriptors[1]))

                await manager.start()
                let replacementListenerReady = await Self.waitForCurrentBootstrapListener(manager, at: socketURL)
                XCTAssertTrue(replacementListenerReady)
                let replacementListenerIdentity = await manager.debugBootstrapListenerIdentityForLifecycleFenceTest()
                XCTAssertNotNil(replacementListenerIdentity)

                await admission.postAccept?()

                let reservationCountAfterStop = await manager.debugBootstrapReservationCount()
                let containsConnection = await manager.debugContainsConnection(connectionID)
                let listenerIdentityAfterStaleCommit = await manager.debugBootstrapListenerIdentityForLifecycleFenceTest()
                XCTAssertEqual(reservationCountAfterStop, 0)
                XCTAssertFalse(containsConnection)
                XCTAssertEqual(listenerIdentityAfterStaleCommit, replacementListenerIdentity)
                try Self.assertBootstrapAdmissionAccepted(at: socketURL)
            }
        #else
            throw XCTSkip("Bootstrap manager shutdown seams are DEBUG-only")
        #endif
    }

    func testOrdinaryDisableRetainsListenerWhileFullStopRemovesIt() async throws {
        #if DEBUG
            try await Self.withIsolatedManagerSocket(prefix: "disable-stop") { manager, socketURL in
                await manager.start()
                let runningAfterStart = await manager.isRunning()
                XCTAssertTrue(runningAfterStart)
                try Self.assertUnixSocketExists(at: socketURL)

                await manager.setEnabled(false)
                let runningAfterDisable = await manager.isRunning()
                XCTAssertTrue(runningAfterDisable)
                try Self.assertUnixSocketExists(at: socketURL)

                await manager.stop()
                let runningAfterStop = await manager.isRunning()
                XCTAssertFalse(runningAfterStop)
                XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
            }
        #else
            throw XCTSkip("Bootstrap manager lifecycle seams are DEBUG-only")
        #endif
    }

    func testStoppedManagerRejectsConnectionWaiterWithoutRegistration() async throws {
        #if DEBUG
            let manager = ServerNetworkManager()
            let result = await manager.waitForNewConnection(clientName: nil, timeout: 5)
            let waiterCount = await manager.debugConnectionWaiterCountForLifecycleFenceTest()
            XCTAssertNil(result)
            XCTAssertEqual(waiterCount, 0)
        #else
            throw XCTSkip("Bootstrap manager lifecycle fence seams are DEBUG-only")
        #endif
    }

    func testFullStopResolvesOldConnectionWaitersBeforeOverlappingReplacementLifecycleStarts() async throws {
        #if DEBUG
            try await Self.withIsolatedManagerSocket(prefix: "stale-waiter") { manager, socketURL in
                await manager.start()
                let initialLifecycleGeneration = await manager.debugLifecycleGenerationForLifecycleFenceTest()
                let waiterTask = Task {
                    await manager.waitForNewConnection(clientName: nil, timeout: 5)
                }
                let waiterRegistered = await Self.waitUntil {
                    await manager.debugConnectionWaiterCountForLifecycleFenceTest() == 1
                }
                XCTAssertTrue(waiterRegistered)

                await manager.debugSuspendNextLifecycleFenceCheckpoint(.listenerStopReturnedBeforeConditionalClear)
                let stopTask = Task { await manager.stop() }
                let oldTeardownSuspended = await Self.waitUntil {
                    await manager.debugIsLifecycleFenceCheckpointSuspended(.listenerStopReturnedBeforeConditionalClear)
                }
                XCTAssertTrue(oldTeardownSuspended)

                let staleWaiterResult = await waiterTask.value
                let waiterCountAfterStopInvalidation = await manager.debugConnectionWaiterCountForLifecycleFenceTest()
                XCTAssertNil(staleWaiterResult)
                XCTAssertEqual(waiterCountAfterStopInvalidation, 0)

                await manager.start()
                let replacementLifecycleGeneration = await manager.debugLifecycleGenerationForLifecycleFenceTest()
                XCTAssertNotEqual(replacementLifecycleGeneration, initialLifecycleGeneration)
                await manager.debugResumeLifecycleFenceCheckpoint(.listenerStopReturnedBeforeConditionalClear)
                await stopTask.value

                let replacementListenerReady = await Self.waitForCurrentBootstrapListener(manager, at: socketURL)
                XCTAssertTrue(replacementListenerReady)
                try Self.assertBootstrapAdmissionAccepted(at: socketURL)
            }
        #else
            throw XCTSkip("Bootstrap manager lifecycle fence seams are DEBUG-only")
        #endif
    }

    func testStaleListenerStopResumptionCannotClearColdStartReplacementListenerOrAdmissions() async throws {
        #if DEBUG
            try await Self.withIsolatedManagerSocket(prefix: "cold-overlap") { manager, socketURL in
                await manager.start()
                let initialListenerReady = await Self.waitForCurrentBootstrapListener(manager, at: socketURL)
                XCTAssertTrue(initialListenerReady)
                let initialLifecycleGeneration = await manager.debugLifecycleGenerationForLifecycleFenceTest()
                let initialListenerGeneration = await manager.debugBootstrapListenerLifecycleGenerationForLifecycleFenceTest()
                XCTAssertEqual(initialListenerGeneration, initialLifecycleGeneration)
                let restartTaskCompletionCount = await manager.debugBootstrapRestartTaskCompletionCountForLifecycleFenceTest()

                await manager.debugSuspendNextLifecycleFenceCheckpoint(.listenerStopReturnedBeforeConditionalClear)
                let restartScheduled = await manager.debugScheduleDelayedBootstrapRestartForLifecycleFenceTest(delay: 0)
                XCTAssertTrue(restartScheduled)
                let staleStopSuspended = await Self.waitUntil {
                    await manager.debugIsLifecycleFenceCheckpointSuspended(.listenerStopReturnedBeforeConditionalClear)
                }
                XCTAssertTrue(staleStopSuspended)

                await manager.stop()
                await manager.start()
                let replacementLifecycleGeneration = await manager.debugLifecycleGenerationForLifecycleFenceTest()
                XCTAssertNotEqual(replacementLifecycleGeneration, initialLifecycleGeneration)
                let replacementListenerReady = await Self.waitForCurrentBootstrapListener(manager, at: socketURL)
                XCTAssertTrue(replacementListenerReady)
                let replacementListenerIdentity = await manager.debugBootstrapListenerIdentityForLifecycleFenceTest()
                XCTAssertNotNil(replacementListenerIdentity)
                try Self.assertBootstrapAdmissionAccepted(at: socketURL)

                await manager.debugResumeLifecycleFenceCheckpoint(.listenerStopReturnedBeforeConditionalClear)
                let staleRestartFinished = await Self.waitUntil {
                    await manager.debugBootstrapRestartTaskCompletionCountForLifecycleFenceTest() > restartTaskCompletionCount
                }
                XCTAssertTrue(staleRestartFinished)

                let listenerIdentityAfterStaleResumption = await manager.debugBootstrapListenerIdentityForLifecycleFenceTest()
                let replacementListenerGeneration = await manager.debugBootstrapListenerLifecycleGenerationForLifecycleFenceTest()
                XCTAssertEqual(listenerIdentityAfterStaleResumption, replacementListenerIdentity)
                XCTAssertEqual(replacementListenerGeneration, replacementLifecycleGeneration)
                try Self.assertUnixSocketExists(at: socketURL)
                try Self.assertBootstrapAdmissionAccepted(at: socketURL)
            }
        #else
            throw XCTSkip("Bootstrap manager lifecycle fence seams are DEBUG-only")
        #endif
    }

    func testDelayedStaleRestartCannotClearReplacementListenerOrAdmissions() async throws {
        #if DEBUG
            try await Self.withIsolatedManagerSocket(prefix: "restart-overlap") { manager, socketURL in
                await manager.start()
                let initialListenerReady = await Self.waitForCurrentBootstrapListener(manager, at: socketURL)
                XCTAssertTrue(initialListenerReady)
                let initialLifecycleGeneration = await manager.debugLifecycleGenerationForLifecycleFenceTest()
                let restartTaskCompletionCount = await manager.debugBootstrapRestartTaskCompletionCountForLifecycleFenceTest()

                await manager.debugSuspendNextLifecycleFenceCheckpoint(.restartTaskBeforePerform)
                let restartScheduled = await manager.debugScheduleDelayedBootstrapRestartForLifecycleFenceTest(delay: 0)
                XCTAssertTrue(restartScheduled)
                let staleRestartSuspended = await Self.waitUntil {
                    await manager.debugIsLifecycleFenceCheckpointSuspended(.restartTaskBeforePerform)
                }
                XCTAssertTrue(staleRestartSuspended)

                await manager.stop()
                await manager.start()
                let replacementLifecycleGeneration = await manager.debugLifecycleGenerationForLifecycleFenceTest()
                XCTAssertNotEqual(replacementLifecycleGeneration, initialLifecycleGeneration)
                let replacementListenerReady = await Self.waitForCurrentBootstrapListener(manager, at: socketURL)
                XCTAssertTrue(replacementListenerReady)
                let replacementListenerIdentity = await manager.debugBootstrapListenerIdentityForLifecycleFenceTest()
                XCTAssertNotNil(replacementListenerIdentity)
                try Self.assertBootstrapAdmissionAccepted(at: socketURL)

                await manager.debugResumeLifecycleFenceCheckpoint(.restartTaskBeforePerform)
                let staleRestartFinished = await Self.waitUntil {
                    await manager.debugBootstrapRestartTaskCompletionCountForLifecycleFenceTest() > restartTaskCompletionCount
                }
                XCTAssertTrue(staleRestartFinished)

                let listenerIdentityAfterStaleRestart = await manager.debugBootstrapListenerIdentityForLifecycleFenceTest()
                let replacementListenerGeneration = await manager.debugBootstrapListenerLifecycleGenerationForLifecycleFenceTest()
                XCTAssertEqual(listenerIdentityAfterStaleRestart, replacementListenerIdentity)
                XCTAssertEqual(replacementListenerGeneration, replacementLifecycleGeneration)
                try Self.assertUnixSocketExists(at: socketURL)
                try Self.assertBootstrapAdmissionAccepted(at: socketURL)
            }
        #else
            throw XCTSkip("Bootstrap manager lifecycle fence seams are DEBUG-only")
        #endif
    }

    func testNonImportableCLISourcesUseSharedDescriptorHardening() throws {
        let root = try RepoRoot.url()
        let main = try Self.sourceText("Sources/RepoPromptMCP/main.swift", relativeTo: root)
        let interactive = try Self.sourceText(
            "Sources/RepoPromptMCP/Interactive/InteractiveMCPClientSession.swift",
            relativeTo: root
        )
        let transport = try Self.sourceText(
            "Sources/RepoPromptMCP/Transports/BootstrapSocketMCPTransport.swift",
            relativeTo: root
        )

        XCTAssertGreaterThanOrEqual(
            main.occurrenceCount(of: "POSIXDescriptorSupport.setCloseOnExec"),
            2,
            "Proxy sockets and kill-signal watcher descriptors should both be hardened"
        )
        XCTAssertTrue(main.contains("POSIXDescriptorSupport.shutdownSocketReadWrite(socketFD)"))
        XCTAssertTrue(interactive.contains("POSIXDescriptorSupport.setCloseOnExec(fd)"))
        XCTAssertTrue(interactive.contains("POSIXDescriptorSupport.shutdownSocketReadWrite(fd)"))
        XCTAssertTrue(transport.contains("POSIXDescriptorSupport.setCloseOnExec(connectedFD)"))
        XCTAssertTrue(transport.contains("POSIXDescriptorSupport.shutdownSocketReadWrite(socketFD)"))
    }

    func testAppAndCLIReadersShareFairOneShotTerminalCancellationLifecycle() throws {
        let root = try RepoRoot.url()
        let appReader = try Self.sourceText(
            "Sources/RepoPrompt/Infrastructure/MCP/AppShared/NewlineDelimitedSocketReader.swift",
            relativeTo: root
        )
        let cliReader = try Self.sourceText(
            "Sources/RepoPromptMCP/Shared/NewlineDelimitedSocketReader.swift",
            relativeTo: root
        )

        XCTAssertEqual(appReader, cliReader)
        Self.assertSourceContains(
            [
                "public enum NewlineDelimitedSocketReaderTerminal: @unchecked Sendable",
                "onTerminal: @escaping (NewlineDelimitedSocketReaderTerminal) -> Void",
                "onEOF: { onTerminal(.eof(hasResidualData: $0)) }",
                "onError: { onTerminal(.error($0)) }",
                "private enum Lifecycle: Equatable",
                "private var generation: UInt64 = 0",
                "private var pendingCancelledSources: [ObjectIdentifier: ReadEventSource] = [:]",
                "finishTerminalOnQueue(.failure(posixError), generation: pumpGeneration)",
                "finishTerminalOnQueue(.success(!buffer.isEmpty), generation: pumpGeneration)",
                "guard terminalGeneration == generation, lifecycle == .running else { return }",
                "cancelCurrentSourceOnQueue()",
                "guard pendingCancelledSources.removeValue(forKey: sourceID) != nil else { return }"
            ],
            in: appReader
        )
    }

    func testAppTransportReplacesTerminalInboundChannelsBeforeReconnect() throws {
        let root = try RepoRoot.url()
        let transport = try Self.sourceText(
            "Sources/RepoPrompt/Infrastructure/MCP/UnixSocketMCPTransport.swift",
            relativeTo: root
        )

        Self.assertSourceContains(
            [
                "private struct InboundChannel {",
                "private struct CloseChannel {",
                "private let receiveBufferCapacity: Int",
                "private var inboundChannel: InboundChannel",
                "private var closeChannel: CloseChannel",
                "prepareForConnectionAttempt()",
                "if streamFinished || closeSignaled {",
                "inboundChannel = InboundChannel(capacity: receiveBufferCapacity)",
                "closeChannel = CloseChannel()",
                "let inboundChannel = inboundChannel",
                "inboundChannel.gate.offer(frame, to: inboundChannel.continuation)",
                "inboundChannel.continuation.finish",
                "closeChannel.continuation.finish()"
            ],
            in: transport
        )
    }

    func testNonImportableCLITransportClaimsEarlyAndDelayedReaderCancellationExactlyOnce() throws {
        let root = try RepoRoot.url()
        let transport = try Self.sourceText(
            "Sources/RepoPromptMCP/Transports/BootstrapSocketMCPTransport.swift",
            relativeTo: root
        )

        Self.assertSourceContains(
            [
                "private struct ReaderIdentity: Hashable {",
                "private struct ActiveReaderOwnership {",
                "private struct PendingReaderCancellation {",
                "let reader: NewlineDelimitedSocketReader",
                "let transportRetainer: BootstrapSocketMCPTransport",
                "private var activeReaderOwnership: ActiveReaderOwnership?",
                "private var pendingReaderCancellations: [UInt64: PendingReaderCancellation] = [:]",
                "private var earlyReaderCancellations: Set<ReaderIdentity> = []",
                "activeReaderOwnership = ActiveReaderOwnership(identity: identity, reader: newReader)",
                "activeReaderOwnership = nil\n\n        let identity = activeOwnership.identity",
                "pendingReaderCancellations[identity.token] = PendingReaderCancellation(",
                "transportRetainer: self",
                "activeOwnership.reader.stop()",
                "if earlyReaderCancellations.contains(identity) {\n            finalizeReaderCancellation(identity)",
                "if pendingReaderCancellations[identity.token]?.identity == identity {",
                "if activeReaderOwnership?.identity == identity {\n            earlyReaderCancellations.insert(identity)",
                "let ownership = pendingReaderCancellations.removeValue(forKey: identity.token)",
                "earlyReaderCancellations.remove(identity)",
                "withExtendedLifetime(ownership) {",
                "Task { await transport.handleReaderTerminal(terminal, from: identity) }",
                "guard activeReaderOwnership?.identity == identity else {",
                "if !pendingReaderCancellationOwnsCurrentSocket() {",
                "closeSocketIfNeeded()"
            ],
            in: transport
        )

        XCTAssertTrue(
            transport.contains(
                "onTerminal: { [weak self] terminal in\n                guard let transport = self else { return }"
            ),
            "Reader terminal delivery must avoid a permanent reader/transport cycle."
        )
        XCTAssertTrue(
            transport.contains(
                "transport.scheduleReaderCancellationCallback {\n                    Task { await transport.readSourceDidCancel(identity) }"
            ),
            "Cancellation delivery must strongly retain the transport until the actor claims the identity."
        )
    }

    func testNonImportableCLISourcesCaptureKillWatcherFDAndFenceAdoptedTransportReconnects() throws {
        let root = try RepoRoot.url()
        let main = try Self.sourceText("Sources/RepoPromptMCP/main.swift", relativeTo: root)
        let transport = try Self.sourceText(
            "Sources/RepoPromptMCP/Transports/BootstrapSocketMCPTransport.swift",
            relativeTo: root
        )

        Self.assertSourceContains(
            [
                "source.setCancelHandler {\n            close(fd)\n        }",
                "let source = killSignalSource\n        killSignalSource = nil\n        killSignalFD = -1\n        source?.cancel()"
            ],
            in: main
        )
        Self.assertSourceContains(
            [
                "private var connectionAttempted = false",
                "guard !isConnected else { return }",
                "guard !connectionAttempted, !socketClosed, !streamFinished else {",
                "throw MCPError.connectionClosed",
                "connectionAttempted = true"
            ],
            in: transport
        )
        XCTAssertEqual(
            transport.occurrenceCount(of: "connectionAttempted = false"),
            1,
            "An adopted CLI socket must never become reconnectable after teardown."
        )
        XCTAssertFalse(
            transport.contains("streamFinished = false\n        socketClosed = false"),
            "CLI reconnect must not reset torn-down adopted-socket state."
        )
    }

    private static func assertSourceContains(
        _ requiredSnippets: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for snippet in requiredSnippets {
            XCTAssertTrue(source.contains(snippet), "Missing CLI transport cleanup invariant: \(snippet)", file: file, line: line)
        }
    }

    private static func sourceText(_ relativePath: String, relativeTo root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    #if DEBUG
        private static func waitForCurrentBootstrapListener(_ manager: ServerNetworkManager, at socketURL: URL) async -> Bool {
            await waitUntil {
                await manager.debugHasCurrentBootstrapListenerForLifecycleFenceTest()
                    && FileManager.default.fileExists(atPath: socketURL.path)
            }
        }

        private static func withIsolatedManagerSocket(
            prefix: String,
            operation: (ServerNetworkManager, URL) async throws -> Void
        ) async throws {
            let fixture = try TemporarySocketFixture.make(prefix: prefix)
            defer { fixture.removeOwnedDirectory() }
            let manager = ServerNetworkManager()
            try await manager.debugInstallBootstrapSocketURLOverride(fixture.socketURL)

            func stopAndRestoreManager() async throws {
                await manager.debugResumeAllLifecycleFenceCheckpoints()
                await manager.stop()
                try await manager.debugRestoreBootstrapSocketURLOverride(expected: fixture.socketURL)
            }

            do {
                try await operation(manager, fixture.socketURL)
            } catch let operationError {
                do {
                    try await stopAndRestoreManager()
                } catch {
                    XCTFail("Failed to clean up isolated MCP manager after operation error: \(error)")
                    throw error
                }
                throw operationError
            }

            try await stopAndRestoreManager()
        }
    #endif

    private static func assertUnixSocketExists(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSocket)
    }

    private static func assertBootstrapAdmissionAccepted(at socketURL: URL) throws {
        let clientFD = try connectRawUnixClient(to: socketURL)
        defer { closeIfOpen(clientFD) }
        try writeBootstrapRequest(to: clientFD)
        let response = try readBootstrapResponse(from: clientFD)
        XCTAssertEqual(response.type, "accepted")
    }

    private static func readBootstrapResponse(from fd: Int32, timeout: TimeInterval = 2) throws -> MCPBootstrapResponse {
        let deadline = Date().addingTimeInterval(timeout)
        var payload = Data()
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let result = Darwin.poll(&descriptor, 1, 50)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { continue }

            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count > 0 {
                if byte == UInt8(ascii: "\n") {
                    return try JSONDecoder().decode(MCPBootstrapResponse.self, from: payload)
                }
                payload.append(byte)
            } else if count == 0 {
                break
            } else if errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        throw TestError.bootstrapResponseTimedOut
    }

    private static func writeBootstrapRequest(
        to fd: Int32,
        sessionToken: String = "fd-hardening-\(UUID().uuidString)",
        clientName: String = "fd-hardening-test"
    ) throws {
        var payload = try JSONEncoder().encode(MCPBootstrapRequest(
            sessionToken: sessionToken,
            clientPid: Int(getpid()),
            clientName: clientName
        ))
        payload.append(UInt8(ascii: "\n"))
        try writeAll(payload, to: fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func makeSocketPair() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptors
    }

    private static func makeUnixListener(at socketURL: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            try bindUnixSocket(fd, to: socketURL)
            guard Darwin.listen(fd, 8) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return fd
        } catch {
            Self.closeIfOpen(fd)
            throw error
        }
    }

    private static func connectRawUnixClient(to socketURL: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var address = try unixSocketAddress(for: socketURL)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return fd
        } catch {
            Self.closeIfOpen(fd)
            throw error
        }
    }

    private static func bindUnixSocket(_ fd: Int32, to socketURL: URL) throws {
        var address = try unixSocketAddress(for: socketURL)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func unixSocketAddress(for socketURL: URL) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketURL.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw TestError.socketPathTooLong(socketURL.path)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = byte
                }
            }
        }
        return address
    }

    private static func peerObservedEOF(on fd: Int32, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let result = Darwin.poll(&descriptor, 1, 50)
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else { continue }

            var byte: UInt8 = 0
            let count = Darwin.recv(fd, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
            if count == 0 { return true }
            if count < 0, errno != EAGAIN, errno != EWOULDBLOCK { return false }
        }
        return false
    }

    private static func hasCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC != 0
    }

    private static func isClosed(_ fd: Int32) -> Bool {
        errno = 0
        return fcntl(fd, F_GETFD) == -1 && errno == EBADF
    }

    private static func closeIfOpen(_ fd: Int32) {
        guard fd >= 0, !isClosed(fd) else { return }
        Darwin.close(fd)
    }

    private static func waitUntil(
        timeout: TimeInterval = 2,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}

private struct TemporarySocketFixture {
    let directoryURL: URL
    let socketURL: URL

    static func make(prefix: String) throws -> Self {
        let directoryURL = URL(
            fileURLWithPath: "/tmp/rpce-fd-xctest-\(prefix)-\(getpid())-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketURL = directoryURL.appendingPathComponent("s.sock")
        XCTAssertLessThan(socketURL.path.utf8CString.count, MemoryLayout<sockaddr_un>.size)
        XCTAssertNotEqual(socketURL.standardizedFileURL, MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return .init(directoryURL: directoryURL, socketURL: socketURL)
    }

    func removeOwnedDirectory() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class SynchronousFDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [Int32] = []

    func record(_ fd: Int32) -> Bool {
        lock.lock()
        descriptors.append(fd)
        lock.unlock()
        return true
    }

    func closeAll() {
        lock.lock()
        let descriptors = descriptors
        self.descriptors.removeAll()
        lock.unlock()
        descriptors.forEach { Darwin.close($0) }
    }
}

private actor OptionalBoolRecorder {
    private(set) var value: Bool?

    func record(_ value: Bool) {
        self.value = value
    }
}

private actor AsyncCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor SuspendedAdmissionGate {
    private var entered = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var hasEntered: Bool {
        entered
    }

    func suspendUntilReleased() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor BootstrapAdmissionTestConnection: MCPServerConnection {
    private let idleSeconds: TimeInterval
    private let stopGate: SuspendedAdmissionGate?

    init(idleSeconds: TimeInterval, stopGate: SuspendedAdmissionGate? = nil) {
        self.idleSeconds = idleSeconds
        self.stopGate = stopGate
    }

    nonisolated var isFilesystemBacked: Bool {
        false
    }

    nonisolated var connectionFolderURL: URL? {
        nil
    }

    nonisolated var capabilityToken: String? {
        nil
    }

    func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {}

    func stop() async {
        await stopGate?.suspendUntilReleased()
    }

    func abortForExecutionWatchdog() async {}
    func notifyToolListChanged() async {}

    func connectionState() -> ConnectionStateSnapshot {
        .ready
    }

    func isViableForRetention() -> Bool {
        true
    }

    func secondsSinceLastActivity() async -> TimeInterval {
        idleSeconds
    }

    func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
        nil
    }

    func terminate(reason _: TerminationReason, message _: String?) async {}

    func sendProgress(
        tool _: String,
        kind _: RepoPromptProgressKind,
        stage _: String,
        message _: String
    ) async {}
}

private enum TestError: Error {
    case bootstrapResponseTimedOut
    case socketPathTooLong(String)
}

private extension String {
    func occurrenceCount(of substring: String) -> Int {
        components(separatedBy: substring).count - 1
    }
}
