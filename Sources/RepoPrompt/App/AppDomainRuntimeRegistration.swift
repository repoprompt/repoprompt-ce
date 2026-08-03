import Foundation
import Logging
import RepoPromptDomainRuntime

private let appDomainRegistrationLog = Logger(label: "com.repoprompt.mcp.domain-registration")

/// App composition operations over the runtime-owned catalog registry.
extension AppDomainRuntimeComposition {
    @MainActor
    @discardableResult
    func register(
        _ service: MCPAppToolCatalogRegistration
    ) async throws -> MCPDomainToolRegistrationResult {
        try await register(
            service: service,
            tools: service.materializeTools(),
            interactionAdapter: service.longRunningInteractionAdapter
        )
    }

    @MainActor
    @discardableResult
    func register(
        _ service: any Service
    ) async throws -> MCPDomainToolRegistrationResult {
        #if DEBUG || EDIT_FLOW_PERF
            let serviceToolsAwaitState = EditFlowPerf.begin(
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupServiceToolsAwait
            )
        #endif
        let tools = await service.tools
        #if DEBUG || EDIT_FLOW_PERF
            EditFlowPerf.end(
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupServiceToolsAwait,
                serviceToolsAwaitState
            )
        #endif
        return try await register(service: service, tools: tools, interactionAdapter: nil)
    }

    @MainActor
    private func register(
        service: any Service,
        tools: [Tool],
        interactionAdapter: DomainLongRunningInteractionAdapter?
    ) async throws -> MCPDomainToolRegistrationResult {
        #if DEBUG || EDIT_FLOW_PERF
            let definitionScanState = EditFlowPerf.begin(
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan
            )
        #endif
        let bindings: [MCPDomainToolBinding]
        do {
            let domainRuntime = runtime
            bindings = try tools.map {
                let domainBinding = try $0.domainBinding()
                let longRunningBinding = domainRuntime.longRunningToolProvider.wrapping(
                    domainBinding,
                    interactionAdapter: domainBinding.definition.name == MCPWindowToolName.askUser
                        ? interactionAdapter
                        : nil
                )
                return try domainRuntime.protectedMutationProvider.protectedBinding(longRunningBinding)
            }
        } catch {
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(
                    EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan,
                    definitionScanState
                )
            #endif
            appDomainRegistrationLog.error(
                "Domain tool definition materialization failed registration=\(service.domainRegistrationID.rawValue.uuidString) error=\(String(reflecting: error))"
            )
            throw error
        }
        #if DEBUG || EDIT_FLOW_PERF
            EditFlowPerf.end(
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan,
                definitionScanState
            )
        #endif

        do {
            let result = try await runtime.toolRegistry.registerWithResult(
                registrationID: service.domainRegistrationID,
                scope: registrationScope(for: service),
                bindings: bindings
            )
            guard result.disposition != .unchanged else { return result }

            #if DEBUG || EDIT_FLOW_PERF
                let publicationState = EditFlowPerf.begin(
                    EditFlowPerf.Stage.MCPWindowToolCatalog.domainRegistrationToolsPublication
                )
            #endif
            ToolAvailabilityStore.shared.registerTools(tools)
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(
                    EditFlowPerf.Stage.MCPWindowToolCatalog.domainRegistrationToolsPublication,
                    publicationState
                )
            #endif
            await ServerNetworkManager.shared.broadcastToolListChanged()
            return result
        } catch {
            appDomainRegistrationLog.error(
                "Domain tool registration failed registration=\(service.domainRegistrationID.rawValue.uuidString) scope=\(String(describing: registrationScope(for: service))) error=\(String(reflecting: error))"
            )
            throw error
        }
    }

    @MainActor
    func unregister(_ service: any Service) async {
        let removal = await runtime.toolRegistry.unregister(
            registrationID: service.domainRegistrationID
        )
        if removal == .removed {
            await ServerNetworkManager.shared.broadcastToolListChanged()
        }
    }

    func unregister(_ handle: MCPDomainToolRegistrationHandle) async {
        let removal = await runtime.toolRegistry.unregister(handle)
        if removal == .removed {
            await ServerNetworkManager.shared.broadcastToolListChanged()
        }
    }

    @MainActor
    func isRegistered(_ service: any Service) async -> Bool {
        await runtime.toolRegistry.isRegistered(
            service.domainRegistrationID
        )
    }

    func catalogSnapshot() async -> MCPDomainToolCatalogSnapshot {
        await runtime.toolRegistry.snapshot()
    }

    func scopePresence(
        requiredToolNames: [String],
        scope: MCPDomainToolRegistrationScope
    ) async -> MCPDomainToolScopePresence {
        await runtime.toolRegistry.scopePresence(
            requiredToolNames: requiredToolNames,
            scope: scope
        )
    }

    func resolve(
        toolName: String,
        scope: MCPDomainToolRegistrationScope
    ) async -> MCPDomainResolvedTool? {
        await runtime.toolRegistry.resolve(
            toolName: toolName,
            scope: scope
        )
    }

    func resolveUniqueWindowTool(
        toolName: String
    ) async -> MCPDomainResolvedTool? {
        await runtime.toolRegistry.resolveUniqueWindowTool(
            toolName: toolName
        )
    }

    func isActive(_ handle: MCPDomainToolRegistrationHandle) async -> Bool {
        await runtime.toolRegistry.isActive(handle)
    }

    @MainActor
    private func registrationScope(
        for service: any Service
    ) -> MCPDomainToolRegistrationScope {
        if let windowService = service as? WindowScopedService {
            return .window(id: windowService.windowID)
        }
        return .application
    }
}
