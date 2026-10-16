import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptShared
import XCTest

@MainActor
final class AgentLifecycleExecutionContractTests: XCTestCase {
    func testAgentRunLifecycleWaitDefaultsAndExplicitOverrides() throws {
        let expected: TimeInterval = 120
        let captured = expected
        XCTAssertEqual(AgentRunMCPToolService.defaultWaitTimeoutSeconds, expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(nil, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(nil, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(nil, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(.null, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.null, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(.null, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(.int(0), capturedDefaultWaitSeconds: captured), 0)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.int(30), capturedDefaultWaitSeconds: captured), 30)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(.double(45.5), capturedDefaultWaitSeconds: captured), 45.5)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.int(7200), capturedDefaultWaitSeconds: captured), 7200)
    }

    func testAgentRunLifecycleWaitUsesInjectedCapturedDefault() throws {
        let capturedDefault: TimeInterval = 600
        XCTAssertEqual(
            try AgentRunMCPToolService.resolvedStartTimeoutSeconds(nil, capturedDefaultWaitSeconds: capturedDefault),
            capturedDefault
        )
        XCTAssertEqual(
            try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.null, capturedDefaultWaitSeconds: capturedDefault),
            capturedDefault
        )
        XCTAssertEqual(
            try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(nil, capturedDefaultWaitSeconds: capturedDefault),
            capturedDefault
        )
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.int(30), capturedDefaultWaitSeconds: capturedDefault), 30)
    }

    func testCapturedDefaultWaitTimeoutSecondsReadsConfiguredPreferenceOnce() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        XCTAssertEqual(AgentRunMCPToolService.capturedDefaultWaitTimeoutSeconds(from: store), 120)

        XCTAssertTrue(store.setSubagentDefaultWaitSeconds(1200))
        // Freeze the value an in-flight wait would have captured, then change the preference:
        // the wait must keep resolving against its capture, not the new setting.
        let frozenDefault = AgentRunMCPToolService.capturedDefaultWaitTimeoutSeconds(from: store)
        XCTAssertEqual(frozenDefault, 1200)

        XCTAssertTrue(store.setSubagentDefaultWaitSeconds(120))
        XCTAssertEqual(
            try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(nil, capturedDefaultWaitSeconds: frozenDefault),
            frozenDefault
        )
        XCTAssertEqual(AgentRunMCPToolService.capturedDefaultWaitTimeoutSeconds(from: store), 120)
    }

    func testAgentExploreStartSharesLifecycleWaitPolicy() throws {
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(
                nil,
                capturedDefaultWaitSeconds: MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
            ),
            MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
        )
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(
                .double(900.5),
                capturedDefaultWaitSeconds: MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
            ),
            900.5
        )
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(nil, capturedDefaultWaitSeconds: 1800),
            1800
        )
    }
}

// MARK: - SessionAdminExecutionContractTests regressions

final class SessionAdminExecutionContractTests: XCTestCase {
    func testEverySessionAdminOperationUsesItsOwningLifecycleContract() {
        let workspaceOperations: Set = ["worktree_create", "worktree_bind", "worktree_unbind", "worktree_release", "worktree_inventory", "merge_preview", "merge_apply"]
        let sessionOperations: Set = [
            "rename", "set_pin", "reorder_pins", "set_group", "reorder_groups", "archive", "unarchive",
            "link", "unlink", "reparent", "adopt", "release", "retire", "fork", "set_model", "set_effort", "undo"
        ]
        for operation in MCPDomainSessionAdminToolDefinition.operations {
            let contract = MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.sessionAdmin, arguments: ["op": .string(operation)])
            if workspaceOperations.contains(operation) {
                XCTAssertEqual(contract, .workspaceLifecycleCancellable, operation)
            } else if sessionOperations.contains(operation) {
                XCTAssertEqual(contract, .lifecycleManagedCancellable, operation)
            } else {
                XCTAssertEqual(contract, MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.sessionAdmin), operation)
                XCTAssertEqual(contract?.cleanupDisposition, .forceDisconnect, operation)
                XCTAssertEqual(contract?.deadline, MCPTimeoutPolicy.boundedToolExecutionDeadline, operation)
            }
        }
    }

    #if DEBUG
        func testDurationDiagnosticsExposeTheArgumentSelectedLifecycleContracts() throws {
            let tools = try XCTUnwrap(MCPToolDurationInventory.debugSnapshot["tools"] as? [[String: Any]])
            let entry = try XCTUnwrap(tools.first { $0["tool"] as? String == MCPWindowToolName.sessionAdmin })
            let overrides = try XCTUnwrap(entry["conditional_execution_overrides"] as? [[String: Any]])
            let byOperation = Dictionary(uniqueKeysWithValues: overrides.compactMap { row -> (String, String)? in
                guard let operation = row["op"] as? String, let kind = row["execution_contract"] as? String else { return nil }
                return (operation, kind)
            })
            XCTAssertEqual(byOperation["rename"], "lifecycle_managed_cancellable")
            XCTAssertEqual(byOperation["merge_preview"], "workspace_lifecycle_cancellable")
            XCTAssertEqual(byOperation["worktree_inventory"], "workspace_lifecycle_cancellable")
            XCTAssertNil(byOperation["inventory"])
            XCTAssertNil(byOperation["get"])
        }
    #endif

    func testInvalidOperationsDoNotReceiveLifecycleExemption() {
        let invalidArguments: [[String: Value]] = [[:], ["op": .int(1)], ["op": .string("unknown")]]
        for arguments in invalidArguments {
            XCTAssertEqual(
                MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.sessionAdmin, arguments: arguments),
                MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.sessionAdmin)
            )
        }
        XCTAssertEqual(
            MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.sessionAdmin, arguments: ["op": .string("  ARCHIVE  ")]),
            .lifecycleManagedCancellable
        )
    }
}
