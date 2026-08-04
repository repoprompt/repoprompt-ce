import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainHostTests: XCTestCase {
    func testHostResolvesAndInvokesExactRegisteredBinding() async throws {
        let fixture = try await makeFixture()
        let resolution = try await fixture.runtime.domainHost.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: MCPDomainToolRegistrationScope.window(id: 1)
        )
        let invocationID = UUID()
        let value = try await fixture.runtime.domainHost.invoke(MCPDomainHostInvocation(
            invocationID: invocationID,
            connectionID: fixture.connection.connectionID,
            resolution: resolution,
            arguments: ["path": .string("README.md")],
            securityContext: securityContext(
                identity: fixture.runtime.identity,
                connection: fixture.connection,
                invocationID: invocationID
            )
        ))

        XCTAssertEqual(value.stringValue, "README.md")
        let snapshot = await fixture.runtime.domainHost.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .accepting)
        XCTAssertEqual(snapshot.activeInvocationCount, 0)
        XCTAssertEqual(snapshot.connectionsWithActiveInvocationsCount, 0)
    }

    func testHostCarriesAdmittedContextIntoHostOwnedExecutionTask() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let fixture = try await makeFixture(binding: Self.binding { _ in
            guard let admitted = MCPDomainAdmittedContextValues.current else {
                return .string("missing")
            }
            return .string(
                "\(admitted.connectionID.uuidString)|\(admitted.windowID)|" +
                    "\(admitted.workspaceID.uuidString)|\(admitted.contextID.uuidString)"
            )
        })
        let resolution = try await fixture.runtime.domainHost.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: MCPDomainToolRegistrationScope.window(id: 1)
        )
        let invocationID = UUID()
        let admitted = MCPDomainAdmittedContext(
            connectionID: fixture.connection.connectionID,
            windowID: 1,
            workspaceID: workspaceID,
            contextID: contextID
        )

        let value = try await fixture.runtime.domainHost.invoke(MCPDomainHostInvocation(
            invocationID: invocationID,
            connectionID: fixture.connection.connectionID,
            resolution: resolution,
            arguments: [:],
            securityContext: securityContext(
                identity: fixture.runtime.identity,
                connection: fixture.connection,
                invocationID: invocationID
            ),
            admittedContext: admitted
        ))

        XCTAssertEqual(
            value.stringValue,
            "\(fixture.connection.connectionID.uuidString)|1|\(workspaceID.uuidString)|\(contextID.uuidString)"
        )
        XCTAssertNil(MCPDomainAdmittedContextValues.current)
    }

    func testHostRejectsStaleResolutionAfterRegistrationReplacement() async throws {
        let fixture = try await makeFixture()
        let stale = try await fixture.runtime.domainHost.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: MCPDomainToolRegistrationScope.window(id: 1)
        )
        _ = try await fixture.runtime.toolRegistry.registerWithResult(
            registrationID: fixture.registrationID,
            scope: MCPDomainToolRegistrationScope.window(id: 1),
            bindings: [Self.binding(description: "replacement")]
        )
        let invocationID = UUID()

        do {
            _ = try await fixture.runtime.domainHost.invoke(MCPDomainHostInvocation(
                invocationID: invocationID,
                connectionID: fixture.connection.connectionID,
                resolution: stale,
                arguments: [:],
                securityContext: securityContext(
                    identity: fixture.runtime.identity,
                    connection: fixture.connection,
                    invocationID: invocationID
                )
            ))
            XCTFail("Stale host resolution invoked a replacement binding")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .staleRegistration(toolName: MCPWindowToolName.readFile))
        }
    }

    func testConnectionCancellationAndDrainRejectNewInvocation() async throws {
        let blocker = InvocationBlocker()
        let fixture = try await makeFixture(binding: Self.binding { arguments in
            await blocker.wait()
            return arguments["path"] ?? .string("done")
        })
        let resolution = try await fixture.runtime.domainHost.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: MCPDomainToolRegistrationScope.window(id: 1)
        )
        let invocationID = UUID()
        let invocation = MCPDomainHostInvocation(
            invocationID: invocationID,
            connectionID: fixture.connection.connectionID,
            resolution: resolution,
            arguments: ["path": .string("settled")],
            securityContext: securityContext(
                identity: fixture.runtime.identity,
                connection: fixture.connection,
                invocationID: invocationID
            )
        )
        let task = Task { try await fixture.runtime.domainHost.invoke(invocation) }
        await blocker.awaitStarted()

        await fixture.runtime.domainHost.cancelInvocations(
            connectionID: fixture.connection.connectionID,
            connectionGeneration: fixture.connection.generation
        )
        let draining = await fixture.runtime.domainHost.drain(timeout: Duration.milliseconds(10))
        XCTAssertTrue(draining.deadlineExpired)
        XCTAssertFalse(draining.callerCancelled)
        XCTAssertEqual(draining.detachedInvocationCount, 1)

        let rejectedID = UUID()
        do {
            _ = try await fixture.runtime.domainHost.invoke(MCPDomainHostInvocation(
                invocationID: rejectedID,
                connectionID: fixture.connection.connectionID,
                resolution: resolution,
                arguments: [:],
                securityContext: securityContext(
                    identity: fixture.runtime.identity,
                    connection: fixture.connection,
                    invocationID: rejectedID
                )
            ))
            XCTFail("Draining host accepted a new invocation")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .draining)
        }

        await blocker.resume()
        _ = try await task.value
        let final = await fixture.runtime.domainHost.snapshot()
        XCTAssertEqual(final.lifecycle, MCPDomainHostLifecycle.drained)
        XCTAssertEqual(final.activeInvocationCount, 0)
    }

    func testTerminalConnectionFenceIsReleasedOnlyAfterRoutingRemovalAndSettlement() async throws {
        let blocker = InvocationBlocker()
        let fixture = try await makeFixture(binding: Self.binding { _ in
            await blocker.wait()
            return .string("settled")
        })
        let resolution = try await fixture.runtime.domainHost.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: .window(id: 1)
        )
        let invocationID = UUID()
        let invocation = MCPDomainHostInvocation(
            invocationID: invocationID,
            connectionID: fixture.connection.connectionID,
            resolution: resolution,
            arguments: [:],
            securityContext: securityContext(
                identity: fixture.runtime.identity,
                connection: fixture.connection,
                invocationID: invocationID
            )
        )
        let task = Task { try await fixture.runtime.domainHost.invoke(invocation) }
        await blocker.awaitStarted()

        await fixture.runtime.domainHost.cancelInvocations(
            connectionID: fixture.connection.connectionID,
            connectionGeneration: fixture.connection.generation
        )
        _ = await fixture.runtime.routingCoordinator.unregisterConnection(
            fixture.connection,
            operationID: UUID()
        )
        await fixture.runtime.domainHost.releaseConnection(
            connectionID: fixture.connection.connectionID,
            connectionGeneration: fixture.connection.generation
        )
        var snapshot = await fixture.runtime.domainHost.snapshot()
        XCTAssertEqual(snapshot.terminalConnectionFenceCount, 1)

        await blocker.resume()
        _ = try await task.value
        snapshot = await fixture.runtime.domainHost.snapshot()
        XCTAssertEqual(snapshot.terminalConnectionFenceCount, 0)
    }

    func testTerminalConnectionFenceReleasesImmediatelyWhenNoInvocationIsActive() async throws {
        let fixture = try await makeFixture()
        await fixture.runtime.domainHost.cancelInvocations(
            connectionID: fixture.connection.connectionID,
            connectionGeneration: fixture.connection.generation
        )
        _ = await fixture.runtime.routingCoordinator.unregisterConnection(
            fixture.connection,
            operationID: UUID()
        )
        await fixture.runtime.domainHost.releaseConnection(
            connectionID: fixture.connection.connectionID,
            connectionGeneration: fixture.connection.generation
        )
        let snapshot = await fixture.runtime.domainHost.snapshot()
        XCTAssertEqual(snapshot.terminalConnectionFenceCount, 0)
    }

    func testDrainRacingSuspendedAdmissionRejectsLateInvocation() async throws {
        let admissionGate = InvocationBlocker()
        let fixture = try await makeFixture()
        let host = MCPDomainHost(
            identity: fixture.runtime.identity,
            registry: fixture.runtime.toolRegistry,
            routingCoordinator: fixture.runtime.routingCoordinator,
            beforeFinalAdmission: { await admissionGate.wait() }
        )
        let resolution = try await host.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: MCPDomainToolRegistrationScope.window(id: 1)
        )
        let invocationID = UUID()
        let invocation = MCPDomainHostInvocation(
            invocationID: invocationID,
            connectionID: fixture.connection.connectionID,
            resolution: resolution,
            arguments: [:],
            securityContext: securityContext(
                identity: fixture.runtime.identity,
                connection: fixture.connection,
                invocationID: invocationID
            )
        )
        let invocationTask = Task {
            try await host.invoke(invocation)
        }
        await admissionGate.awaitStarted()

        let drain = await host.drain(timeout: .milliseconds(25))
        XCTAssertFalse(drain.deadlineExpired)
        XCTAssertFalse(drain.callerCancelled)
        XCTAssertEqual(drain.detachedInvocationCount, 0)
        await admissionGate.resume()

        do {
            _ = try await invocationTask.value
            XCTFail("Invocation crossed the final admission fence after drain")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .draining)
        }
        let snapshot = await host.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .drained)
        XCTAssertEqual(snapshot.activeInvocationCount, 0)
    }

    func testConnectionCancellationFencesSuspendedFinalAdmission() async throws {
        let admissionGate = InvocationBlocker()
        let invocationCounter = InvocationCounter()
        let fixture = try await makeFixture(binding: Self.binding { _ in
            await invocationCounter.increment()
            return .string("unexpected")
        })
        let host = MCPDomainHost(
            identity: fixture.runtime.identity,
            registry: fixture.runtime.toolRegistry,
            routingCoordinator: fixture.runtime.routingCoordinator,
            beforeFinalAdmission: { await admissionGate.wait() }
        )
        let resolution = try await host.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: .window(id: 1)
        )
        let invocationID = UUID()
        let invocation = MCPDomainHostInvocation(
            invocationID: invocationID,
            connectionID: fixture.connection.connectionID,
            resolution: resolution,
            arguments: [:],
            securityContext: securityContext(
                identity: fixture.runtime.identity,
                connection: fixture.connection,
                invocationID: invocationID
            )
        )
        let task = Task {
            try await host.invoke(invocation)
        }
        await admissionGate.awaitStarted()

        await host.cancelInvocations(
            connectionID: fixture.connection.connectionID,
            connectionGeneration: fixture.connection.generation
        )
        await admissionGate.resume()

        do {
            _ = try await task.value
            XCTFail("Connection cancellation allowed suspended admission to run")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .connectionRegistrationInvalid)
        }
        let invocationCount = await invocationCounter.value()
        XCTAssertEqual(invocationCount, 0)
    }

    func testDuplicateInvocationIDIsFencedAtFinalAdmission() async throws {
        let admissionBarrier = InvocationAdmissionBarrier(expectedArrivalCount: 2)
        let invocationCounter = InvocationCounter()
        let fixture = try await makeFixture(binding: Self.binding { _ in
            await invocationCounter.increment()
            return .string("ok")
        })
        let host = MCPDomainHost(
            identity: fixture.runtime.identity,
            registry: fixture.runtime.toolRegistry,
            routingCoordinator: fixture.runtime.routingCoordinator,
            beforeFinalAdmission: { await admissionBarrier.arriveAndWait() }
        )
        let resolution = try await host.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: .window(id: 1)
        )
        let invocationID = UUID()
        let invocation = MCPDomainHostInvocation(
            invocationID: invocationID,
            connectionID: fixture.connection.connectionID,
            resolution: resolution,
            arguments: [:],
            securityContext: securityContext(
                identity: fixture.runtime.identity,
                connection: fixture.connection,
                invocationID: invocationID
            )
        )
        let first = Task { () -> Error? in
            do {
                _ = try await host.invoke(invocation)
                return nil
            } catch {
                return error
            }
        }
        let second = Task { () -> Error? in
            do {
                _ = try await host.invoke(invocation)
                return nil
            } catch {
                return error
            }
        }
        await admissionBarrier.awaitAllArrivals()
        await admissionBarrier.release()

        let errors = await [first.value, second.value]
        XCTAssertEqual(errors.filter { $0 == nil }.count, 1)
        let duplicateErrors = errors.compactMap { $0 as? MCPDomainHostError }
        XCTAssertEqual(duplicateErrors, [.duplicateInvocationID(invocationID)])
        let invocationCount = await invocationCounter.value()
        XCTAssertEqual(invocationCount, 1)
    }

    func testDrainClosesResourceAdmissionAndWaitsForActiveLease() async throws {
        let fixture = try await makeFixture()
        let host = fixture.runtime.domainHost
        let lease = try await host.acquireMutationResourceAdmission(.appWide)
        let waiter = Task { () -> Error? in
            do {
                _ = try await host.acquireMutationResourceAdmission(.appWide)
                return nil
            } catch {
                return error
            }
        }
        for _ in 0 ..< 100 {
            if await host.snapshot().resourceAdmissionWaiterCount == 1 { break }
            await Task.yield()
        }
        let queuedSnapshot = await host.snapshot()
        XCTAssertEqual(queuedSnapshot.resourceAdmissionWaiterCount, 1)

        let drainTask = Task { await host.drain(timeout: .seconds(1)) }
        let waiterError = await waiter.value
        XCTAssertEqual(
            waiterError as? MCPDomainToolResourceAdmissionController.AdmissionError,
            .closed
        )
        XCTAssertTrue(lease.release())
        let drain = await drainTask.value
        XCTAssertFalse(drain.deadlineExpired)
        XCTAssertEqual(drain.detachedInvocationCount, 0)
        let snapshot = await host.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .drained)
        XCTAssertEqual(snapshot.activeResourceAdmissionLeaseCount, 0)
        XCTAssertEqual(snapshot.resourceAdmissionWaiterCount, 0)

        do {
            _ = try await host.acquireMutationResourceAdmission(.appWide)
            XCTFail("Drained host issued a new resource lease")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .draining)
        }
    }

    func testHostOwnsCanonicalCatalogAndCallPolicyDecisions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-domain-host-policy-\(UUID().uuidString)", isDirectory: true)
        let runtime = MCPDomainRuntime(
            configuration: .init(
                mode: .standalone,
                profileIdentifier: "host-policy-test",
                storageDirectory: directory,
                eventDirectory: directory,
                temporaryDirectory: directory,
                externalReloadInterval: nil
            )
        )
        try await runtime.start()
        _ = try await runtime.toolRegistry.register(
            registrationID: MCPDomainToolRegistrationID(),
            scope: .window(id: 1),
            bindings: [
                Self.binding(toolName: MCPWindowToolName.readFile),
                Self.binding(toolName: MCPWindowToolName.askUser),
                Self.binding(toolName: MCPWindowToolName.agentExplore),
            ]
        )

        let directPolicy = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [MCPWindowToolName.askUser],
            additionalToolNames: [],
            role: .direct,
            allowsAgentExternalControlTools: false
        )
        let advertisement = await runtime.domainHost.advertisedCatalog(
            MCPDomainCatalogAdvertisementRequest(
                isGloballyEnabled: true,
                disabledToolNames: [MCPWindowToolName.readFile],
                policy: directPolicy
            )
        )
        XCTAssertTrue(advertisement.definitions.isEmpty)
        XCTAssertEqual(advertisement.hiddenReasonsByToolName[MCPWindowToolName.readFile], .disabled)
        XCTAssertEqual(advertisement.hiddenReasonsByToolName[MCPWindowToolName.askUser], .restricted)
        XCTAssertEqual(advertisement.hiddenReasonsByToolName[MCPWindowToolName.agentExplore], .roleAdvertisementPolicy)

        do {
            try await runtime.domainHost.evaluateEarlyCallPolicy(
                toolName: MCPWindowToolName.askUser,
                policy: directPolicy
            )
            XCTFail("Missing additional grant passed early policy")
        } catch let denial as MCPDomainCallPolicyDenial {
            XCTAssertEqual(denial, .missingAdditionalGrant(toolName: MCPWindowToolName.askUser))
        }

        let grantedPolicy = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [MCPWindowToolName.askUser],
            additionalToolNames: [MCPWindowToolName.askUser],
            role: .direct,
            allowsAgentExternalControlTools: false
        )
        try await runtime.domainHost.evaluateEarlyCallPolicy(
            toolName: MCPWindowToolName.askUser,
            policy: grantedPolicy
        )
        do {
            _ = try await runtime.domainHost.evaluatePreAdmissionCallPolicy(
                toolName: MCPWindowToolName.askUser,
                policy: grantedPolicy
            )
            XCTFail("Restricted tool passed pre-admission policy")
        } catch let denial as MCPDomainCallPolicyDenial {
            XCTAssertEqual(denial, .restricted(toolName: MCPWindowToolName.askUser))
        }
        do {
            _ = try await runtime.domainHost.evaluatePreAdmissionCallPolicy(
                toolName: MCPWindowToolName.agentExplore,
                policy: directPolicy
            )
            XCTFail("Role-hidden agent_explore passed pre-admission policy")
        } catch let denial as MCPDomainCallPolicyDenial {
            XCTAssertEqual(denial, .roleUnavailable(toolName: MCPWindowToolName.agentExplore))
        }

        let readDecision = try await runtime.domainHost.evaluatePreAdmissionCallPolicy(
            toolName: MCPWindowToolName.readFile,
            policy: directPolicy
        )
        XCTAssertEqual(readDecision.admissionClass, .smallRead)

        let disabled = await runtime.domainHost.advertisedCatalog(
            MCPDomainCatalogAdvertisementRequest(
                isGloballyEnabled: false,
                disabledToolNames: [],
                policy: directPolicy
            )
        )
        XCTAssertTrue(disabled.definitions.isEmpty)
        XCTAssertTrue(disabled.hiddenReasonsByToolName.isEmpty)
    }

    func testHostOwnsRequestProgressLifecycleAcrossFinishAndConnectionCancellation() async throws {
        let fixture = try await makeFixture()
        let transport = DomainProgressRecorder()
        let invocationID = UUID()
        let optionalHandle = await fixture.runtime.domainHost.beginRequestProgress(
            connectionID: fixture.connection.connectionID,
            connectionGeneration: fixture.connection.generation,
            invocationID: invocationID,
            token: .string("host-progress")
        )
        let handle = try XCTUnwrap(optionalHandle)

        await fixture.runtime.domainHost.sendRequestProgress(
            handle,
            through: transport,
            message: "first"
        )
        await transport.waitUntilCount(1)
        await fixture.runtime.domainHost.finishRequestProgress(handle)
        await fixture.runtime.domainHost.sendRequestProgress(
            handle,
            through: transport,
            message: "late-after-finish"
        )
        try await Task.sleep(for: .milliseconds(5))
        let messagesAfterFinish = await transport.messages()
        XCTAssertEqual(messagesAfterFinish, ["first"])

        let optionalCancelledHandle = await fixture.runtime.domainHost.beginRequestProgress(
            connectionID: fixture.connection.connectionID,
            connectionGeneration: fixture.connection.generation,
            invocationID: UUID(),
            token: .integer(2)
        )
        let cancelledHandle = try XCTUnwrap(optionalCancelledHandle)
        await fixture.runtime.domainHost.cancelInvocations(
            connectionID: fixture.connection.connectionID,
            connectionGeneration: fixture.connection.generation
        )
        await fixture.runtime.domainHost.sendRequestProgress(
            cancelledHandle,
            through: transport,
            message: "late-after-close"
        )
        try await Task.sleep(for: .milliseconds(5))
        let messagesAfterCancellation = await transport.messages()
        XCTAssertEqual(messagesAfterCancellation, ["first"])
    }

    func testCancelledDrainCallerReturnsWithoutSpinning() async throws {
        let blocker = InvocationBlocker()
        let fixture = try await makeFixture(binding: Self.binding { arguments in
            await blocker.wait()
            return arguments["path"] ?? .string("settled")
        })
        let resolution = try await fixture.runtime.domainHost.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: MCPDomainToolRegistrationScope.window(id: 1)
        )
        let invocationID = UUID()
        let invocation = MCPDomainHostInvocation(
            invocationID: invocationID,
            connectionID: fixture.connection.connectionID,
            resolution: resolution,
            arguments: [:],
            securityContext: securityContext(
                identity: fixture.runtime.identity,
                connection: fixture.connection,
                invocationID: invocationID
            )
        )
        let host = fixture.runtime.domainHost
        let invocationTask = Task {
            try await host.invoke(invocation)
        }
        await blocker.awaitStarted()
        await fixture.runtime.domainHost.beginDrain()

        let clock = ContinuousClock()
        let startedAt = clock.now
        let drainTask = Task {
            await fixture.runtime.domainHost.drain(timeout: .seconds(5))
        }
        drainTask.cancel()
        let drain = await drainTask.value
        XCTAssertTrue(drain.callerCancelled)
        XCTAssertFalse(drain.deadlineExpired)
        XCTAssertEqual(drain.detachedInvocationCount, 1)
        XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(250))

        await blocker.resume()
        _ = try await invocationTask.value
    }

    private struct Fixture {
        let runtime: MCPDomainRuntime
        let connection: DomainConnectionRegistration
        let registrationID: MCPDomainToolRegistrationID
    }

    private func makeFixture(
        binding: MCPDomainToolBinding = MCPDomainHostTests.binding()
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-domain-host-\(UUID().uuidString)", isDirectory: true)
        let runtime = MCPDomainRuntime(
            configuration: .init(
                mode: .standalone,
                profileIdentifier: "host-test",
                storageDirectory: directory,
                eventDirectory: directory,
                temporaryDirectory: directory,
                externalReloadInterval: nil,
                hostDrainTimeout: .milliseconds(25)
            )
        )
        try await runtime.start()
        let registrationID = MCPDomainToolRegistrationID()
        _ = try await runtime.toolRegistry.register(
            registrationID: registrationID,
            scope: MCPDomainToolRegistrationScope.window(id: 1),
            bindings: [binding]
        )
        let connectionID = UUID()
        _ = await runtime.routingCoordinator.registerConnection(
            connectionID: connectionID,
            operationID: UUID()
        )
        let connection = try await runtime.routingCoordinator.currentRegistration(
            connectionID: connectionID
        )
        return Fixture(
            runtime: runtime,
            connection: connection,
            registrationID: registrationID
        )
    }

    private static func binding(
        toolName: String = MCPWindowToolName.readFile,
        description: String = "host fixture",
        operation: @Sendable @escaping ([String: Value]) async throws -> Value = { arguments in
            arguments["path"] ?? .string("ok")
        }
    ) -> MCPDomainToolBinding {
        MCPDomainToolBinding(
            definition: MCPDomainToolDefinition(
                name: toolName,
                description: description,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            ),
            operation: operation
        )
    }

    private func securityContext(
        identity: DomainRuntimeIdentity,
        connection: DomainConnectionRegistration,
        invocationID: UUID
    ) -> DomainToolInvocationSecurityContext {
        DomainToolInvocationSecurityContext(
            principal: DomainClientPrincipal(
                principalID: connection.connectionID,
                stableKey: "host-test",
                displayName: "Host Test",
                kind: .appProxy,
                assurance: .verifiedProcess,
                processID: 42,
                runID: nil,
                provider: nil,
                verifiedIdentityFingerprint: "fixture"
            ),
            connectionID: connection.connectionID,
            connectionGeneration: connection.generation,
            invocationID: invocationID,
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            hasAuthoritativeRoutingContext: false,
            ephemeralGrantedToolNames: [MCPWindowToolName.readFile]
        )
    }
}

private actor InvocationCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor InvocationAdmissionBarrier {
    private let expectedArrivalCount: Int
    private var arrivalCount = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(expectedArrivalCount: Int) {
        self.expectedArrivalCount = expectedArrivalCount
    }

    func arriveAndWait() async {
        arrivalCount += 1
        if arrivalCount >= expectedArrivalCount {
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func awaitAllArrivals() async {
        guard arrivalCount < expectedArrivalCount else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor DomainProgressRecorder: MCPDomainProgressTransport {
    private var recordedMessages: [String] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func deliverMCPProgress(
        token _: ProgressToken,
        progress _: Double,
        message: String?
    ) -> MCPProgressDeliveryResult {
        recordedMessages.append(message ?? "")
        let ready = countWaiters.filter { recordedMessages.count >= $0.0 }
        countWaiters.removeAll { recordedMessages.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        return .delivered
    }

    func waitUntilCount(_ count: Int) async {
        guard recordedMessages.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func messages() -> [String] {
        recordedMessages
    }
}

private actor InvocationBlocker {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
    }

    func awaitStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
