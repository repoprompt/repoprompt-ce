import Foundation
import Security

package struct DomainWindowDescriptor: Codable, Equatable {
    package let windowID: Int
    package let generation: UInt64
    package let activeWorkspaceID: UUID?
    package let activeContextID: UUID?
    package let isClosing: Bool
    package let presentationRevision: UInt64

    package init(
        windowID: Int,
        generation: UInt64,
        activeWorkspaceID: UUID?,
        activeContextID: UUID?,
        isClosing: Bool,
        presentationRevision: UInt64
    ) {
        self.windowID = windowID
        self.generation = generation
        self.activeWorkspaceID = activeWorkspaceID
        self.activeContextID = activeContextID
        self.isClosing = isClosing
        self.presentationRevision = presentationRevision
    }
}

package struct DomainConnectionRegistration: Codable, Hashable {
    package let connectionID: UUID
    package let generation: UInt64
    package let runtimeID: UUID

    package init(connectionID: UUID, generation: UInt64, runtimeID: UUID) {
        self.connectionID = connectionID
        self.generation = generation
        self.runtimeID = runtimeID
    }
}

package enum DomainBinding: Codable, Equatable {
    case unbound
    case context(DomainContextIdentity, explicit: Bool)
    case appPresentationWindow(Int)
    case runScoped(runID: UUID, context: DomainContextIdentity)
}

package extension DomainBinding {
    func ordinaryContextMatches(_ identity: DomainContextIdentity) -> Bool {
        guard case let .context(boundIdentity, _) = self else { return false }
        return boundIdentity == identity
    }
}

package struct DomainConnectionBindingSnapshot: Codable, Equatable, Sendable {
    package let registration: DomainConnectionRegistration
    package let binding: DomainBinding
}

package struct DomainRoutingSnapshot: Codable, Equatable {
    package let runtimeID: UUID
    package let revision: UInt64
    package let windows: [DomainWindowDescriptor]
    package let connections: [DomainConnectionBindingSnapshot]
    package let pendingRunContexts: [UUID: DomainContextIdentity]
}

package enum DomainRoutingDisposition: String, Codable {
    case applied
    case unchanged
    case conflict
    case rejected
    case staleGeneration
}

package struct DomainRoutingOutcome: Codable, Equatable {
    package let operationID: UUID
    package let disposition: DomainRoutingDisposition
    package let snapshot: DomainRoutingSnapshot
    package let diagnostic: String?
}

package struct DomainRunLaunchToken {
    package let tokenID: UUID
    package let material: String
}

package struct DomainRunLaunchReservationRequest {
    package let runID: UUID
    package let context: DomainContextIdentity
    package let expectedContextRevision: UInt64
    package let windowID: Int?
    package let clientPrincipal: String
    package let providerIdentifier: String
    package let runPurpose: String
    package let restrictedTools: Set<String>
    package let additionalTools: Set<String>
    package let expectedProcessID: Int32?
    package let lifetime: Duration

    package init(
        runID: UUID,
        context: DomainContextIdentity,
        expectedContextRevision: UInt64,
        windowID: Int?,
        clientPrincipal: String,
        providerIdentifier: String,
        runPurpose: String,
        restrictedTools: Set<String> = [],
        additionalTools: Set<String> = [],
        expectedProcessID: Int32? = nil,
        lifetime: Duration = .seconds(60)
    ) {
        self.runID = runID
        self.context = context
        self.expectedContextRevision = expectedContextRevision
        self.windowID = windowID
        self.clientPrincipal = clientPrincipal
        self.providerIdentifier = providerIdentifier
        self.runPurpose = runPurpose
        self.restrictedTools = restrictedTools
        self.additionalTools = additionalTools
        self.expectedProcessID = expectedProcessID
        self.lifetime = lifetime
    }
}

package struct DomainRunLaunchRedemption: Equatable, Sendable {
    package let binding: DomainConnectionBindingSnapshot
    package let restrictedTools: Set<String>
    package let additionalTools: Set<String>

    package init(
        binding: DomainConnectionBindingSnapshot,
        restrictedTools: Set<String>,
        additionalTools: Set<String>
    ) {
        self.binding = binding
        self.restrictedTools = restrictedTools
        self.additionalTools = additionalTools
    }
}

package enum DomainRunLaunchRedemptionResult: Equatable, Sendable {
    case accepted(DomainRunLaunchRedemption)
    case unknown
    case expired
    case alreadyConsumed
    case generationMismatch
    case identityMismatch
    case revoked
}

package enum DomainRunLaunchTokenError: Error, Equatable {
    case runtimeStopped
    case contextUnavailable
    case staleContextRevision(expected: UInt64, actual: UInt64)
    case randomGenerationFailed
}

package actor DomainRoutingCoordinator {
    static let maximumRoutingOperations = 4096
    static let maximumTokenRecords = 1024

    private enum TokenState: Equatable {
        case active
        case consumed
        case revoked
    }

    private struct TokenRecord {
        let tokenID: UUID
        let digest: String
        let request: DomainRunLaunchReservationRequest
        let issuedAt: ContinuousClock.Instant
        let expiresAt: ContinuousClock.Instant
        var state: TokenState
    }

    private let identity: DomainRuntimeIdentity
    private let contextStore: DomainContextStore
    private let metrics: DomainRuntimeMetricsSink
    private let clock = ContinuousClock()
    private var revision: UInt64 = 0
    private var isStopped = false
    private var windows: [Int: DomainWindowDescriptor] = [:]
    private var nextWindowGeneration: [Int: UInt64] = [:]
    private var connections: [UUID: DomainConnectionBindingSnapshot] = [:]
    private var nextConnectionGeneration: [UUID: UInt64] = [:]
    private var pendingRunContexts: [UUID: DomainContextIdentity] = [:]
    private var tokenRecords: [String: TokenRecord] = [:]
    private var tokenDigestsByID: [UUID: String] = [:]
    private var tokenIssueOrder: [String] = []
    private var tokenIssueOrderHead = 0
    private var routingOperations: [UUID: DomainRoutingOutcome] = [:]
    private var routingOperationOrder: [UUID] = []
    private var routingOperationOrderHead = 0

    init(
        identity: DomainRuntimeIdentity,
        contextStore: DomainContextStore,
        metrics: DomainRuntimeMetricsSink
    ) {
        self.identity = identity
        self.contextStore = contextStore
        self.metrics = metrics
    }

    package func snapshot() -> DomainRoutingSnapshot {
        DomainRoutingSnapshot(
            runtimeID: identity.runtimeID,
            revision: revision,
            windows: windows.values.sorted { $0.windowID < $1.windowID },
            connections: connections.values.sorted {
                $0.registration.connectionID.uuidString < $1.registration.connectionID.uuidString
            },
            pendingRunContexts: pendingRunContexts
        )
    }

    /// Returns the coordinator-owned registration token for the live connection incarnation.
    /// Callers must never synthesize a generation from transport lifecycle counters.
    package func currentRegistration(connectionID: UUID) throws -> DomainConnectionRegistration {
        guard let current = connections[connectionID] else {
            throw DomainReadContextResolutionError.connectionUnavailable
        }
        return current.registration
    }

    package func resolveReadContext(
        connection registration: DomainConnectionRegistration
    ) async throws -> DomainReadContextHandle {
        guard registration.runtimeID == identity.runtimeID else {
            throw DomainReadContextResolutionError.runtimeGenerationMismatch
        }
        guard let current = connections[registration.connectionID] else {
            throw DomainReadContextResolutionError.connectionUnavailable
        }
        guard current.registration == registration else {
            throw DomainReadContextResolutionError.staleConnectionGeneration
        }

        let contextIdentity: DomainContextIdentity
        let bindingKind: DomainReadBindingKind
        switch current.binding {
        case .unbound:
            throw DomainReadContextResolutionError.unboundConnection
        case let .context(context, explicit):
            contextIdentity = context
            bindingKind = explicit ? .explicit : .appPresentation
        case let .runScoped(runID, context):
            contextIdentity = context
            bindingKind = .runScoped(runID: runID)
        case let .appPresentationWindow(windowID):
            guard let window = windows[windowID], !window.isClosing else {
                throw DomainReadContextResolutionError.presentationWindowUnavailable
            }
            guard let workspaceID = window.activeWorkspaceID,
                  let contextID = window.activeContextID
            else {
                throw DomainReadContextResolutionError.presentationContextUnavailable
            }
            contextIdentity = DomainContextIdentity(workspaceID: workspaceID, contextID: contextID)
            bindingKind = .appPresentation
        }

        guard let workspace = await contextStore.workspaceSnapshot(contextIdentity.workspaceID) else {
            throw DomainReadContextResolutionError.contextUnavailable
        }
        guard let context = workspace.contexts.first(where: {
            $0.metadata.identity == contextIdentity
        }) else {
            throw DomainReadContextResolutionError.contextUnavailable
        }
        if case .removed = context.health {
            throw DomainReadContextResolutionError.contextRemoved
        }
        return DomainReadContextHandle(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            connectionID: registration.connectionID,
            connectionGeneration: registration.generation,
            context: contextIdentity,
            workspaceRevision: workspace.revisions.workingRevision,
            contextRevision: context.revisions.workingRevision,
            routingRevision: revision,
            bindingKind: bindingKind
        )
    }

    /// Revalidates only the authority actually consumed by a read: runtime generation,
    /// connection incarnation, bound context identity, and that context's current revisions.
    /// Global routing revision and unrelated presentation/window changes are intentionally ignored.
    package func refreshReadContext(
        _ handle: DomainReadContextHandle
    ) async throws -> DomainReadContextHandle {
        guard handle.runtimeID == identity.runtimeID,
              handle.runtimeGeneration == identity.lifecycleGeneration
        else {
            throw DomainReadContextResolutionError.runtimeGenerationMismatch
        }
        let registration = DomainConnectionRegistration(
            connectionID: handle.connectionID,
            generation: handle.connectionGeneration,
            runtimeID: handle.runtimeID
        )
        let refreshed = try await resolveReadContext(connection: registration)
        guard refreshed.context == handle.context,
              refreshed.bindingKind == handle.bindingKind
        else {
            throw DomainReadContextResolutionError.staleConnectionGeneration
        }
        return refreshed
    }

    /// Opens a presentation window with a runtime-issued monotonic incarnation.
    /// Reusing an app window ID after teardown therefore cannot revive stale bindings.
    package func openWindow(
        windowID: Int,
        activeWorkspaceID: UUID?,
        activeContextID: UUID?,
        presentationRevision: UInt64,
        operationID: UUID
    ) -> DomainRoutingOutcome {
        guard !isStopped else { return stoppedOutcome(operationID) }
        if let prior = routingOperations[operationID] { return prior }
        let generation = nextWindowGeneration[windowID, default: 0] &+ 1
        nextWindowGeneration[windowID] = generation
        windows[windowID] = DomainWindowDescriptor(
            windowID: windowID,
            generation: generation,
            activeWorkspaceID: activeWorkspaceID,
            activeContextID: activeContextID,
            isClosing: false,
            presentationRevision: presentationRevision
        )
        revision &+= 1
        return finish(operationID, disposition: .applied, diagnostic: nil)
    }

    package func registerWindow(
        _ descriptor: DomainWindowDescriptor,
        operationID: UUID,
        expectedRevision: UInt64? = nil
    ) -> DomainRoutingOutcome {
        guard !isStopped else { return stoppedOutcome(operationID) }
        if let prior = routingOperations[operationID] { return prior }
        guard expectedRevision == nil || expectedRevision == revision else {
            return finish(operationID, disposition: .conflict, diagnostic: "routing_revision_mismatch")
        }
        if let current = windows[descriptor.windowID] {
            guard current.generation <= descriptor.generation else {
                return finish(operationID, disposition: .staleGeneration, diagnostic: "window_generation_stale")
            }
            guard current.generation != descriptor.generation
                || current.presentationRevision <= descriptor.presentationRevision
            else {
                return finish(operationID, disposition: .staleGeneration, diagnostic: "window_presentation_revision_stale")
            }
        } else if descriptor.generation <= nextWindowGeneration[descriptor.windowID, default: 0] {
            return finish(operationID, disposition: .staleGeneration, diagnostic: "window_generation_closed")
        }
        if windows[descriptor.windowID] == descriptor {
            return finish(operationID, disposition: .unchanged, diagnostic: nil)
        }
        nextWindowGeneration[descriptor.windowID] = max(
            nextWindowGeneration[descriptor.windowID, default: 0],
            descriptor.generation
        )
        windows[descriptor.windowID] = descriptor
        revision &+= 1
        return finish(operationID, disposition: .applied, diagnostic: nil)
    }

    package func unregisterWindow(
        windowID: Int,
        generation: UInt64,
        operationID: UUID
    ) -> DomainRoutingOutcome {
        guard !isStopped else { return stoppedOutcome(operationID) }
        if let prior = routingOperations[operationID] { return prior }
        guard let current = windows[windowID] else {
            return finish(operationID, disposition: .unchanged, diagnostic: nil)
        }
        guard current.generation == generation else {
            return finish(operationID, disposition: .staleGeneration, diagnostic: "window_generation_replaced")
        }
        windows.removeValue(forKey: windowID)
        for (connectionID, snapshot) in connections {
            if case let .appPresentationWindow(boundWindowID) = snapshot.binding,
               boundWindowID == windowID
            {
                connections[connectionID] = DomainConnectionBindingSnapshot(
                    registration: snapshot.registration,
                    binding: .unbound
                )
            }
        }
        revision &+= 1
        return finish(operationID, disposition: .applied, diagnostic: nil)
    }

    package func registerConnection(connectionID: UUID, operationID: UUID) -> DomainRoutingOutcome {
        guard !isStopped else { return stoppedOutcome(operationID) }
        if let prior = routingOperations[operationID] { return prior }
        let generation = nextConnectionGeneration[connectionID, default: 0] &+ 1
        nextConnectionGeneration[connectionID] = generation
        connections[connectionID] = DomainConnectionBindingSnapshot(
            registration: DomainConnectionRegistration(
                connectionID: connectionID,
                generation: generation,
                runtimeID: identity.runtimeID
            ),
            binding: .unbound
        )
        revision &+= 1
        return finish(operationID, disposition: .applied, diagnostic: nil)
    }

    package func unregisterConnection(
        _ connection: DomainConnectionRegistration,
        operationID: UUID
    ) -> DomainRoutingOutcome {
        guard !isStopped else { return stoppedOutcome(operationID) }
        if let prior = routingOperations[operationID] { return prior }
        guard let current = connections[connection.connectionID] else {
            return finish(operationID, disposition: .unchanged, diagnostic: nil)
        }
        guard current.registration == connection else {
            return finish(operationID, disposition: .staleGeneration, diagnostic: "connection_generation_replaced")
        }
        connections.removeValue(forKey: connection.connectionID)
        revision &+= 1
        return finish(operationID, disposition: .applied, diagnostic: nil)
    }

    package func bind(
        connection: DomainConnectionRegistration,
        binding: DomainBinding,
        operationID: UUID,
        expectedRevision: UInt64? = nil,
        expectedBinding: DomainBinding? = nil
    ) async -> DomainRoutingOutcome {
        guard !isStopped else { return stoppedOutcome(operationID) }
        // Resolve the async context dependency first so validation and commit below run
        // without suspension: actor reentrancy cannot interleave routing-state changes
        // between the checks and the committed binding.
        var contextExists = true
        switch binding {
        case let .context(context, _), let .runScoped(_, context):
            contextExists = await contextStore.snapshot(context) != nil
        case .appPresentationWindow, .unbound:
            break
        }
        guard !isStopped else { return stoppedOutcome(operationID) }
        if let prior = routingOperations[operationID] { return prior }
        guard expectedRevision == nil || expectedRevision == revision else {
            return finish(operationID, disposition: .conflict, diagnostic: "routing_revision_mismatch")
        }
        guard let current = connections[connection.connectionID], current.registration == connection else {
            return finish(operationID, disposition: .staleGeneration, diagnostic: "connection_generation_stale")
        }
        guard expectedBinding == nil || current.binding == expectedBinding else {
            return finish(operationID, disposition: .conflict, diagnostic: "connection_binding_mismatch")
        }
        if case .runScoped = current.binding,
           current.binding != binding
        {
            return finish(operationID, disposition: .rejected, diagnostic: "run_scoped_binding_is_immutable")
        }
        switch binding {
        case .context, .runScoped:
            guard contextExists else {
                return finish(operationID, disposition: .rejected, diagnostic: "context_unavailable")
            }
        case let .appPresentationWindow(windowID):
            guard let window = windows[windowID], !window.isClosing else {
                return finish(operationID, disposition: .rejected, diagnostic: "window_target_unavailable")
            }
        case .unbound:
            break
        }
        if current.binding == binding {
            return finish(operationID, disposition: .unchanged, diagnostic: nil)
        }
        connections[connection.connectionID] = DomainConnectionBindingSnapshot(
            registration: connection,
            binding: binding
        )
        revision &+= 1
        return finish(operationID, disposition: .applied, diagnostic: nil)
    }

    package func issueLaunchToken(
        _ request: DomainRunLaunchReservationRequest
    ) async throws -> DomainRunLaunchToken {
        guard !isStopped else { throw DomainRunLaunchTokenError.runtimeStopped }
        guard let context = await contextStore.snapshot(request.context) else {
            throw DomainRunLaunchTokenError.contextUnavailable
        }
        guard !isStopped else { throw DomainRunLaunchTokenError.runtimeStopped }
        guard context.revisions.workingRevision == request.expectedContextRevision else {
            throw DomainRunLaunchTokenError.staleContextRevision(
                expected: request.expectedContextRevision,
                actual: context.revisions.workingRevision
            )
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DomainRunLaunchTokenError.randomGenerationFailed
        }
        let material = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let digest = DomainContentDigest.sha256(Data(material.utf8))
        let now = clock.now
        let tokenID = UUID()
        sweepExpiredTokens(now: now)
        tokenRecords[digest] = TokenRecord(
            tokenID: tokenID,
            digest: digest,
            request: request,
            issuedAt: now,
            expiresAt: now.advanced(by: request.lifetime),
            state: .active
        )
        tokenDigestsByID[tokenID] = digest
        tokenIssueOrder.append(digest)
        enforceTokenCapacity()
        pendingRunContexts[request.runID] = request.context
        revision &+= 1
        metrics.record(DomainRuntimeMetric(
            phase: .backend,
            name: "EditFlow.DomainRuntime.LaunchTokenIssued",
            dimensions: [
                "runtime_id": identity.runtimeID.uuidString,
                "runtime_generation": "\(identity.lifecycleGeneration)",
                "routing_revision": "\(revision)",
                "run_id": request.runID.uuidString
            ]
        ))
        return DomainRunLaunchToken(tokenID: tokenID, material: material)
    }

    package func redeemLaunchToken(
        material: String,
        runtimeID: UUID,
        runtimeGeneration: UInt64,
        connectionID: UUID,
        processID: Int32?,
        clientPrincipal: String,
        providerIdentifier: String
    ) -> DomainRunLaunchRedemptionResult {
        let digest = DomainContentDigest.sha256(Data(material.utf8))
        guard var record = tokenRecords[digest] else { return .unknown }
        switch record.state {
        case .consumed:
            return .alreadyConsumed
        case .revoked:
            return .revoked
        case .active:
            break
        }
        guard clock.now < record.expiresAt else {
            record.state = .revoked
            pendingRunContexts.removeValue(forKey: record.request.runID)
            tokenRecords[digest] = record
            return .expired
        }
        guard runtimeID == identity.runtimeID,
              runtimeGeneration == identity.lifecycleGeneration
        else {
            return .generationMismatch
        }
        guard record.request.clientPrincipal == clientPrincipal,
              record.request.providerIdentifier == providerIdentifier
        else {
            return .identityMismatch
        }
        if let expected = record.request.expectedProcessID, expected != processID {
            return .identityMismatch
        }
        let generation = nextConnectionGeneration[connectionID, default: 0] &+ 1
        nextConnectionGeneration[connectionID] = generation
        let registration = DomainConnectionRegistration(
            connectionID: connectionID,
            generation: generation,
            runtimeID: identity.runtimeID
        )
        let binding = DomainConnectionBindingSnapshot(
            registration: registration,
            binding: .runScoped(runID: record.request.runID, context: record.request.context)
        )
        connections[connectionID] = binding
        record.state = .consumed
        tokenRecords[digest] = record
        pendingRunContexts.removeValue(forKey: record.request.runID)
        revision &+= 1
        return .accepted(DomainRunLaunchRedemption(
            binding: binding,
            restrictedTools: record.request.restrictedTools,
            additionalTools: record.request.additionalTools
        ))
    }

    package func revokeLaunchToken(_ tokenID: UUID) {
        guard !isStopped else { return }
        if let digest = tokenDigestsByID[tokenID], var record = tokenRecords[digest] {
            record.state = .revoked
            pendingRunContexts.removeValue(forKey: record.request.runID)
            tokenRecords[digest] = record
        }
        revision &+= 1
    }

    /// Retires expired reservations (releasing their pending run contexts) and drops retired
    /// records once their lifetime has elapsed, so token bookkeeping cannot grow with uptime.
    private func sweepExpiredTokens(now: ContinuousClock.Instant) {
        guard !tokenRecords.isEmpty else { return }
        for (digest, record) in tokenRecords where now >= record.expiresAt {
            if record.state == .active {
                pendingRunContexts.removeValue(forKey: record.request.runID)
            }
            removeTokenRecord(digest: digest)
        }
    }

    /// Deterministically evicts the oldest-issued records once the bound is exceeded.
    private func enforceTokenCapacity() {
        while tokenRecords.count > Self.maximumTokenRecords, tokenIssueOrderHead < tokenIssueOrder.count {
            let digest = tokenIssueOrder[tokenIssueOrderHead]
            tokenIssueOrderHead += 1
            guard let record = tokenRecords[digest] else { continue }
            if record.state == .active {
                pendingRunContexts.removeValue(forKey: record.request.runID)
            }
            removeTokenRecord(digest: digest)
        }
        compactTokenIssueOrderIfNeeded()
    }

    /// Expiry can remove records without advancing the FIFO head. Rebuild from live digests
    /// only after a fixed amount of slack is consumed, keeping storage bounded while making
    /// the O(n) rebuild amortized O(1) across token issuance.
    private func compactTokenIssueOrderIfNeeded() {
        let maximumStoredDigests = Self.maximumTokenRecords * 2
        guard tokenIssueOrder.count > maximumStoredDigests else { return }
        tokenIssueOrder = tokenIssueOrder[tokenIssueOrderHead...].filter {
            tokenRecords[$0] != nil
        }
        tokenIssueOrderHead = 0
    }

    func tokenBookkeepingCounts() -> (records: Int, issueOrderStorage: Int, pendingRunContexts: Int) {
        (tokenRecords.count, tokenIssueOrder.count, pendingRunContexts.count)
    }

    private func removeTokenRecord(digest: String) {
        guard let record = tokenRecords.removeValue(forKey: digest) else { return }
        tokenDigestsByID.removeValue(forKey: record.tokenID)
    }

    package func shutdown() {
        guard !isStopped else { return }
        isStopped = true
        for (digest, var record) in tokenRecords {
            if case .active = record.state {
                record.state = .revoked
                tokenRecords[digest] = record
            }
        }
        pendingRunContexts.removeAll()
        windows.removeAll()
        connections.removeAll()
        revision &+= 1
    }

    private func stoppedOutcome(_ operationID: UUID) -> DomainRoutingOutcome {
        DomainRoutingOutcome(
            operationID: operationID,
            disposition: .rejected,
            snapshot: snapshot(),
            diagnostic: "routing_coordinator_stopped"
        )
    }

    private func finish(
        _ operationID: UUID,
        disposition: DomainRoutingDisposition,
        diagnostic: String?
    ) -> DomainRoutingOutcome {
        let outcome = DomainRoutingOutcome(
            operationID: operationID,
            disposition: disposition,
            snapshot: snapshot(),
            diagnostic: diagnostic
        )
        if routingOperations.updateValue(outcome, forKey: operationID) == nil {
            routingOperationOrder.append(operationID)
        }
        while routingOperations.count > Self.maximumRoutingOperations,
              routingOperationOrderHead < routingOperationOrder.count
        {
            routingOperations.removeValue(forKey: routingOperationOrder[routingOperationOrderHead])
            routingOperationOrderHead += 1
        }
        if routingOperationOrderHead >= Self.maximumRoutingOperations,
           routingOperationOrderHead * 2 >= routingOperationOrder.count
        {
            routingOperationOrder.removeFirst(routingOperationOrderHead)
            routingOperationOrderHead = 0
        }
        return outcome
    }
}
