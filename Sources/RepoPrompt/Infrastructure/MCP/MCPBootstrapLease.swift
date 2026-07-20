import Foundation
import OSLog

private func acpLeaseLog(_ message: @autoclosure () -> String) {
    guard AgentRuntimeProviderService.enableDebugLogging else { return }
    print(message())
}

enum MCPBootstrapRoutingProgress: String {
    case waitingForChildConnection = "waiting_for_child_connection"
    case childConnectionObserved = "child_connection_observed"
    case waitingForRouting = "waiting_for_routing"
    case routingConfirmed = "routing_confirmed"
    case routingTimeoutBeforeConnection = "routing_timeout_before_connection"
    case routingTimeoutAfterConnection = "routing_timeout_after_connection"
}

typealias MCPBootstrapRoutingProgressReporter = @MainActor @Sendable (
    MCPBootstrapRoutingProgress
) async -> Void

actor MCPBootstrapRoutingProgressLifecycle {
    private let reporter: MCPBootstrapRoutingProgressReporter
    private var childConnectionObserved = false
    private var waitOutcomeFence: MCPRoutingWaitOutcome?
    private var authoritativeOutcome: MCPRoutingWaitOutcome?
    private var deliveryTask: Task<Void, Never>?

    init(reporter: @escaping MCPBootstrapRoutingProgressReporter) {
        self.reporter = reporter
        deliveryTask = Task {
            await reporter(.waitingForChildConnection)
        }
    }

    func recordChildConnectionObserved() {
        guard waitOutcomeFence == nil, authoritativeOutcome == nil, !childConnectionObserved else { return }
        childConnectionObserved = true
        enqueue([.childConnectionObserved, .waitingForRouting])
    }

    /// Fences late waiter callbacks without claiming authority over the lease's final outcome.
    func fenceAfterWaitOutcome(_ outcome: MCPRoutingWaitOutcome) {
        guard waitOutcomeFence == nil else { return }
        waitOutcomeFence = outcome
    }

    func finish(with outcome: MCPRoutingWaitOutcome) async {
        guard authoritativeOutcome == nil else {
            await deliveryTask?.value
            return
        }
        let fence = waitOutcomeFence
        waitOutcomeFence = fence ?? outcome
        authoritativeOutcome = outcome

        let needsObservedBackfill = !childConnectionObserved && (
            outcome == .timedOutAfterConnection
                || outcome == .routed && (
                    fence == .timedOutBeforeConnection
                        || fence == .timedOutAfterConnection
                )
        )
        if needsObservedBackfill {
            childConnectionObserved = true
            enqueue([.childConnectionObserved, .waitingForRouting])
        }

        switch outcome {
        case .routed:
            enqueue([.routingConfirmed])
        case .timedOutBeforeConnection:
            enqueue([.routingTimeoutBeforeConnection])
        case .timedOutAfterConnection:
            enqueue([.routingTimeoutAfterConnection])
        case .failed, .cancelled:
            break
        }

        await deliveryTask?.value
    }

    private func enqueue(_ phases: [MCPBootstrapRoutingProgress]) {
        let previousDelivery = deliveryTask
        let reporter = reporter
        deliveryTask = Task {
            await previousDelivery?.value
            for phase in phases {
                await reporter(phase)
            }
        }
    }
}

/// Specification describing the MCP bootstrap requirements for a single run.
/// Used by both agent-mode and headless discovery paths.
struct MCPBootstrapLeaseSpec {
    let runID: UUID
    let gateID: UUID
    let windowID: Int
    let tabID: UUID?
    let clientName: String?

    let restrictedTools: Set<String>
    let additionalTools: Set<String>?
    let oneShot: Bool
    let reason: String?
    let ttl: TimeInterval
    let purpose: MCPRunPurpose
    /// The task label kind for role-aware tool advertisement filtering.
    /// `nil` for non-role connections (discover, delegate-edit, direct MCP).
    let taskLabelKind: AgentModelCatalog.TaskLabelKind?
    /// Whether this run may see external agent control tools even when role filtering would hide them.
    let allowsAgentExternalControlTools: Bool
    /// When true, the queued policy is reserved until the MCP peer PID is a descendant
    /// of an explicitly registered expected agent process.
    let requiresExpectedAgentPID: Bool
}

/// Typed readiness failures for the MCP bootstrap path.
///
/// ``routingUnavailable`` reports that a run's routing wait ended without a confirmed MCP
/// connection (timeout or routing failure). ``provisioningUnavailable`` is reserved for
/// provisioning validation (MCP server start / config bootstrap) and carries no behavioral
/// guarantees on its own.
enum MCPBootstrapReadinessError: Error, Equatable {
    /// MCP provisioning validation (server start / config bootstrap) could not be completed for the
    /// run. Used by provisioning validation; no behavioral guarantees are attached here.
    case provisioningUnavailable
    /// The run's routing wait ended without a confirmed MCP connection — a timeout, a routing
    /// failure, or a lease that was already released or consumed (its routing signal already taken).
    case routingUnavailable
}

extension MCPBootstrapReadinessError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .provisioningUnavailable:
            "RepoPrompt MCP provisioning could not be completed: the RepoPrompt MCP server entry could not be created or updated in the Codex configuration, so the agent cannot start with RepoPrompt tools."
        case .routingUnavailable:
            "RepoPrompt MCP routing was not confirmed: the run's routing wait ended without an established MCP connection (timeout or routing failure)."
        }
    }
}

/// Unified lease actor for the MCP bootstrap policy and routing lifecycle.
///
/// Policy installation remains serialized across shared MCP client types. PID-owned policies
/// release the process-global gate as soon as the unique run policy is confirmed armed, allowing
/// independent provider processes to initialize concurrently while their routing waits remain isolated.
/// Legacy policies without expected-PID ownership retain release-on-routed serialization.
///
/// ## Lifecycle
/// 1. `acquire()` — registers routing, acquires the gate, installs and arms the policy
/// 2. PID-owned policies release the gate immediately; routing state stays retained by the lease
/// 3. `releaseWhenRouted()` — waits for routing (or timeout) and cleans retained state
/// 4. `cancelAndCleanup()` — emergency cleanup on cancellation
///
/// ## Additional operations (agent-mode specific)
/// - `releaseWithoutRoutingWait()` — releases gate immediately (when no fresh connection is expected)
/// - `releaseGateForDeferredRouting()` — releases the gate while retaining pending routing/policy state
actor MCPBootstrapLease {
    private let log = Logger(subsystem: "com.repoprompt.mcp", category: "BootstrapLease")

    private var spec: MCPBootstrapLeaseSpec
    private let mcpServerEnabler: (() async -> Void)?
    private let policyInstaller: (MCPBootstrapLeaseSpec) async -> Void
    private let expectedPIDPolicyArmer: (MCPBootstrapLeaseSpec) async -> Bool
    private let policyClearer: (MCPBootstrapLeaseSpec) async -> Void
    private let routeAuthorityResolver: (MCPBootstrapLeaseSpec) async -> MCPRunRouteAuthorityDecision

    private var hasAcquired = false
    private var hasReleased = false
    private var cleanupRequested = false
    private var ownsGate = false
    private var routingRegistered = false
    private var policyInstalled = false
    private var didSignalRoutingFailure = false
    private var didReleaseGate = false
    /// Lease-local terminal memory survives teardown of the process-global waiter state. Because a
    /// lease is permanently scoped to one immutable run and releaseRouting is one-shot, this cache
    /// cannot confer routing authority on a successor run.
    private var routingTerminalOutcome: MCPRoutingWaitOutcome?
    // Memoized in-flight cleanup operations backing the joinable clear/teardown (see clearPolicyOnce()).
    private var policyClearOperation: Task<Void, Never>?
    private var routingCleanupOperation: Task<Void, Never>?
    #if DEBUG
        // Test-only observability for the join probe (see debugWaitForPolicyClearJoiner()).
        private var debugPolicyClearJoinerCount = 0
        private var debugPolicyClearJoinWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    /// Creates a unified bootstrap lease.
    ///
    /// - Parameters:
    ///   - spec: The run specification (run ID, gate ID, policy parameters, etc.)
    ///   - mcpServerEnabler: Optional hook to ensure the MCP server is started before acquisition.
    ///     Agent-mode provides this; headless flows typically don't need it.
    ///   - policyInstaller: Installs the per-run connection policy. Defaults to calling
    ///     `ServerNetworkManager.shared.installClientConnectionPolicy(...)`.
    ///   - expectedPIDPolicyArmer: Confirms the intended pending policy is uniquely PID-owned.
    ///   - policyClearer: Clears the per-run connection policy on failure/timeout. Defaults to calling
    ///     `ServerNetworkManager.shared.clearClientConnectionPolicy(...)`.
    init(
        spec: MCPBootstrapLeaseSpec,
        mcpServerEnabler: (() async -> Void)? = nil,
        policyInstaller: ((MCPBootstrapLeaseSpec) async -> Void)? = nil,
        expectedPIDPolicyArmer: ((MCPBootstrapLeaseSpec) async -> Bool)? = nil,
        policyClearer: ((MCPBootstrapLeaseSpec) async -> Void)? = nil,
        routeAuthorityResolver: ((MCPBootstrapLeaseSpec) async -> MCPRunRouteAuthorityDecision)? = nil
    ) {
        self.spec = spec
        self.mcpServerEnabler = mcpServerEnabler
        self.policyInstaller = policyInstaller ?? Self.defaultPolicyInstaller
        self.expectedPIDPolicyArmer = expectedPIDPolicyArmer ?? Self.defaultExpectedPIDPolicyArmer
        self.policyClearer = policyClearer ?? Self.defaultPolicyClearer
        self.routeAuthorityResolver = routeAuthorityResolver ?? Self.defaultRouteAuthorityResolver
    }

    // MARK: - Core Lifecycle

    /// Atomically acquires the global gate, registers routing, and installs connection policy.
    /// PID-owned policies release the gate after their unique pending policy is confirmed armed.
    /// Returns `false` if cancelled, the gate could not be acquired, or PID ownership could not be armed.
    func acquire() async -> Bool {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() ignored because lease already released")
            return false
        }
        if hasAcquired {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() returning cached success")
            return true
        }

        let runID = spec.runID
        let gateID = spec.gateID
        acpLeaseLog("[ACP-Runner] lease run=\(runID) gate=\(gateID) acquire() begin client=\(spec.clientName ?? "<none>") window=\(spec.windowID) purpose=\(spec.purpose.rawValue)")

        // Ensure MCP server is started (agent-mode hook)
        if let enabler = mcpServerEnabler {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) enabling MCP server before gate acquire")
            await enabler()
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) MCP server enabler completed")
            if shouldAbortAcquire {
                await cancelAndCleanup()
                return false
            }
        }

        // Register routing state before gate acquisition
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) registering routing waiter")
        await MCPRoutingWaiter.register(runID: spec.runID)
        routingRegistered = true
        if shouldAbortAcquire {
            await cancelAndCleanup()
            return false
        }
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "routing_waiter_registered",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "window_id": String(spec.windowID),
                    "tab_id": spec.tabID?.uuidString ?? "nil",
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) routing waiter registered")

        return await withTaskCancellationHandler {
            // Atomically wait + acquire the global gate.
            let gateSnapshot = await HeadlessAgentConnectionGate.snapshot()
            await recordDiagnosticEvent(
                "lease_gate_wait_started",
                fields: [
                    "active_gate_id": gateSnapshot.activeConnectionID?.uuidString ?? "nil",
                    "queue_depth": String(gateSnapshot.queueDepth)
                ]
            )
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) waiting to acquire global MCP gate")
            let gateAcquisition = await HeadlessAgentConnectionGate.acquireWithDiagnostics(spec.gateID)
            if gateAcquisition.acquired {
                ownsGate = true
            }
            await recordDiagnosticEvent(
                gateAcquisition.acquired ? "lease_gate_acquired" : "lease_gate_acquire_failed",
                fields: [
                    "active_gate_id_at_start": gateAcquisition.activeConnectionIDAtStart?.uuidString ?? "nil",
                    "queue_depth_at_start": String(gateAcquisition.queueDepthAtStart),
                    "queue_depth_at_acquire": String(gateAcquisition.queueDepthAtAcquire),
                    "wait_duration_ms": String(format: "%.3f", gateAcquisition.waitDurationMS)
                ]
            )
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) global MCP gate acquired=\(gateAcquisition.acquired)")
            if !gateAcquisition.acquired || shouldAbortAcquire {
                acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() failed, was released, or task cancelled")
                await cancelAndCleanup()
                return false
            }

            // Install per-run connection policy
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) installing connection policy for client=\(spec.clientName ?? "<none>")")
            await policyInstaller(spec)
            policyInstalled = true
            if shouldAbortAcquire {
                await cancelAndCleanup()
                return false
            }
            if spec.requiresExpectedAgentPID {
                let policyArmed = await expectedPIDPolicyArmer(spec)
                await recordDiagnosticEvent(
                    "lease_expected_pid_policy_armed",
                    fields: ["armed": String(policyArmed)]
                )
                guard policyArmed else {
                    acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) expected-PID policy could not be armed")
                    await cancelAndCleanup()
                    return false
                }
                if shouldAbortAcquire {
                    await cancelAndCleanup()
                    return false
                }
            }
            #if DEBUG
                await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                    runID: spec.runID,
                    event: "lease_policy_ready",
                    fields: [
                        "client_name": spec.clientName ?? "nil",
                        "requires_expected_pid": String(spec.requiresExpectedAgentPID),
                        "window_id": String(spec.windowID),
                        "tab_id": spec.tabID?.uuidString ?? "nil"
                    ]
                )
            #endif
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) connection policy installed")
            if shouldAbortAcquire {
                acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) task cancelled or lease released after policy install")
                await cancelAndCleanup()
                return false
            }

            hasAcquired = true
            if spec.requiresExpectedAgentPID {
                // The pending policy is now uniquely run-scoped and PID-owned. Release the
                // process-global gate before spawning so independent sessions may initialize
                // concurrently; the routing waiter and policy remain owned by this lease.
                await releaseOwnedGate(reason: "expected_pid_policy_armed")
            }
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() completed")
            return true
        } onCancel: {
            acpLeaseLog("[ACP-Runner] lease run=\(runID) gate=\(gateID) acquire() cancellation handler invoked")
            Task { await self.cancelAndCleanup() }
        }
    }

    // MARK: - Release Strategies

    private enum RoutingWaitSelection {
        case absolute(timeoutMs: Int)
        case adaptive(MCPRoutingWaitPolicy)
        case indefinite
    }

    /// Legacy compatibility API. The Boolean wrapper retains one absolute deadline and
    /// deliberately ignores matching-connection observation.
    @discardableResult
    func releaseWhenRouted(
        timeoutMs: Int = 10000,
        progressReporter: MCPBootstrapRoutingProgressReporter? = nil
    ) async -> Bool {
        let outcome = await releaseRouting(
            selection: .absolute(timeoutMs: timeoutMs),
            progressReporter: progressReporter
        )
        return outcome.routed
    }

    /// Typed adaptive API retained for callers that require bounded readiness.
    func releaseWhenRouted(
        waitPolicy: MCPRoutingWaitPolicy,
        progressReporter: MCPBootstrapRoutingProgressReporter? = nil
    ) async -> MCPRoutingWaitOutcome {
        await releaseRouting(
            selection: .adaptive(waitPolicy),
            progressReporter: progressReporter
        )
    }

    /// Waits until routing commits, ownership is lost, or the caller cancels. Elapsed time is not terminal.
    func releaseWhenRoutedIndefinitely(
        progressReporter: MCPBootstrapRoutingProgressReporter? = nil
    ) async -> MCPRoutingWaitOutcome {
        await releaseRouting(
            selection: .indefinite,
            progressReporter: progressReporter
        )
    }

    /// Returns a routing terminal signal that may have arrived before the waiter task enrolled.
    func currentRoutingTerminalOutcome() async -> MCPRoutingWaitOutcome? {
        if let routingTerminalOutcome {
            return routingTerminalOutcome
        }
        return await MCPRoutingWaiter.currentTerminalOutcome(runID: spec.runID)
    }

    /// Resolves a provider-boundary race through the same route authority used by bounded waits.
    /// Re-signaling a confirmed route prevents notification lag from parking the indefinite waiter.
    func resolveRouteAuthorityAtProviderCompletion() async -> MCPRunRouteAuthorityDecision {
        let decision = await routeAuthorityResolver(spec)
        if decision == .committed {
            await MCPRoutingWaiter.notifyRouted(runID: spec.runID)
        }
        return decision
    }

    private func releaseRouting(
        selection: RoutingWaitSelection,
        progressReporter: MCPBootstrapRoutingProgressReporter?
    ) async -> MCPRoutingWaitOutcome {
        guard !hasReleased else {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) routing release ignored because lease already released")
            return .failed(.cleanedUp)
        }
        hasReleased = true

        let timeoutMs: Int
        let waitPolicy: MCPRoutingWaitPolicy?
        switch selection {
        case let .absolute(value):
            timeoutMs = value
            waitPolicy = nil
        case let .adaptive(policy):
            timeoutMs = 0
            waitPolicy = policy
        case .indefinite:
            timeoutMs = 0
            waitPolicy = nil
        }

        if case .indefinite = selection {
            // PID-owned policies already released the gate during acquire. This also prevents
            // legacy ownership from parking the process-global gate for an unbounded wait.
            await releaseOwnedGate(reason: "indefinite_route_wait")
        }
        let ownedGateBeforeWait = ownsGate
        let progressLifecycle = progressReporter.map {
            MCPBootstrapRoutingProgressLifecycle(reporter: $0)
        }
        async let pendingReleaseResult = AgentRunCoordinator.shared.releaseGateWhenRouted(
            runID: spec.runID,
            gateID: spec.gateID,
            timeoutMs: timeoutMs,
            waitPolicy: waitPolicy,
            progressLifecycle: progressLifecycle
        )

        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "route_wait_started",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "timeout_ms": String(timeoutMs),
                    "adaptive": String(waitPolicy != nil),
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif

        let releaseResult = await pendingReleaseResult
        ownsGate = false
        var outcome = releaseResult.routingOutcome

        // A committed route can cross the waiter deadline before its notification is delivered.
        // Resolve that race through the route owner's conditional revocation fence. A fenced
        // timeout is revoked below through clearPolicyOnce so concurrent cancellation still
        // joins the lease's sole idempotent cleanup operation.
        var routeAuthorityDecision: MCPRunRouteAuthorityDecision?
        switch outcome {
        case .timedOutBeforeConnection, .timedOutAfterConnection:
            routeAuthorityDecision = await routeAuthorityResolver(spec)
            if routeAuthorityDecision == .committed {
                outcome = .routed
            }
        case .routed, .failed, .cancelled:
            break
        }

        // Publish the finalized result to this run's lease before any awaited diagnostics or
        // cleanup can erase MCPRoutingWaiter's process-global terminal state.
        routingTerminalOutcome = outcome

        if ownedGateBeforeWait || releaseResult.gateRelease.released {
            let gateReleaseReason = switch outcome {
            case .routed:
                "routing_completed"
            case .cancelled:
                "routing_cancelled"
            case .failed:
                "routing_failed"
            case .timedOutBeforeConnection:
                "routing_timeout_before_connection"
            case .timedOutAfterConnection:
                "routing_timeout_after_connection"
            }
            await recordGateRelease(releaseResult.gateRelease, reason: gateReleaseReason)
        }

        if !outcome.routed, policyInstalled,
           routeAuthorityDecision == nil || routeAuthorityDecision == .revocationFenced
        {
            await clearPolicyOnce()
        }
        if routingRegistered {
            await cleanupRoutingOnce()
        }

        await progressLifecycle?.finish(with: outcome)

        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "route_wait_completed",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "outcome": String(describing: outcome),
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif
        return outcome
    }

    /// Fail-closed routing readiness that consumes the typed absolute-deadline core.
    func requireRouting(timeoutMs: Int = 10000) async throws {
        let outcome = await releaseRouting(
            selection: .absolute(timeoutMs: timeoutMs),
            progressReporter: nil
        )
        switch outcome {
        case .routed:
            return
        case .cancelled:
            throw CancellationError()
        case .failed, .timedOutBeforeConnection, .timedOutAfterConnection:
            throw MCPBootstrapReadinessError.routingUnavailable
        }
    }

    // MARK: - Joinable Cleanup

    /// Clears the per-run connection policy at most once and lets every caller of this helper join
    /// the same in-flight clear: such a caller never returns before a clear started on another path
    /// (e.g. a racing ``cancelAndCleanup()``) has completed. Fast-path exits that skip this helper —
    /// e.g. a repeated call on an already-released lease — are outside that barrier.
    private func clearPolicyOnce() async {
        if let existing = policyClearOperation {
            #if DEBUG
                debugPolicyClearJoinerCount += 1
                for waiter in debugPolicyClearJoinWaiters {
                    waiter.resume()
                }
                debugPolicyClearJoinWaiters.removeAll()
            #endif
            await existing.value
            return
        }
        let operation = Task { await self.policyClearer(self.spec) }
        policyClearOperation = operation
        await operation.value
    }

    /// Tears down routing state at most once; joinable under the same single-flight rule as
    /// ``clearPolicyOnce()``.
    private func cleanupRoutingOnce() async {
        if let existing = routingCleanupOperation {
            await existing.value
            return
        }
        let operation = Task { await AgentRunCoordinator.shared.cleanupRouting(runID: self.spec.runID) }
        routingCleanupOperation = operation
        await operation.value
    }

    #if DEBUG
        /// Awaits the next caller joining an in-flight ``clearPolicyOnce()`` operation and returns the
        /// observed joiner count, so tests can deterministically prove a second caller entered the
        /// existing-operation branch while the primary clear is still parked.
        func debugWaitForPolicyClearJoiner() async -> Int {
            if debugPolicyClearJoinerCount == 0 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    debugPolicyClearJoinWaiters.append(continuation)
                }
            }
            return debugPolicyClearJoinerCount
        }
    #endif

    /// Releases the global connection gate without waiting for a routing signal.
    /// Use this when no fresh connection is expected but we still need to free the gate.
    func releaseWithoutRoutingWait() async {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWithoutRoutingWait() ignored because lease already released")
            return
        }
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releasing gate without waiting for routing")
        await releaseOwnedGate(reason: "without_routing_wait")
        await cleanupRoutingOnce()
    }

    /// Releases only the serialized bootstrap gate while retaining the pending run policy.
    /// Use this for ACP runtimes that do not open their MCP transport until the first prompt.
    func releaseGateForDeferredRouting() async {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseGateForDeferredRouting() ignored because lease already released")
            return
        }
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) deferring route wait until provider prompt")
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "route_wait_deferred",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif
        await releaseOwnedGate(reason: "deferred_routing")
    }

    /// Cleans up deferred routing state after a prompt-deferred provider reaches a terminal state
    /// without needing to report a bootstrap failure.
    func cleanupDeferredRouting() async {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) cleanupDeferredRouting() ignored because lease already released")
            return
        }
        cleanupRequested = true
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) cleaning up deferred routing state")
        await performDeferredRoutingCleanup(reason: "deferred_terminal")
    }

    // MARK: - Failure & Cancellation

    /// Hard failure path: signal routing failure and release gate immediately.
    func failAndRelease() async {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) failAndRelease() ignored because lease already released")
            return
        }
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) failAndRelease() signaling routing failure")
        await MCPRoutingWaiter.notifyFailed(runID: spec.runID)
        _ = await releaseWhenRouted()
    }

    /// Hard failure path variant used by headless flows.
    func failAndCleanup() async {
        cleanupRequested = true
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) failAndCleanup() signaling failure and clearing policy")
        await performCancellationCleanup(reason: "failed")
    }

    /// Cancellation path: signal failure, release any gate ownership that materializes,
    /// clear installed policy, and clean up routing. Cleanup remains retryable while a
    /// queued gate acquisition is still suspended.
    func cancelAndCleanup() async {
        cleanupRequested = true
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) cancelAndCleanup() signaling failure and releasing gate")
        await performCancellationCleanup(reason: "cancelled")
    }

    private var shouldAbortAcquire: Bool {
        cleanupRequested || hasReleased || Task.isCancelled
    }

    func providerInitializationStarted(provider: String) async {
        await recordDiagnosticEvent(
            "provider_initialization_started",
            fields: ["provider": provider]
        )
    }

    func providerInitializationCompleted(provider: String, outcome: String) async {
        await recordDiagnosticEvent(
            "provider_initialization_completed",
            fields: [
                "provider": provider,
                "outcome": outcome
            ]
        )
    }

    private func releaseOwnedGate(reason: String) async {
        guard ownsGate else { return }
        let result = await HeadlessAgentConnectionGate.completeIfActiveWithDiagnostics(spec.gateID)
        ownsGate = false
        didReleaseGate = didReleaseGate || result.released
        await recordGateRelease(result, reason: reason)
    }

    private func recordGateRelease(
        _ result: HeadlessAgentConnectionGate.ReleaseResult,
        reason: String
    ) async {
        await recordDiagnosticEvent(
            "lease_gate_release",
            fields: [
                "reason": reason,
                "released": String(result.released),
                "active_gate_id_before_release": result.activeConnectionIDBeforeRelease?.uuidString ?? "nil",
                "queue_depth_before_release": String(result.queueDepthBeforeRelease),
                "resumed_waiter": String(result.resumedWaiter)
            ]
        )
    }

    private func recordDiagnosticEvent(
        _ event: String,
        fields: [String: String] = [:]
    ) async {
        #if DEBUG
            var diagnosticFields: [String: String] = [
                "client_name": spec.clientName ?? "nil",
                "connection_id": "nil",
                "gate_id": spec.gateID.uuidString,
                "window_id": String(spec.windowID),
                "tab_id": spec.tabID?.uuidString ?? "nil",
                "requires_expected_pid": String(spec.requiresExpectedAgentPID)
            ]
            for (key, value) in fields {
                diagnosticFields[key] = value
            }
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: event,
                fields: diagnosticFields
            )
            AgentModePerfDiagnostics.event(
                "mcp.routing.\(event)",
                tabID: spec.tabID,
                fields: diagnosticFields
            )
        #endif
    }

    private func performCancellationCleanup(reason: String) async {
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_cancelled",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "gate_id": spec.gateID.uuidString,
                    "reason": reason
                ]
            )
        #endif
        if routingRegistered, !didSignalRoutingFailure {
            didSignalRoutingFailure = true
            await MCPRoutingWaiter.notifyFailed(runID: spec.runID)
        }
        await releaseOwnedGate(reason: reason)
        if policyInstalled {
            await clearPolicyOnce()
        }
        if routingRegistered {
            await cleanupRoutingOnce()
        }
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_cleanup_completed",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "reason": reason,
                    "owns_gate": String(ownsGate),
                    "gate_released": String(didReleaseGate),
                    "routing_cleaned": String(routingCleanupOperation != nil),
                    "policy_installed": String(policyInstalled),
                    "policy_cleared": String(policyClearOperation != nil)
                ]
            )
        #endif
    }

    private func performDeferredRoutingCleanup(reason: String) async {
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_deferred_cleanup",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "gate_id": spec.gateID.uuidString,
                    "reason": reason
                ]
            )
        #endif
        await releaseOwnedGate(reason: reason)
        if policyInstalled {
            await clearPolicyOnce()
        }
        if routingRegistered {
            await cleanupRoutingOnce()
        }
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_cleanup_completed",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "reason": reason,
                    "owns_gate": String(ownsGate),
                    "gate_released": String(didReleaseGate),
                    "routing_cleaned": String(routingCleanupOperation != nil),
                    "policy_installed": String(policyInstalled),
                    "policy_cleared": String(policyClearOperation != nil)
                ]
            )
        #endif
    }

    // MARK: - Default Policy Hooks

    private static let defaultExpectedPIDPolicyArmer: (MCPBootstrapLeaseSpec) async -> Bool = { spec in
        guard spec.requiresExpectedAgentPID, let clientName = spec.clientName else {
            return !spec.requiresExpectedAgentPID
        }
        return await ServerNetworkManager.shared.requireExpectedAgentPIDForPendingPolicy(
            for: clientName,
            runID: spec.runID,
            windowID: spec.windowID
        )
    }

    private static let defaultPolicyInstaller: (MCPBootstrapLeaseSpec) async -> Void = { spec in
        guard let clientName = spec.clientName else { return }
        await ServerNetworkManager.shared.installClientConnectionPolicy(
            for: clientName,
            windowID: spec.windowID,
            restrictedTools: spec.restrictedTools,
            oneShot: spec.oneShot,
            reason: spec.reason,
            ttl: spec.ttl,
            tabID: spec.tabID,
            runID: spec.runID,
            additionalTools: spec.additionalTools,
            purpose: spec.purpose,
            taskLabelKind: spec.taskLabelKind,
            allowsAgentExternalControlTools: spec.allowsAgentExternalControlTools,
            requiresExpectedAgentPID: spec.requiresExpectedAgentPID,
            prunesOnlyAfterSettlement: spec.purpose == .discoverRun
        )
    }

    private static let defaultPolicyClearer: (MCPBootstrapLeaseSpec) async -> Void = { spec in
        guard let clientName = spec.clientName else { return }
        await ServerNetworkManager.shared.revokeClientConnectionPolicy(
            for: clientName,
            windowID: spec.windowID,
            runID: spec.runID
        )
    }

    private static let defaultRouteAuthorityResolver: (MCPBootstrapLeaseSpec) async -> MCPRunRouteAuthorityDecision = { spec in
        await ServerNetworkManager.shared.confirmCommittedRunRouteOrFenceRevocation(
            runID: spec.runID,
            windowID: spec.windowID,
            tabID: spec.tabID
        )
    }
}
