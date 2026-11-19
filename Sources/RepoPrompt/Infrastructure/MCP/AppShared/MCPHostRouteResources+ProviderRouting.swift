import Foundation

extension MCPHostRouteResources {
    func installProviderContext(
        _ admitted: ProviderContext, receipt: MCPRunRoutingCleanupReceipt,
        connectionID: UUID, tabID: UUID?
    ) -> PolicyContextInstallation? {
        var context = admitted.snapshot
        guard !Task.isCancelled, !isClosing, receipt.routeOwner === self, !receipt.isConsumed,
              receipt.routeID == identity.routeID, context.windowID == identity.routeID,
              context.workspaceID != nil, context.runID == receipt.runID,
              tabID.map({ $0 == context.tabID }) ?? true,
              runRouteBindings.tabContextByConnectionID[connectionID] == nil, admitted.isCurrent(),
              var token = runRouteBindings.beginPendingPolicy(
                  connectionID: connectionID, runID: receipt.runID, windowID: identity.routeID, cleanupReceipt: receipt
              )
        else { return nil }

        token.validateProviderCarrier = admitted.validateCarrier
        runRouteBindings.nextReadFileAutoSelectionBindingGeneration &+= 1
        context.readFileAutoSelectionGeneration = runRouteBindings.nextReadFileAutoSelectionBindingGeneration
        context.routeOwnerIdentity = ObjectIdentifier(self)
        runRouteBindings.tabContextByConnectionID[connectionID] = context
        runRouteBindings.installReadFileAutoSelectionHandoverLineage(for: token)
        publishBinding(connectionID: connectionID, context: context, cleanupReceipt: receipt)
        return .init(token: token, workspaceID: context.workspaceID, tabID: context.tabID)
    }

    func rollbackProviderContext(
        _ receipt: MCPRunRoutingCleanupReceipt, token: MCPRunRouteBindings.PendingPolicyToken
    ) -> MCPRunRouteBindings.PendingPolicyRollbackResult {
        let ownsContext = runRouteBindings.cleanupOwnership(for: token.connectionID)?.policyID == receipt.policyID
        if ownsContext, runRouteBindings.rollback(token, removingContext: {
            removeProviderContext(connectionID: token.connectionID, runID: token.runID)
            publishRelease(connectionID: token.connectionID)
        }) {
            return .restored
        }

        let currentConnection = runRouteBindings.connectionIDByRunID[token.runID]
        if ownsContext, currentConnection != token.connectionID {
            removeProviderContext(connectionID: token.connectionID, runID: token.runID)
            publishRelease(connectionID: token.connectionID)
        }
        return currentConnection == token.connectionID ? .supersededBySameConnection : .supersededByOtherConnection
    }

    func removeProviderContext(connectionID: UUID, runID: UUID) {
        guard let context = runRouteBindings.tabContextByConnectionID[connectionID],
              context.runID == runID, context.routeOwnerIdentity == ObjectIdentifier(self)
        else { return }
        runRouteBindings.tabContextByConnectionID.removeValue(forKey: connectionID)
        runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
        readFileAutoSelectionCoordinator?.invalidate(context: runRouteBindings.readFileAutoSelectionContextKey(connectionID: connectionID, context: context))
    }
}
