import Foundation
import OSLog

/// Identifies the type of headless agent run.
enum AgentRunType {
    case discover
}

/// Specification describing a single agent run instance.
struct AgentRunSpec {
    let type: AgentRunType
    let runID: UUID
    let agentKind: AgentProviderKind
    /// Optional model identifier; when nil the CLI's default model is used.
    let modelString: String?
    /// Target window ID this run is associated with (for routing/policy).
    let windowID: Int
    /// Tools to restrict for this run (same pattern as discovery).
    let restrictedTools: Set<String>
    /// TTL in seconds for the client connection policy.
    let connectionTTL: TimeInterval
}

/// Shared coordinator for preparing, launching, and cleaning up headless agent runs.
/// This centralises policy installation and provider orchestration for headless runs.
final class AgentRunCoordinator {
    struct GateRoutingReleaseResult {
        let routingOutcome: MCPRoutingWaitOutcome
        let gateRelease: HeadlessAgentConnectionGate.ReleaseResult

        var routed: Bool {
            routingOutcome.routed
        }
    }

    static let shared = AgentRunCoordinator()

    private let log = Logger(subsystem: "com.repoprompt.agents", category: "AgentRunCoordinator")

    /// Default timeout for waiting for connection routing (10 seconds)
    private static let defaultRoutingTimeoutMs = 10000

    private init() {}

    /// Register routing state for a runID before any routing signals are expected.
    func registerRouting(runID: UUID) async {
        await MCPRoutingWaiter.register(runID: runID)
    }

    /// Cleanup routing state for a runID (idempotent backstop).
    func cleanupRouting(runID: UUID) async {
        await MCPRoutingWaiter.cleanup(runID: runID)
    }

    /// Maps agent run type to MCP run purpose for UI routing (e.g., ask_user).
    private func runPurpose(for type: AgentRunType) -> MCPRunPurpose {
        switch type {
        case .discover:
            .discoverRun
        }
    }

    /// Install a per-run client policy for the given agent, and acquire the global headless gate.
    /// - Returns: A lease that must be released via `lease.releaseWhenRouted(...)` or cleaned up via `lease.failAndCleanup()`.
    /// - Note: This prevents the "acquire gate without guaranteed release" footgun by centralizing gating.
    func prepareAndInstallPolicy(
        _ spec: AgentRunSpec,
        tabID: UUID? = nil,
        additionalTools: Set<String>? = nil,
        reason: String? = nil,
        gateID: UUID? = nil
    ) async throws -> MCPBootstrapLease {
        guard let clientName = spec.agentKind.mcpClientNameHint else {
            throw NSError(domain: "AgentRunCoordinator", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Missing MCP client name hint for agent \(spec.agentKind)"
            ])
        }

        let leaseSpec = MCPBootstrapLeaseSpec.headless(
            runID: spec.runID,
            gateID: gateID ?? UUID(),
            clientName: clientName,
            windowID: spec.windowID,
            restrictedTools: spec.restrictedTools,
            additionalTools: additionalTools,
            reason: reason ?? "\(spec.type)",
            ttl: spec.connectionTTL,
            tabID: tabID,
            purpose: runPurpose(for: spec.type),
            requiresExpectedAgentPID: spec.agentKind.requiresExpectedPIDOwnedAgentModeMCPRouting
        )

        let lease = MCPBootstrapLease(spec: leaseSpec)
        let acquired = await lease.acquire()
        guard acquired else { throw CancellationError() }
        return lease
    }

    /// Factory for headless agent providers (Claude Code, Codex Exec, etc.)
    func makeProvider(
        agentKind: AgentProviderKind,
        modelString: String?,
        runType: AgentRunType = .discover,
        workspacePath: String? = nil
    ) -> HeadlessAgentProvider {
        AgentRuntimeProviderService.shared.makeProvider(
            for: agentKind,
            modelString: modelString,
            runType: runType,
            workspacePath: workspacePath
        )
    }

    /// Run the provider and return its streaming result as-is.
    func runStream(provider: HeadlessAgentProvider, message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        try await provider.streamAgentMessage(message, runID: runID)
    }

    /// Cleanup ownership:
    /// - Policy cleanup: clearClientConnectionPolicy(for:windowID:) is invoked here.
    /// - Provider lifecycle: provider.dispose() is invoked here.
    /// Context Builder runs perform their own policy cleanup in ContextBuilderAgentViewModel (runContextBuilderAgent) to coordinate
    /// end‑of‑run tab‑context commit/clear ordering.
    func cleanup(_ spec: AgentRunSpec, provider: HeadlessAgentProvider?) async {
        if let clientName = spec.agentKind.mcpClientNameHint {
            await ServerNetworkManager.shared.clearClientConnectionPolicy(
                for: clientName,
                windowID: spec.windowID,
                runID: spec.runID
            )
        }
        if let provider {
            await provider.dispose()
        }
        await cleanupRouting(runID: spec.runID)
    }

    /// Waits for the runID to be routed (connection mapping established across windows) and then releases the gate.
    /// Always releases the gate on timeout to prevent deadlocks.
    ///
    /// Uses event-driven waiting via `MCPRoutingWaiter` instead of polling. The waiter is notified when:
    /// - `registerRunIDMapping` succeeds
    /// - cleanup or explicit routing failure resolves the run
    /// - the selected absolute/adaptive deadline expires
    /// - the individual waiting task is cancelled
    ///
    /// - Parameters:
    ///   - runID: The run identifier associated with routing state and waiter notifications.
    ///   - gateID: The gate ownership identifier to release when routing completes. Defaults to `runID`.
    ///   - timeoutMs: Maximum time to wait for routing before forcing release (default: 10,000 ms).
    /// - Returns: Routing and gate-release diagnostics for the run.
    @discardableResult
    func releaseGateWhenRouted(
        runID: UUID,
        gateID: UUID? = nil,
        timeoutMs: Int = defaultRoutingTimeoutMs,
        waitPolicy: MCPRoutingWaitPolicy? = nil,
        progressLifecycle: MCPBootstrapRoutingProgressLifecycle? = nil
    ) async -> GateRoutingReleaseResult {
        let timeoutSeconds = TimeInterval(timeoutMs) / 1000.0
        let routingOutcome: MCPRoutingWaitOutcome = if let waitPolicy {
            await MCPRoutingWaiter.waitForRoutingOutcome(
                runID: runID,
                policy: waitPolicy,
                progressLifecycle: progressLifecycle
            )
        } else {
            // Compatibility path: one absolute deadline that ignores connection observation.
            await MCPRoutingWaiter.waitForRoutingOutcome(
                runID: runID,
                timeoutSeconds: timeoutSeconds,
                progressLifecycle: progressLifecycle
            )
        }

        let gateKey = gateID ?? runID
        let gateRelease = await HeadlessAgentConnectionGate.completeIfActiveWithDiagnostics(gateKey)

        if routingOutcome.routed {
            log.info("Gate release after routing event: runID=\(runID.uuidString) gateID=\(gateKey.uuidString) released=\(gateRelease.released)")
        } else {
            log.info("Gate release after routing outcome \(String(describing: routingOutcome)): runID=\(runID.uuidString) gateID=\(gateKey.uuidString) released=\(gateRelease.released)")
        }

        return GateRoutingReleaseResult(
            routingOutcome: routingOutcome,
            gateRelease: gateRelease
        )
    }
}

// Temporary overload removed; ServerNetworkManager now exposes installClientConnectionPolicy directly.
