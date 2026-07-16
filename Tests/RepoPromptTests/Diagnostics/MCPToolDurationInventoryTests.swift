import Foundation
import MCP
import Ontology
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

#if DEBUG
    final class MCPToolDurationInventoryTests: XCTestCase {
        func testInventoryAndDiagnosticProjectPayloadFreeExecutionContracts() async throws {
            do {
                let caseLabel = "testInventoryCoversFullAdvertisedCatalogAndProjectsExecutionContracts"
                XCTAssertEqual(
                    MCPToolDurationInventory.entries.map(\.toolName),
                    MCPToolExecutionContractCatalog.orderedAdvertisedToolNames,
                    caseLabel
                )
                XCTAssertEqual(MCPToolDurationInventory.entries.count, 27, caseLabel)
                XCTAssertEqual(
                    Set(MCPToolDurationInventory.entries.map(\.toolName)).count,
                    MCPToolDurationInventory.entries.count,
                    caseLabel
                )
                XCTAssertEqual(
                    MCPToolDurationInventory.activeTimeoutSeconds,
                    MCPTimeoutPolicy.codexServerActiveTimeoutSeconds,
                    caseLabel
                )
                XCTAssertEqual(MCPToolDurationInventory.timeoutScope, "per_mcp_server", caseLabel)
                XCTAssertFalse(MCPToolDurationInventory.perToolTimeoutOverridesSupported, caseLabel)
                XCTAssertTrue(MCPToolDurationInventory.intentionalPhaseB3Deviation, caseLabel)
                XCTAssertEqual(
                    MCPToolDurationInventory.boundedExecutionDeadlineSeconds,
                    Double(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds),
                    caseLabel
                )
                XCTAssertEqual(
                    MCPToolDurationInventory.boundedCleanupGraceSeconds,
                    Double(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds),
                    caseLabel
                )
                XCTAssertEqual(
                    MCPToolDurationInventory.workspaceSwitchExecutionDeadlineSeconds,
                    Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds),
                    caseLabel
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
                    ],
                    caseLabel
                )
                XCTAssertEqual(
                    MCPToolDurationInventory.lifecycleManagedToolNames,
                    [MCPWindowToolName.agentExplore, MCPWindowToolName.agentRun],
                    caseLabel
                )
                XCTAssertEqual(
                    MCPToolDurationInventory.interactiveToolNames,
                    [
                        MCPWindowToolName.applyEdits,
                        MCPWindowToolName.askUser,
                        MCPWindowToolName.waitForNextInstruction
                    ],
                    caseLabel
                )
                XCTAssertEqual(
                    MCPToolDurationInventory.workspaceLifecycleToolNames,
                    [
                        MCPGlobalToolName.bindContext,
                        MCPGlobalToolName.manageWorkspaces,
                        MCPWindowToolName.git,
                        MCPWindowToolName.manageWorktree
                    ],
                    caseLabel
                )
                XCTAssertEqual(MCPToolDurationInventory.boundedToolNames.count, 12, caseLabel)
                XCTAssertEqual(
                    MCPToolDurationInventory.detachAndSettleToolNames,
                    [MCPWindowToolName.getCodeStructure],
                    caseLabel
                )
                XCTAssertTrue(
                    MCPToolDurationInventory.entries.allSatisfy {
                        !$0.expectedActiveDuration.isEmpty
                            && !$0.evidence.isEmpty
                            && !$0.qualification.isEmpty
                    },
                    caseLabel
                )

                let applyEdits = MCPToolDurationInventory.entries.first {
                    $0.toolName == MCPWindowToolName.applyEdits
                }
                XCTAssertEqual(
                    applyEdits?.semanticWaitMaximumSeconds,
                    MCPTimeoutPolicy.applyEditsApprovalTimeoutSeconds,
                    caseLabel
                )
                let manageWorktree = MCPToolDurationInventory.entries.first {
                    $0.toolName == MCPWindowToolName.manageWorktree
                }
                XCTAssertEqual(
                    manageWorktree?.semanticWaitMaximumSeconds,
                    MCPTimeoutPolicy.worktreeMergeApprovalTimeoutSeconds,
                    caseLabel
                )
                let manageWorkspaces = try XCTUnwrap(MCPToolDurationInventory.entries.first {
                    $0.toolName == MCPGlobalToolName.manageWorkspaces
                }, caseLabel)
                XCTAssertEqual(manageWorkspaces.contractKind, .workspaceLifecycleCancellable, caseLabel)
                XCTAssertNil(manageWorkspaces.executionDeadlineSeconds, caseLabel)
                XCTAssertNil(manageWorkspaces.cleanupGraceSeconds, caseLabel)
                XCTAssertNil(manageWorkspaces.cleanupDisposition, caseLabel)
                XCTAssertEqual(
                    manageWorkspaces.conditionalExecutionOverrides,
                    [
                        .init(
                            action: "switch",
                            condition: "always",
                            executionDeadlineSeconds: Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds),
                            cleanupGraceSeconds: Double(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds),
                            cleanupDisposition: .forceDisconnect
                        ),
                        .init(
                            action: "create",
                            condition: "switch_to_created != false (handler default)",
                            executionDeadlineSeconds: Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds),
                            cleanupGraceSeconds: Double(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds),
                            cleanupDisposition: .forceDisconnect
                        ),
                        .init(
                            action: "delete",
                            condition: "close_window == true",
                            executionDeadlineSeconds: Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds),
                            cleanupGraceSeconds: Double(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds),
                            cleanupDisposition: .forceDisconnect
                        )
                    ],
                    caseLabel
                )
                for toolName in [
                    MCPWindowToolName.askUser,
                    MCPWindowToolName.waitForNextInstruction,
                    MCPWindowToolName.agentExplore,
                    MCPWindowToolName.agentRun
                ] {
                    let entry = try XCTUnwrap(MCPToolDurationInventory.entries.first { $0.toolName == toolName }, caseLabel + ": " + toolName)
                    XCTAssertNil(entry.semanticWaitMaximumSeconds, caseLabel + ": " + toolName)
                }
            }

            do {
                let caseLabel = "testInventoryDiagnosticIsPayloadFreeAndSeparatesServerAndExecutionTimeouts"
                let result = await ServerNetworkManager.shared.handleDebugDiagnosticsTool(
                    connectionID: UUID(),
                    arguments: ["op": .string("mcp_tool_duration_inventory")]
                )
                let text = try XCTUnwrap(result.content.compactMap { content -> String? in
                    if case let .text(text, _, _) = content { return text }
                    return nil
                }.first, caseLabel)
                let data = try XCTUnwrap(text.data(using: .utf8), caseLabel)
                let payload = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data) as? [String: Any],
                    caseLabel
                )

                XCTAssertEqual(payload["ok"] as? Bool, true, caseLabel)
                XCTAssertEqual(payload["op"] as? String, "mcp_tool_duration_inventory", caseLabel)
                XCTAssertEqual(
                    (payload["timeout_active_seconds"] as? NSNumber)?.intValue,
                    MCPTimeoutPolicy.codexServerActiveTimeoutSeconds,
                    caseLabel
                )
                XCTAssertEqual(
                    (payload["bounded_execution_deadline_seconds"] as? NSNumber)?.intValue,
                    MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds,
                    caseLabel
                )
                XCTAssertEqual(
                    (payload["bounded_cleanup_grace_seconds"] as? NSNumber)?.intValue,
                    MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds,
                    caseLabel
                )
                XCTAssertEqual(
                    (payload["workspace_switch_execution_deadline_seconds"] as? NSNumber)?.intValue,
                    MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds,
                    caseLabel
                )
                XCTAssertEqual(payload["timeout_scope"] as? String, "per_mcp_server", caseLabel)
                XCTAssertEqual(payload["per_tool_timeout_overrides_supported"] as? Bool, false, caseLabel)
                XCTAssertEqual(payload["intentional_phase_b3_deviation"] as? Bool, true, caseLabel)
                XCTAssertTrue((payload["timeout_semantics"] as? String)?.contains("separate dispatch-boundary") == true, caseLabel)
                XCTAssertEqual(
                    payload["lifecycle_managed_tools"] as? [String],
                    [MCPWindowToolName.agentExplore, MCPWindowToolName.agentRun],
                    caseLabel
                )
                XCTAssertEqual(
                    payload["interactive_tools"] as? [String],
                    [
                        MCPWindowToolName.applyEdits,
                        MCPWindowToolName.askUser,
                        MCPWindowToolName.waitForNextInstruction
                    ],
                    caseLabel
                )
                XCTAssertEqual(
                    payload["workspace_lifecycle_tools"] as? [String],
                    [
                        MCPGlobalToolName.bindContext,
                        MCPGlobalToolName.manageWorkspaces,
                        MCPWindowToolName.git,
                        MCPWindowToolName.manageWorktree
                    ],
                    caseLabel
                )
                XCTAssertEqual(
                    payload["detach_and_settle_tools"] as? [String],
                    [MCPWindowToolName.getCodeStructure],
                    caseLabel
                )
                let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]], caseLabel)
                XCTAssertEqual(tools.count, 27, caseLabel)
                let getCodeStructure = try XCTUnwrap(tools.first {
                    $0["tool"] as? String == MCPWindowToolName.getCodeStructure
                }, caseLabel)
                XCTAssertEqual(
                    getCodeStructure["cleanup_disposition"] as? String,
                    MCPToolExecutionCleanupDisposition.detachAndSettle.rawValue,
                    caseLabel
                )
                let manageWorkspaces = try XCTUnwrap(tools.first {
                    $0["tool"] as? String == MCPGlobalToolName.manageWorkspaces
                }, caseLabel)
                XCTAssertEqual(
                    manageWorkspaces["execution_contract"] as? String,
                    MCPToolExecutionContract.Kind.workspaceLifecycleCancellable.rawValue,
                    caseLabel
                )
                XCTAssertNil(manageWorkspaces["execution_deadline_seconds"], caseLabel)
                let conditionalOverrides = try XCTUnwrap(
                    manageWorkspaces["conditional_execution_overrides"] as? [[String: Any]],
                    caseLabel
                )
                XCTAssertEqual(conditionalOverrides.map { $0["action"] as? String }, ["switch", "create", "delete"], caseLabel)
                XCTAssertEqual(
                    conditionalOverrides.map { ($0["execution_deadline_seconds"] as? NSNumber)?.intValue },
                    [120, 120, 120],
                    caseLabel
                )
                XCTAssertEqual(
                    conditionalOverrides.map { $0["condition"] as? String },
                    ["always", "switch_to_created != false (handler default)", "close_window == true"],
                    caseLabel
                )
                XCTAssertEqual(
                    conditionalOverrides.map { $0["cleanup_disposition"] as? String },
                    ["force_disconnect", "force_disconnect", "force_disconnect"],
                    caseLabel
                )

                for forbiddenKey in [
                    "prompt_text",
                    "transcript_text",
                    "tool_arguments",
                    "tool_result",
                    "provider_payload"
                ] {
                    XCTAssertFalse(text.contains(forbiddenKey), caseLabel + ": " + forbiddenKey)
                }
            }
        }
    }
#endif
