import Foundation
import OSLog

private func acpLeaseLog(_ message: @autoclosure () -> String) {
    guard AgentRuntimeProviderService.enableDebugLogging else { return }
    print(message())
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

/// Unified lease actor that owns the entire MCP "bootstrap window" that must be serialized
/// across all shared MCP client types — agent mode, headless agent runs, and any future flows.
///
/// This consolidates the gate acquisition, routing waiter registration, policy installation,
/// and release-on-routed semantics for all MCP bootstrap flows.
///
/// ## Lifecycle
/// 1. `acquire()` — registers routing, acquires gate atomically, installs policy
/// 2. `releaseWhenRouted()` — releases gate when connection routing is established (or on timeout)
/// 3. `cancelAndCleanup()` — emergency cleanup on cancellation
///
/// ## Additional operations (agent-mode specific)
/// - `releaseWithoutRoutingWait()` — releases gate immediately (when no fresh connection is expected)
actor MCPBootstrapLease {
    private let log = Logger(subsystem: "com.repoprompt.mcp", category: "BootstrapLease")

    private var spec: MCPBootstrapLeaseSpec
    private let mcpServerEnabler: (() async -> Void)?
    private let policyInstaller: (MCPBootstrapLeaseSpec) async -> Void
    private let policyClearer: (MCPBootstrapLeaseSpec) async -> Void

    private var hasAcquired = false
    private var hasReleased = false
    private var cleanupRequested = false
    private var ownsGate = false
    private var routingRegistered = false
    private var policyInstalled = false
    private var didSignalRoutingFailure = false
    private var didCleanupRouting = false
    private var didClearPolicy = false

    /// Creates a unified bootstrap lease.
    ///
    /// - Parameters:
    ///   - spec: The run specification (run ID, gate ID, policy parameters, etc.)
    ///   - mcpServerEnabler: Optional hook to ensure the MCP server is started before acquisition.
    ///     Agent-mode provides this; headless flows typically don't need it.
    ///   - policyInstaller: Installs the per-run connection policy. Defaults to calling
    ///     `ServerNetworkManager.shared.installClientConnectionPolicy(...)`.
    ///   - policyClearer: Clears the per-run connection policy on failure/timeout. Defaults to calling
    ///     `ServerNetworkManager.shared.clearClientConnectionPolicy(...)`.
    init(
        spec: MCPBootstrapLeaseSpec,
        mcpServerEnabler: (() async -> Void)? = nil,
        policyInstaller: ((MCPBootstrapLeaseSpec) async -> Void)? = nil,
        policyClearer: ((MCPBootstrapLeaseSpec) async -> Void)? = nil
    ) {
        self.spec = spec
        self.mcpServerEnabler = mcpServerEnabler
        self.policyInstaller = policyInstaller ?? Self.defaultPolicyInstaller
        self.policyClearer = policyClearer ?? Self.defaultPolicyClearer
    }

    // MARK: - Core Lifecycle

    /// Atomically acquires the global gate, registers routing, and installs connection policy.
    /// Returns `false` if cancelled or the gate could not be acquired.
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
            // Atomically wait + acquire the global gate
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) waiting to acquire global MCP gate")
            let gateAcquired = await HeadlessAgentConnectionGate.acquire(spec.gateID)
            if gateAcquired {
                ownsGate = true
            }
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) global MCP gate acquired=\(gateAcquired)")
            if !gateAcquired || shouldAbortAcquire {
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
            if spec.requiresExpectedAgentPID, let clientName = spec.clientName {
                await ServerNetworkManager.shared.requireExpectedAgentPIDForPendingPolicy(
                    for: clientName,
                    runID: spec.runID,
                    windowID: spec.windowID
                )
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
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() completed")
            return true
        } onCancel: {
            acpLeaseLog("[ACP-Runner] lease run=\(runID) gate=\(gateID) acquire() cancellation handler invoked")
            Task { await self.cancelAndCleanup() }
        }
    }

    // MARK: - Release Strategies

    /// Releases the global gate once routing is established, or on timeout.
    /// If routing fails/times out, clears the pending policy entry.
    @discardableResult
    func releaseWhenRouted(timeoutMs: Int = 10000) async -> Bool {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWhenRouted() ignored because lease already released")
            return false
        }
        hasReleased = true

        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWhenRouted() waiting for routing client=\(spec.clientName ?? "<none>") timeoutMs=\(timeoutMs)")
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "route_wait_started",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "timeout_ms": String(timeoutMs),
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif
        let routed = await AgentRunCoordinator.shared.releaseGateWhenRouted(
            runID: spec.runID,
            gateID: spec.gateID,
            timeoutMs: timeoutMs
        )
        ownsGate = false
        didCleanupRouting = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWhenRouted() completed routed=\(routed)")
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "route_wait_completed",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "routed": String(routed),
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif

        if !routed {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) routing wait failed or timed out; clearing connection policy")
            await policyClearer(spec)
        }

        return routed
    }

    /// Releases the global connection gate without waiting for a routing signal.
    /// Use this when no fresh connection is expected but we still need to free the gate.
    func releaseWithoutRoutingWait() async {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWithoutRoutingWait() ignored because lease already released")
            return
        }
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releasing gate without waiting for routing")
        _ = await HeadlessAgentConnectionGate.completeIfActive(spec.gateID)
        ownsGate = false
        await AgentRunCoordinator.shared.cleanupRouting(runID: spec.runID)
        didCleanupRouting = true
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
        if ownsGate {
            _ = await HeadlessAgentConnectionGate.completeIfActive(spec.gateID)
            ownsGate = false
        }
        if routingRegistered, !didCleanupRouting {
            didCleanupRouting = true
            await AgentRunCoordinator.shared.cleanupRouting(runID: spec.runID)
        }
        if policyInstalled, !didClearPolicy {
            didClearPolicy = true
            await policyClearer(spec)
        }
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_cleanup_completed",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "reason": reason,
                    "owns_gate": String(ownsGate),
                    "policy_installed": String(policyInstalled)
                ]
            )
        #endif
    }

    // MARK: - Default Policy Hooks

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
            requiresExpectedAgentPID: spec.requiresExpectedAgentPID
        )
    }

    private static let defaultPolicyClearer: (MCPBootstrapLeaseSpec) async -> Void = { spec in
        guard let clientName = spec.clientName else { return }
        await ServerNetworkManager.shared.clearClientConnectionPolicy(
            for: clientName,
            windowID: spec.windowID,
            runID: spec.runID
        )
    }
}
