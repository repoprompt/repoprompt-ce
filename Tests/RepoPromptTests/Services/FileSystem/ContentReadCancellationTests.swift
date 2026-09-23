import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContentReadCancellationTests: XCTestCase {
    func testCooperativeChunkReadCancellationSettlesAndReleasesLimiter() async throws {
        let rootURL = try makeTemporaryRoot()
        try "cooperative physical read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let service = try await FileSystemService(path: rootURL.path)
        let chunkReadEntered = AsyncSignal()
        let cancellationGate = CancellableTestGate()
        addTeardownBlock { await cancellationGate.releaseAll() }
        await service.setContentReadChunkHandlerForTesting { _ in
            await chunkReadEntered.signal()
            _ = try? await cancellationGate.wait()
        }
        addTeardownBlock {
            await service.setContentReadChunkHandlerForTesting(nil)
        }

        let readTask = Task {
            try await service.loadContent(
                ofRelativePath: "Target.swift",
                workloadClass: .interactiveRead
            )
        }
        let chunkReadDidEnter = await waitUntil { await chunkReadEntered.isSignaledSnapshot() }
        guard chunkReadDidEnter else {
            readTask.cancel()
            return XCTFail("Chunk read did not reach the controlled cancellation gate")
        }
        readTask.cancel()

        guard let readResult = await waitForTaskResult(readTask) else {
            await cancellationGate.releaseAll()
            return XCTFail("Cooperative chunk read did not settle after cancellation")
        }
        do {
            _ = try readResult.get()
            XCTFail("Expected cooperative chunk read cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let limiterSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(limiterSnapshot.isIdle)
    }

    func testWatchdogCancellationSettlesBeforeBlockedSynchronousFingerprintIsReleased() async throws {
        let rootURL = try makeTemporaryRoot()
        try "blocked physical read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let service = try await FileSystemService(path: rootURL.path)
        let physicalReadGate = SynchronousPhysicalReadGate()
        let clock = SynchronousDurationClock()
        let sleeps = ControlledWatchdogSleeps(clock: clock)
        let events = WatchdogEventRecorder()
        let settlementRecorder = SettlementRecorder()
        let phaseRecorder = MCPToolExecutionHandlerPhaseRecorder(origin: .zero, now: { .zero })

        await service.setContentPhysicalReadHandlerForTesting {
            physicalReadGate.blockUntilReleased()
        }
        addTeardownBlock {
            physicalReadGate.release()
            await service.setContentPhysicalReadHandlerForTesting(nil)
            await sleeps.releaseAll()
        }

        let watchdogTask = Task { () -> Result<Void, Error> in
            do {
                try await MCPToolExecutionWatchdog.execute(
                    deadline: .seconds(30),
                    cancellationGrace: .seconds(5),
                    cleanupDisposition: .detachAndSettle,
                    environment: MCPToolExecutionWatchdogEnvironment(
                        now: { clock.now() },
                        sleep: { duration in try await sleeps.sleep(for: duration) }
                    ),
                    onEvent: { event in await events.record(event) },
                    onSynchronousSettlement: { settlement in
                        await settlementRecorder.record(settlement)
                    }
                ) {
                    try await MCPToolExecutionHandlerPhaseContext.$recorder.withValue(phaseRecorder) {
                        await MCPToolExecutionHandlerPhaseContext.report(.readFileContentRead)
                        let fingerprint = try await service.contentFingerprint(ofRelativePath: "Target.swift")
                        _ = try await service.loadValidatedContent(
                            ofRelativePath: "Target.swift",
                            expectedFingerprint: fingerprint,
                            workloadClass: .interactiveRead
                        )
                        await MCPToolExecutionHandlerPhaseContext.report(
                            .readFileContentRead,
                            transition: .completed
                        )
                    }
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        let physicalReadDidBlock = await waitUntil { physicalReadGate.isBlockedSnapshot() }
        guard physicalReadDidBlock else {
            watchdogTask.cancel()
            return XCTFail("Fingerprint read did not reach the physical gate")
        }
        let deadlineDidRegister = await waitUntil { await sleeps.registeredCountSnapshot() >= 1 }
        guard deadlineDidRegister else {
            watchdogTask.cancel()
            return XCTFail("Watchdog deadline did not register")
        }
        await sleeps.releaseNext()

        guard let observedWatchdogResult = await waitForTaskResult(watchdogTask) else {
            physicalReadGate.release()
            return XCTFail("Watchdog did not settle within the bounded observation window")
        }
        let watchdogResult = try observedWatchdogResult.get()
        guard case let .failure(error) = watchdogResult,
              error as? MCPToolExecutionWatchdogError == .executionTimedOut(settlement: .cancellation)
        else {
            return XCTFail("Expected the blocked physical read caller to settle cancellation during grace")
        }
        let recordedEvents = await events.snapshot()
        XCTAssertEqual(
            recordedEvents,
            [
                .deadlineExpired,
                .cancellationRequested(origin: .watchdogDeadline),
                .settledDuringGrace(.cancellation, cancellationRequested: true)
            ]
        )
        XCTAssertEqual(phaseRecorder.snapshot()?.phase, .readFileContentRead)
        XCTAssertEqual(phaseRecorder.snapshot()?.transition, .started)

        let settlementBeforeRelease = await settlementRecorder.snapshot()
        XCTAssertEqual(
            settlementBeforeRelease,
            .cancellation,
            "Detached read must settle before a blocked synchronous filesystem operation is released"
        )
        let blockedLimiterSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(blockedLimiterSnapshot.activePermitCount, 1)
        XCTAssertEqual(blockedLimiterSnapshot.queuedWaiterCount, 0)
        XCTAssertFalse(blockedLimiterSnapshot.isIdle)

        physicalReadGate.release()
        let limiterSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(limiterSnapshot.isIdle)
    }

    func testOuterProviderSettlementReleasesRegistryBeforeBlockedPhysicalReadReturns() async throws {
        let rootURL = try makeTemporaryRoot()
        try "blocked provider read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }

        let physicalReadGate = SynchronousPhysicalReadGate()
        let clock = SynchronousDurationClock()
        let sleeps = ControlledWatchdogSleeps(clock: clock)
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 949
        let connectionID = UUID()
        let invocationID = UUID()
        let admission = registry.admit(
            windowID: windowID,
            connectionID: connectionID,
            invocationID: invocationID,
            toolName: MCPWindowToolName.readFile,
            now: .zero,
            handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
        )
        guard case let .admitted(settlementSlot) = admission else {
            return XCTFail("Expected settlement-registry admission")
        }

        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            physicalReadGate.blockUntilReleased()
        }
        addTeardownBlock {
            physicalReadGate.release()
            try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil)
            await sleeps.releaseAll()
        }

        let watchdogTask = Task { () -> Result<Void, Error> in
            do {
                try await MCPToolExecutionWatchdog.execute(
                    deadline: .seconds(30),
                    cancellationGrace: .seconds(5),
                    cleanupDisposition: .detachAndSettle,
                    settlementSlot: settlementSlot,
                    environment: MCPToolExecutionWatchdogEnvironment(
                        now: { clock.now() },
                        sleep: { duration in try await sleeps.sleep(for: duration) }
                    )
                ) {
                    try await runMainActorProviderTask(
                        store: store,
                        record: record,
                        roots: store.rootRefs(scope: .visibleWorkspace)
                    )
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        let physicalReadDidBlock = await waitUntil { physicalReadGate.isBlockedSnapshot() }
        guard physicalReadDidBlock else {
            watchdogTask.cancel()
            return XCTFail("Provider read did not reach the controlled physical gate")
        }
        let deadlineDidRegister = await waitUntil { await sleeps.registeredCountSnapshot() >= 1 }
        guard deadlineDidRegister else {
            watchdogTask.cancel()
            return XCTFail("Watchdog deadline did not register")
        }
        await sleeps.releaseNext()

        guard let observedWatchdogResult = await waitForTaskResult(watchdogTask) else {
            physicalReadGate.release()
            return XCTFail("Outer provider did not settle within the bounded observation window")
        }
        let watchdogResult = try observedWatchdogResult.get()
        guard case let .failure(error) = watchdogResult,
              error as? MCPToolExecutionWatchdogError == .executionTimedOut(settlement: .cancellation)
        else {
            return XCTFail("Expected the outer provider to settle cancellation during grace")
        }
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
        )
        let blockedLimiterSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(blockedLimiterSnapshot.activePermitCount, 1)

        physicalReadGate.release()
        let limiterSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(limiterSnapshot.isIdle)
    }

    func testDomainHostAndRunToolCancellationChainSettlesBeforeBlockedPhysicalReadReturns() async throws {
        let rootURL = try makeTemporaryRoot()
        try "blocked nested provider read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }

        let physicalReadGate = SynchronousPhysicalReadGate()
        let clock = SynchronousDurationClock()
        let sleeps = ControlledWatchdogSleeps(clock: clock)
        let registry = MCPCodeStructureSettlementRegistry()
        let admission = registry.admit(
            windowID: 950,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: MCPWindowToolName.readFile,
            now: .zero,
            handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
        )
        guard case let .admitted(settlementSlot) = admission else {
            return XCTFail("Expected settlement-registry admission")
        }

        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            physicalReadGate.blockUntilReleased()
        }
        addTeardownBlock {
            physicalReadGate.release()
            try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil)
            await sleeps.releaseAll()
        }

        let watchdogTask = Task { () -> Result<Void, Error> in
            do {
                try await MCPToolExecutionWatchdog.execute(
                    deadline: .seconds(30),
                    cancellationGrace: .seconds(5),
                    cleanupDisposition: .detachAndSettle,
                    settlementSlot: settlementSlot,
                    environment: MCPToolExecutionWatchdogEnvironment(
                        now: { clock.now() },
                        sleep: { duration in try await sleeps.sleep(for: duration) }
                    )
                ) {
                    try await runDomainHostProviderTask {
                        try await runDomainReadProviderTask(path: record.standardizedRelativePath) {
                            try await runMainActorProviderTask(
                                store: store,
                                record: record,
                                roots: store.rootRefs(scope: .visibleWorkspace)
                            )
                        }
                    }
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        guard await waitUntil(iterations: 100_000, { physicalReadGate.isBlockedSnapshot() }) else {
            watchdogTask.cancel()
            return XCTFail("Nested provider did not reach the controlled physical gate")
        }
        guard await waitUntil({ await sleeps.pendingCountSnapshot() >= 1 }) else {
            watchdogTask.cancel()
            return XCTFail("Watchdog deadline did not register")
        }
        let deadlineSleepReleased = await sleeps.releaseNext()
        XCTAssertTrue(deadlineSleepReleased)

        guard let observedResult = await waitForTaskResult(watchdogTask) else {
            physicalReadGate.release()
            return XCTFail("Nested provider did not settle within cancellation grace")
        }
        guard case let .failure(error) = observedResult.get() else {
            return XCTFail("Expected nested provider timeout")
        }
        XCTAssertEqual(
            error as? MCPToolExecutionWatchdogError,
            .executionTimedOut(settlement: .cancellation)
        )
        XCTAssertEqual(
            registry.snapshot(windowID: 950),
            .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
        )

        physicalReadGate.release()
        let limiterSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(limiterSnapshot.isIdle)
    }

    func testConcreteDomainHostAndAppBinderSettleBeforeBlockedPhysicalReadReturns() async throws {
        let rootURL = try makeTemporaryRoot()
        try "blocked concrete host read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }

        let physicalReadGate = SynchronousPhysicalReadGate()
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            physicalReadGate.blockUntilReleased()
        }
        addTeardownBlock {
            physicalReadGate.release()
            try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil)
        }

        let runtimeDirectory = rootURL.appendingPathComponent("Runtime", isDirectory: true)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app,
            profileIdentifier: "content-read-cancellation",
            storageDirectory: runtimeDirectory,
            eventDirectory: rootURL.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: rootURL.appendingPathComponent("Temporary", isDirectory: true),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock { _ = await runtime.shutdown() }

        let path = record.standardizedRelativePath
        let connectionID = UUID()
        let readContext = DomainReadInvocationContext(
            handle: DomainReadContextHandle(
                runtimeID: runtime.identity.runtimeID,
                runtimeGeneration: runtime.identity.lifecycleGeneration,
                connectionID: connectionID,
                connectionGeneration: 1,
                context: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
                workspaceRevision: 1,
                contextRevision: 1,
                routingRevision: 1,
                bindingKind: .explicit
            ),
            connectionID: connectionID,
            refreshesDomainRouting: false
        )
        let rawProvider = MCPDomainReadToolProvider(
            resolveContext: { _, _ in readContext },
            backend: MCPDomainReadToolBackend { _, _, _, _ in
                try await runMainActorProviderTask(
                    store: store,
                    record: record,
                    roots: store.rootRefs(scope: .visibleWorkspace)
                )
                return .null
            },
            sideEffects: DomainReadSideEffectCoordinator(identity: runtime.identity)
        )
        let rawBinding = try XCTUnwrap(rawProvider.binding(named: MCPWindowToolName.readFile))
        let (appBoundTool, appBinderRetention) = try await MainActor.run {
            let binder = MCPAppToolBinder(windowID: 952) { _, _, arguments, implementation in
                try await runAppBinderProviderTask {
                    try await implementation(
                        MCPAppToolInvocation(toolName: MCPWindowToolName.readFile, windowID: 952),
                        arguments
                    )
                }
            }
            return try (
                Tool(domainBinding: rawBinding, runtime: binder),
                SendableObjectRetention(binder)
            )
        }
        let registeredBinding = try appBoundTool.domainBinding()
        _ = try await runtime.toolRegistry.register(
            registrationID: MCPDomainToolRegistrationID(),
            scope: .window(id: 952),
            bindings: [registeredBinding]
        )

        _ = await runtime.routingCoordinator.registerConnection(
            connectionID: connectionID,
            operationID: UUID()
        )
        let registration = try await runtime.routingCoordinator.currentRegistration(
            connectionID: connectionID
        )
        let resolution = try await runtime.domainHost.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: .window(id: 952)
        )
        let invocationID = UUID()
        let securityContext = DomainToolInvocationSecurityContext(
            principal: DomainClientPrincipal(
                principalID: UUID(),
                stableKey: "content-read-cancellation",
                displayName: "ContentReadCancellationTests",
                kind: .appProxy,
                assurance: .verifiedProcess,
                processID: 949,
                runID: nil,
                provider: "test",
                verifiedIdentityFingerprint: "content-read-cancellation"
            ),
            connectionID: connectionID,
            connectionGeneration: registration.generation,
            invocationID: invocationID,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            ephemeralGrantedToolNames: []
        )

        let clock = SynchronousDurationClock()
        let sleeps = ControlledWatchdogSleeps(clock: clock)
        let registry = MCPCodeStructureSettlementRegistry()
        let admission = registry.admit(
            windowID: 952,
            connectionID: connectionID,
            invocationID: invocationID,
            toolName: MCPWindowToolName.readFile,
            now: .zero,
            handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
        )
        guard case let .admitted(settlementSlot) = admission else {
            return XCTFail("Expected settlement-registry admission")
        }
        addTeardownBlock { await sleeps.releaseAll() }

        let watchdogTask = Task { () -> Result<Value, Error> in
            do {
                return try await .success(MCPToolExecutionWatchdog.execute(
                    deadline: .seconds(30),
                    cancellationGrace: .seconds(5),
                    cleanupDisposition: .detachAndSettle,
                    settlementSlot: settlementSlot,
                    environment: MCPToolExecutionWatchdogEnvironment(
                        now: { clock.now() },
                        sleep: { duration in try await sleeps.sleep(for: duration) }
                    )
                ) {
                    try await runtime.domainHost.invoke(MCPDomainHostInvocation(
                        invocationID: invocationID,
                        connectionID: connectionID,
                        resolution: resolution,
                        arguments: ["path": .string(path)],
                        securityContext: securityContext
                    ))
                })
            } catch {
                return .failure(error)
            }
        }

        guard await waitUntil(iterations: 100_000, { physicalReadGate.isBlockedSnapshot() }) else {
            watchdogTask.cancel()
            if let earlyResult = await waitForTaskResult(watchdogTask),
               case let .failure(error) = earlyResult.get()
            {
                return XCTFail("Concrete host provider failed before the physical gate: \(String(reflecting: error))")
            }
            return XCTFail("Concrete host provider did not reach the controlled physical gate")
        }
        guard await waitUntil({ await sleeps.pendingCountSnapshot() >= 1 }) else {
            watchdogTask.cancel()
            return XCTFail("Watchdog deadline did not register")
        }
        let deadlineSleepReleased = await sleeps.releaseNext()
        XCTAssertTrue(deadlineSleepReleased)

        guard let observedResult = await waitForTaskResult(watchdogTask) else {
            physicalReadGate.release()
            return XCTFail("Concrete host provider did not settle within cancellation grace")
        }
        guard case let .failure(error) = observedResult.get() else {
            return XCTFail("Expected concrete host provider timeout")
        }
        XCTAssertEqual(
            error as? MCPToolExecutionWatchdogError,
            .executionTimedOut(settlement: .cancellation)
        )
        XCTAssertEqual(
            registry.snapshot(windowID: 952),
            .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
        )

        physicalReadGate.release()
        let limiterSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(limiterSnapshot.isIdle)
        _ = appBinderRetention
    }

    func testSuccessiveDomainProviderExplicitMaterializationTimeoutsDoNotExhaustReleasedProviderAllowance() async throws {
        let firstRootURL = try makeTemporaryRoot()
        try "Ignored.swift\n".write(
            to: firstRootURL.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let firstTargetURL = firstRootURL.appendingPathComponent("Ignored.swift")
        try "first materialized read\n".write(to: firstTargetURL, atomically: true, encoding: .utf8)
        let firstStore = WorkspaceFileContextStore()
        let firstRoot = try await firstStore.loadRoot(path: firstRootURL.path)
        let firstRoots = await firstStore.rootRefs(scope: .visibleWorkspace)
        let firstCatalogedTarget = await firstStore.file(rootID: firstRoot.id, relativePath: "Ignored.swift")
        XCTAssertNil(firstCatalogedTarget)

        let secondRootURL = try makeTemporaryRoot()
        try "Ignored.swift\n".write(
            to: secondRootURL.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let secondTargetURL = secondRootURL.appendingPathComponent("Ignored.swift")
        try "second materialized read\n".write(to: secondTargetURL, atomically: true, encoding: .utf8)
        let secondStore = WorkspaceFileContextStore()
        let secondRoot = try await secondStore.loadRoot(path: secondRootURL.path)
        let secondRoots = await secondStore.rootRefs(scope: .visibleWorkspace)
        let secondCatalogedTarget = await secondStore.file(rootID: secondRoot.id, relativePath: "Ignored.swift")
        XCTAssertNil(secondCatalogedTarget)

        let firstPhysicalReadGate = SynchronousPhysicalReadGate()
        let secondPhysicalReadGate = SynchronousPhysicalReadGate()
        let clock = SynchronousDurationClock()
        let registry = MCPCodeStructureSettlementRegistry()
        try await firstStore.setContentPhysicalReadHandlerForTesting(rootID: firstRoot.id) {
            firstPhysicalReadGate.blockUntilReleased()
        }
        try await secondStore.setContentPhysicalReadHandlerForTesting(rootID: secondRoot.id) {
            secondPhysicalReadGate.blockUntilReleased()
        }
        addTeardownBlock {
            firstPhysicalReadGate.release()
            secondPhysicalReadGate.release()
            try? await firstStore.setContentPhysicalReadHandlerForTesting(rootID: firstRoot.id, nil)
            try? await secondStore.setContentPhysicalReadHandlerForTesting(rootID: secondRoot.id, nil)
        }

        let attempts = [
            (
                store: firstStore,
                roots: firstRoots,
                targetURL: firstTargetURL,
                physicalReadGate: firstPhysicalReadGate
            ),
            (
                store: secondStore,
                roots: secondRoots,
                targetURL: secondTargetURL,
                physicalReadGate: secondPhysicalReadGate
            )
        ]
        var watchdogTasks: [Task<Result<Void, Error>, Never>] = []
        var watchdogResults: [Result<Void, Error>] = []
        var controlledSleeps: [ControlledWatchdogSleeps] = []

        for (index, attempt) in attempts.enumerated() {
            let attemptNumber = index + 1
            let sleeps = ControlledWatchdogSleeps(clock: clock)
            controlledSleeps.append(sleeps)
            let admission = registry.admit(
                windowID: 951,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.readFile,
                now: clock.now(),
                handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
            )
            guard case let .admitted(settlementSlot) = admission else {
                return XCTFail("Explicit-materialization attempt \(attemptNumber) was blocked before execution")
            }
            let watchdogTask = Task { () -> Result<Void, Error> in
                do {
                    try await MCPToolExecutionWatchdog.execute(
                        deadline: .seconds(30),
                        cancellationGrace: .seconds(5),
                        cleanupDisposition: .detachAndSettle,
                        settlementSlot: settlementSlot,
                        environment: MCPToolExecutionWatchdogEnvironment(
                            now: { clock.now() },
                            sleep: { duration in try await sleeps.sleep(for: duration) }
                        )
                    ) {
                        try await runDomainReadProviderTask(path: attempt.targetURL.path) {
                            let materialization = try await attempt.store.materializeExplicitlyRequestedFile(
                                attempt.targetURL.path,
                                rootRefs: attempt.roots
                            )
                            guard case .materialized = materialization else {
                                throw PhysicalReadTestError.syntheticFailure
                            }
                        }
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            watchdogTasks.append(watchdogTask)

            guard await waitUntil(iterations: 100_000, { attempt.physicalReadGate.isBlockedSnapshot() }) else {
                watchdogTask.cancel()
                return XCTFail("Explicit-materialization attempt \(attemptNumber) did not reach its physical probe")
            }
            guard await waitUntil({ await sleeps.pendingCountSnapshot() >= 1 }) else {
                watchdogTask.cancel()
                return XCTFail("Explicit-materialization attempt \(attemptNumber) did not register its deadline")
            }
            let deadlineSleepReleased = await sleeps.releaseNext()
            XCTAssertTrue(deadlineSleepReleased)
            var observedResult = await waitForTaskResult(watchdogTask)
            if observedResult == nil {
                guard await waitUntil({ await sleeps.pendingCountSnapshot() >= 1 }) else {
                    watchdogTask.cancel()
                    return XCTFail("Explicit-materialization attempt \(attemptNumber) did not register cancellation grace")
                }
                let graceSleepReleased = await sleeps.releaseNext()
                XCTAssertTrue(graceSleepReleased)
                observedResult = await waitForTaskResult(watchdogTask)
            }
            guard let observedResult else {
                attempt.physicalReadGate.release()
                return XCTFail("Explicit-materialization attempt \(attemptNumber) did not settle")
            }
            watchdogResults.append(observedResult.get())

            if index == 0 {
                clock.advance(by: .seconds(30))
            }
        }

        let thirdAdmission = registry.admit(
            windowID: 951,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: MCPWindowToolName.readFile,
            now: clock.now(),
            handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
        )
        let thirdAdmissionSucceeded: Bool
        switch thirdAdmission {
        case let .admitted(slot):
            thirdAdmissionSucceeded = true
            _ = slot.closeBeforeExecutionExit()
        case .busy:
            thirdAdmissionSucceeded = false
        }

        for (index, result) in watchdogResults.enumerated() {
            guard case let .failure(error) = result else {
                XCTFail("Explicit-materialization attempt \(index + 1) did not time out")
                continue
            }
            XCTAssertEqual(
                error as? MCPToolExecutionWatchdogError,
                .executionTimedOut(settlement: .cancellation),
                "Explicit-materialization attempt \(index + 1) detached instead of settling cancellation"
            )
        }
        XCTAssertTrue(thirdAdmissionSucceeded, "Two released providers exhausted replacement admission")
        XCTAssertEqual(
            registry.snapshot(windowID: 951),
            .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
        )
        let blockedLimiterSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(blockedLimiterSnapshot.activePermitCount, 2)
        XCTAssertEqual(blockedLimiterSnapshot.queuedWaiterCount, 0)

        firstPhysicalReadGate.release()
        secondPhysicalReadGate.release()
        for sleeps in controlledSleeps {
            await sleeps.releaseAll()
        }
        for task in watchdogTasks {
            _ = await waitForTaskResult(task)
        }
        let limiterSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(limiterSnapshot.isIdle)
    }

    func testExplicitMaterializationValidatesPhysicalEligibilityBeforeCommit() async throws {
        let rootURL = try makeTemporaryRoot()
        try "Ignored.swift\n".write(
            to: rootURL.appendingPathComponent(".repo_ignore"),
            atomically: true,
            encoding: .utf8
        )
        let targetURL = rootURL.appendingPathComponent("Ignored.swift")
        try "single physical eligibility probe\n".write(to: targetURL, atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let probeCount = SynchronousInvocationCounter()
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            probeCount.recordInvocation()
        }
        addTeardownBlock {
            try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil)
        }

        let result = try await store.materializeExplicitlyRequestedFile(
            targetURL.path,
            rootRefs: roots
        )
        guard case let .materialized(file) = result else {
            return XCTFail("Expected ignored file to materialize")
        }
        XCTAssertEqual(file.standardizedFullPath, StandardizedPath.absolute(targetURL.path))
        XCTAssertEqual(probeCount.snapshot(), 2)
    }

    func testFailedFinalMaterializationRollsBackIgnoredRegistration() async throws {
        let rootURL = try makeTemporaryRoot()
        try "Ignored.swift\n".write(to: rootURL.appendingPathComponent(".repo_ignore"), atomically: true, encoding: .utf8)
        let targetURL = rootURL.appendingPathComponent("Ignored.swift")
        try "ignored content\n".write(to: targetURL, atomically: true, encoding: .utf8)
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedService = await store.fileSystemServiceForTesting(rootID: root.id)
        let service = try XCTUnwrap(loadedService)
        let before = await service.explicitlyManagedIgnoredRegistrationSnapshotForTesting(relativePath: "Ignored.swift")
        let reachedFence = AsyncSignal()
        let releaseFence = AsyncSignal()
        await store.setExplicitMaterializationDidAcquireCodemapFenceHandlerForTesting { _ in
            await reachedFence.signal()
            await releaseFence.wait()
        }
        let task = Task { try await store.materializeExplicitlyRequestedFile(targetURL.path, rootRefs: roots) }
        addTeardownBlock {
            await releaseFence.signal()
            task.cancel()
            await store.setExplicitMaterializationDidAcquireCodemapFenceHandlerForTesting(nil)
        }
        guard await waitUntil({ await reachedFence.isSignaledSnapshot() }) else {
            return XCTFail("Materialization did not reach its post-registration fence")
        }
        let pending = await service.explicitlyManagedIgnoredRegistrationSnapshotForTesting(relativePath: "Ignored.swift")
        XCTAssertEqual(pending.pendingOwnerCount, 1)
        try FileManager.default.removeItem(at: targetURL)
        await releaseFence.signal()
        guard let result = await waitForTaskResult(task) else { return XCTFail("Missing-file ingress did not settle") }
        if case .success = result {
            XCTFail("Missing final physical evidence must reject materialization")
        }
        let after = await service.explicitlyManagedIgnoredRegistrationSnapshotForTesting(relativePath: "Ignored.swift")
        XCTAssertEqual(after, before)
        let file = await store.file(rootID: root.id, relativePath: "Ignored.swift")
        XCTAssertNil(file)
        try "recreated ignored content\n".write(to: targetURL, atomically: true, encoding: .utf8)
        let recreated = await service.explicitlyManagedIgnoredRegistrationSnapshotForTesting(relativePath: "Ignored.swift")
        XCTAssertFalse(recreated.watcherExemptsPath)
        XCTAssertFalse(recreated.isRegistered)
    }

    func testCancelledFinalMaterializationSettlesBeforePhysicalReturnAndRollsBack() async throws {
        let rootURL = try makeTemporaryRoot()
        try "Ignored.swift\n".write(to: rootURL.appendingPathComponent(".repo_ignore"), atomically: true, encoding: .utf8)
        let targetURL = rootURL.appendingPathComponent("Ignored.swift")
        try "ignored content\n".write(to: targetURL, atomically: true, encoding: .utf8)
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedService = await store.fileSystemServiceForTesting(rootID: root.id)
        let service = try XCTUnwrap(loadedService)
        let before = await service.explicitlyManagedIgnoredRegistrationSnapshotForTesting(relativePath: "Ignored.swift")
        let physicalGate = SynchronousPhysicalReadGate()
        await store.setExplicitMaterializationDidAcquireCodemapFenceHandlerForTesting { service in
            await service.setContentPhysicalReadHandlerForTesting { physicalGate.blockUntilReleased() }
        }
        let task = Task { try await store.materializeExplicitlyRequestedFile(targetURL.path, rootRefs: roots) }
        addTeardownBlock {
            physicalGate.release()
            task.cancel()
            await service.setContentPhysicalReadHandlerForTesting(nil)
            await store.setExplicitMaterializationDidAcquireCodemapFenceHandlerForTesting(nil)
        }
        guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
            return XCTFail("Final physical validation did not enter the controlled boundary")
        }
        task.cancel()
        guard let result = await waitForTaskResult(task) else { return XCTFail("Cancelled ingress waited for physical completion") }
        guard case let .failure(error) = result, error is CancellationError else {
            return XCTFail("Expected cancellation before releasing final physical validation")
        }
        let storeProbe = Task { () throws -> [WorkspaceRootRef] in await store.rootRefs(scope: .visibleWorkspace) }
        guard let storeResult = await waitForTaskResult(storeProbe) else {
            return XCTFail("Final physical validation blocked unrelated store operations")
        }
        XCTAssertEqual(try storeResult.get(), roots)
        let after = await service.explicitlyManagedIgnoredRegistrationSnapshotForTesting(relativePath: "Ignored.swift")
        XCTAssertEqual(after, before)
        let file = await store.file(rootID: root.id, relativePath: "Ignored.swift")
        XCTAssertNil(file)
        let blocked = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(blocked.activePermitCount, 1)
        XCTAssertEqual(blocked.foregroundActivityCount, 1)
        physicalGate.release()
        let settled = await waitForLimiterIdle()
        XCTAssertTrue(settled.isIdle)
    }

    func testExplicitRegistrationRechecksIgnoreRuleRevisionAfterEligibilityValidation() async throws {
        let rootURL = try makeTemporaryRoot()
        try "policy drift\n".write(
            to: rootURL.appendingPathComponent("Ignored.swift"),
            atomically: true,
            encoding: .utf8
        )
        let service = try await FileSystemService(path: rootURL.path)
        let probeCount = SynchronousInvocationCounter()
        await service.setContentPhysicalReadHandlerForTesting {
            probeCount.recordInvocation()
        }
        addTeardownBlock {
            await service.setContentPhysicalReadHandlerForTesting(nil)
        }
        let evidence = try await service.cancellationResponsiveCatalogRegularFileEligibilityWithPolicy(
            relativePath: "Ignored.swift"
        )
        XCTAssertEqual(evidence.eligibility, .eligible)

        try "Ignored.swift\n".write(
            to: rootURL.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try await service.refreshIgnoreRules()
        let refreshedPolicyIdentity = await service.currentWorkspaceRootCatalogPolicyIdentity()
        XCTAssertEqual(refreshedPolicyIdentity, evidence.policyIdentity)
        let registeredEligibility = try await service.beginExplicitlyManagedRegularFileRegistration(
            relativePath: "Ignored.swift",
            validatedEligibility: evidence.eligibility,
            policyIdentity: evidence.policyIdentity,
            ignoreRulesRevision: evidence.ignoreRulesRevision
        )

        if let token = registeredEligibility.token {
            _ = await service.rollbackExplicitlyManagedRegularFileRegistration(token)
        }
        XCTAssertEqual(registeredEligibility.eligibility, .ineligible(.ignored))
        XCTAssertEqual(probeCount.snapshot(), 1)
    }

    func testExplicitRegistrationRechecksPhysicalEligibilityAfterPolicyIdentityChanges() async throws {
        let rootURL = try makeTemporaryRoot()
        let realDirectoryURL = rootURL.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectoryURL, withIntermediateDirectories: true)
        try "policy identity drift\n".write(
            to: realDirectoryURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: rootURL.appendingPathComponent("Alias"),
            withDestinationURL: realDirectoryURL
        )

        let service = try await FileSystemService(path: rootURL.path, skipSymlinks: false)
        let probeCount = SynchronousInvocationCounter()
        await service.setContentPhysicalReadHandlerForTesting {
            probeCount.recordInvocation()
        }
        addTeardownBlock {
            await service.setContentPhysicalReadHandlerForTesting(nil)
        }
        let evidence = try await service.cancellationResponsiveCatalogRegularFileEligibilityWithPolicy(
            relativePath: "Alias/Target.swift"
        )
        XCTAssertEqual(evidence.eligibility, .eligible)

        await service.updateSkipSymlinks(true)
        let registeredEligibility = try await service.beginExplicitlyManagedRegularFileRegistration(
            relativePath: "Alias/Target.swift",
            validatedEligibility: evidence.eligibility,
            policyIdentity: evidence.policyIdentity,
            ignoreRulesRevision: evidence.ignoreRulesRevision
        )

        XCTAssertEqual(registeredEligibility.eligibility, .ineligible(.symlinkComponent))
        XCTAssertEqual(probeCount.snapshot(), 2)
    }

    func testExplicitMaterializationRechecksIgnoreRuleRevisionAfterCodemapFence() async throws {
        let rootURL = try makeTemporaryRoot()
        let ignoreURL = rootURL.appendingPathComponent(".gitignore")
        try "Ignored.swift\n".write(to: ignoreURL, atomically: true, encoding: .utf8)
        let targetURL = rootURL.appendingPathComponent("Ignored.swift")
        try "fence policy drift\n".write(to: targetURL, atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let probeCount = SynchronousInvocationCounter()
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            probeCount.recordInvocation()
        }
        await store.setExplicitMaterializationDidAcquireCodemapFenceHandlerForTesting { service in
            try? "".write(to: ignoreURL, atomically: true, encoding: .utf8)
            try? await service.refreshIgnoreRules()
        }
        addTeardownBlock {
            try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil)
            await store.setExplicitMaterializationDidAcquireCodemapFenceHandlerForTesting(nil)
        }

        let result = try await store.materializeExplicitlyRequestedFile(
            targetURL.path,
            rootRefs: roots
        )
        guard case let .materialized(file) = result else {
            return XCTFail("Expected file to materialize after ignore policy changed")
        }
        let discoverableFile = await store.file(id: file.id)
        XCTAssertEqual(discoverableFile?.id, file.id)
        XCTAssertEqual(probeCount.snapshot(), 2)
    }

    func testExplicitMaterializationRejectsRootTurnoverDuringPolicyRevalidation() async throws {
        let rootURL = try makeTemporaryRoot()
        try "Target.swift\n".write(to: rootURL.appendingPathComponent(".repo_ignore"), atomically: true, encoding: .utf8)
        let targetURL = rootURL.appendingPathComponent("Target.swift")
        try "root turnover\n".write(to: targetURL, atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let physicalGate = SynchronousPhysicalReadGate()
        await store.setExplicitMaterializationDidAcquireCodemapFenceHandlerForTesting { service in
            await service.updateSkipSymlinks(false)
            await service.setContentPhysicalReadHandlerForTesting {
                physicalGate.blockUntilReleased()
            }
        }
        addTeardownBlock {
            physicalGate.release()
            await store.setExplicitMaterializationDidAcquireCodemapFenceHandlerForTesting(nil)
        }

        let materializationTask = Task {
            try await store.materializeExplicitlyRequestedFile(targetURL.path, rootRefs: roots)
        }
        guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
            materializationTask.cancel()
            physicalGate.release()
            return XCTFail("Policy revalidation did not reach the controlled physical boundary")
        }

        await store.unloadRoot(id: root.id)
        physicalGate.release()
        guard let materializationResult = await waitForTaskResult(materializationTask) else {
            return XCTFail("Materialization did not settle after root turnover")
        }
        XCTAssertEqual(try materializationResult.get(), .unavailable)
        let materializedFile = await store.file(rootID: root.id, relativePath: "Target.swift")
        XCTAssertNil(materializedFile)
    }

    func testExplicitMaterializationRejectsRootTurnoverDuringInitialEligibility() async throws {
        let rootURL = try makeTemporaryRoot()
        let targetURL = rootURL.appendingPathComponent("Target.swift")
        try "initial eligibility turnover\n".write(to: targetURL, atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let physicalGate = SynchronousPhysicalReadGate()
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            physicalGate.blockUntilReleased()
        }
        addTeardownBlock {
            physicalGate.release()
            try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil)
        }

        let materializationTask = Task {
            try await store.materializeExplicitlyRequestedFile(targetURL.path, rootRefs: roots)
        }
        guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
            materializationTask.cancel()
            physicalGate.release()
            return XCTFail("Initial eligibility did not reach the controlled physical boundary")
        }

        try await store.replaceRootLifetimeForTesting(rootID: root.id)
        physicalGate.release()
        guard let materializationResult = await waitForTaskResult(materializationTask) else {
            return XCTFail("Materialization did not settle after initial-eligibility root turnover")
        }
        XCTAssertEqual(try materializationResult.get(), .unavailable)
    }

    func testCanonicalCompactionRejectsTargetTurnoverDuringRevalidation() async throws {
        let rootURL = try makeTemporaryRoot()
        try "cataloged target\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let revalidationEntered = AsyncSignal()
        let releaseRevalidation = AsyncSignal()
        await store.setExactFileSuspensionGateForTesting(
            point: .canonicalCompactionRevalidation,
            rootID: root.id
        ) {
            await revalidationEntered.signal()
            await releaseRevalidation.wait()
        }
        let resolutionTask = Task {
            try await store.resolveExactExistingWorkspaceFile(
                WorkspaceExactFileInput.parse("Target.swift"),
                namespace: WorkspaceExactFileNamespace.identity(roots: roots)
            )
        }
        addTeardownBlock {
            await releaseRevalidation.signal()
            resolutionTask.cancel()
            await store.clearExactFileCandidateProbeGateForTesting()
            let result = await self.waitForTaskResult(resolutionTask)
            XCTAssertNotNil(result)
        }
        guard await waitUntil({ await revalidationEntered.isSignaledSnapshot() }) else {
            return XCTFail("Compaction did not reach observation revalidation")
        }
        try await store.replaceRootLifetimeForTesting(rootID: root.id)
        await releaseRevalidation.signal()
        guard let result = await waitForTaskResult(resolutionTask) else {
            return XCTFail("Compaction did not settle after target turnover")
        }
        XCTAssertEqual(try result.get(), .issue(.unresolved(input: "Target.swift")))
    }

    func testExactCandidatesRejectUncataloguedEligibilityAfterRootTurnover() async throws {
        let catalogRootURL = try makeTemporaryRoot()
        let ignoredRootURL = try makeTemporaryRoot()
        try "catalog match\n".write(
            to: catalogRootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "Target.swift\n".write(
            to: ignoredRootURL.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored physical match\n".write(
            to: ignoredRootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: catalogRootURL.path)
        let ignoredRoot = try await store.loadRoot(path: ignoredRootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let ignoredCatalogFile = await store.file(rootID: ignoredRoot.id, relativePath: "Target.swift")
        XCTAssertNil(ignoredCatalogFile)
        let physicalGate = SynchronousPhysicalReadGate()
        try await store.setContentPhysicalReadHandlerForTesting(rootID: ignoredRoot.id) {
            physicalGate.blockUntilReleased()
        }
        addTeardownBlock {
            physicalGate.release()
            try? await store.setContentPhysicalReadHandlerForTesting(rootID: ignoredRoot.id, nil)
        }

        let resolutionTask = Task {
            try await store.resolveExactExistingWorkspaceFile(
                WorkspaceExactFileInput.parse("Target.swift"),
                namespace: WorkspaceExactFileNamespace.identity(roots: roots)
            )
        }
        guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
            resolutionTask.cancel()
            physicalGate.release()
            return XCTFail("Uncatalogued eligibility did not reach the controlled physical boundary")
        }

        try await store.replaceRootLifetimeForTesting(rootID: ignoredRoot.id)
        physicalGate.release()
        guard let observedResolution = await waitForTaskResult(resolutionTask) else {
            return XCTFail("Exact resolution did not settle after root turnover")
        }
        XCTAssertEqual(
            try observedResolution.get(),
            .issue(.unresolved(input: "Target.swift"))
        )
    }

    func testSuccessiveOuterProviderTimeoutsDoNotEnterUnrelatedGitArtifactPreflight() async throws {
        XCTAssertTrue(MCPServerViewModel.shouldAttemptSelectedGitArtifactReadForTesting(
            requestedPath: "_git_data/repos/repo/snapshot/MAP.txt",
            translatedLookupPath: "/workspace/_git_data/repos/repo/snapshot/MAP.txt"
        ))
        XCTAssertFalse(MCPServerViewModel.shouldAttemptSelectedGitArtifactReadForTesting(
            requestedPath: "Target.swift",
            translatedLookupPath: "/workspace/Target.swift"
        ))

        let rootURL = try makeTemporaryRoot()
        try "successive provider timeout\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }

        let registry = MCPCodeStructureSettlementRegistry()
        let gitArtifactPreflightGate = AsyncSignal()
        addTeardownBlock {
            await gitArtifactPreflightGate.signal()
            try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil)
        }

        for attempt in 1 ... 2 {
            let physicalReadGate = SynchronousPhysicalReadGate()
            let clock = SynchronousDurationClock()
            let sleeps = ControlledWatchdogSleeps(clock: clock)
            let invocationID = UUID()
            let admission = registry.admit(
                windowID: 949,
                connectionID: UUID(),
                invocationID: invocationID,
                toolName: MCPWindowToolName.readFile,
                now: clock.now(),
                handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
            )
            guard case let .admitted(settlementSlot) = admission else {
                return XCTFail("Timeout attempt \(attempt) was blocked by prior provider settlement debt")
            }

            try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
                physicalReadGate.blockUntilReleased()
            }
            let watchdogTask = Task { () -> Result<Void, Error> in
                do {
                    try await MCPToolExecutionWatchdog.execute(
                        deadline: .seconds(30),
                        cancellationGrace: .seconds(5),
                        cleanupDisposition: .detachAndSettle,
                        settlementSlot: settlementSlot,
                        environment: MCPToolExecutionWatchdogEnvironment(
                            now: { clock.now() },
                            sleep: { duration in try await sleeps.sleep(for: duration) }
                        )
                    ) {
                        if MCPServerViewModel.shouldAttemptSelectedGitArtifactReadForTesting(
                            requestedPath: "Target.swift",
                            translatedLookupPath: record.standardizedFullPath
                        ) {
                            await gitArtifactPreflightGate.wait()
                        }
                        try await runMainActorProviderTask(
                            store: store,
                            record: record,
                            roots: store.rootRefs(scope: .visibleWorkspace)
                        )
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }

            let physicalReadDidBlock = await waitUntil { physicalReadGate.isBlockedSnapshot() }
            guard physicalReadDidBlock else {
                watchdogTask.cancel()
                await gitArtifactPreflightGate.signal()
                physicalReadGate.release()
                await sleeps.releaseAll()
                _ = await waitForTaskResult(watchdogTask)
                return XCTFail("Timeout attempt \(attempt) stalled in unrelated Git-artifact preflight")
            }
            let deadlineDidRegister = await waitUntil { await sleeps.registeredCountSnapshot() >= 1 }
            guard deadlineDidRegister else {
                watchdogTask.cancel()
                physicalReadGate.release()
                await sleeps.releaseAll()
                return XCTFail("Timeout attempt \(attempt) did not register its watchdog deadline")
            }
            await sleeps.releaseNext()

            guard let observedWatchdogResult = await waitForTaskResult(watchdogTask) else {
                physicalReadGate.release()
                return XCTFail("Timeout attempt \(attempt) did not settle during cancellation grace")
            }
            let watchdogResult = try observedWatchdogResult.get()
            guard case let .failure(error) = watchdogResult,
                  error as? MCPToolExecutionWatchdogError == .executionTimedOut(settlement: .cancellation)
            else {
                physicalReadGate.release()
                return XCTFail("Timeout attempt \(attempt) did not report cancellation settlement")
            }
            XCTAssertEqual(
                registry.snapshot(windowID: 949),
                .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
            )

            physicalReadGate.release()
            let limiterSnapshot = await waitForLimiterIdle()
            XCTAssertTrue(limiterSnapshot.isIdle)
            try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil)
        }
    }

    func testSuccessiveDomainProviderExactResolutionPathStateStallsSettleAndRecover() async throws {
        let parentURL = try makeTemporaryRoot()
        let rootURLs = ["catalog-hit", "catalog-miss-a", "catalog-miss-b"].map {
            parentURL.appendingPathComponent($0, isDirectory: true)
        }
        for rootURL in rootURLs {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        try "cataloged target\n".write(
            to: rootURLs[0].appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        for rootURL in rootURLs {
            _ = try await store.loadRoot(path: rootURL.path)
        }
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        guard let catalogRoot = roots.first(where: {
            $0.standardizedFullPath == StandardizedPath.absolute(rootURLs[0].path)
        }), let record = await store.file(rootID: catalogRoot.id, relativePath: "Target.swift")
        else {
            return XCTFail("Expected cataloged target record")
        }
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let missingRootIDs = roots
            .filter { $0.standardizedFullPath != StandardizedPath.absolute(rootURLs[0].path) }
            .map(\.id)
        XCTAssertEqual(missingRootIDs.count, 2)

        let physicalReadGates = PeriodicPhysicalReadGates(interval: 3, count: 2)
        let physicalReadHandler: @Sendable () -> Void = {
            physicalReadGates.reachNextProbe()
        }
        for rootID in missingRootIDs {
            try await store.setContentPhysicalReadHandlerForTesting(
                rootID: rootID,
                physicalReadHandler
            )
        }
        addTeardownBlock {
            physicalReadGates.releaseAll()
            for rootID in missingRootIDs {
                try? await store.setContentPhysicalReadHandlerForTesting(rootID: rootID, nil)
            }
        }

        let registry = MCPCodeStructureSettlementRegistry()
        let clock = SynchronousDurationClock()
        func startWatchdogAttempt(
            _ attempt: Int,
            sleeps: ControlledWatchdogSleeps
        ) -> Task<Result<Void, Error>, Never>? {
            let admission = registry.admit(
                windowID: 949,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.readFile,
                now: clock.now(),
                handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
            )
            guard case let .admitted(settlementSlot) = admission else {
                XCTFail("Exact-resolution attempt \(attempt) was blocked before execution")
                return nil
            }
            return Task { () -> Result<Void, Error> in
                do {
                    try await MCPToolExecutionWatchdog.execute(
                        deadline: .seconds(30),
                        cancellationGrace: .seconds(5),
                        cleanupDisposition: .detachAndSettle,
                        settlementSlot: settlementSlot,
                        environment: MCPToolExecutionWatchdogEnvironment(
                            now: { clock.now() },
                            sleep: { duration in try await sleeps.sleep(for: duration) }
                        )
                    ) {
                        try await runDomainReadProviderTask(
                            store: store,
                            record: record,
                            roots: roots
                        )
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
        }

        func finishWatchdogAttempt(
            _ task: Task<Result<Void, Error>, Never>,
            sleeps: ControlledWatchdogSleeps
        ) async -> Result<Void, Error>? {
            let deadlineDidRegister = await waitUntil {
                await sleeps.pendingCountSnapshot() >= 1
            }
            guard deadlineDidRegister else {
                task.cancel()
                await sleeps.releaseAll()
                return nil
            }
            guard await sleeps.releaseNext() else {
                XCTFail("Exact-resolution deadline sleeper disappeared before release")
                return nil
            }
            if let observedResult = await waitForTaskResult(task) {
                return observedResult.get()
            }
            let graceDidRegister = await waitUntil {
                await sleeps.pendingCountSnapshot() >= 1
            }
            guard graceDidRegister else { return nil }
            guard await sleeps.releaseNext() else {
                XCTFail("Exact-resolution grace sleeper disappeared before release")
                return nil
            }
            guard let observedResult = await waitForTaskResult(task) else { return nil }
            return observedResult.get()
        }

        let firstSleeps = ControlledWatchdogSleeps(clock: clock)
        guard let firstTask = startWatchdogAttempt(1, sleeps: firstSleeps) else { return }
        guard await waitUntil(iterations: 100_000, { physicalReadGates.isBlocked(at: 0) }) else {
            firstTask.cancel()
            let earlyResult = await waitForTaskResult(firstTask)
            return XCTFail("First exact-resolution path-state probe did not block; result=\(String(describing: earlyResult))")
        }
        let firstResult = await finishWatchdogAttempt(firstTask, sleeps: firstSleeps)

        // The settlement registry's recovery horizon admits a replacement provider even
        // while the first cancellation-ignoring producer still owns its physical work.
        clock.advance(by: .seconds(30))
        let secondSleeps = ControlledWatchdogSleeps(clock: clock)
        guard let secondTask = startWatchdogAttempt(2, sleeps: secondSleeps) else {
            physicalReadGates.releaseAll()
            return
        }
        let secondPhysicalReadDidBlock = await waitUntil { physicalReadGates.isBlocked(at: 1) }
        let secondResult = await finishWatchdogAttempt(secondTask, sleeps: secondSleeps)

        let thirdAdmission = registry.admit(
            windowID: 949,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: MCPWindowToolName.readFile,
            now: clock.now(),
            handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
        )
        let thirdAdmissionSucceeded: Bool
        switch thirdAdmission {
        case let .admitted(slot):
            thirdAdmissionSucceeded = true
            _ = slot.closeBeforeExecutionExit()
        case .busy:
            thirdAdmissionSucceeded = false
        }

        XCTAssertTrue(secondPhysicalReadDidBlock, "The second provider remained queued behind the first actor-pinning probe")
        for (attempt, result) in [firstResult, secondResult].enumerated() {
            guard case let .failure(error) = result else {
                XCTFail("Exact-resolution attempt \(attempt + 1) did not time out")
                continue
            }
            XCTAssertEqual(
                error as? MCPToolExecutionWatchdogError,
                .executionTimedOut(settlement: .cancellation),
                "Exact-resolution attempt \(attempt + 1) detached instead of settling cancellation"
            )
        }
        XCTAssertTrue(thirdAdmissionSucceeded, "Two detached providers exhausted the released-provider allowance")
        XCTAssertEqual(
            registry.snapshot(windowID: 949),
            .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
        )

        physicalReadGates.releaseAll()
        await firstSleeps.releaseAll()
        await secondSleeps.releaseAll()
        _ = await waitForTaskResult(firstTask)
        _ = await waitForTaskResult(secondTask)
        let limiterSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(limiterSnapshot.isIdle)

        let recovered = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse("Target.swift"),
            namespace: namespace
        )
        guard case let .matched(match) = recovered else {
            return XCTFail("Expected exact resolution to recover after both physical reads returned")
        }
        XCTAssertEqual(match.file.standardizedFullPath, StandardizedPath.absolute(rootURLs[0].appendingPathComponent("Target.swift").path))
        let finalLimiterSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertTrue(finalLimiterSnapshot.isIdle)
    }

    func testSuccessiveExactResolutionMissingFileRechecksSettleAndRecover() async throws {
        let parentURL = try makeTemporaryRoot()
        let rootURLs = ["catalog-hit", "catalog-miss-a", "catalog-miss-b"].map {
            parentURL.appendingPathComponent($0, isDirectory: true)
        }
        for rootURL in rootURLs {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        try "cataloged target\n".write(
            to: rootURLs[0].appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        for rootURL in rootURLs {
            _ = try await store.loadRoot(path: rootURL.path)
        }
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        guard let catalogRoot = roots.first(where: {
            $0.standardizedFullPath == StandardizedPath.absolute(rootURLs[0].path)
        }), let record = await store.file(rootID: catalogRoot.id, relativePath: "Target.swift")
        else {
            return XCTFail("Expected cataloged target record")
        }
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let missingRootIDs = roots
            .filter { $0.standardizedFullPath != StandardizedPath.absolute(rootURLs[0].path) }
            .map(\.id)
        XCTAssertEqual(missingRootIDs.count, 2)

        let physicalReadGates = PeriodicPhysicalReadGates(interval: 2, count: 2)
        let physicalReadHandler: @Sendable () -> Void = {
            physicalReadGates.reachNextProbe()
        }
        for rootID in missingRootIDs {
            try await store.setContentPhysicalReadHandlerForTesting(
                rootID: rootID,
                physicalReadHandler
            )
        }
        addTeardownBlock {
            physicalReadGates.releaseAll()
            for rootID in missingRootIDs {
                try? await store.setContentPhysicalReadHandlerForTesting(rootID: rootID, nil)
            }
        }

        let registry = MCPCodeStructureSettlementRegistry()
        let clock = SynchronousDurationClock()
        func startWatchdogAttempt(
            _ attempt: Int,
            sleeps: ControlledWatchdogSleeps
        ) -> Task<Result<Void, Error>, Never>? {
            let admission = registry.admit(
                windowID: 950,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.readFile,
                now: clock.now(),
                handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
            )
            guard case let .admitted(settlementSlot) = admission else {
                XCTFail("Exact-resolution attempt \(attempt) was blocked before execution")
                return nil
            }
            return Task { () -> Result<Void, Error> in
                do {
                    try await MCPToolExecutionWatchdog.execute(
                        deadline: .seconds(30),
                        cancellationGrace: .seconds(5),
                        cleanupDisposition: .detachAndSettle,
                        settlementSlot: settlementSlot,
                        environment: MCPToolExecutionWatchdogEnvironment(
                            now: { clock.now() },
                            sleep: { duration in try await sleeps.sleep(for: duration) }
                        )
                    ) {
                        try await runMainActorProviderTask(
                            store: store,
                            record: record,
                            roots: roots
                        )
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
        }

        func finishWatchdogAttempt(
            _ task: Task<Result<Void, Error>, Never>,
            sleeps: ControlledWatchdogSleeps
        ) async -> Result<Void, Error>? {
            let deadlineDidRegister = await waitUntil {
                await sleeps.pendingCountSnapshot() >= 1
            }
            guard deadlineDidRegister else {
                task.cancel()
                await sleeps.releaseAll()
                return nil
            }
            guard await sleeps.releaseNext() else {
                XCTFail("Missing-file deadline sleeper disappeared before release")
                return nil
            }
            if let observedResult = await waitForTaskResult(task) {
                return observedResult.get()
            }
            let graceDidRegister = await waitUntil {
                await sleeps.pendingCountSnapshot() >= 1
            }
            guard graceDidRegister else { return nil }
            guard await sleeps.releaseNext() else {
                XCTFail("Missing-file grace sleeper disappeared before release")
                return nil
            }
            guard let observedResult = await waitForTaskResult(task) else { return nil }
            return observedResult.get()
        }

        let firstSleeps = ControlledWatchdogSleeps(clock: clock)
        guard let firstTask = startWatchdogAttempt(1, sleeps: firstSleeps) else { return }
        guard await waitUntil({ physicalReadGates.isBlocked(at: 0) }) else {
            firstTask.cancel()
            return XCTFail("First exact-resolution missing-file recheck did not block")
        }
        let firstResult = await finishWatchdogAttempt(firstTask, sleeps: firstSleeps)

        clock.advance(by: .seconds(30))
        let secondSleeps = ControlledWatchdogSleeps(clock: clock)
        guard let secondTask = startWatchdogAttempt(2, sleeps: secondSleeps) else {
            physicalReadGates.releaseAll()
            return
        }
        let secondPhysicalReadDidBlock = await waitUntil {
            physicalReadGates.isBlocked(at: 1)
        }
        let secondResult = await finishWatchdogAttempt(secondTask, sleeps: secondSleeps)

        let thirdAdmission = registry.admit(
            windowID: 950,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: MCPWindowToolName.readFile,
            now: clock.now(),
            handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
        )
        let thirdAdmissionSucceeded: Bool
        switch thirdAdmission {
        case let .admitted(slot):
            thirdAdmissionSucceeded = true
            _ = slot.closeBeforeExecutionExit()
        case .busy:
            thirdAdmissionSucceeded = false
        }

        XCTAssertTrue(
            secondPhysicalReadDidBlock,
            "The second provider remained queued behind the first actor-isolated regular-file probe"
        )
        for (attempt, result) in [firstResult, secondResult].enumerated() {
            guard case let .failure(error) = result else {
                XCTFail("Exact-resolution attempt \(attempt + 1) did not time out")
                continue
            }
            XCTAssertEqual(
                error as? MCPToolExecutionWatchdogError,
                .executionTimedOut(settlement: .cancellation),
                "Exact-resolution attempt \(attempt + 1) detached instead of settling cancellation"
            )
        }
        XCTAssertTrue(thirdAdmissionSucceeded, "A released provider plus a second detachment exhausted admission")
        XCTAssertEqual(
            registry.snapshot(windowID: 950),
            .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
        )
        let blockedLimiterSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(blockedLimiterSnapshot.activePermitCount, 2)
        XCTAssertEqual(blockedLimiterSnapshot.queuedWaiterCount, 0)

        physicalReadGates.releaseAll()
        await firstSleeps.releaseAll()
        await secondSleeps.releaseAll()
        _ = await waitForTaskResult(firstTask)
        _ = await waitForTaskResult(secondTask)
        let limiterSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(limiterSnapshot.isIdle)

        let recovered = try await store.resolveExactExistingWorkspaceFile(
            WorkspaceExactFileInput.parse("Target.swift"),
            namespace: namespace
        )
        guard case let .matched(match) = recovered else {
            return XCTFail("Expected exact resolution to recover after both missing-file probes returned")
        }
        XCTAssertEqual(
            match.file.standardizedFullPath,
            StandardizedPath.absolute(rootURLs[0].appendingPathComponent("Target.swift").path)
        )
    }

    func testLimiterReportsBackpressureAndRemovesCancelledQueuedRead() async throws {
        let limiter = ContentReadAsyncLimiter(
            capacity: 1,
            bulkPermitLimit: 1,
            maxQueuedWaiterCount: 1,
            retryAfterMilliseconds: 37
        )
        let activeReadStarted = AsyncSignal()
        let releaseActiveRead = AsyncSignal()
        let activeTask = Task {
            try await limiter.withPermit(workloadClass: .interactiveRead, ownerID: UUID()) {
                await activeReadStarted.signal()
                await releaseActiveRead.wait()
            }
        }
        let activeReadDidStart = await waitUntil { await activeReadStarted.isSignaledSnapshot() }
        guard activeReadDidStart else {
            activeTask.cancel()
            await releaseActiveRead.signal()
            return XCTFail("Active limiter read did not start")
        }

        let queuedTask = Task {
            try await limiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) {}
        }
        let queuedSnapshot = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 1 }
        XCTAssertEqual(queuedSnapshot.activePermitCount, 1)
        XCTAssertEqual(queuedSnapshot.ownerLaneCount, 2)

        do {
            try await limiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) {}
            XCTFail("Expected an explicit queue-full error")
        } catch {
            XCTAssertEqual(error as? ContentReadSchedulerError, .queueFull(retryAfterMilliseconds: 37))
        }

        queuedTask.cancel()
        guard let queuedResult = await waitForTaskResult(queuedTask) else {
            await releaseActiveRead.signal()
            return XCTFail("Queued limiter read did not settle after cancellation")
        }
        do {
            try queuedResult.get()
            XCTFail("Expected queued read cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let cancelledSnapshot = await limiter.snapshotForTesting()
        XCTAssertEqual(cancelledSnapshot.activePermitCount, 1)
        XCTAssertEqual(cancelledSnapshot.queuedWaiterCount, 0)
        XCTAssertEqual(cancelledSnapshot.ownerLaneCount, 1)
        XCTAssertEqual(cancelledSnapshot.cancellationCount, 1)
        XCTAssertEqual(cancelledSnapshot.overloadCount, 1)

        await releaseActiveRead.signal()
        guard let activeResult = await waitForTaskResult(activeTask) else {
            return XCTFail("Active limiter read did not settle after release")
        }
        try activeResult.get()
        let idleSnapshot = await limiter.snapshotForTesting()
        XCTAssertTrue(idleSnapshot.isIdle)
    }

    func testDetachedPhysicalReadPreservesTaskLocalAttribution() async throws {
        let rootURL = try makeTemporaryRoot()
        let contents = "attributed physical read\n"
        try contents.write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let service = try await FileSystemService(path: rootURL.path)
        EditFlowPerf.resetDebugCaptureForTesting()
        _ = EditFlowPerf.beginDebugCapture(label: "physical-read-attribution", maxSamples: 32)
        guard let lifecycleCorrelation = EditFlowPerf.makeLifecycleCorrelationIfActive() else {
            return XCTFail("Expected an active lifecycle correlation")
        }
        let benchmarkMetricTag = WorktreeStartupInstrumentation.BenchmarkMetricTag(
            correlationID: UUID(),
            contextID: UUID(),
            agentSessionID: UUID(),
            logicalRootID: UUID(),
            repositoryID: "repository",
            destinationID: "destination"
        )
        let attributionRecorder = PhysicalReadAttributionRecorder()
        await service.setContentPhysicalReadHandlerForTesting {
            attributionRecorder.record(
                lifecycleCorrelationID: EditFlowPerf.currentLifecycleCorrelation?.id,
                benchmarkMetricTag: WorktreeStartupInstrumentation.currentBenchmarkMetricTag
            )
        }
        addTeardownBlock {
            await service.setContentPhysicalReadHandlerForTesting(nil)
            MCPToolWorkCountDiagnostics.resetForTesting()
            EditFlowPerf.resetDebugCaptureForTesting()
        }
        MCPToolWorkCountDiagnostics.resetForTesting()

        try await EditFlowPerf.$currentLifecycleCorrelation.withValue(lifecycleCorrelation) {
            try await WorktreeStartupInstrumentation.$currentBenchmarkMetricTag.withValue(benchmarkMetricTag) {
                try await MCPToolWorkCountDiagnostics.withReadFileInvocation {
                    let fingerprint = try await service.contentFingerprint(ofRelativePath: "Target.swift")
                    let snapshot = try await service.loadValidatedContent(
                        ofRelativePath: "Target.swift",
                        expectedFingerprint: fingerprint,
                        workloadClass: .interactiveRead
                    )
                    XCTAssertEqual(snapshot.content, contents)
                }
            }
        }

        XCTAssertEqual(attributionRecorder.snapshot()?.lifecycleCorrelationID, lifecycleCorrelation.id)
        XCTAssertEqual(attributionRecorder.snapshot()?.benchmarkMetricTag, benchmarkMetricTag)
        let readSnapshots = MCPToolWorkCountDiagnostics.debugSnapshots().readFile
        XCTAssertEqual(readSnapshots.count, 1)
        XCTAssertEqual(readSnapshots.first?.source, "disk")
        XCTAssertEqual(readSnapshots.first?.readBytes, contents.utf8.count)
        XCTAssertEqual(readSnapshots.first?.outcome, "success")
    }

    func testCancellingOnlyInteractiveCacheWaiterRemovesFlight() async throws {
        let cache = WorkspaceInteractiveReadCache()
        let loaderStarted = AsyncSignal()
        let releaseLoader = AsyncSignal()
        let task = Task {
            try await cache.snapshot(
                for: makeInteractiveReadCacheKey(),
                fingerprint: makeFingerprint(),
                invalidationEpoch: 0
            ) {
                await loaderStarted.signal()
                await releaseLoader.wait()
                return WorkspaceInteractiveReadProcessor.prepare("single waiter\n")
            }
        }
        let loaderDidStart = await waitUntil { await loaderStarted.isSignaledSnapshot() }
        guard loaderDidStart else {
            task.cancel()
            await releaseLoader.signal()
            return XCTFail("Single-waiter cache loader did not start")
        }

        task.cancel()
        guard let taskResult = await waitForTaskResult(task) else {
            await releaseLoader.signal()
            return XCTFail("Single cache waiter did not settle after cancellation")
        }
        do {
            _ = try taskResult.get()
            XCTFail("Expected the only cache waiter to observe cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let cancelledSnapshot = await waitForCacheSnapshot(cache) {
            $0.activeFlightCount == 0 && $0.cancellationCount == 1
        }
        XCTAssertEqual(cancelledSnapshot.waiterCount, 0)
        XCTAssertEqual(cancelledSnapshot.entryCount, 0)

        await releaseLoader.signal()
    }

    func testCancellingOneOfTwoInteractiveCacheWaitersPreservesSharedFlight() async throws {
        let cache = WorkspaceInteractiveReadCache()
        let key = makeInteractiveReadCacheKey()
        let fingerprint = makeFingerprint()
        let loaderStarted = AsyncSignal()
        let releaseLoader = AsyncSignal()
        let expected = WorkspaceInteractiveReadProcessor.prepare("shared flight\n")
        let firstTask = Task {
            try await cache.snapshot(for: key, fingerprint: fingerprint, invalidationEpoch: 0) {
                await loaderStarted.signal()
                await releaseLoader.wait()
                return expected
            }
        }
        let loaderDidStart = await waitUntil { await loaderStarted.isSignaledSnapshot() }
        guard loaderDidStart else {
            firstTask.cancel()
            await releaseLoader.signal()
            return XCTFail("Shared cache loader did not start")
        }
        let secondTask = Task {
            try await cache.snapshot(for: key, fingerprint: fingerprint, invalidationEpoch: 0) {
                XCTFail("Joined waiter must not start a second loader")
                return nil
            }
        }
        let sharedSnapshot = await waitForCacheSnapshot(cache) { $0.waiterCount == 2 }
        XCTAssertEqual(sharedSnapshot.waiterCount, 2)

        firstTask.cancel()
        guard let firstResult = await waitForTaskResult(firstTask) else {
            await releaseLoader.signal()
            return XCTFail("Cancelled shared cache waiter did not settle")
        }
        do {
            _ = try firstResult.get()
            XCTFail("Expected the cancelled waiter to settle independently")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let joinedSnapshot = await waitForCacheSnapshot(cache) {
            $0.waiterCount == 1 && $0.cancellationCount == 1
        }
        XCTAssertEqual(joinedSnapshot.activeFlightCount, 1)
        XCTAssertEqual(joinedSnapshot.preparationCount, 1)
        XCTAssertEqual(joinedSnapshot.joinCount, 1)

        await releaseLoader.signal()
        guard let observedSecondResult = await waitForTaskResult(secondTask) else {
            return XCTFail("Remaining shared cache waiter did not settle after release")
        }
        let secondResult = try observedSecondResult.get()
        XCTAssertEqual(secondResult.preparedContent, expected)
        let completedSnapshot = await cache.snapshotForTesting()
        XCTAssertEqual(completedSnapshot.activeFlightCount, 0)
        XCTAssertEqual(completedSnapshot.entryCount, 1)
        XCTAssertEqual(completedSnapshot.acceptedPreparationCount, 1)
    }

    func testProducerCompletionBeforeHandleInstallationSettlesSuccessExactlyOnce() async throws {
        let installGate = SynchronousPhysicalReadGate()
        let producerCompleted = AsyncSignal()
        addTeardownBlock { installGate.release() }

        let task = Task {
            try await FileSystemService.withCancellationResponsivePhysicalReadPermit(
                workloadClass: .interactiveRead,
                schedulerOwnerID: UUID(),
                priority: .userInitiated,
                beforeProducerInstallForTesting: { installGate.blockUntilReleased() }
            ) {
                await producerCompleted.signal()
                return 42
            }
        }

        let installDidBlock = await waitUntil { installGate.isBlockedSnapshot() }
        let producerDidComplete = await waitUntil { await producerCompleted.isSignaledSnapshot() }
        guard installDidBlock, producerDidComplete else {
            task.cancel()
            installGate.release()
            return XCTFail("Completion-before-install interleaving was not reached")
        }
        installGate.release()
        guard let observedResult = await waitForTaskResult(task) else {
            return XCTFail("Completion-before-install result did not settle")
        }
        let result = try observedResult.get()
        XCTAssertEqual(result, 42)
        let idleSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(idleSnapshot.isIdle)
    }

    func testCancellationBeforeProducerHandleInstallationSettlesPromptlyAndCancelsProducer() async throws {
        let installGate = SynchronousPhysicalReadGate()
        let producerGate = SynchronousPhysicalReadGate()
        addTeardownBlock {
            installGate.release()
            producerGate.release()
        }

        let task = Task {
            try await FileSystemService.withCancellationResponsivePhysicalReadPermit(
                workloadClass: .interactiveRead,
                schedulerOwnerID: UUID(),
                priority: .userInitiated,
                beforeProducerInstallForTesting: { installGate.blockUntilReleased() }
            ) {
                producerGate.blockUntilReleased()
                try Task.checkCancellation()
                return 1
            }
        }
        let installDidBlock = await waitUntil { installGate.isBlockedSnapshot() }
        let producerDidBlock = await waitUntil { producerGate.isBlockedSnapshot() }
        guard installDidBlock, producerDidBlock else {
            task.cancel()
            installGate.release()
            producerGate.release()
            return XCTFail("Cancellation-before-install interleaving was not reached")
        }

        task.cancel()
        installGate.release()
        guard let taskResult = await waitForTaskResult(task) else {
            producerGate.release()
            return XCTFail("Cancellation-before-install did not settle promptly")
        }
        do {
            _ = try taskResult.get()
            XCTFail("Expected cancellation before producer-handle installation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let blockedSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(blockedSnapshot.activePermitCount, 1)

        producerGate.release()
        let idleSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(idleSnapshot.isIdle)
    }

    func testCancelledCallerDiscardsLatePhysicalReadFailure() async throws {
        let physicalGate = SynchronousPhysicalReadGate()
        addTeardownBlock { physicalGate.release() }
        let task = Task {
            try await FileSystemService.withCancellationResponsivePhysicalReadPermit(
                workloadClass: .interactiveRead,
                schedulerOwnerID: UUID(),
                priority: .userInitiated
            ) {
                physicalGate.blockUntilReleased()
                throw PhysicalReadTestError.syntheticFailure
            }
        }
        let physicalReadDidBlock = await waitUntil { physicalGate.isBlockedSnapshot() }
        guard physicalReadDidBlock else {
            task.cancel()
            physicalGate.release()
            return XCTFail("Late physical failure did not reach the controlled gate")
        }

        task.cancel()
        guard let taskResult = await waitForTaskResult(task) else {
            physicalGate.release()
            return XCTFail("Caller did not settle before the late physical failure")
        }
        do {
            _ = try taskResult.get()
            XCTFail("Expected caller cancellation to win the late physical failure race")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let blockedSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(blockedSnapshot.activePermitCount, 1)

        physicalGate.release()
        let idleSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(idleSnapshot.isIdle)
    }

    func testStoreContentReadGrantsPreserveWorkloadAndOwnerAttribution() async throws {
        let rootURL = try makeTemporaryRoot()
        try "attributed store read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }
        let idleSnapshot = await waitForLimiterIdle()
        guard idleSnapshot.isIdle else {
            return XCTFail("Shared content-read limiter was not idle before attribution verification")
        }

        let physicalGate = SynchronousPhysicalReadGate()
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            physicalGate.blockUntilReleased()
        }
        addTeardownBlock {
            physicalGate.release()
            try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil)
        }
        let ownerIDs = await store.contentReadSchedulerOwnerIDsForTesting()
        XCTAssertNotEqual(ownerIDs.search, ownerIDs.interactive)

        let searchTask = Task { try await store.searchContentSnapshot(for: record) }
        let interactiveTask = Task { try await store.interactiveReadSnapshot(for: record) }
        let bothReadsBlocked = await waitUntil { physicalGate.blockedCountSnapshot() >= 2 }
        guard bothReadsBlocked else {
            searchTask.cancel()
            interactiveTask.cancel()
            physicalGate.release()
            return XCTFail("Store reads did not both reach their controlled physical-read grants")
        }

        let activeSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(activeSnapshot.activePermitCount, 2)
        XCTAssertEqual(activeSnapshot.activePermitCountsByWorkload[ContentReadWorkloadClass.contentSearch.rawValue], 1)
        XCTAssertEqual(activeSnapshot.activePermitCountsByWorkload[ContentReadWorkloadClass.interactiveRead.rawValue], 1)
        XCTAssertEqual(activeSnapshot.activePermitCountsByOwner[ownerIDs.search], 1)
        XCTAssertEqual(activeSnapshot.activePermitCountsByOwner[ownerIDs.interactive], 1)

        physicalGate.release()
        guard let searchResult = await waitForTaskResult(searchTask),
              let interactiveResult = await waitForTaskResult(interactiveTask)
        else {
            return XCTFail("Attributed store reads did not settle after release")
        }
        XCTAssertTrue(try searchResult.get().isFresh)
        XCTAssertNotNil(try interactiveResult.get())
        let finalSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(finalSnapshot.isIdle)
    }

    func testCacheCommitDoesNotReenterSharedLimiterAfterValidatedRead() async throws {
        let rootURL = try makeTemporaryRoot()
        let contents = "validated content survives cache pressure\n"
        try contents.write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let service = try await FileSystemService(path: rootURL.path)
        let fingerprint = try await service.contentFingerprint(ofRelativePath: "Target.swift")
        let cacheCommitReached = AsyncSignal()
        let releaseCacheCommit = AsyncSignal()
        await service.setContentReadCacheCommitHandlerForTesting {
            await cacheCommitReached.signal()
            await releaseCacheCommit.wait()
        }
        addTeardownBlock {
            await releaseCacheCommit.signal()
            await service.setContentReadCacheCommitHandlerForTesting(nil)
        }

        let readTask = Task {
            try await service.loadValidatedContent(
                ofRelativePath: "Target.swift",
                expectedFingerprint: fingerprint,
                workloadClass: .interactiveRead
            )
        }
        addTeardownBlock {
            await releaseCacheCommit.signal()
            readTask.cancel()
            let readResult = await self.waitForTaskResult(readTask)
            XCTAssertNotNil(readResult, "Validated read did not settle during teardown")
        }
        guard await waitUntil({ await cacheCommitReached.isSignaledSnapshot() }) else {
            return XCTFail("Validated read did not reach the cache-only commit boundary")
        }
        let beforeCommitSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(beforeCommitSnapshot.activePermitCount, 1)

        await releaseCacheCommit.signal()
        guard let observedReadResult = await waitForTaskResult(readTask) else {
            return XCTFail("Validated read did not settle after cache commit")
        }
        let snapshot = try observedReadResult.get()
        XCTAssertEqual(snapshot.content, contents)
        let afterReadSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(afterReadSnapshot.grantCount, beforeCommitSnapshot.grantCount)
        XCTAssertEqual(afterReadSnapshot.overloadCount, beforeCommitSnapshot.overloadCount)
        let cachedEncoding = await service.cachedEncodingForTesting(relativePath: "Target.swift")
        XCTAssertNotNil(cachedEncoding)
        XCTAssertTrue(afterReadSnapshot.isIdle)
    }

    func testReadStartedDuringMutationCannotReplaceReconciledEncoding() async throws {
        let rootURL = try makeTemporaryRoot()
        let targetURL = rootURL.appendingPathComponent("Target.swift")
        let originalContents = "old UTF-16 content\n"
        try originalContents.write(to: targetURL, atomically: true, encoding: .utf16)
        let service = try await FileSystemService(path: rootURL.path)
        let mutationEntered = AsyncSignal()
        let releaseMutation = AsyncSignal()
        let cacheCommitEntered = AsyncSignal()
        let releaseCacheCommit = AsyncSignal()
        await service.setMutationIOWillBeginHandlerForTesting { _ in
            await mutationEntered.signal()
            await releaseMutation.wait()
        }
        await service.setContentReadCacheCommitHandlerForTesting {
            await cacheCommitEntered.signal()
            await releaseCacheCommit.wait()
        }
        let mutationTask = Task {
            try await service.createFile(
                atRelativePath: "Target.swift",
                content: "replacement UTF-8 content\n",
                overwrite: true
            )
        }
        addTeardownBlock {
            await releaseMutation.signal()
            await releaseCacheCommit.signal()
            mutationTask.cancel()
            await service.setMutationIOWillBeginHandlerForTesting(nil)
            await service.setContentReadCacheCommitHandlerForTesting(nil)
            let result = await self.waitForTaskResult(mutationTask)
            XCTAssertNotNil(result)
        }
        guard await waitUntil({ await mutationEntered.isSignaledSnapshot() }) else {
            return XCTFail("Overwrite did not reach its reserved pre-I/O boundary")
        }
        let readTask = Task {
            try await service.loadContent(ofRelativePath: "Target.swift", workloadClass: .interactiveRead)
        }
        addTeardownBlock {
            await releaseCacheCommit.signal()
            readTask.cancel()
            let result = await self.waitForTaskResult(readTask)
            XCTAssertNotNil(result)
        }
        guard await waitUntil({ await cacheCommitEntered.isSignaledSnapshot() }) else {
            return XCTFail("Read did not capture pre-overwrite encoding evidence")
        }
        await releaseMutation.signal()
        guard let mutationResult = await waitForTaskResult(mutationTask) else {
            return XCTFail("Overwrite did not reconcile while the read was paused")
        }
        try mutationResult.get()
        let reconciledEncoding = await service.cachedEncodingForTesting(relativePath: "Target.swift")
        XCTAssertEqual(reconciledEncoding, .utf8)
        await releaseCacheCommit.signal()
        guard let readResult = await waitForTaskResult(readTask) else {
            return XCTFail("Read did not settle after cache commit was released")
        }
        XCTAssertEqual(try readResult.get(), originalContents)
        let finalEncoding = await service.cachedEncodingForTesting(relativePath: "Target.swift")
        XCTAssertEqual(finalEncoding, .utf8)
    }

    func testCacheCommitRejectsInvalidationAfterFinalFingerprint() async throws {
        let rootURL = try makeTemporaryRoot()
        let targetURL = rootURL.appendingPathComponent("Target.swift")
        let originalContents = "original cache content\n"
        try originalContents.write(to: targetURL, atomically: true, encoding: .utf8)
        let service = try await FileSystemService(path: rootURL.path)
        await service.setContentReadCacheCommitHandlerForTesting {
            try? "replacement cache content\n".write(to: targetURL, atomically: true, encoding: .utf8)
            await service.advanceContentReadCacheRevisionForTesting()
        }
        addTeardownBlock {
            await service.setContentReadCacheCommitHandlerForTesting(nil)
        }

        let content = try await service.loadContent(
            ofRelativePath: "Target.swift",
            workloadClass: .interactiveRead
        )

        XCTAssertEqual(content, originalContents)
        let cachedEncoding = await service.cachedEncodingForTesting(relativePath: "Target.swift")
        XCTAssertNil(cachedEncoding)
    }

    func testCancelledWorkspaceInteractiveReadSuppressesCodeMapUntilPhysicalCompletion() async throws {
        let rootURL = try makeTemporaryRoot()
        try "foreground workspace read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }
        let physicalGate = SynchronousPhysicalReadGate()
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            physicalGate.blockUntilReleased()
        }
        let interactiveReadTask = Task { try await store.interactiveReadSnapshot(for: record) }
        guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
            interactiveReadTask.cancel()
            physicalGate.release()
            return XCTFail("Workspace read did not reach its controlled physical boundary")
        }

        let codeMapGranted = AsyncSignal()
        let codeMapTask = Task {
            try await FileSystemService.withCodeMapArtifactBuildPermit(
                ownerID: UUID(),
                priority: .utility
            ) {
                await codeMapGranted.signal()
            }
        }
        addTeardownBlock {
            physicalGate.release()
            interactiveReadTask.cancel()
            codeMapTask.cancel()
            try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil)
            let interactiveResult = await self.waitForTaskResult(interactiveReadTask)
            let codeMapResult = await self.waitForTaskResult(codeMapTask)
            XCTAssertNotNil(interactiveResult, "Workspace read did not settle during teardown")
            XCTAssertNotNil(codeMapResult, "CodeMap permit task did not settle during teardown")
            let teardownSnapshot = await self.waitForLimiterIdle()
            XCTAssertTrue(teardownSnapshot.isIdle)
        }
        let codeMapQueued = await waitUntil {
            let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            return snapshot.foregroundActivityCountsByKind[.interactiveRead] == 2
                && snapshot.activeCodemapPermitCount == 0
                && snapshot.queuedCodemapWaiterCount == 1
        }
        guard codeMapQueued else {
            return XCTFail("CodeMap work was not held behind workspace interactive activity")
        }
        let grantedBeforeCancellation = await codeMapGranted.isSignaledSnapshot()
        XCTAssertFalse(grantedBeforeCancellation)

        interactiveReadTask.cancel()
        guard let cancelledResult = await waitForTaskResult(interactiveReadTask) else {
            physicalGate.release()
            return XCTFail("Cancelled workspace caller did not settle before physical completion")
        }
        do {
            _ = try cancelledResult.get()
            XCTFail("Expected workspace caller cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let cancelledSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(cancelledSnapshot.activePermitCount, 1)
        XCTAssertEqual(cancelledSnapshot.foregroundActivityCountsByKind[.interactiveRead], 1)
        XCTAssertEqual(cancelledSnapshot.activeCodemapPermitCount, 0)
        XCTAssertEqual(cancelledSnapshot.queuedCodemapWaiterCount, 1)
        let grantedAfterCallerCancellation = await codeMapGranted.isSignaledSnapshot()
        XCTAssertFalse(grantedAfterCallerCancellation)

        physicalGate.release()
        guard let codeMapResult = await waitForTaskResult(codeMapTask) else {
            return XCTFail("Queued CodeMap work did not settle after physical release")
        }
        try codeMapResult.get()
        let grantedAfterRelease = await codeMapGranted.isSignaledSnapshot()
        XCTAssertTrue(grantedAfterRelease)
        let finalSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(finalSnapshot.isIdle)
    }

    func testWorkspaceInteractiveReadSuppressesCodeMapBetweenPhysicalStages() async throws {
        let rootURL = try makeTemporaryRoot()
        try "multi-stage foreground read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }
        let fingerprintResolved = AsyncSignal()
        let releaseStageGap = AsyncSignal()
        await store.setInteractiveReadFingerprintDidResolveHandlerForTesting {
            await fingerprintResolved.signal()
            await releaseStageGap.wait()
        }
        let interactiveReadTask = Task { try await store.interactiveReadSnapshot(for: record) }
        guard await waitUntil({ await fingerprintResolved.isSignaledSnapshot() }) else {
            interactiveReadTask.cancel()
            await releaseStageGap.signal()
            return XCTFail("Interactive read did not reach the post-fingerprint stage gap")
        }

        let codeMapGranted = AsyncSignal()
        let codeMapTask = Task {
            try await FileSystemService.withCodeMapArtifactBuildPermit(
                ownerID: UUID(),
                priority: .utility
            ) {
                await codeMapGranted.signal()
            }
        }
        addTeardownBlock {
            await releaseStageGap.signal()
            interactiveReadTask.cancel()
            codeMapTask.cancel()
            await store.setInteractiveReadFingerprintDidResolveHandlerForTesting(nil)
            _ = await self.waitForTaskResult(interactiveReadTask)
            _ = await self.waitForTaskResult(codeMapTask)
            let teardownSnapshot = await self.waitForLimiterIdle()
            XCTAssertTrue(teardownSnapshot.isIdle)
        }
        guard await waitUntil({
            let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            return snapshot.queuedCodemapWaiterCount == 1
        }) else {
            return XCTFail("CodeMap work was not queued behind the fingerprint stage")
        }
        let grantedBetweenStages = await codeMapGranted.isSignaledSnapshot()
        XCTAssertFalse(grantedBetweenStages)
        let stageGapSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(stageGapSnapshot.activePermitCount, 0)
        XCTAssertEqual(stageGapSnapshot.foregroundActivityCountsByKind[.interactiveRead], 1)
        XCTAssertEqual(stageGapSnapshot.activeCodemapPermitCount, 0)
        XCTAssertEqual(stageGapSnapshot.queuedCodemapWaiterCount, 1)

        await releaseStageGap.signal()
        guard let interactiveResult = await waitForTaskResult(interactiveReadTask),
              let codeMapResult = await waitForTaskResult(codeMapTask)
        else {
            return XCTFail("Foreground and CodeMap work did not settle after physical release")
        }
        XCTAssertNotNil(try interactiveResult.get())
        try codeMapResult.get()
        let grantedAfterRead = await codeMapGranted.isSignaledSnapshot()
        XCTAssertTrue(grantedAfterRead)
        let finalSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(finalSnapshot.isIdle)
    }

    func testCancelledAllowlistedExternalReadSuppressesCodeMapUntilPhysicalCompletion() async throws {
        let homeURL = try makeTemporaryRoot()
        let skillsURL = homeURL.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        let fileURL = skillsURL.appendingPathComponent("External.md")
        let contents = "foreground external read\n"
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        let physicalGate = SynchronousPhysicalReadGate()
        let readableService = WorkspaceReadableFileService(
            store: WorkspaceFileContextStore(),
            homeDirectoryURL: homeURL,
            beforeExternalReadOpenForTesting: { _ in physicalGate.blockUntilReleased() }
        )
        let file = WorkspaceExternalReadableFile(
            absolutePath: fileURL.path,
            displayPath: "~/.agents/skills/External.md"
        )
        let externalReadTask = Task { try await readableService.readAlwaysReadableExternalFile(file) }
        guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
            externalReadTask.cancel()
            physicalGate.release()
            return XCTFail("External read did not reach its controlled physical boundary")
        }

        let codeMapGranted = AsyncSignal()
        let codeMapTask = Task {
            try await FileSystemService.withCodeMapArtifactBuildPermit(
                ownerID: UUID(),
                priority: .utility
            ) {
                await codeMapGranted.signal()
            }
        }
        addTeardownBlock {
            physicalGate.release()
            externalReadTask.cancel()
            codeMapTask.cancel()
            let externalResult = await self.waitForTaskResult(externalReadTask)
            let codeMapResult = await self.waitForTaskResult(codeMapTask)
            XCTAssertNotNil(externalResult, "External read did not settle during teardown")
            XCTAssertNotNil(codeMapResult, "CodeMap permit task did not settle during teardown")
            let teardownSnapshot = await self.waitForLimiterIdle()
            XCTAssertTrue(teardownSnapshot.isIdle)
        }
        let codeMapQueued = await waitUntil {
            let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            return snapshot.foregroundActivityCountsByKind[.interactiveRead] == 1
                && snapshot.activeCodemapPermitCount == 0
                && snapshot.queuedCodemapWaiterCount == 1
        }
        guard codeMapQueued else {
            return XCTFail("CodeMap work was not held behind external interactive activity")
        }
        let grantedBeforeRelease = await codeMapGranted.isSignaledSnapshot()
        XCTAssertFalse(grantedBeforeRelease)

        externalReadTask.cancel()
        guard let cancelledExternalResult = await waitForTaskResult(externalReadTask) else {
            physicalGate.release()
            return XCTFail("Cancelled external caller did not settle before physical completion")
        }
        do {
            _ = try cancelledExternalResult.get()
            XCTFail("Expected external caller cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let cancelledSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(cancelledSnapshot.activePermitCount, 1)
        XCTAssertEqual(cancelledSnapshot.foregroundActivityCountsByKind[.interactiveRead], 1)
        XCTAssertEqual(cancelledSnapshot.activeCodemapPermitCount, 0)
        XCTAssertEqual(cancelledSnapshot.queuedCodemapWaiterCount, 1)
        let grantedAfterCallerCancellation = await codeMapGranted.isSignaledSnapshot()
        XCTAssertFalse(grantedAfterCallerCancellation)

        physicalGate.release()
        guard let codeMapResult = await waitForTaskResult(codeMapTask) else {
            return XCTFail("Queued CodeMap work did not settle after physical release")
        }
        try codeMapResult.get()
        let grantedAfterRelease = await codeMapGranted.isSignaledSnapshot()
        XCTAssertTrue(grantedAfterRelease)
        let finalSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(finalSnapshot.isIdle)
    }

    func testSharedLimiterQueueFullPropagatesThroughStoreAndExternalReadPaths() async throws {
        let rootURL = try makeTemporaryRoot()
        try "queue full\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }

        let homeURL = try makeTemporaryRoot()
        let skillsURL = homeURL.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        let externalURL = skillsURL.appendingPathComponent("External.md")
        try "external queue full\n".write(to: externalURL, atomically: true, encoding: .utf8)
        let readableService = WorkspaceReadableFileService(store: store, homeDirectoryURL: homeURL)
        let externalFile = WorkspaceExternalReadableFile(
            absolutePath: externalURL.path,
            displayPath: "~/.agents/skills/External.md"
        )

        guard let saturation = await saturateSharedContentReadLimiter() else {
            return XCTFail("Shared content-read limiter did not reach its production bounds")
        }
        addTeardownBlock {
            let settlement = await self.settleSharedContentReadLimiter(saturation)
            XCTAssertTrue(settlement.activeSettled, "Active saturation tasks did not settle during teardown")
            XCTAssertTrue(settlement.queuedSettled, "Queued saturation tasks did not settle during teardown")
            XCTAssertTrue(settlement.limiterIdle, "Shared limiter was not idle after saturation teardown")
        }
        let expected = ContentReadSchedulerError.queueFull(retryAfterMilliseconds: 1000)

        do {
            _ = try await store.searchContentSnapshot(for: record)
            XCTFail("Expected search fingerprint backpressure")
        } catch {
            XCTAssertEqual(error as? ContentReadSchedulerError, expected)
        }
        do {
            _ = try await store.interactiveReadSnapshot(for: record)
            XCTFail("Expected interactive fingerprint backpressure")
        } catch {
            XCTAssertEqual(error as? ContentReadSchedulerError, expected)
        }
        do {
            _ = try await MCPServerViewModel.prepareAlwaysReadableExternalFileThroughEnvelopeForTesting(
                externalFile,
                readableService: readableService
            )
            XCTFail("Expected view-model external-read backpressure")
        } catch {
            XCTAssertEqual(error as? ContentReadSchedulerError, expected)
        }

        let settlement = await settleSharedContentReadLimiter(saturation)
        XCTAssertTrue(settlement.activeSettled, "Active saturation tasks did not settle")
        XCTAssertTrue(settlement.queuedSettled, "Queued saturation tasks did not settle")
        XCTAssertTrue(settlement.limiterIdle, "Shared limiter was not idle after saturation")
    }

    func testAllowlistedExternalReadCancellationKeepsSharedPermitUntilPhysicalReturn() async throws {
        let homeURL = try makeTemporaryRoot()
        let skillsURL = homeURL.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        let fileURL = skillsURL.appendingPathComponent("External.md")
        try "external read\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let physicalGate = SynchronousPhysicalReadGate()
        addTeardownBlock { physicalGate.release() }
        let readableService = WorkspaceReadableFileService(
            store: WorkspaceFileContextStore(),
            homeDirectoryURL: homeURL,
            beforeExternalReadOpenForTesting: { _ in physicalGate.blockUntilReleased() }
        )
        let file = WorkspaceExternalReadableFile(absolutePath: fileURL.path, displayPath: "~/.agents/skills/External.md")
        let task = Task { try await readableService.readAlwaysReadableExternalFile(file) }
        let physicalReadDidBlock = await waitUntil { physicalGate.isBlockedSnapshot() }
        guard physicalReadDidBlock else {
            task.cancel()
            physicalGate.release()
            return XCTFail("External read did not reach the controlled open gate")
        }

        task.cancel()
        guard let taskResult = await waitForTaskResult(task) else {
            physicalGate.release()
            return XCTFail("External read caller did not settle after cancellation")
        }
        do {
            _ = try taskResult.get()
            XCTFail("Expected external read cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let blockedSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        XCTAssertEqual(blockedSnapshot.activePermitCount, 1)
        XCTAssertFalse(blockedSnapshot.isIdle)

        physicalGate.release()
        let idleSnapshot = await waitForLimiterIdle()
        XCTAssertTrue(idleSnapshot.isIdle)
    }

    func testStreamedDecodeUsesReadFileRecorderCapturedBeforeDetachment() async throws {
        let rootURL = try makeTemporaryRoot()
        let contents = "first\nsecond\nthird\n"
        try contents.write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let service = try await FileSystemService(path: rootURL.path)
        MCPToolWorkCountDiagnostics.resetForTesting()
        addTeardownBlock { MCPToolWorkCountDiagnostics.resetForTesting() }

        try await MCPToolWorkCountDiagnostics.withReadFileInvocation {
            let loaded = try await service.loadEntireFileContentOptimized(
                ofRelativePath: "Target.swift",
                chunkSize: 4,
                workloadClass: .interactiveRead
            )
            XCTAssertEqual(loaded, contents)
        }

        let snapshots = MCPToolWorkCountDiagnostics.debugSnapshots().readFile
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.source, "disk")
        XCTAssertEqual(snapshots.first?.readBytes, contents.utf8.count)
        XCTAssertEqual(snapshots.first?.diskReadRecordCount, 2)
    }

    private func saturateSharedContentReadLimiter() async -> SharedLimiterSaturation? {
        let initialSnapshot = await waitForLimiterIdle()
        guard initialSnapshot.isIdle else { return nil }

        let releaseActiveReads = AsyncSignal()
        let activeTasks: [Task<Void, Error>] = (0 ..< initialSnapshot.capacity).map { _ in
            Task {
                try await FileSystemService.withCancellationResponsivePhysicalReadPermit(
                    workloadClass: .interactiveRead,
                    schedulerOwnerID: UUID(),
                    priority: .userInitiated
                ) {
                    await releaseActiveReads.wait()
                }
            }
        }
        let allPermitsHeld = await waitUntil {
            let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            return snapshot.activePermitCount == snapshot.capacity
        }
        guard allPermitsHeld else {
            _ = await settleSharedContentReadLimiter(
                SharedLimiterSaturation(
                    releaseActiveReads: releaseActiveReads,
                    activeTasks: activeTasks,
                    queuedTasks: []
                )
            )
            return nil
        }

        let queuedTasks: [Task<Void, Error>] = (0 ..< initialSnapshot.maxQueuedWaiterCount).map { _ in
            Task {
                try await FileSystemService.withCancellationResponsivePhysicalReadPermit(
                    workloadClass: .contentSearch,
                    schedulerOwnerID: UUID(),
                    priority: .utility
                ) {}
            }
        }
        let queueDidFill = await waitUntil {
            let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            return snapshot.activePermitCount == snapshot.capacity
                && snapshot.queuedWaiterCount == snapshot.maxQueuedWaiterCount
        }
        let saturation = SharedLimiterSaturation(
            releaseActiveReads: releaseActiveReads,
            activeTasks: activeTasks,
            queuedTasks: queuedTasks
        )
        guard queueDidFill else {
            _ = await settleSharedContentReadLimiter(saturation)
            return nil
        }
        return saturation
    }

    private func settleSharedContentReadLimiter(
        _ saturation: SharedLimiterSaturation
    ) async -> SharedLimiterSettlement {
        await saturation.releaseActiveReads.signal()
        saturation.activeTasks.forEach { $0.cancel() }
        saturation.queuedTasks.forEach { $0.cancel() }
        let activeResults = await waitForTaskResults(saturation.activeTasks)
        let queuedResults = await waitForTaskResults(saturation.queuedTasks)
        let finalSnapshot = await waitForLimiterIdle()
        return SharedLimiterSettlement(
            activeSettled: activeResults != nil,
            queuedSettled: queuedResults != nil,
            limiterIdle: finalSnapshot.isIdle
        )
    }

    private func waitForLimiterIdle() async -> ContentReadAsyncLimiter.Snapshot {
        for _ in 0 ..< 10000 {
            let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            if snapshot.isIdle {
                return snapshot
            }
            await Task.yield()
        }
        return await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
    }

    private func waitForLimiterSnapshot(
        _ limiter: ContentReadAsyncLimiter,
        matching predicate: (ContentReadAsyncLimiter.Snapshot) -> Bool
    ) async -> ContentReadAsyncLimiter.Snapshot {
        for _ in 0 ..< 10000 {
            let snapshot = await limiter.snapshotForTesting()
            if predicate(snapshot) {
                return snapshot
            }
            await Task.yield()
        }
        return await limiter.snapshotForTesting()
    }

    private func waitForCacheSnapshot(
        _ cache: WorkspaceInteractiveReadCache,
        matching predicate: (WorkspaceInteractiveReadCache.Snapshot) -> Bool
    ) async -> WorkspaceInteractiveReadCache.Snapshot {
        for _ in 0 ..< 10000 {
            let snapshot = await cache.snapshotForTesting()
            if predicate(snapshot) {
                return snapshot
            }
            await Task.yield()
        }
        return await cache.snapshotForTesting()
    }

    private func waitUntil(
        iterations: Int = 10000,
        _ predicate: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< iterations {
            if await predicate() {
                return true
            }
            await Task.yield()
        }
        return await predicate()
    }

    private func waitForTaskResult<Success: Sendable, Failure: Error & Sendable>(
        _ task: Task<Success, Failure>
    ) async -> Result<Success, Failure>? {
        let recorder = TaskResultRecorder<Success, Failure>()
        Task { await recorder.record(task.result) }
        guard await waitUntil({ await recorder.hasResult() }) else { return nil }
        return await recorder.snapshot()
    }

    private func waitForTaskResults<Success: Sendable, Failure: Error & Sendable>(
        _ tasks: [Task<Success, Failure>]
    ) async -> [Result<Success, Failure>]? {
        let recorder = TaskResultsRecorder<Success, Failure>(expectedCount: tasks.count)
        for (index, task) in tasks.enumerated() {
            Task { await recorder.record(task.result, at: index) }
        }
        guard await waitUntil({ await recorder.isComplete() }) else { return nil }
        return await recorder.snapshot()
    }

    private func makeInteractiveReadCacheKey() -> WorkspaceInteractiveReadCacheKey {
        WorkspaceInteractiveReadCacheKey(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            fileID: UUID(),
            standardizedRelativePath: "Target.swift"
        )
    }

    private func makeFingerprint() -> FileContentFingerprint {
        FileContentFingerprint(
            deviceID: 1,
            fileNumber: 2,
            byteSize: 3,
            modificationSeconds: 4,
            modificationNanoseconds: 5,
            statusChangeSeconds: 6,
            statusChangeNanoseconds: 7
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("ContentReadCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

@MainActor
private func runMainActorProviderTask(
    store: WorkspaceFileContextStore,
    record: WorkspaceFileRecord,
    roots: [WorkspaceRootRef]
) async throws {
    // `MCPServerViewModel.runTool` creates this task while isolated to MainActor.
    let providerTask = Task {
        let readableService = WorkspaceReadableFileService(store: store)
        let resolution = try await readableService.resolveReadFileRequest(
            .relative(record.standardizedRelativePath),
            rootScope: .visibleWorkspace,
            rootRefs: roots,
            namespace: .identity(roots: roots)
        )
        guard case let .workspace(match) = resolution else {
            throw PhysicalReadTestError.syntheticFailure
        }
        _ = try await store.interactiveReadSnapshot(for: match.file)
    }
    return try await withTaskCancellationHandler {
        try await providerTask.value
    } onCancel: {
        providerTask.cancel()
    }
}

@MainActor
private func runAppBinderProviderTask<T: Sendable>(
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    // `MCPServerViewModel.runTool` creates this task while isolated to MainActor.
    let providerTask = Task {
        try Task.checkCancellation()
        return try await operation()
    }
    return try await withTaskCancellationHandler {
        try await providerTask.value
    } onCancel: {
        providerTask.cancel()
    }
}

private func runDomainHostProviderTask(
    operation: @Sendable @escaping () async throws -> Void
) async throws {
    // `MCPDomainHost.invoke` owns an unstructured invocation task and forwards caller cancellation.
    let invocationTask = Task {
        try Task.checkCancellation()
        try await operation()
    }
    return try await withTaskCancellationHandler {
        try await invocationTask.value
    } onCancel: {
        invocationTask.cancel()
    }
}

private func runDomainReadProviderTask(
    store: WorkspaceFileContextStore,
    record: WorkspaceFileRecord,
    roots: [WorkspaceRootRef]
) async throws {
    try await runDomainReadProviderTask(path: record.standardizedRelativePath) {
        try await runMainActorProviderTask(store: store, record: record, roots: roots)
    }
}

private func runDomainReadProviderTask(
    path: String,
    operation: @Sendable @escaping () async throws -> Void
) async throws {
    let runtimeIdentity = DomainRuntimeIdentity(
        runtimeID: UUID(),
        lifecycleGeneration: 1,
        processID: 949,
        mode: .app,
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let connectionID = UUID()
    let context = DomainReadInvocationContext(
        handle: DomainReadContextHandle(
            runtimeID: runtimeIdentity.runtimeID,
            runtimeGeneration: runtimeIdentity.lifecycleGeneration,
            connectionID: connectionID,
            connectionGeneration: 1,
            context: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            workspaceRevision: 1,
            contextRevision: 1,
            routingRevision: 1,
            bindingKind: .explicit
        ),
        connectionID: connectionID
    )
    let provider = MCPDomainReadToolProvider(
        resolveContext: { _, _ in context },
        backend: MCPDomainReadToolBackend { _, _, _, _ in
            try await operation()
            return .null
        },
        sideEffects: DomainReadSideEffectCoordinator(identity: runtimeIdentity)
    )
    let readFile = try XCTUnwrap(provider.binding(named: MCPWindowToolName.readFile))
    _ = try await readFile(["path": .string(path)])
}

private struct SharedLimiterSaturation {
    let releaseActiveReads: AsyncSignal
    let activeTasks: [Task<Void, Error>]
    let queuedTasks: [Task<Void, Error>]
}

private struct SharedLimiterSettlement {
    let activeSettled: Bool
    let queuedSettled: Bool
    let limiterIdle: Bool
}

private actor AsyncSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if isSignaled {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func isSignaledSnapshot() -> Bool {
        isSignaled
    }
}

private actor CancellableTestGate {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    private func cancel(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }

    func releaseAll() {
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor TaskResultRecorder<Success: Sendable, Failure: Error & Sendable> {
    private var result: Result<Success, Failure>?

    func record(_ result: Result<Success, Failure>) {
        self.result = result
    }

    func hasResult() -> Bool {
        result != nil
    }

    func snapshot() -> Result<Success, Failure>? {
        result
    }
}

private actor TaskResultsRecorder<Success: Sendable, Failure: Error & Sendable> {
    private let expectedCount: Int
    private var results: [Int: Result<Success, Failure>] = [:]

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func record(_ result: Result<Success, Failure>, at index: Int) {
        results[index] = result
    }

    func isComplete() -> Bool {
        results.count == expectedCount
    }

    func snapshot() -> [Result<Success, Failure>]? {
        guard isComplete() else { return nil }
        return (0 ..< expectedCount).compactMap { results[$0] }
    }
}

private enum PhysicalReadTestError: Error {
    case syntheticFailure
}

private final class SendableObjectRetention: @unchecked Sendable {
    private let object: AnyObject

    init(_ object: AnyObject) {
        self.object = object
    }
}

private final class SynchronousPhysicalReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blockedCount = 0
    private var isReleased = false

    func blockUntilReleased() {
        condition.lock()
        blockedCount += 1
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func isBlockedSnapshot() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return blockedCount > 0
    }

    func blockedCountSnapshot() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return blockedCount
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class SynchronousInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func recordInvocation() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class PeriodicPhysicalReadGates: @unchecked Sendable {
    private let condition = NSCondition()
    private var probeCount = 0
    private var blockedIndices: Set<Int> = []
    private var releasedIndices: Set<Int> = []
    private let interval: Int
    private let gates: Int

    init(interval: Int, count: Int) {
        self.interval = interval
        gates = count
    }

    func reachNextProbe() {
        condition.lock()
        probeCount += 1
        guard probeCount.isMultiple(of: interval) else {
            condition.unlock()
            return
        }
        let index = probeCount / interval - 1
        guard index < gates else {
            condition.unlock()
            return
        }
        blockedIndices.insert(index)
        condition.broadcast()
        while !releasedIndices.contains(index) {
            condition.wait()
        }
        condition.unlock()
    }

    func isBlocked(at index: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return blockedIndices.contains(index)
    }

    func releaseAll() {
        condition.lock()
        releasedIndices.formUnion(0 ..< gates)
        condition.broadcast()
        condition.unlock()
    }
}

private final class PhysicalReadAttributionRecorder: @unchecked Sendable {
    struct Snapshot {
        let lifecycleCorrelationID: UUID?
        let benchmarkMetricTag: WorktreeStartupInstrumentation.BenchmarkMetricTag?
    }

    private let lock = NSLock()
    private var value: Snapshot?

    func record(
        lifecycleCorrelationID: UUID?,
        benchmarkMetricTag: WorktreeStartupInstrumentation.BenchmarkMetricTag?
    ) {
        lock.lock()
        value = Snapshot(
            lifecycleCorrelationID: lifecycleCorrelationID,
            benchmarkMetricTag: benchmarkMetricTag
        )
        lock.unlock()
    }

    func snapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private actor ControlledWatchdogSleeps {
    private let clock: SynchronousDurationClock
    private var registeredCount = 0
    private var sleepers: [(duration: Duration, continuation: CheckedContinuation<Void, Error>)] = []

    init(clock: SynchronousDurationClock) {
        self.clock = clock
    }

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            registeredCount += 1
            sleepers.append((duration, continuation))
        }
    }

    func registeredCountSnapshot() -> Int {
        registeredCount
    }

    func pendingCountSnapshot() -> Int {
        sleepers.count
    }

    @discardableResult
    func releaseNext() -> Bool {
        guard !sleepers.isEmpty else { return false }
        let sleeper = sleepers.removeFirst()
        clock.advance(by: sleeper.duration)
        sleeper.continuation.resume()
        return true
    }

    func releaseAll() {
        let pending = sleepers
        sleepers.removeAll()
        pending.forEach { $0.continuation.resume() }
    }
}

private final class SynchronousDurationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Duration.zero

    func now() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by duration: Duration) {
        lock.lock()
        instant += duration
        lock.unlock()
    }
}

private actor WatchdogEventRecorder {
    private var events: [MCPToolExecutionWatchdogEvent] = []

    func record(_ event: MCPToolExecutionWatchdogEvent) {
        events.append(event)
    }

    func snapshot() -> [MCPToolExecutionWatchdogEvent] {
        events
    }
}

private actor SettlementRecorder {
    private var settlement: MCPToolExecutionSettlement?

    func record(_ settlement: MCPToolExecutionSettlement) {
        self.settlement = settlement
    }

    func snapshot() -> MCPToolExecutionSettlement? {
        settlement
    }
}
