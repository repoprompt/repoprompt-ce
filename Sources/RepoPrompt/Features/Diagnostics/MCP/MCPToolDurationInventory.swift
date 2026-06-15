import Foundation
import MCP
import RepoPromptShared

#if DEBUG
    /// Payload-free inventory of the server-wide Codex timeout and the independent
    /// RepoPrompt dispatch-boundary execution contracts.
    enum MCPToolDurationInventory {
        struct ConditionalExecutionOverride: Equatable {
            let action: String
            let condition: String
            let executionDeadlineSeconds: Double
            let cleanupGraceSeconds: Double
        }

        struct Entry: Equatable {
            let toolName: String
            let contractKind: MCPToolExecutionContract.Kind
            let executionDeadlineSeconds: Double?
            let cleanupGraceSeconds: Double?
            let expectedActiveDuration: String
            let evidence: String
            let qualification: String
            let semanticWaitMaximumSeconds: Double?
            let conditionalExecutionOverrides: [ConditionalExecutionOverride]
        }

        static let activeTimeoutSeconds = MCPTimeoutPolicy.codexServerActiveTimeoutSeconds
        static let timeoutScope = "per_mcp_server"
        static let perToolTimeoutOverridesSupported = false
        static let intentionalPhaseB3Deviation = true
        static let deviationReason = "Codex applies tool_timeout_sec to every tool on the RepoPromptCE server, while Oracle and Context Builder remain synchronous and can legitimately run for an hour or more."
        static let activeTimeoutSemantics = "RepoPromptCE intentionally preserves a \(MCPTimeoutPolicy.codexServerActiveTimeoutSeconds.formatted())-active-second per-server timeout. The separate dispatch-boundary execution contract bounds computational/local tools expected to finish within \(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds) seconds and switch-producing manage_workspaces calls within \(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds) seconds; other workspace/VCS lifecycle actions retain explicit cancellable exemptions."
        static let wallClockMayBeLongerDuringElicitation = true
        static let customUIWaitsAreElicitation = false
        static let boundedExecutionDeadlineSeconds = MCPTimeoutPolicy.boundedToolExecutionDeadline.mcpSeconds
        static let workspaceSwitchExecutionDeadlineSeconds = MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadline.mcpSeconds
        static let boundedCleanupGraceSeconds = MCPTimeoutPolicy.boundedToolCancellationCleanupGrace.mcpSeconds

        static let entries: [Entry] = MCPToolExecutionContractCatalog.orderedAdvertisedToolNames.map { toolName in
            guard let contract = MCPToolExecutionContractCatalog.contract(for: toolName) else {
                preconditionFailure("Missing MCP execution contract for \(toolName)")
            }
            return entry(toolName: toolName, contract: contract)
        }

        static var preservedLongSynchronousToolNames: [String] {
            entries.compactMap { entry in
                entry.contractKind == .longSynchronousCancellable ? entry.toolName : nil
            }
        }

        static var lifecycleManagedToolNames: [String] {
            entries.compactMap { entry in
                entry.contractKind == .lifecycleManagedCancellable ? entry.toolName : nil
            }
        }

        static var interactiveToolNames: [String] {
            entries.compactMap { entry in
                entry.contractKind == .interactiveCancellable ? entry.toolName : nil
            }
        }

        static var workspaceLifecycleToolNames: [String] {
            entries.compactMap { entry in
                entry.contractKind == .workspaceLifecycleCancellable ? entry.toolName : nil
            }
        }

        static var boundedToolNames: [String] {
            entries.compactMap { entry in
                entry.contractKind == .bounded ? entry.toolName : nil
            }
        }

        static var debugSnapshot: [String: Any] {
            [
                "payload_logging": false,
                "timeout_active_seconds": activeTimeoutSeconds,
                "timeout_scope": timeoutScope,
                "per_tool_timeout_overrides_supported": perToolTimeoutOverridesSupported,
                "intentional_phase_b3_deviation": intentionalPhaseB3Deviation,
                "phase_b3_deviation_reason": deviationReason,
                "timeout_semantics": activeTimeoutSemantics,
                "wall_clock_may_be_longer_during_elicitation": wallClockMayBeLongerDuringElicitation,
                "custom_ui_waits_are_mcp_elicitation": customUIWaitsAreElicitation,
                "bounded_execution_deadline_seconds": boundedExecutionDeadlineSeconds,
                "workspace_switch_execution_deadline_seconds": workspaceSwitchExecutionDeadlineSeconds,
                "bounded_cleanup_grace_seconds": boundedCleanupGraceSeconds,
                "preserved_long_synchronous_tools": preservedLongSynchronousToolNames,
                "lifecycle_managed_tools": lifecycleManagedToolNames,
                "interactive_tools": interactiveToolNames,
                "workspace_lifecycle_tools": workspaceLifecycleToolNames,
                "bounded_tools": boundedToolNames,
                "tools": entries.map { entry in
                    var payload: [String: Any] = [
                        "tool": entry.toolName,
                        "execution_contract": entry.contractKind.rawValue,
                        "expected_active_duration": entry.expectedActiveDuration,
                        "evidence": entry.evidence,
                        "qualification": entry.qualification
                    ]
                    if let executionDeadlineSeconds = entry.executionDeadlineSeconds {
                        payload["execution_deadline_seconds"] = executionDeadlineSeconds
                    }
                    if let cleanupGraceSeconds = entry.cleanupGraceSeconds {
                        payload["cleanup_grace_seconds"] = cleanupGraceSeconds
                    }
                    if let semanticWaitMaximumSeconds = entry.semanticWaitMaximumSeconds {
                        payload["semantic_wait_maximum_seconds"] = semanticWaitMaximumSeconds
                    }
                    if !entry.conditionalExecutionOverrides.isEmpty {
                        payload["conditional_execution_overrides"] = entry.conditionalExecutionOverrides.map { override in
                            [
                                "action": override.action,
                                "condition": override.condition,
                                "execution_contract": MCPToolExecutionContract.Kind.bounded.rawValue,
                                "execution_deadline_seconds": override.executionDeadlineSeconds,
                                "cleanup_grace_seconds": override.cleanupGraceSeconds
                            ]
                        }
                    }
                    return payload
                }
            ]
        }

        private static func entry(
            toolName: String,
            contract: MCPToolExecutionContract
        ) -> Entry {
            let semanticWaitMaximumSeconds: Double? = switch toolName {
            case MCPWindowToolName.applyEdits:
                MCPTimeoutPolicy.applyEditsApprovalTimeoutSeconds
            case MCPWindowToolName.manageWorktree:
                MCPTimeoutPolicy.worktreeMergeApprovalTimeoutSeconds
            default:
                nil
            }
            let conditionalExecutionOverrides: [ConditionalExecutionOverride] = if toolName == MCPGlobalToolName.manageWorkspaces {
                [
                    ConditionalExecutionOverride(
                        action: "switch",
                        condition: "always",
                        executionDeadlineSeconds: workspaceSwitchExecutionDeadlineSeconds,
                        cleanupGraceSeconds: boundedCleanupGraceSeconds
                    ),
                    ConditionalExecutionOverride(
                        action: "create",
                        condition: "switch_to_created != false (handler default)",
                        executionDeadlineSeconds: workspaceSwitchExecutionDeadlineSeconds,
                        cleanupGraceSeconds: boundedCleanupGraceSeconds
                    ),
                    ConditionalExecutionOverride(
                        action: "delete",
                        condition: "close_window == true",
                        executionDeadlineSeconds: workspaceSwitchExecutionDeadlineSeconds,
                        cleanupGraceSeconds: boundedCleanupGraceSeconds
                    )
                ]
            } else {
                []
            }

            switch contract {
            case let .bounded(deadline, cancellationGrace):
                return Entry(
                    toolName: toolName,
                    contractKind: contract.kind,
                    executionDeadlineSeconds: deadline.mcpSeconds,
                    cleanupGraceSeconds: cancellationGrace.mcpSeconds,
                    expectedActiveDuration: "Ordinary dispatch must complete within \(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds) seconds.",
                    evidence: "ServerNetworkManager applies MCPToolExecutionWatchdog at the resolved provider boundary.",
                    qualification: "Cancellation must release provider, limiter, ownership, and run-registration state; an uncooperative handler force-disconnects its connection after grace.",
                    semanticWaitMaximumSeconds: semanticWaitMaximumSeconds,
                    conditionalExecutionOverrides: conditionalExecutionOverrides
                )
            case .longSynchronousCancellable:
                return Entry(
                    toolName: toolName,
                    contractKind: contract.kind,
                    executionDeadlineSeconds: nil,
                    cleanupGraceSeconds: nil,
                    expectedActiveDuration: "May remain synchronously active beyond \(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds) seconds.",
                    evidence: "The product contract explicitly exempts Oracle operations and Context Builder while preserving external cancellation.",
                    qualification: "Keep the \(MCPTimeoutPolicy.codexServerActiveTimeoutSeconds.formatted())-active-second Codex server timeout until this workflow gains a detached lifecycle or separate server.",
                    semanticWaitMaximumSeconds: nil,
                    conditionalExecutionOverrides: conditionalExecutionOverrides
                )
            case .lifecycleManagedCancellable:
                return Entry(
                    toolName: toolName,
                    contractKind: contract.kind,
                    executionDeadlineSeconds: nil,
                    cleanupGraceSeconds: nil,
                    expectedActiveDuration: "Long work is owned by start/poll/wait/cancel lifecycle operations.",
                    evidence: "agent_run and agent_explore expose detached lifecycle control rather than an ordinary synchronous provider contract.",
                    qualification: "Cancelling an individual control request must not implicitly destroy the detached run unless the lifecycle operation requests cancellation.",
                    semanticWaitMaximumSeconds: nil,
                    conditionalExecutionOverrides: conditionalExecutionOverrides
                )
            case .interactiveCancellable:
                return Entry(
                    toolName: toolName,
                    contractKind: contract.kind,
                    executionDeadlineSeconds: nil,
                    cleanupGraceSeconds: nil,
                    expectedActiveDuration: "May wait for a user interaction beyond \(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds) seconds.",
                    evidence: "The tool exposes a cancellable UI interaction whose configured timeout remains authoritative.",
                    qualification: "User- or workspace-driven interaction waits are not clamped by the ordinary execution watchdog.",
                    semanticWaitMaximumSeconds: semanticWaitMaximumSeconds,
                    conditionalExecutionOverrides: conditionalExecutionOverrides
                )
            case .workspaceLifecycleCancellable:
                return Entry(
                    toolName: toolName,
                    contractKind: contract.kind,
                    executionDeadlineSeconds: nil,
                    cleanupGraceSeconds: nil,
                    expectedActiveDuration: "Workspace or VCS lifecycle work may legitimately exceed \(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds) seconds.",
                    evidence: "The tool can open, switch, hydrate, create, merge, or inspect workspace/repository lifecycle state.",
                    qualification: toolName == MCPGlobalToolName.manageWorkspaces
                        ? "Only switch-producing actions receive the \(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds)-second watchdog; all other manage_workspaces actions retain the workspace-lifecycle exemption."
                        : "External cancellation remains supported without imposing the ordinary computational-tool watchdog.",
                    semanticWaitMaximumSeconds: semanticWaitMaximumSeconds,
                    conditionalExecutionOverrides: conditionalExecutionOverrides
                )
            }
        }
    }

    extension ServerNetworkManager {
        func debugMCPToolDurationInventoryPayload(op: String) -> CallTool.Result {
            var payload = MCPToolDurationInventory.debugSnapshot
            payload["ok"] = true
            payload["op"] = op
            return debugDiagnosticsResult(payload)
        }
    }
#endif
