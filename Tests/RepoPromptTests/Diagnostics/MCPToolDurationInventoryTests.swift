import Foundation
import MCP
import Ontology
@testable import RepoPrompt
import RepoPromptShared
import XCTest

#if DEBUG
    final class MCPToolDurationInventoryTests: XCTestCase {
        func testInventoryCoversFullAdvertisedCatalogAndProjectsExecutionContracts() {
            XCTAssertEqual(
                MCPToolDurationInventory.entries.map(\.toolName),
                MCPToolExecutionContractCatalog.orderedAdvertisedToolNames
            )
            XCTAssertEqual(MCPToolDurationInventory.entries.count, 26)
            XCTAssertEqual(
                Set(MCPToolDurationInventory.entries.map(\.toolName)).count,
                MCPToolDurationInventory.entries.count
            )
            XCTAssertEqual(
                MCPToolDurationInventory.activeTimeoutSeconds,
                MCPTimeoutPolicy.codexServerActiveTimeoutSeconds
            )
            XCTAssertEqual(MCPToolDurationInventory.timeoutScope, "per_mcp_server")
            XCTAssertFalse(MCPToolDurationInventory.perToolTimeoutOverridesSupported)
            XCTAssertTrue(MCPToolDurationInventory.intentionalPhaseB3Deviation)
            XCTAssertEqual(
                MCPToolDurationInventory.boundedExecutionDeadlineSeconds,
                Double(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds)
            )
            XCTAssertEqual(
                MCPToolDurationInventory.boundedCleanupGraceSeconds,
                Double(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds)
            )
            XCTAssertEqual(
                MCPToolDurationInventory.workspaceSwitchExecutionDeadlineSeconds,
                Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds)
            )
            XCTAssertEqual(
                MCPToolDurationInventory.preservedLongSynchronousToolNames,
                [
                    MCPWindowToolName.search,
                    MCPWindowToolName.oracleUtils,
                    MCPWindowToolName.askOracle,
                    MCPWindowToolName.oracleSend,
                    MCPWindowToolName.oracleChatLog,
                    MCPWindowToolName.contextBuilder
                ]
            )
            XCTAssertEqual(
                MCPToolDurationInventory.lifecycleManagedToolNames,
                [
                    MCPWindowToolName.agentExplore,
                    MCPWindowToolName.agentRun
                ]
            )
            XCTAssertEqual(
                MCPToolDurationInventory.interactiveToolNames,
                [
                    MCPWindowToolName.applyEdits,
                    MCPWindowToolName.askUser,
                    MCPWindowToolName.waitForNextInstruction
                ]
            )
            XCTAssertEqual(
                MCPToolDurationInventory.workspaceLifecycleToolNames,
                [
                    MCPGlobalToolName.bindContext,
                    MCPGlobalToolName.manageWorkspaces,
                    MCPWindowToolName.git,
                    MCPWindowToolName.manageWorktree
                ]
            )
            XCTAssertEqual(MCPToolDurationInventory.boundedToolNames.count, 11)
            XCTAssertTrue(
                MCPToolDurationInventory.entries.allSatisfy {
                    !$0.expectedActiveDuration.isEmpty
                        && !$0.evidence.isEmpty
                        && !$0.qualification.isEmpty
                }
            )

            let applyEdits = MCPToolDurationInventory.entries.first {
                $0.toolName == MCPWindowToolName.applyEdits
            }
            XCTAssertEqual(
                applyEdits?.semanticWaitMaximumSeconds,
                MCPTimeoutPolicy.applyEditsApprovalTimeoutSeconds
            )
            let manageWorktree = MCPToolDurationInventory.entries.first {
                $0.toolName == MCPWindowToolName.manageWorktree
            }
            XCTAssertEqual(
                manageWorktree?.semanticWaitMaximumSeconds,
                MCPTimeoutPolicy.worktreeMergeApprovalTimeoutSeconds
            )
            let manageWorkspaces = try? XCTUnwrap(MCPToolDurationInventory.entries.first {
                $0.toolName == MCPGlobalToolName.manageWorkspaces
            })
            XCTAssertEqual(manageWorkspaces?.contractKind, .workspaceLifecycleCancellable)
            XCTAssertNil(manageWorkspaces?.executionDeadlineSeconds)
            XCTAssertNil(manageWorkspaces?.cleanupGraceSeconds)
            XCTAssertEqual(
                manageWorkspaces?.conditionalExecutionOverrides,
                [
                    .init(
                        action: "switch",
                        condition: "always",
                        executionDeadlineSeconds: Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds),
                        cleanupGraceSeconds: Double(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds)
                    ),
                    .init(
                        action: "create",
                        condition: "switch_to_created != false (handler default)",
                        executionDeadlineSeconds: Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds),
                        cleanupGraceSeconds: Double(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds)
                    ),
                    .init(
                        action: "delete",
                        condition: "close_window == true",
                        executionDeadlineSeconds: Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds),
                        cleanupGraceSeconds: Double(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds)
                    )
                ]
            )
            for toolName in [
                MCPWindowToolName.askUser,
                MCPWindowToolName.waitForNextInstruction,
                MCPWindowToolName.agentExplore,
                MCPWindowToolName.agentRun
            ] {
                let entry = try? XCTUnwrap(MCPToolDurationInventory.entries.first { $0.toolName == toolName })
                XCTAssertNil(entry?.semanticWaitMaximumSeconds)
            }
        }

        func testInventoryDiagnosticIsPayloadFreeAndSeparatesServerAndExecutionTimeouts() async throws {
            let result = await ServerNetworkManager.shared.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: ["op": .string("mcp_tool_duration_inventory")]
            )
            let text = try XCTUnwrap(result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.first)
            let data = try XCTUnwrap(text.data(using: .utf8))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )

            XCTAssertEqual(payload["ok"] as? Bool, true)
            XCTAssertEqual(payload["op"] as? String, "mcp_tool_duration_inventory")
            XCTAssertEqual(
                (payload["timeout_active_seconds"] as? NSNumber)?.intValue,
                MCPTimeoutPolicy.codexServerActiveTimeoutSeconds
            )
            XCTAssertEqual(
                (payload["bounded_execution_deadline_seconds"] as? NSNumber)?.intValue,
                MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds
            )
            XCTAssertEqual(
                (payload["bounded_cleanup_grace_seconds"] as? NSNumber)?.intValue,
                MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds
            )
            XCTAssertEqual(
                (payload["workspace_switch_execution_deadline_seconds"] as? NSNumber)?.intValue,
                MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds
            )
            XCTAssertEqual(payload["timeout_scope"] as? String, "per_mcp_server")
            XCTAssertEqual(payload["per_tool_timeout_overrides_supported"] as? Bool, false)
            XCTAssertEqual(payload["intentional_phase_b3_deviation"] as? Bool, true)
            XCTAssertTrue((payload["timeout_semantics"] as? String)?.contains("separate dispatch-boundary") == true)
            XCTAssertEqual(
                payload["lifecycle_managed_tools"] as? [String],
                [MCPWindowToolName.agentExplore, MCPWindowToolName.agentRun]
            )
            XCTAssertEqual(
                payload["interactive_tools"] as? [String],
                [
                    MCPWindowToolName.applyEdits,
                    MCPWindowToolName.askUser,
                    MCPWindowToolName.waitForNextInstruction
                ]
            )
            XCTAssertEqual(
                payload["workspace_lifecycle_tools"] as? [String],
                [
                    MCPGlobalToolName.bindContext,
                    MCPGlobalToolName.manageWorkspaces,
                    MCPWindowToolName.git,
                    MCPWindowToolName.manageWorktree
                ]
            )
            let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 26)
            let manageWorkspaces = try XCTUnwrap(tools.first {
                $0["tool"] as? String == MCPGlobalToolName.manageWorkspaces
            })
            XCTAssertEqual(
                manageWorkspaces["execution_contract"] as? String,
                MCPToolExecutionContract.Kind.workspaceLifecycleCancellable.rawValue
            )
            XCTAssertNil(manageWorkspaces["execution_deadline_seconds"])
            let conditionalOverrides = try XCTUnwrap(
                manageWorkspaces["conditional_execution_overrides"] as? [[String: Any]]
            )
            XCTAssertEqual(conditionalOverrides.map { $0["action"] as? String }, ["switch", "create", "delete"])
            XCTAssertEqual(
                conditionalOverrides.map { ($0["execution_deadline_seconds"] as? NSNumber)?.intValue },
                [120, 120, 120]
            )
            XCTAssertEqual(
                conditionalOverrides.map { $0["condition"] as? String },
                ["always", "switch_to_created != false (handler default)", "close_window == true"]
            )

            for forbiddenKey in [
                "prompt_text",
                "transcript_text",
                "tool_arguments",
                "tool_result",
                "provider_payload"
            ] {
                XCTAssertFalse(text.contains(forbiddenKey))
            }
        }
    }
#endif
