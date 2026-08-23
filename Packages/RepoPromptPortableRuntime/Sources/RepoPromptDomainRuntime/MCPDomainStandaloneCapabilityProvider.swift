import Foundation
import MCP

/// Protocol-neutral argument carrier used by physical capability backends.
/// Backends decode only the request type for the capability they implement; MCP `Value`
/// never appears in a backend protocol signature.
public struct DomainPhysicalToolRequest: Sendable {
    public let argumentsJSON: Data
    public let securityContext: DomainToolInvocationSecurityContext?

    public init(
        argumentsJSON: Data,
        securityContext: DomainToolInvocationSecurityContext?
    ) {
        self.argumentsJSON = argumentsJSON
        self.securityContext = securityContext
    }

    init(arguments: [String: Value]) throws {
        argumentsJSON = try JSONEncoder().encode(arguments)
        securityContext = MCPDomainInvocationSecurityContext.current
    }
}

public struct DomainPhysicalReadRequest: Sendable {
    public let request: DomainPhysicalToolRequest
    public let context: DomainReadInvocationContext
    public let sideEffects: MCPDomainReadSideEffectEmitter

    public init(
        request: DomainPhysicalToolRequest,
        context: DomainReadInvocationContext,
        sideEffects: MCPDomainReadSideEffectEmitter
    ) {
        self.request = request
        self.context = context
        self.sideEffects = sideEffects
    }
}

public struct DomainPhysicalToolResult: Sendable {
    public let json: Data

    public init(json: Data) {
        self.json = json
    }

    public init<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        json = try encoder.encode(value)
    }

    func mcpValue() throws -> Value {
        try JSONDecoder().decode(Value.self, from: json)
    }
}

public protocol DomainGlobalControlBackend: Sendable {
    func accessSettings(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func routeContext(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func manageWorkspaceLifecycle(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
}

public protocol DomainWorkspaceCapabilityBackend: Sendable {
    func mutateSelection(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func inspectCodeStructure(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func renderFileTree(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func readFile(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func searchFiles(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func renderWorkspaceContext(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func accessPrompt(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
}

public protocol DomainFilesystemMutationBackend: Sendable {
    func manageFiles(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func applyFileEdits(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
}

public protocol DomainConversationCapabilityBackend: Sendable {
    func accessOracleUtilities(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func startOracleConversation(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func continueOracleConversation(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func readOracleLog(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func buildContext(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func requestUserInput(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
}

public protocol DomainVersionControlCapabilityBackend: Sendable {
    func inspectGit(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func manageWorktree(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
}

public protocol DomainAgentCapabilityBackend: Sendable {
    func explore(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func run(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func manage(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func shareThoughts(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func publishStatus(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func waitForInstruction(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
}

public protocol DomainHistoryCapabilityBackend: Sendable {
    func inspectHistory(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
}

public struct MCPDomainStandaloneCapabilityBackends: Sendable {
    public let global: any DomainGlobalControlBackend
    public let workspace: any DomainWorkspaceCapabilityBackend
    public let filesystem: any DomainFilesystemMutationBackend
    public let conversation: any DomainConversationCapabilityBackend
    public let versionControl: any DomainVersionControlCapabilityBackend
    public let agent: any DomainAgentCapabilityBackend
    public let history: any DomainHistoryCapabilityBackend

    public init(
        global: any DomainGlobalControlBackend,
        workspace: any DomainWorkspaceCapabilityBackend,
        filesystem: any DomainFilesystemMutationBackend,
        conversation: any DomainConversationCapabilityBackend,
        versionControl: any DomainVersionControlCapabilityBackend,
        agent: any DomainAgentCapabilityBackend,
        history: any DomainHistoryCapabilityBackend
    ) {
        self.global = global
        self.workspace = workspace
        self.filesystem = filesystem
        self.conversation = conversation
        self.versionControl = versionControl
        self.agent = agent
        self.history = history
    }
}

public struct MCPDomainStandaloneToolInstallation: Sendable {
    public let globalRegistration: MCPDomainToolRegistrationHandle
    public let standaloneRegistration: MCPDomainToolRegistrationHandle
    public let scopeID: DomainStandaloneScopeID
}

public enum MCPDomainStandaloneToolInstaller {
    public static func install(
        runtime: MCPDomainRuntime,
        scopeID: DomainStandaloneScopeID,
        backends: MCPDomainStandaloneCapabilityBackends
    ) async throws -> MCPDomainStandaloneToolInstallation {
        let readProvider = MCPDomainReadToolProvider(
            resolveContext: { _, requirement in
                try await resolveReadContext(runtime: runtime, requirement: requirement)
            },
            refreshContext: { handle in
                try await runtime.routingCoordinator.refreshReadContext(handle)
            },
            backend: MCPDomainReadToolBackend { toolName, context, arguments, sideEffects in
                let request = try DomainPhysicalReadRequest(
                    request: DomainPhysicalToolRequest(arguments: arguments),
                    context: context,
                    sideEffects: sideEffects
                )
                let result: DomainPhysicalToolResult = switch toolName {
                case MCPWindowToolName.getCodeStructure:
                    try await backends.workspace.inspectCodeStructure(request)
                case MCPWindowToolName.getFileTree:
                    try await backends.workspace.renderFileTree(request)
                case MCPWindowToolName.readFile:
                    try await backends.workspace.readFile(request)
                case MCPWindowToolName.search:
                    try await backends.workspace.searchFiles(request)
                case MCPWindowToolName.workspaceContext:
                    try await backends.workspace.renderWorkspaceContext(request)
                case MCPWindowToolName.prompt:
                    try await backends.workspace.accessPrompt(request)
                case MCPWindowToolName.oracleChatLog:
                    try await backends.conversation.readOracleLog(request)
                case MCPWindowToolName.git:
                    try await backends.versionControl.inspectGit(request)
                case MCPWindowToolName.history:
                    try await backends.history.inspectHistory(request)
                default:
                    throw MCPDomainToolRegistryError.unknownToolName(toolName)
                }
                return try result.mcpValue()
            },
            sideEffects: runtime.readSideEffectCoordinator
        )

        var rawBindings = readProvider.bindings
        rawBindings.append(contentsOf: capabilityBindings(backends: backends))
        let names = rawBindings.map(\.definition.name)
        guard names.count == MCPDomainToolCatalog.orderedToolNames.count,
              Set(names) == Set(MCPDomainToolCatalog.orderedToolNames),
              Set(names).count == names.count
        else {
            throw MCPDomainToolRegistryError.emptyRegistration
        }

        let decorated = rawBindings.map { binding in
            runtime.protectedMutationProvider.protectedBinding(
                runtime.longRunningToolProvider.wrapping(binding)
            )
        }
        let byName = Dictionary(uniqueKeysWithValues: decorated.map { ($0.definition.name, $0) })
        let globalBindings = MCPGlobalToolName.orderedToolNames.compactMap { byName[$0] }
        let standaloneBindings = MCPWindowToolName.orderedToolNames.compactMap { byName[$0] }

        let globalRegistration = try await runtime.toolRegistry.register(
            registrationID: MCPDomainToolRegistrationID(),
            scope: .application,
            bindings: globalBindings
        )
        do {
            let standaloneRegistration = try await runtime.toolRegistry.register(
                registrationID: MCPDomainToolRegistrationID(),
                scope: .standalone(id: scopeID),
                bindings: standaloneBindings
            )
            return MCPDomainStandaloneToolInstallation(
                globalRegistration: globalRegistration,
                standaloneRegistration: standaloneRegistration,
                scopeID: scopeID
            )
        } catch {
            _ = await runtime.toolRegistry.unregister(globalRegistration)
            throw error
        }
    }

    public static func uninstall(
        _ installation: MCPDomainStandaloneToolInstallation,
        runtime: MCPDomainRuntime
    ) async {
        _ = await runtime.toolRegistry.unregister(installation.standaloneRegistration)
        _ = await runtime.toolRegistry.unregister(installation.globalRegistration)
    }

    private static func resolveReadContext(
        runtime: MCPDomainRuntime,
        requirement: DomainReadContextRequirement
    ) async throws -> DomainReadInvocationContext {
        guard let securityContext = MCPDomainInvocationSecurityContext.current else {
            if requirement == .workspaceRequired {
                throw DomainReadContextResolutionError.connectionUnavailable
            }
            return DomainReadInvocationContext(handle: nil, connectionID: nil)
        }
        let registration = try await runtime.routingCoordinator.currentRegistration(
            connectionID: securityContext.connectionID
        )
        do {
            let handle = try await runtime.routingCoordinator.resolveReadContext(connection: registration)
            return DomainReadInvocationContext(
                invocationID: securityContext.invocationID,
                handle: handle,
                connectionID: securityContext.connectionID
            )
        } catch {
            if requirement == .workspaceRequired { throw error }
            return DomainReadInvocationContext(
                invocationID: securityContext.invocationID,
                handle: nil,
                connectionID: securityContext.connectionID
            )
        }
    }

    private static func capabilityBindings(
        backends: MCPDomainStandaloneCapabilityBackends
    ) -> [MCPDomainToolBinding] {
        [
            binding(MCPGlobalToolName.appSettings, backends.global.accessSettings),
            binding(MCPGlobalToolName.bindContext, backends.global.routeContext),
            binding(MCPGlobalToolName.manageWorkspaces, backends.global.manageWorkspaceLifecycle),
            binding(MCPWindowToolName.manageSelection, backends.workspace.mutateSelection),
            binding(MCPWindowToolName.fileActions, backends.filesystem.manageFiles),
            binding(MCPWindowToolName.applyEdits, backends.filesystem.applyFileEdits),
            binding(MCPWindowToolName.oracleUtils, backends.conversation.accessOracleUtilities),
            binding(MCPWindowToolName.askOracle, backends.conversation.startOracleConversation),
            binding(MCPWindowToolName.oracleSend, backends.conversation.continueOracleConversation),
            binding(MCPWindowToolName.manageWorktree, backends.versionControl.manageWorktree),
            binding(MCPWindowToolName.contextBuilder, backends.conversation.buildContext),
            binding(MCPWindowToolName.askUser, backends.conversation.requestUserInput),
            binding(MCPWindowToolName.agentExplore, backends.agent.explore),
            binding(MCPWindowToolName.agentRun, backends.agent.run),
            binding(MCPWindowToolName.agentManage, backends.agent.manage),
            binding(MCPWindowToolName.shareThoughts, backends.agent.shareThoughts),
            binding(MCPWindowToolName.setStatus, backends.agent.publishStatus),
            binding(MCPWindowToolName.waitForNextInstruction, backends.agent.waitForInstruction),
        ]
    }

    private static func binding(
        _ name: String,
        _ operation: @escaping @Sendable (DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    ) -> MCPDomainToolBinding {
        guard let definition = MCPDomainCanonicalToolDefinitions.definition(named: name) else {
            preconditionFailure("Missing canonical definition for \(name)")
        }
        return MCPDomainToolBinding(definition: definition) { arguments in
            let request = try DomainPhysicalToolRequest(arguments: arguments)
            return try await operation(request).mcpValue()
        }
    }
}
