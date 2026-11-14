import Foundation

extension AgentModeViewModel {
    /// Transitional destination-creation adapter. The existing handoff owner acknowledges the
    /// configured durable first save; administration owns exact source command admission.
    func installAdministrationComposition(_ runtime: AgentSessionAdministrationRuntime) {
        runtime.prepareForkDestination = { [weak self] request in
            guard let self,
                  workspaceManager?.activeWorkspaceID == request.workspaceID,
                  sessions[request.source.tabID] === request.source,
                  request.isStillAuthorized()
            else { throw SessionAdminHostError.sessionUnavailable }
            let source = request.source
            var receipt: AgentSessionAdministrationRuntime.ForkReceipt?
            _ = try await prepareHandoffToNewTab(
                upToItemID: request.cutoff,
                destinationAgent: source.selectedAgent,
                destinationModelRaw: source.selectedModelRaw,
                destinationReasoningEffortRaw: source.persistedReasoningEffortRaw,
                sourceTabID: source.tabID,
                activateDestination: false,
                inheritOversightLinks: false,
                missingImagePolicy: .strict,
                isStillAuthorized: { [weak self] in
                    guard let self else { return false }
                    return request.isStillAuthorized()
                        && workspaceManager?.activeWorkspaceID == request.workspaceID
                },
                onConfiguredDestination: { receipt = .init(identity: $0) }
            )
            guard let receipt else {
                throw SessionAdminHostError.invalid("The fork did not acknowledge its configured durable destination. Inspect the created tab before retrying.")
            }
            return receipt
        }
    }
}
