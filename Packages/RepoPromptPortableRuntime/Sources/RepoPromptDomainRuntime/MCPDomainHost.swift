import Foundation
import MCP

public enum MCPDomainHostLifecycle: String, CaseIterable, Sendable {
    case accepting
    case draining
    case drained
}

public enum MCPDomainHostError: Error, Equatable, Sendable {
    case draining
    case duplicateInvocationID(UUID)
    case unknownTool(String)
    case scopeUnavailable(toolName: String, scope: MCPDomainToolRegistrationScope)
    case staleRegistration(toolName: String)
    case runtimeGenerationMismatch
    case connectionRegistrationInvalid
}

public struct MCPDomainHostResolution: Sendable {
    public let toolName: String
    public let scope: MCPDomainToolRegistrationScope
    public let registrationHandle: MCPDomainToolRegistrationHandle
    public let definition: MCPDomainToolDefinition

    public init(
        toolName: String,
        scope: MCPDomainToolRegistrationScope,
        registrationHandle: MCPDomainToolRegistrationHandle,
        definition: MCPDomainToolDefinition
    ) {
        self.toolName = toolName
        self.scope = scope
        self.registrationHandle = registrationHandle
        self.definition = definition
    }
}

public struct MCPDomainAdmittedContext: Equatable, Sendable {
    public let connectionID: UUID
    public let windowID: Int
    public let workspaceID: UUID
    public let contextID: UUID

    public init(
        connectionID: UUID,
        windowID: Int,
        workspaceID: UUID,
        contextID: UUID
    ) {
        self.connectionID = connectionID
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.contextID = contextID
    }
}

public enum MCPDomainAdmittedContextValues {
    @TaskLocal public static var current: MCPDomainAdmittedContext?
}

public struct MCPDomainHostInvocation: Sendable {
    public let invocationID: UUID
    public let connectionID: UUID
    public let resolution: MCPDomainHostResolution
    public let arguments: [String: Value]
    public let securityContext: DomainToolInvocationSecurityContext
    public let admittedContext: MCPDomainAdmittedContext?
    public let submittedAt: ContinuousClock.Instant

    public init(
        invocationID: UUID,
        connectionID: UUID,
        resolution: MCPDomainHostResolution,
        arguments: [String: Value],
        securityContext: DomainToolInvocationSecurityContext,
        admittedContext: MCPDomainAdmittedContext? = nil,
        submittedAt: ContinuousClock.Instant = ContinuousClock().now
    ) {
        precondition(admittedContext == nil || admittedContext?.connectionID == connectionID)
        self.invocationID = invocationID
        self.connectionID = connectionID
        self.resolution = resolution
        self.arguments = arguments
        self.securityContext = securityContext
        self.admittedContext = admittedContext
        self.submittedAt = submittedAt
    }
}

public struct MCPDomainHostSnapshot: Equatable, Sendable {
    public let lifecycle: MCPDomainHostLifecycle
    public let activeInvocationCount: Int
    public let connectionsWithActiveInvocationsCount: Int
    public let activeResourceAdmissionLeaseCount: Int
    public let resourceAdmissionWaiterCount: Int
    public let terminalConnectionFenceCount: Int
}

public struct MCPDomainHostDrainResult: Equatable, Sendable {
    public let settledInvocationCount: Int
    public let detachedInvocationCount: Int
    public let deadlineExpired: Bool
    public let callerCancelled: Bool
}

/// Protocol-neutral owner for catalog resolution and exact domain-binding invocation.
/// Transports and the app presentation shell resolve routing/admission before entry;
/// this actor owns registry-generation fencing, invocation cancellation, and drain.
public actor MCPDomainHost {
    private struct ActiveInvocation {
        let connectionID: UUID
        let connectionGeneration: UInt64
        let task: Task<Value, Error>
    }

    private struct RequestProgressRecord {
        let handle: MCPDomainRequestProgressHandle
        let connectionGeneration: UInt64
        let state: MCPRequestProgressState
    }

    public nonisolated let identity: DomainRuntimeIdentity
    public nonisolated let registry: MCPDomainToolRegistry
    public nonisolated let routingCoordinator: DomainRoutingCoordinator

    private let metrics: DomainRuntimeMetricsSink
    private let beforeFinalAdmission: @Sendable () async -> Void
    private let mutationAdmissionController = MCPDomainToolResourceAdmissionController(
        limit: MCPDomainToolAdmissionLimits.exclusiveConnection
    )
    private let smallReadAdmissionController = MCPDomainToolResourceAdmissionController(
        limit: MCPDomainToolAdmissionLimits.smallReadPerWindow
    )
    private let fileReadAdmissionController = MCPDomainToolResourceAdmissionController(
        limit: MCPDomainToolAdmissionLimits.fileReadPerWindow
    )
    private var lifecycle: MCPDomainHostLifecycle = .accepting
    private var activeInvocations: [UUID: ActiveInvocation] = [:]
    private var invocationIDsByConnection: [UUID: Set<UUID>] = [:]
    private var requestProgressByStateID: [UUID: RequestProgressRecord] = [:]
    private var terminalConnectionGenerationByID: [UUID: UInt64] = [:]
    private var releasedConnectionGenerationByID: [UUID: UInt64] = [:]

    public init(
        identity: DomainRuntimeIdentity,
        registry: MCPDomainToolRegistry,
        routingCoordinator: DomainRoutingCoordinator,
        metrics: DomainRuntimeMetricsSink = .disabled,
        beforeFinalAdmission: @escaping @Sendable () async -> Void = {}
    ) {
        self.identity = identity
        self.registry = registry
        self.routingCoordinator = routingCoordinator
        self.metrics = metrics
        self.beforeFinalAdmission = beforeFinalAdmission
    }

    public func catalogSnapshot() async -> MCPDomainToolCatalogSnapshot {
        await registry.snapshot()
    }

    public func resolve(
        toolName: String,
        scope: MCPDomainToolRegistrationScope
    ) async throws -> MCPDomainHostResolution {
        guard MCPDomainToolCatalog.entry(named: toolName) != nil else {
            throw MCPDomainHostError.unknownTool(toolName)
        }
        guard let resolved = await registry.resolve(toolName: toolName, scope: scope) else {
            throw MCPDomainHostError.scopeUnavailable(toolName: toolName, scope: scope)
        }
        return makeResolution(resolved)
    }

    public func resolveUniqueWindowTool(toolName: String) async throws -> MCPDomainHostResolution? {
        guard MCPDomainToolCatalog.entry(named: toolName) != nil else {
            throw MCPDomainHostError.unknownTool(toolName)
        }
        guard let resolved = await registry.resolveUniqueWindowTool(toolName: toolName) else {
            return nil
        }
        return makeResolution(resolved)
    }

    public func invoke(_ invocation: MCPDomainHostInvocation) async throws -> Value {
        let clock = ContinuousClock()
        let hostEntry = clock.now
        recordTimingMetric(
            name: "mcp_domain_host_queue_wait",
            toolName: invocation.resolution.toolName,
            duration: invocation.submittedAt.duration(to: hostEntry),
            outcome: "entered"
        )
        guard lifecycle == .accepting else {
            throw MCPDomainHostError.draining
        }
        guard activeInvocations[invocation.invocationID] == nil else {
            throw MCPDomainHostError.duplicateInvocationID(invocation.invocationID)
        }
        try validateSecurityContext(invocation)

        guard let resolved = await registry.resolve(
            toolName: invocation.resolution.toolName,
            scope: invocation.resolution.scope
        ) else {
            throw MCPDomainHostError.scopeUnavailable(
                toolName: invocation.resolution.toolName,
                scope: invocation.resolution.scope
            )
        }
        guard resolved.handle == invocation.resolution.registrationHandle,
              await registry.isActive(resolved.handle)
        else {
            throw MCPDomainHostError.staleRegistration(toolName: invocation.resolution.toolName)
        }

        let currentRegistration: DomainConnectionRegistration
        do {
            currentRegistration = try await routingCoordinator.currentRegistration(
                connectionID: invocation.connectionID
            )
        } catch {
            throw MCPDomainHostError.connectionRegistrationInvalid
        }
        guard currentRegistration.runtimeID == identity.runtimeID,
              currentRegistration.generation == invocation.securityContext.connectionGeneration
        else {
            throw MCPDomainHostError.connectionRegistrationInvalid
        }

        await beforeFinalAdmission()

        // Actor reentrancy permits drain to begin across any validation suspension above.
        // This final check and active-map insertion form the authoritative admission fence:
        // there is no suspension between them, so beginDrain cannot miss a late invocation.
        guard lifecycle == .accepting else {
            throw MCPDomainHostError.draining
        }
        guard activeInvocations[invocation.invocationID] == nil else {
            throw MCPDomainHostError.duplicateInvocationID(invocation.invocationID)
        }
        guard !isConnectionGenerationTerminal(
            connectionID: invocation.connectionID,
            generation: invocation.securityContext.connectionGeneration
        ) else {
            throw MCPDomainHostError.connectionRegistrationInvalid
        }
        let metrics = metrics
        let toolName = invocation.resolution.toolName
        let task = Task {
            let executionStartedAt = clock.now
            do {
                try Task.checkCancellation()
                guard await self.registry.isActive(resolved.handle) else {
                    throw MCPDomainHostError.staleRegistration(toolName: toolName)
                }
                let value = try await MCPDomainInvocationSecurityContext.$current.withValue(
                    invocation.securityContext
                ) {
                    try await MCPDomainAdmittedContextValues.$current.withValue(
                        invocation.admittedContext
                    ) {
                        try await resolved.binding(invocation.arguments)
                    }
                }
                Self.recordTimingMetric(
                    metrics: metrics,
                    name: "mcp_domain_host_execution",
                    toolName: toolName,
                    duration: executionStartedAt.duration(to: clock.now),
                    outcome: "success"
                )
                return value
            } catch {
                Self.recordTimingMetric(
                    metrics: metrics,
                    name: "mcp_domain_host_execution",
                    toolName: toolName,
                    duration: executionStartedAt.duration(to: clock.now),
                    outcome: error is CancellationError ? "cancelled" : "error"
                )
                throw error
            }
        }
        activeInvocations[invocation.invocationID] = ActiveInvocation(
            connectionID: invocation.connectionID,
            connectionGeneration: invocation.securityContext.connectionGeneration,
            task: task
        )
        invocationIDsByConnection[invocation.connectionID, default: []].insert(invocation.invocationID)

        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                finishInvocation(invocation.invocationID)
                return value
            } catch {
                finishInvocation(invocation.invocationID)
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func beginRequestProgress(
        connectionID: UUID,
        connectionGeneration: UInt64,
        invocationID: UUID,
        token: ProgressToken
    ) -> MCPDomainRequestProgressHandle? {
        guard lifecycle == .accepting,
              !isConnectionGenerationTerminal(
                  connectionID: connectionID,
                  generation: connectionGeneration
              )
        else { return nil }
        let handle = MCPDomainRequestProgressHandle(
            stateID: UUID(),
            connectionID: connectionID,
            invocationID: invocationID
        )
        requestProgressByStateID[handle.stateID] = RequestProgressRecord(
            handle: handle,
            connectionGeneration: connectionGeneration,
            state: MCPRequestProgressState(token: token)
        )
        return handle
    }

    public func sendRequestProgress(
        _ handle: MCPDomainRequestProgressHandle,
        through transport: any MCPDomainProgressTransport,
        message: String?
    ) async {
        guard let record = requestProgressByStateID[handle.stateID],
              record.handle == handle
        else { return }
        await record.state.send(through: transport, message: message)
    }

    public func finishRequestProgress(_ handle: MCPDomainRequestProgressHandle) async {
        guard let record = requestProgressByStateID.removeValue(forKey: handle.stateID),
              record.handle == handle
        else { return }
        await record.state.invalidate()
    }

    public func acquireMutationResourceAdmission(
        _ resource: MCPDomainToolResourceAdmissionController.Resource
    ) async throws -> MCPDomainToolResourceAdmissionController.Lease {
        guard lifecycle == .accepting else { throw MCPDomainHostError.draining }
        return try await mutationAdmissionController.acquire(resource)
    }

    public func acquireSmallReadResourceAdmission(
        windowID: Int
    ) async throws -> MCPDomainToolResourceAdmissionController.Lease {
        guard lifecycle == .accepting else { throw MCPDomainHostError.draining }
        return try await smallReadAdmissionController.acquire(.window(windowID))
    }

    public func acquireFileReadResourceAdmission(
        windowID: Int
    ) async throws -> MCPDomainToolResourceAdmissionController.Lease {
        guard lifecycle == .accepting else { throw MCPDomainHostError.draining }
        return try await fileReadAdmissionController.acquire(.window(windowID))
    }

    public func cancelInvocations(
        connectionID: UUID,
        connectionGeneration: UInt64
    ) async {
        terminalConnectionGenerationByID[connectionID] = max(
            terminalConnectionGenerationByID[connectionID] ?? 0,
            connectionGeneration
        )
        let progressRecords = requestProgressByStateID.values.filter {
            $0.handle.connectionID == connectionID
                && $0.connectionGeneration <= connectionGeneration
        }
        for record in progressRecords {
            requestProgressByStateID.removeValue(forKey: record.handle.stateID)
            await record.state.invalidate()
        }

        let invocationIDs = invocationIDsByConnection[connectionID] ?? []
        for invocationID in invocationIDs {
            guard let invocation = activeInvocations[invocationID],
                  invocation.connectionGeneration <= connectionGeneration
            else { continue }
            invocation.task.cancel()
        }
    }

    /// Releases the terminal-generation fence after routing has removed this exact
    /// connection generation. If cancelled work is still settling, cleanup is deferred
    /// until the last matching invocation leaves the active map.
    public func releaseConnection(
        connectionID: UUID,
        connectionGeneration: UInt64
    ) {
        releasedConnectionGenerationByID[connectionID] = max(
            releasedConnectionGenerationByID[connectionID] ?? 0,
            connectionGeneration
        )
        pruneTerminalConnectionFenceIfSafe(connectionID: connectionID)
    }

    public func beginDrain() {
        guard lifecycle == .accepting else { return }
        lifecycle = .draining
        _ = mutationAdmissionController.close()
        _ = smallReadAdmissionController.close()
        _ = fileReadAdmissionController.close()
        for invocation in activeInvocations.values {
            invocation.task.cancel()
        }
        markDrainedIfSettled()
    }

    public func drain(timeout: Duration) async -> MCPDomainHostDrainResult {
        beginDrain()
        let progressRecords = Array(requestProgressByStateID.values)
        requestProgressByStateID.removeAll()
        for record in progressRecords {
            await record.state.invalidate()
        }
        let initialCount = activeInvocations.count
        guard hasOutstandingWork else {
            lifecycle = .drained
            return MCPDomainHostDrainResult(
                settledInvocationCount: 0,
                detachedInvocationCount: 0,
                deadlineExpired: false,
                callerCancelled: false
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var callerCancelled = false
        while hasOutstandingWork, clock.now < deadline {
            if Task.isCancelled {
                callerCancelled = true
                break
            }
            let remaining = clock.now.duration(to: deadline)
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(10)))
            } catch is CancellationError {
                callerCancelled = true
                break
            } catch {
                break
            }
        }

        let detachedCount = activeInvocations.count
        let deadlineExpired = hasOutstandingWork && !callerCancelled && clock.now >= deadline
        markDrainedIfSettled()
        return MCPDomainHostDrainResult(
            settledInvocationCount: max(0, initialCount - detachedCount),
            detachedInvocationCount: detachedCount,
            deadlineExpired: deadlineExpired,
            callerCancelled: callerCancelled
        )
    }

    public func snapshot() -> MCPDomainHostSnapshot {
        let admission = resourceAdmissionSnapshot
        return MCPDomainHostSnapshot(
            lifecycle: lifecycle,
            activeInvocationCount: activeInvocations.count,
            connectionsWithActiveInvocationsCount: invocationIDsByConnection.count,
            activeResourceAdmissionLeaseCount: admission.activeLeaseCount,
            resourceAdmissionWaiterCount: admission.waiterCount,
            terminalConnectionFenceCount: terminalConnectionGenerationByID.count
        )
    }

    private func makeResolution(_ resolved: MCPDomainResolvedTool) -> MCPDomainHostResolution {
        MCPDomainHostResolution(
            toolName: resolved.binding.definition.name,
            scope: resolved.scope,
            registrationHandle: resolved.handle,
            definition: resolved.binding.definition
        )
    }

    private func validateSecurityContext(_ invocation: MCPDomainHostInvocation) throws {
        let context = invocation.securityContext
        guard context.runtimeID == identity.runtimeID,
              context.runtimeGeneration == identity.lifecycleGeneration
        else {
            throw MCPDomainHostError.runtimeGenerationMismatch
        }
        guard context.connectionID == invocation.connectionID,
              context.invocationID == invocation.invocationID
        else {
            throw MCPDomainHostError.connectionRegistrationInvalid
        }
    }

    private func recordTimingMetric(
        name: String,
        toolName: String,
        duration: Duration,
        outcome: String
    ) {
        Self.recordTimingMetric(
            metrics: metrics,
            name: name,
            toolName: toolName,
            duration: duration,
            outcome: outcome
        )
    }

    private nonisolated static func recordTimingMetric(
        metrics: DomainRuntimeMetricsSink,
        name: String,
        toolName: String,
        duration: Duration,
        outcome: String
    ) {
        let components = duration.components
        let microseconds = max(
            0,
            components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
        )
        metrics.record(DomainRuntimeMetric(
            phase: .runtime,
            name: name,
            dimensions: [
                "tool_name": toolName,
                "duration_microseconds": String(microseconds),
                "outcome": outcome,
            ]
        ))
    }

    private func finishInvocation(_ invocationID: UUID) {
        guard let invocation = activeInvocations.removeValue(forKey: invocationID) else { return }
        invocationIDsByConnection[invocation.connectionID]?.remove(invocationID)
        if invocationIDsByConnection[invocation.connectionID]?.isEmpty == true {
            invocationIDsByConnection.removeValue(forKey: invocation.connectionID)
        }
        pruneTerminalConnectionFenceIfSafe(connectionID: invocation.connectionID)
        markDrainedIfSettled()
    }

    private func pruneTerminalConnectionFenceIfSafe(connectionID: UUID) {
        guard let terminalGeneration = terminalConnectionGenerationByID[connectionID],
              let releasedGeneration = releasedConnectionGenerationByID[connectionID],
              releasedGeneration >= terminalGeneration
        else { return }
        let hasUnsettledGeneration = activeInvocations.values.contains {
            $0.connectionID == connectionID && $0.connectionGeneration <= releasedGeneration
        }
        guard !hasUnsettledGeneration else { return }
        terminalConnectionGenerationByID.removeValue(forKey: connectionID)
        releasedConnectionGenerationByID.removeValue(forKey: connectionID)
    }

    private func isConnectionGenerationTerminal(
        connectionID: UUID,
        generation: UInt64
    ) -> Bool {
        guard let terminalGeneration = terminalConnectionGenerationByID[connectionID] else {
            return false
        }
        return generation <= terminalGeneration
    }

    private var resourceAdmissionSnapshot: (activeLeaseCount: Int, waiterCount: Int) {
        let mutation = mutationAdmissionController.snapshot()
        let smallRead = smallReadAdmissionController.snapshot()
        let fileRead = fileReadAdmissionController.snapshot()
        return (
            mutation.activeLeaseCount + smallRead.activeLeaseCount + fileRead.activeLeaseCount,
            mutation.waiterCount + smallRead.waiterCount + fileRead.waiterCount
        )
    }

    private var hasOutstandingWork: Bool {
        let admission = resourceAdmissionSnapshot
        return !activeInvocations.isEmpty
            || admission.activeLeaseCount > 0
            || admission.waiterCount > 0
    }

    private func markDrainedIfSettled() {
        if lifecycle == .draining, !hasOutstandingWork {
            lifecycle = .drained
        }
    }
}
