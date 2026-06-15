import Foundation
import MCP
import RepoPromptShared

enum MCPToolExecutionContract: Equatable {
    case bounded(deadline: Duration, cancellationGrace: Duration)
    case longSynchronousCancellable
    case lifecycleManagedCancellable
    case interactiveCancellable
    case workspaceLifecycleCancellable

    var kind: Kind {
        switch self {
        case .bounded:
            .bounded
        case .longSynchronousCancellable:
            .longSynchronousCancellable
        case .lifecycleManagedCancellable:
            .lifecycleManagedCancellable
        case .interactiveCancellable:
            .interactiveCancellable
        case .workspaceLifecycleCancellable:
            .workspaceLifecycleCancellable
        }
    }

    var deadline: Duration? {
        guard case let .bounded(deadline, _) = self else { return nil }
        return deadline
    }

    var cancellationGrace: Duration? {
        guard case let .bounded(_, cancellationGrace) = self else { return nil }
        return cancellationGrace
    }

    enum Kind: String {
        case bounded
        case longSynchronousCancellable = "long_synchronous_cancellable"
        case lifecycleManagedCancellable = "lifecycle_managed_cancellable"
        case interactiveCancellable = "interactive_cancellable"
        case workspaceLifecycleCancellable = "workspace_lifecycle_cancellable"
    }
}

enum MCPToolExecutionDispatchError: Error, Equatable {
    case missingContract(toolName: String)
}

enum MCPToolExecutionContractCatalog {
    private static let workspaceSwitchContract = MCPToolExecutionContract.bounded(
        deadline: MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadline,
        cancellationGrace: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace
    )

    static let orderedAdvertisedToolNames = MCPGlobalToolName.orderedToolNames + MCPWindowToolGroup.orderedToolNames

    static let contracts: [String: MCPToolExecutionContract] = {
        let bounded = MCPToolExecutionContract.bounded(
            deadline: MCPTimeoutPolicy.boundedToolExecutionDeadline,
            cancellationGrace: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace
        )
        var result = Dictionary(uniqueKeysWithValues: orderedAdvertisedToolNames.map { ($0, bounded) })

        for toolName in [
            MCPWindowToolName.oracleUtils,
            MCPWindowToolName.askOracle,
            MCPWindowToolName.oracleSend,
            MCPWindowToolName.oracleChatLog,
            MCPWindowToolName.contextBuilder,
            MCPWindowToolName.search
        ] {
            result[toolName] = .longSynchronousCancellable
        }

        for toolName in [
            MCPWindowToolName.agentExplore,
            MCPWindowToolName.agentRun
        ] {
            result[toolName] = .lifecycleManagedCancellable
        }

        for toolName in [
            MCPWindowToolName.applyEdits,
            MCPWindowToolName.askUser,
            MCPWindowToolName.waitForNextInstruction
        ] {
            result[toolName] = .interactiveCancellable
        }

        for toolName in [
            MCPGlobalToolName.bindContext,
            MCPGlobalToolName.manageWorkspaces,
            MCPWindowToolName.git,
            MCPWindowToolName.manageWorktree
        ] {
            result[toolName] = .workspaceLifecycleCancellable
        }

        return result
    }()

    static func contract(for toolName: String) -> MCPToolExecutionContract? {
        contracts[toolName]
    }

    static func contract(
        for toolName: String,
        arguments: [String: Value]
    ) -> MCPToolExecutionContract? {
        guard let baseContract = contract(for: toolName) else { return nil }
        guard toolName == MCPGlobalToolName.manageWorkspaces else { return baseContract }
        guard let rawAction = arguments["action"]?.stringValue else {
            return baseContract
        }
        let action = rawAction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let producesWorkspaceSwitch: Bool = switch action {
        case "switch":
            true
        case "create":
            // Mirror the handler's `args["switch_to_created"]?.boolValue ?? true`: an
            // omitted or malformed flag still performs the switch, so it must stay
            // under the workspace-switch deadline.
            arguments["switch_to_created"]?.boolValue ?? true
        case "delete":
            arguments["close_window"]?.boolValue == true
        default:
            false
        }

        return producesWorkspaceSwitch ? workspaceSwitchContract : baseContract
    }
}
