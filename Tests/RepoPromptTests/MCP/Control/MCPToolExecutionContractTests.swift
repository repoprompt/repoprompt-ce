import Foundation
@testable import RepoPrompt
import RepoPromptShared
import XCTest

final class MCPToolExecutionContractTests: XCTestCase {
    func testCentralTimeoutPolicyMatchesProductContract() {
        XCTAssertEqual(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds, 30)
        XCTAssertEqual(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds, 5)
        XCTAssertEqual(MCPTimeoutPolicy.responseSendDeadlineSeconds, 30)
        XCTAssertEqual(MCPTimeoutPolicy.codexServerActiveTimeoutSeconds, 10000)
        XCTAssertEqual(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds, 120)
        XCTAssertEqual(MCPTimeoutPolicy.askUserDefaultTimeoutSeconds, 300)
        XCTAssertEqual(MCPTimeoutPolicy.nextUserInstructionDefaultWaitSeconds, 600)
        XCTAssertEqual(MCPTimeoutPolicy.applyEditsApprovalTimeoutSeconds, 300)
        XCTAssertEqual(MCPTimeoutPolicy.worktreeMergeApprovalTimeoutSeconds, 600)
    }

    func testCatalogCoversEveryAdvertisedGlobalAndWindowToolExactlyOnce() {
        XCTAssertEqual(
            MCPToolExecutionContractCatalog.orderedAdvertisedToolNames,
            MCPGlobalToolName.orderedToolNames + MCPWindowToolGroup.orderedToolNames
        )
        XCTAssertEqual(MCPToolExecutionContractCatalog.orderedAdvertisedToolNames.count, 26)
        XCTAssertEqual(
            Set(MCPToolExecutionContractCatalog.orderedAdvertisedToolNames).count,
            MCPToolExecutionContractCatalog.orderedAdvertisedToolNames.count
        )
        XCTAssertEqual(
            Set(MCPToolExecutionContractCatalog.contracts.keys),
            Set(MCPToolExecutionContractCatalog.orderedAdvertisedToolNames)
        )
        XCTAssertEqual(
            MCPGlobalToolName.orderedToolNames,
            ["app_settings", "bind_context", "manage_workspaces"]
        )
    }

    func testBoundedCatalogContainsOnlyComputationalAndLocalOperations() {
        XCTAssertEqual(names(for: .bounded), [
            MCPGlobalToolName.appSettings,
            MCPWindowToolName.manageSelection,
            MCPWindowToolName.fileActions,
            MCPWindowToolName.getCodeStructure,
            MCPWindowToolName.getFileTree,
            MCPWindowToolName.readFile,
            MCPWindowToolName.search,
            MCPWindowToolName.workspaceContext,
            MCPWindowToolName.prompt,
            MCPWindowToolName.agentManage,
            MCPWindowToolName.shareThoughts,
            MCPWindowToolName.setStatus
        ])

        for toolName in names(for: .bounded) {
            guard case let .bounded(deadline, cancellationGrace) = MCPToolExecutionContractCatalog.contract(for: toolName) else {
                return XCTFail("Expected bounded contract for \(toolName)")
            }
            XCTAssertEqual(deadline, MCPTimeoutPolicy.boundedToolExecutionDeadline, toolName)
            XCTAssertEqual(cancellationGrace, MCPTimeoutPolicy.boundedToolCancellationCleanupGrace, toolName)
        }
    }

    func testOracleAndContextBuilderUseLongSynchronousExemption() {
        XCTAssertEqual(names(for: .longSynchronousCancellable), [
            MCPWindowToolName.oracleUtils,
            MCPWindowToolName.askOracle,
            MCPWindowToolName.oracleSend,
            MCPWindowToolName.oracleChatLog,
            MCPWindowToolName.contextBuilder
        ])
        assertNoWatchdogDeadline(for: names(for: .longSynchronousCancellable))
    }

    func testAgentRunAndExploreUseLifecycleManagedExemption() {
        XCTAssertEqual(names(for: .lifecycleManagedCancellable), [
            MCPWindowToolName.agentExplore,
            MCPWindowToolName.agentRun
        ])
        assertNoWatchdogDeadline(for: names(for: .lifecycleManagedCancellable))
    }

    func testInteractiveToolsUseInteractiveCancellableExemption() {
        XCTAssertEqual(names(for: .interactiveCancellable), [
            MCPWindowToolName.applyEdits,
            MCPWindowToolName.askUser,
            MCPWindowToolName.waitForNextInstruction
        ])
        assertNoWatchdogDeadline(for: names(for: .interactiveCancellable))
    }

    func testWorkspaceAndVCSLifecycleToolsUseWorkspaceCancellableExemption() {
        XCTAssertEqual(names(for: .workspaceLifecycleCancellable), [
            MCPGlobalToolName.bindContext,
            MCPGlobalToolName.manageWorkspaces,
            MCPWindowToolName.git,
            MCPWindowToolName.manageWorktree
        ])
        assertNoWatchdogDeadline(for: names(for: .workspaceLifecycleCancellable))
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

    private func assertNoWatchdogDeadline(for toolNames: [String]) {
        XCTAssertTrue(toolNames.allSatisfy {
            let contract = MCPToolExecutionContractCatalog.contract(for: $0)
            return contract?.deadline == nil && contract?.cancellationGrace == nil
        })
    }
}
