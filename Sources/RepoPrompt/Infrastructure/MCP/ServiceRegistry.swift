import Foundation
import Logging
import RepoPromptDomainRuntime

private let serviceRegistryLog = Logger(label: "com.repoprompt.mcp.service-registry")

/// App adapter over the runtime-owned catalog registry. This facade stores no services,
/// schemas, registrations, or tool definitions of its own.
enum ServiceRegistry {
    @MainActor
    @discardableResult
    static func register(
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
            let definitionScanState = EditFlowPerf.begin(
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan
            )
        #endif
        let bindings: [MCPDomainToolBinding]
        do {
            let runtime = AppDomainRuntimeComposition.shared.runtime
            let interactionAdapter = (service as? MCPWindowToolCatalogService)?.longRunningInteractionAdapter
            bindings = try tools.map {
                let domainBinding = try $0.domainBinding()
                let longRunningBinding = runtime.longRunningToolProvider.wrapping(
                    domainBinding,
                    interactionAdapter: domainBinding.definition.name == MCPWindowToolName.askUser
                        ? interactionAdapter
                        : nil
                )
                return try runtime.protectedMutationProvider.protectedBinding(longRunningBinding)
            }
        } catch {
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(
                    EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan,
                    definitionScanState
                )
            #endif
            serviceRegistryLog.error(
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
            let result = try await AppDomainRuntimeComposition.shared.runtime.toolRegistry.registerWithResult(
                registrationID: service.domainRegistrationID,
                scope: registrationScope(for: service),
                bindings: bindings
            )
            guard result.disposition != .unchanged else { return result }

            #if DEBUG || EDIT_FLOW_PERF
                let publicationState = EditFlowPerf.begin(
                    EditFlowPerf.Stage.MCPWindowToolCatalog.serviceRegistryToolsPublication
                )
            #endif
            ToolAvailabilityStore.shared.registerTools(tools)
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(
                    EditFlowPerf.Stage.MCPWindowToolCatalog.serviceRegistryToolsPublication,
                    publicationState
                )
            #endif
            await ServerNetworkManager.shared.broadcastToolListChanged()
            return result
        } catch {
            serviceRegistryLog.error(
                "Domain tool registration failed registration=\(service.domainRegistrationID.rawValue.uuidString) scope=\(String(describing: registrationScope(for: service))) error=\(String(reflecting: error))"
            )
            throw error
        }
    }

    @MainActor
    static func unregister(_ service: any Service) async {
        let removal = await AppDomainRuntimeComposition.shared.runtime.toolRegistry.unregister(
            registrationID: service.domainRegistrationID
        )
        if removal == .removed {
            await ServerNetworkManager.shared.broadcastToolListChanged()
        }
    }

    static func unregister(_ handle: MCPDomainToolRegistrationHandle) async {
        let removal = await AppDomainRuntimeComposition.shared.runtime.toolRegistry.unregister(handle)
        if removal == .removed {
            await ServerNetworkManager.shared.broadcastToolListChanged()
        }
    }

    @MainActor
    static func isRegistered(_ service: any Service) async -> Bool {
        await AppDomainRuntimeComposition.shared.runtime.toolRegistry.isRegistered(
            service.domainRegistrationID
        )
    }

    static func catalogSnapshot() async -> MCPDomainToolCatalogSnapshot {
        await AppDomainRuntimeComposition.shared.runtime.toolRegistry.snapshot()
    }

    static func scopePresence(
        requiredToolNames: [String],
        scope: MCPDomainToolRegistrationScope
    ) async -> MCPDomainToolScopePresence {
        await AppDomainRuntimeComposition.shared.runtime.toolRegistry.scopePresence(
            requiredToolNames: requiredToolNames,
            scope: scope
        )
    }

    static func resolve(
        toolName: String,
        scope: MCPDomainToolRegistrationScope
    ) async -> MCPDomainResolvedTool? {
        await AppDomainRuntimeComposition.shared.runtime.toolRegistry.resolve(
            toolName: toolName,
            scope: scope
        )
    }

    static func resolveUniqueWindowTool(
        toolName: String
    ) async -> MCPDomainResolvedTool? {
        await AppDomainRuntimeComposition.shared.runtime.toolRegistry.resolveUniqueWindowTool(
            toolName: toolName
        )
    }

    static func isActive(_ handle: MCPDomainToolRegistrationHandle) async -> Bool {
        await AppDomainRuntimeComposition.shared.runtime.toolRegistry.isActive(handle)
    }

    @MainActor
    private static func registrationScope(
        for service: any Service
    ) -> MCPDomainToolRegistrationScope {
        if let windowService = service as? WindowScopedService {
            return .window(id: windowService.windowID)
        }
        return .application
    }
}
