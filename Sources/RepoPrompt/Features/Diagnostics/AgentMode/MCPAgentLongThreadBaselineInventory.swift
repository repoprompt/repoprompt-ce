import Foundation

#if DEBUG
    /// Checked, payload-free Item 0 baseline and cross-cutting seam inventory.
    ///
    /// This is intentionally code-owned so drift is reviewable with the implementation and
    /// available through the existing Agent Mode diagnostics snapshot without logging prompts,
    /// transcript text, tool arguments, tool results, or provider payloads.
    enum MCPAgentLongThreadBaselineInventory {
        struct TestBaseline: Equatable {
            let command: String
            let filter: String
            let executedTests: Int
            let elapsedSeconds: Double
            let result: String
        }

        static let capturedAt = "2026-06-05"
        static let baselineRevision = "862413d32919019dfd96e58115479eae630c1883"
        static let baselines: [TestBaseline] = [
            .init(
                command: "make dev-test FILTER=AgentModeRunServiceLifecycleTests",
                filter: "AgentModeRunServiceLifecycleTests",
                executedTests: 5,
                elapsedSeconds: 0.891,
                result: "passed"
            ),
            .init(
                command: "make dev-test FILTER=AgentModeViewModelInactiveRefreshTests",
                filter: "AgentModeViewModelInactiveRefreshTests",
                executedTests: 6,
                elapsedSeconds: 0.061,
                result: "passed"
            ),
            .init(
                command: "make dev-test FILTER=PersistentMCPDistinctConnectionConcurrencyTests",
                filter: "PersistentMCPDistinctConnectionConcurrencyTests",
                executedTests: 3,
                elapsedSeconds: 4.266,
                result: "passed"
            )
        ]

        static let activeAgentSessionIDWriterInventory = [
            "AgentModeViewModel.swift:prepareSessionForRunStart",
            "AgentModeViewModel.swift:session(for:createIfNeeded:)",
            "AgentModeViewModel.swift:ensurePersistentSessionIdentity",
            "AgentModeViewModel.swift:applyPersistedSessionPayload",
            "AgentModeViewModel.swift:activateAgentSession",
            "AgentModeViewModel.swift:resolveMCPAgentSessionTarget",
            "AgentModeViewModel.swift:saveSession",
            "AgentModeViewModel.swift:bindSessionIfNeeded",
            "AgentModeViewModel.swift:deleteSession compose-tab cleanup",
            "AgentModeViewModel.swift:deleteSession stashed-tab cleanup",
            "AgentModeViewModel+StressHarnessSupport.swift:stored tab fixture",
            "AgentModeViewModel+StressHarnessSupport.swift:live session fixture",
            "PromptViewModel.swift:duplicateComposeTab reset",
            "WorkspaceManagerViewModel.swift:compose-tab binding removal",
            "WorkspaceManagerViewModel.swift:stashed-tab binding removal",
            "WorkspaceManagerViewModel.swift:compose-tab binding set",
            "WorkspaceManagerViewModel.swift:stashed-tab binding set"
        ]

        static let activeAgentSessionIDConstructionInventory = [
            "WorkspaceModel.swift:ComposeTabState.init",
            "WorkspaceModel.swift:ComposeTabState.decode",
            "MCPServerViewModel+TabContext.swift:AgentTabContext.init"
        ]

        static let agentRunSessionStorePublisherInventory = [
            "AgentModeViewModel.swift:publishMCPStateChange signalSnapshot",
            "AgentModeViewModel.swift:signalMCPInstructionDelivered signalSnapshotAndWakeWaiters",
            "AgentModeViewModel.swift:fireInstructionDelivered signalSnapshotAndWakeWaiters",
            "AgentModeViewModel.swift:fireSteeringRequested wakeCurrentWaiters",
            "AgentModeViewModel.swift:signalSteeringRequested wakeCurrentWaiters",
            "AgentRunMCPToolService.swift:cancelled multi-wait signalSnapshot",
            "AgentRunMCPToolService.swift:live multi-wait signalSnapshot",
            "AgentRunMCPToolService.swift:stored multi-wait signalSnapshot",
            "AgentRunMCPToolService.swift:replaceStaleActionableSnapshot signalSnapshot"
        ]

        static let agentRunSessionStoreRegistrationAndResetInventory = [
            "AgentModeViewModel.swift:mcpActivateControlContext register",
            "AgentModeViewModel.swift:resetSnapshotForNewTurn",
            "AgentRunMCPToolService.swift:dispatch resetSnapshotForNewTurn",
            "AgentRunMCPToolService.swift:wait resetSnapshotForNewTurn",
            "AgentRunMCPToolService.swift:replaceStaleActionableSnapshot resetSnapshotForNewTurn"
        ]

        static let agentRunSessionStoreCleanupInventory = [
            "AgentModeViewModel.swift:mcpDeactivateControlContext cleanup",
            "AgentModeViewModel.swift:mcpActivateControlContext prior-session cleanup",
            "AgentModeViewModel.swift:failed activation cleanup",
            "AgentModeViewModel.swift:deleted-session cleanup",
            "AgentExternalMCPRunStarter.swift:start failure cleanup",
            "AgentManageMCPToolService.swift:managed cleanup"
        ]

        static let receiveStreamTerminalBehavior = [
            "swift-sdk Server exits its detached receive loop when transport.receive() terminates; thrown receive errors are logged and are not surfaced through a host callback.",
            "swift-sdk StdioTransport finishes its receive stream normally on EOF or read failure rather than finish(throwing:).",
            "UnixSocketMCPTransport separately distinguishes clean EOF from truncated-frame failure and BootstrapSocketConnectionManager observes transport.closed() for cleanup."
        ]

        static let mainActorConstraint = "AIStreamResult has no Sendable conformance; provider stream iteration remains MainActor-first."

        static var debugSnapshot: [String: Any] {
            [
                "captured_at": capturedAt,
                "baseline_revision": baselineRevision,
                "payload_logging": false,
                "baselines": baselines.map {
                    [
                        "command": $0.command,
                        "filter": $0.filter,
                        "executed_tests": $0.executedTests,
                        "elapsed_seconds": $0.elapsedSeconds,
                        "result": $0.result
                    ]
                },
                "active_agent_session_id_writers": activeAgentSessionIDWriterInventory,
                "active_agent_session_id_construction": activeAgentSessionIDConstructionInventory,
                "agent_run_session_store_publishers": agentRunSessionStorePublisherInventory,
                "agent_run_session_store_registration_and_reset": agentRunSessionStoreRegistrationAndResetInventory,
                "agent_run_session_store_cleanup": agentRunSessionStoreCleanupInventory,
                "receive_stream_terminal_behavior": receiveStreamTerminalBehavior,
                "main_actor_constraint": mainActorConstraint
            ]
        }
    }
#endif
