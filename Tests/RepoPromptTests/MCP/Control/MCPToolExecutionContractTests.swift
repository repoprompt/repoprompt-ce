import Foundation
import MCP
@testable import RepoPrompt
import RepoPromptShared
import XCTest

final class MCPToolExecutionContractTests: XCTestCase {
    func testCentralTimeoutPolicyMatchesProductContract() {
        XCTAssertEqual(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds, 30)
        XCTAssertEqual(MCPTimeoutPolicy.workspaceFreshnessWaitTimeoutSeconds, 30)
        XCTAssertEqual(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds, 120)
        XCTAssertEqual(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds, 5)
        XCTAssertEqual(MCPTimeoutPolicy.responseSendDeadlineSeconds, 30)
        XCTAssertEqual(MCPTimeoutPolicy.codexServerActiveTimeoutSeconds, 10000)
        XCTAssertEqual(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds, 120)
        XCTAssertEqual(MCPTimeoutPolicy.askUserDefaultTimeoutSeconds, 300)
        XCTAssertEqual(MCPTimeoutPolicy.nextUserInstructionDefaultWaitSeconds, 600)
        XCTAssertEqual(MCPTimeoutPolicy.applyEditsApprovalTimeoutSeconds, 300)
        XCTAssertEqual(MCPTimeoutPolicy.worktreeMergeApprovalTimeoutSeconds, 600)
    }

    func testAdvertisedToolCatalogMatchesExecutionContractClassificationMatrix() {
        do {
            let caseLabel = "testCatalogCoversEveryAdvertisedGlobalAndWindowToolExactlyOnce"
            XCTAssertEqual(
                MCPToolExecutionContractCatalog.orderedAdvertisedToolNames,
                MCPGlobalToolName.orderedToolNames + MCPWindowToolGroup.orderedToolNames,
                caseLabel
            )
            XCTAssertEqual(MCPToolExecutionContractCatalog.orderedAdvertisedToolNames.count, 26, caseLabel)
            XCTAssertEqual(
                Set(MCPToolExecutionContractCatalog.orderedAdvertisedToolNames).count,
                MCPToolExecutionContractCatalog.orderedAdvertisedToolNames.count,
                caseLabel
            )
            XCTAssertEqual(
                Set(MCPToolExecutionContractCatalog.contracts.keys),
                Set(MCPToolExecutionContractCatalog.orderedAdvertisedToolNames),
                caseLabel
            )
            XCTAssertEqual(
                MCPGlobalToolName.orderedToolNames,
                ["app_settings", "bind_context", "manage_workspaces"],
                caseLabel
            )
        }

        do {
            let caseLabel = "testBoundedCatalogContainsOnlyComputationalAndLocalOperations"
            XCTAssertEqual(names(for: .bounded), [
                MCPGlobalToolName.appSettings,
                MCPWindowToolName.manageSelection,
                MCPWindowToolName.fileActions,
                MCPWindowToolName.getCodeStructure,
                MCPWindowToolName.getFileTree,
                MCPWindowToolName.readFile,
                MCPWindowToolName.workspaceContext,
                MCPWindowToolName.prompt,
                MCPWindowToolName.agentManage,
                MCPWindowToolName.shareThoughts,
                MCPWindowToolName.setStatus
            ], caseLabel)

            for toolName in names(for: .bounded) {
                guard case let .bounded(deadline, cancellationGrace) = MCPToolExecutionContractCatalog.contract(for: toolName) else {
                    return XCTFail(caseLabel + ": Expected bounded contract for \(toolName)")
                }
                XCTAssertEqual(deadline, MCPTimeoutPolicy.boundedToolExecutionDeadline, caseLabel + ": " + toolName)
                XCTAssertEqual(cancellationGrace, MCPTimeoutPolicy.boundedToolCancellationCleanupGrace, caseLabel + ": " + toolName)
            }
        }

        do {
            let caseLabel = "testSearchOracleAndContextBuilderUseLongSynchronousExemption"
            XCTAssertEqual(names(for: .longSynchronousCancellable), [
                MCPWindowToolName.search,
                MCPWindowToolName.oracleUtils,
                MCPWindowToolName.askOracle,
                MCPWindowToolName.oracleSend,
                MCPWindowToolName.oracleChatLog,
                MCPWindowToolName.contextBuilder
            ], caseLabel)
            assertNoWatchdogDeadline(for: names(for: .longSynchronousCancellable), label: caseLabel)
        }

        do {
            let caseLabel = "testAgentRunAndExploreUseLifecycleManagedExemption"
            XCTAssertEqual(names(for: .lifecycleManagedCancellable), [
                MCPWindowToolName.agentExplore,
                MCPWindowToolName.agentRun
            ], caseLabel)
            assertNoWatchdogDeadline(for: names(for: .lifecycleManagedCancellable), label: caseLabel)
        }

        do {
            let caseLabel = "testInteractiveToolsUseInteractiveCancellableExemption"
            XCTAssertEqual(names(for: .interactiveCancellable), [
                MCPWindowToolName.applyEdits,
                MCPWindowToolName.askUser,
                MCPWindowToolName.waitForNextInstruction
            ], caseLabel)
            assertNoWatchdogDeadline(for: names(for: .interactiveCancellable), label: caseLabel)
        }

        do {
            let caseLabel = "testWorkspaceAndVCSLifecycleToolsUseWorkspaceCancellableExemption"
            XCTAssertEqual(names(for: .workspaceLifecycleCancellable), [
                MCPGlobalToolName.bindContext,
                MCPGlobalToolName.manageWorkspaces,
                MCPWindowToolName.git,
                MCPWindowToolName.manageWorktree
            ], caseLabel)
            assertNoWatchdogDeadline(for: names(for: .workspaceLifecycleCancellable), label: caseLabel)
        }
    }

    func testManageWorkspacesUsesBoundedContractOnlyForSwitchProducingArguments() {
        let boundedCases: [(label: String, arguments: [String: Value])] = [
            ("switch", ["action": .string("switch")]),
            ("normalized switch", ["action": .string("  SwItCh  ")]),
            ("create default", ["action": .string("create")]),
            ("create true", ["action": .string("create"), "switch_to_created": .bool(true)]),
            // The handler resolves a present-but-non-bool flag as `?? true` and switches,
            // so the contract must keep the watchdog on that path.
            ("create malformed flag", ["action": .string("create"), "switch_to_created": .string("true")]),
            ("delete close window", ["action": .string("delete"), "close_window": .bool(true)])
        ]

        for testCase in boundedCases {
            guard case let .bounded(deadline, cancellationGrace) = MCPToolExecutionContractCatalog.contract(
                for: MCPGlobalToolName.manageWorkspaces,
                arguments: testCase.arguments
            ) else {
                XCTFail("Expected bounded contract for \(testCase.label)")
                continue
            }
            XCTAssertEqual(deadline, MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadline, testCase.label)
            XCTAssertEqual(cancellationGrace, MCPTimeoutPolicy.boundedToolCancellationCleanupGrace, testCase.label)
        }

        let unboundedCases: [(label: String, arguments: [String: Value])] = [
            ("list", ["action": .string("list")]),
            ("create false", ["action": .string("create"), "switch_to_created": .bool(false)]),
            ("delete default", ["action": .string("delete")]),
            ("delete false", ["action": .string("delete"), "close_window": .bool(false)]),
            ("delete malformed flag", ["action": .string("delete"), "close_window": .string("true")]),
            ("missing action", [:]),
            ("malformed action", ["action": .bool(true)])
        ]

        for testCase in unboundedCases {
            XCTAssertEqual(
                MCPToolExecutionContractCatalog.contract(
                    for: MCPGlobalToolName.manageWorkspaces,
                    arguments: testCase.arguments
                ),
                .workspaceLifecycleCancellable,
                testCase.label
            )
        }

        XCTAssertEqual(
            MCPToolExecutionContractCatalog.contract(
                for: MCPWindowToolName.git,
                arguments: ["action": .string("switch")]
            ),
            .workspaceLifecycleCancellable
        )
    }

    func testMissingClassificationIsDetectedBeforeProviderEntry() {
        var providerEntered = false
        let toolName = "unclassified_test_tool"

        guard MCPToolExecutionContractCatalog.contract(for: toolName) != nil else {
            XCTAssertFalse(providerEntered)
            XCTAssertNil(MCPToolExecutionContractCatalog.contract(for: toolName))
            return
        }
        providerEntered = true
        XCTFail("Unexpected contract allowed provider entry")
    }

    private func names(for kind: MCPToolExecutionContract.Kind) -> [String] {
        MCPToolExecutionContractCatalog.orderedAdvertisedToolNames.filter {
            MCPToolExecutionContractCatalog.contract(for: $0)?.kind == kind
        }
    }

    private func assertNoWatchdogDeadline(
        for toolNames: [String],
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(toolNames.allSatisfy {
            let contract = MCPToolExecutionContractCatalog.contract(for: $0)
            return contract?.deadline == nil && contract?.cancellationGrace == nil
        }, label, file: file, line: line)
    }
}
