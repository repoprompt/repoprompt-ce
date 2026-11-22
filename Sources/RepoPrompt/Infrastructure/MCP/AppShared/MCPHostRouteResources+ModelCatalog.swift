import Foundation
import RepoPromptDomainRuntime

extension MCPHostRouteResources {
    /// Snapshot the writer in the same slice that publishes the original binding. A refresh of
    /// the catalog or subsequent context edits cannot bless a successor writer on this connection.
    func recordModelWriterForBinding(
        _ registration: MCPRunRoutingCleanupReceipt, connectionID: UUID, published: MCPTabContextSnapshot
    ) {
        guard registration.routeOwner === self, !registration.isConsumed, registration.routeID == identity.routeID,
              runRouteBindings.cleanupOwnership(for: connectionID)?.policyID == registration.policyID,
              var context = runRouteBindings.tabContextByConnectionID[connectionID],
              context.runID == registration.runID, case .unrecorded = context.modelWriterAtBinding,
              context.routeOwnerIdentity == ObjectIdentifier(self), context.windowID == identity.routeID,
              context.tabID == published.tabID, context.workspaceID == published.workspaceID,
              context.readFileAutoSelectionGeneration == published.readFileAutoSelectionGeneration
        else { return }

        context.modelWriterAtBinding = .unavailable
        if let model = modelEndpointForTab?(context.tabID), model.endpoint.sessionID == context.activeAgentSessionID,
           model.endpoint.workspaceID == context.workspaceID, model.endpoint.windowID == identity.routeID,
           model.endpoint.tabID == context.tabID
        {
            context.modelWriterAtBinding = .captured(model.writer)
        }
        runRouteBindings.tabContextByConnectionID[connectionID] = context
    }

    func registeredModelObserverEndpoint(
        registration: MCPRunRoutingCleanupReceipt, connectionID: UUID, workspaceID: UUID, tabID: UUID
    ) -> DomainAgentSessionLinkEndpointIdentity? {
        guard hasCurrentModelCatalogRoute else { return nil }
        return modelObserverEndpoint(registration: registration, connectionID: connectionID, workspaceID: workspaceID, tabID: tabID)
    }

    func modelObserverEndpoint(
        registration: MCPRunRoutingCleanupReceipt, connectionID: UUID, workspaceID: UUID, tabID: UUID
    ) -> DomainAgentSessionLinkEndpointIdentity? {
        guard !isClosing, registration.routeOwner === self, !registration.isConsumed,
              registration.routeID == identity.routeID,
              runRouteBindings.cleanupOwnership(for: connectionID)?.policyID == registration.policyID,
              runRouteBindings.hasCurrentMapping(runID: registration.runID, connectionID: connectionID, expectedTabID: tabID),
              let context = runRouteBindings.tabContextByConnectionID[connectionID],
              context.routeOwnerIdentity == ObjectIdentifier(self), context.windowID == identity.routeID,
              context.workspaceID == workspaceID, let sessionID = context.activeAgentSessionID,
              case let .captured(writer) = context.modelWriterAtBinding else { return nil }
        if registration.providerContextResolver != nil {
            let metadata = MCPRequestMetadata(connectionID: connectionID, clientName: nil, windowID: identity.routeID)
            guard let invocation = canonicalHostInvocation(metadata), invocation.command.identity == writer,
                  let endpoint = invocation.host.scope.linkExecution?.agentSessionLinkObserverEndpoint(tabID: tabID),
                  endpoint.windowID == identity.routeID, endpoint.workspaceID == workspaceID, endpoint.sessionID == sessionID
            else { return nil }
            return endpoint
        }
        guard let model = modelEndpointForTab?(tabID), model.writer == writer,
              model.endpoint.windowID == identity.routeID, model.endpoint.workspaceID == workspaceID,
              model.endpoint.tabID == tabID, model.endpoint.sessionID == sessionID else { return nil }
        return model.endpoint
    }
}
