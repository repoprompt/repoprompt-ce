import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptMCPServer

extension MCPHostRouteResources {
    /// The existing complete catalog consumes this binder for both route kinds. Unmigrated
    /// physical capabilities retain their original preparation and presenter requirements.
    func makeToolBinder(
        service: MCPService,
        validateInvocation: @escaping MCPToolInvocationValidator,
        windowExecution: @escaping MCPAppToolBinder.ExecuteTool
    ) -> MCPAppToolBinder {
        MCPAppToolBinder(windowID: identity.routeID) { [self] name, freshness, arguments, implementation in
            try await invokeBoundTool(
                service: service, name: name, freshness: freshness, arguments: arguments,
                validateInvocation: validateInvocation, windowExecution: windowExecution, implementation: implementation
            )
        }
    }

    private func invokeBoundTool(
        service: MCPService, name: String, freshness: MCPToolFreshnessPolicy,
        arguments: [String: Value], validateInvocation: @escaping MCPToolInvocationValidator,
        windowExecution: @escaping MCPAppToolBinder.ExecuteTool,
        implementation: @escaping MCPAppToolBinder.ProviderImplementation
    ) async throws -> Value {
        // Capture exactly once, before preparation or provider work can suspend.
        let context = try service.captureInvocationContext(toolName: name, expectedWindowID: identity.routeID)
        if identity.kind == .independent, name == MCPWindowToolName.history {
            // History's existing domain contract is workspace-independent and provider-managed.
            // A future freshness requirement must not be silently bypassed here.
            guard case .providerManaged = freshness else {
                throw MCPError.internalError("History requires its provider-managed freshness contract")
            }
            return try await executeHistoryInvocation(context, validateInvocation: validateInvocation) {
                try await implementation(.init(toolName: name, windowID: self.identity.routeID, context: context), arguments)
            }
        }
        return try await MCPInvocationContextBridge.withInvocation(context) {
            try await windowExecution(name, freshness, arguments, implementation)
        }
    }

    /// Pin the original descriptor/catalog proof for the whole invocation. The existing runtime
    /// owns registration, cancellation and completion; a waiter never acquires a successor route.
    private func executeHistoryInvocation(
        _ context: ToolInvocationContext,
        validateInvocation: @escaping MCPToolInvocationValidator,
        body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let network = ServerNetworkManager.shared
        // Freeze the route's exact run association before the first actor hop. Independent
        // routes never borrow the selected window or a manager fallback to manufacture it.
        let indexedRunID = context.connectionID.flatMap {
            runRouteBindings.connectionIDToRunID[$0] ?? runRouteBindings.tabContextByConnectionID[$0]?.runID
        }
        #if DEBUG || EDIT_FLOW_PERF
            let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        #else
            let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil
        #endif
        guard !isClosing, let handle = catalogHandle,
              let dispatch = await network.captureWindowToolDispatchIdentity(
                  windowID: identity.routeID, catalogRegistrationHandle: handle
              ), !isClosing, catalogHandle == handle,
              dispatch.serverViewModelIdentity == ObjectIdentifier(self)
        else { throw ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal }
        let ownerIdentity = ObjectIdentifier(self)
        return try await toolExecutionRuntime.execute(
            .init(toolName: context.toolName, windowID: identity.routeID, context: context),
            ownerIdentity: ownerIdentity, indexedRunID: indexedRunID, lifecycleCorrelation: lifecycleCorrelation,
            validateInvocation: { [self] invocation, routeID, owner in
                await historyInvocationIsCurrent(
                    invocation, dispatch: dispatch, routeID: routeID, owner: owner, validateInvocation: validateInvocation
                )
            }, body: body
        )
    }

    private func historyInvocationIsCurrent(
        _ invocation: ToolInvocationContext, dispatch: MCPWindowToolDispatchIdentity,
        routeID: Int, owner: ObjectIdentifier, validateInvocation: MCPToolInvocationValidator
    ) async -> Bool {
        guard !isClosing, catalogHandle == dispatch.catalogRegistrationHandle,
              routeID == identity.routeID, owner == ObjectIdentifier(self)
        else { return false }
        switch invocation.origin {
        case .network:
            // The canonical validator rechecks connection/policy currency after its route await.
            // Its invocation proof must be the same catalog/owner captured by this binding.
            guard let original = invocation.dispatchAuthorization?.windowIdentity,
                  original.windowID == dispatch.windowID,
                  original.windowStateIdentity == dispatch.windowStateIdentity,
                  original.serverViewModelIdentity == dispatch.serverViewModelIdentity,
                  original.catalogRegistrationHandle == dispatch.catalogRegistrationHandle,
                  await validateInvocation(invocation, routeID, owner)
            else { return false }
        case .trustedLocal:
            // Trusted local calls have no network authorization. They still cannot bypass the
            // original independent route/catalog generation, even when a test injects a validator.
            guard await validateInvocation(invocation, routeID, owner),
                  !isClosing, catalogHandle == dispatch.catalogRegistrationHandle,
                  await ServerNetworkManager.shared.isCurrentWindowToolDispatchIdentity(
                      dispatch, expectedServerViewModelIdentity: owner
                  )
            else { return false }
        }
        return !isClosing && catalogHandle == dispatch.catalogRegistrationHandle
    }
}
