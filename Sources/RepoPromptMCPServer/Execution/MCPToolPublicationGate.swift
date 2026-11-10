// Exported Swift 5 package values need explicit cross-module Sendable contracts.
// swiftformat:disable redundantSendable
import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared

/// Publication authority is distinct from provider completion and physical delivery.
package struct MCPToolPublicationGate: Sendable {
    private let promptExportExecutionEnvelope: PromptExportExecutionEnvelope?
    private let promptExportMutationObservation: PromptExportMutationSettlementObservation?
    private let promptExportPublicationAuthorityObservation: PromptExportPublicationAuthorityObservation?
    private let fence: MCPToolDispatchFence
    private let connectionID: UUID
    private let invocationID: UUID
    private let toolName: String
    private let resolvedRequestIdentity: MCPRequestTimelineIdentity?
    private let beforeClaim: @Sendable () async -> Void
    private let closeAfterAuthorityLoss: @Sendable () async -> Void
    private let droppedResult: @Sendable () -> CallTool.Result

    package init(
        promptExportExecutionEnvelope: PromptExportExecutionEnvelope?,
        promptExportMutationObservation: PromptExportMutationSettlementObservation?,
        promptExportPublicationAuthorityObservation: PromptExportPublicationAuthorityObservation?,
        fence: MCPToolDispatchFence,
        connectionID: UUID,
        invocationID: UUID,
        toolName: String,
        resolvedRequestIdentity: MCPRequestTimelineIdentity?,
        beforeClaim: @escaping @Sendable () async -> Void,
        closeAfterAuthorityLoss: @escaping @Sendable () async -> Void,
        droppedResult: @escaping @Sendable () -> CallTool.Result
    ) {
        self.promptExportExecutionEnvelope = promptExportExecutionEnvelope
        self.promptExportMutationObservation = promptExportMutationObservation
        self.promptExportPublicationAuthorityObservation = promptExportPublicationAuthorityObservation
        self.fence = fence
        self.connectionID = connectionID
        self.invocationID = invocationID
        self.toolName = toolName
        self.resolvedRequestIdentity = resolvedRequestIdentity
        self.beforeClaim = beforeClaim
        self.closeAfterAuthorityLoss = closeAfterAuthorityLoss
        self.droppedResult = droppedResult
    }

    package func finalize(_ result: CallTool.Result) async -> CallTool.Result {
        guard promptExportMutationObservation?.snapshot()?.state == .applied else {
            return result
        }
        await beforeClaim()
        let authorization = promptExportPublicationAuthorityObservation?.snapshot()
        let windowAuthorityIsCurrent: Bool = if let windowIdentity = authorization?.windowIdentity {
            await fence.isWindowIdentityCurrent(windowIdentity)
        } else {
            true
        }
        let limiterIsCurrent = await fence.isLimiterCurrent()
        let dispatchAuthorizationIsCurrent: Bool = if let authorization {
            await fence.isAuthorizationCurrent(authorization)
        } else {
            false
        }
        let responseDeliveryIsCurrent = promptExportExecutionEnvelope?.responseDeliveryDeadline.hasExpired != true
        let authorityIsCurrent = responseDeliveryIsCurrent
            && !Task.isCancelled
            && limiterIsCurrent
            && dispatchAuthorizationIsCurrent
            && windowAuthorityIsCurrent
        guard authorityIsCurrent else {
            MCPResponseDeliveryTracer.emit(MCPResponseDeliveryTraceEvent(
                layer: "app_tool_handler",
                phase: "publication_suppressed_after_applied_mutation",
                connectionID: resolvedRequestIdentity?.connectionID ?? connectionID.uuidString,
                connectionGeneration: resolvedRequestIdentity?.connectionGeneration,
                method: "tools/call",
                tool: toolName,
                invocationID: invocationID.uuidString,
                lifecycleState: "applied",
                requestOrdinal: resolvedRequestIdentity?.requestOrdinal,
                requestIdentity: resolvedRequestIdentity,
                providerActive: false,
                networkScopeActive: false,
                permitActive: false,
                publicationPending: false,
                terminalBarrier: true
            ))
            await closeAfterAuthorityLoss()
            return droppedResult()
        }
        return result
    }

    package func validate(
        requiresUncancelledRequest: Bool = true
    ) async throws {
        guard promptExportMutationObservation != nil else { return }
        guard promptExportExecutionEnvelope?.responseDeliveryDeadline.hasExpired != true,
              !requiresUncancelledRequest || !Task.isCancelled,
              await fence.isLimiterCurrent(),
              let authorization =
              MCPToolDispatchContextValues.authorization.get()
                  ?? promptExportPublicationAuthorityObservation?.snapshot(),
                  await fence.isAuthorizationCurrent(authorization)
        else {
            throw PromptExportPublicationAuthorityLost()
        }
        if let windowIdentity = authorization.windowIdentity,
           await !(fence.isWindowIdentityCurrent(windowIdentity))
        {
            throw PromptExportPublicationAuthorityLost()
        }
    }

    package func isPublicationCurrent() async -> Bool {
        do { try await validate()
            return true
        } catch { return false }
    }

    package func isCompletionObserverCurrent() async -> Bool {
        do { try await validate(requiresUncancelledRequest: false)
            return true
        } catch { return false }
    }

    package func droppedPublicationResult() -> CallTool.Result {
        droppedResult()
    }
}
