import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

package struct MCPServerExecutionFailure {
    package let code: String
    package let message: String
    package let outcome: String
    package let shouldForceDisconnect: Bool
    package let errorMetadata: [String: Value]
    package let isAdmissionExpiry: Bool
    package let limitReachedWindowID: Int?

    package static func classify(
        _ error: Error,
        toolName: String,
        selectedExecutionContract: MCPToolExecutionContract?,
        promptExportOperationID: String,
        promptExportExecutionEnvelope: PromptExportExecutionEnvelope?,
        promptExportMutationObservation: PromptExportMutationSettlementObservation?
    ) -> Self? {
        var limitReachedWindowID: Int?
        let isAdmissionExpiry = error is MCPDomainAdmissionDeadline.Expired
            || (error as? MCPToolExecutionWatchdogError) == .admissionEnvelopeExpired
        let code: String
        let message: String
        let outcome: String
        let shouldForceDisconnect: Bool
        let errorMetadata: [String: Value]
        let selectedDeadlineDescription: String = {
            guard let seconds = selectedExecutionContract?.deadline?.mcpSeconds else {
                return "declared"
            }
            if seconds.rounded() == seconds {
                return String(Int(seconds))
            }
            return seconds.formatted()
        }()

        switch error {
        case MCPToolDispatchAdmissionError.connectionTerminal:
            code = "tool_execution_connection_terminal"
            message = "The MCP connection is closing."
            outcome = "connectionTerminal"
            shouldForceDisconnect = false
            errorMetadata = [:]
        case MCPToolDispatchAdmissionError.windowTerminal:
            code = "tool_execution_window_terminal"
            message = "The selected window is closing or no longer owns this tool catalog."
            outcome = "windowTerminal"
            shouldForceDisconnect = false
            errorMetadata = [:]
        case let MCPToolExecutionDispatchError.missingContract(missingToolName):
            code = "tool_execution_contract_missing"
            message = "No declared execution contract exists for MCP tool '\(missingToolName)'."
            outcome = "executionContractMissing"
            shouldForceDisconnect = false
            errorMetadata = [:]
        case let MCPToolExecutionDispatchError.structureSettlementBusy(windowID, busyContext):
            code = "tool_execution_structure_settlement_busy"
            let limitReached = busyContext.reason == .releasedProviderLimitReached
            let abandoned = busyContext.reason == .abandoned
            if limitReached {
                limitReachedWindowID = windowID
                message = "Window \(windowID) reached its limit of one released cancellation-ignoring structure provider. Wait for it to settle or restart RepoPrompt CE."
            } else if abandoned {
                message = "A prior canceled MCP operation for window \(windowID) is still settling. Retry after the bounded recovery wait."
            } else {
                message = "A prior timed-out MCP operation for window \(windowID) is still settling. Retry after the bounded recovery wait."
            }
            outcome = "executionStructureSettlementBusy"
            shouldForceDisconnect = false

            var busyMetadata: [String: Value] = [
                "retryable": .bool(!limitReached),
                "busy_reason": .string(
                    limitReached
                        ? "released_provider_limit_reached"
                        : abandoned
                        ? "abandoned_settlement_in_progress"
                        : "detached_settlement_in_progress"
                ),
                "settlement": .string("busy"),
                "origin_tool": .string(busyContext.originToolName),
                "origin_invocation_id": .string(busyContext.originInvocationID.uuidString),
                "origin_connection_id": .string(busyContext.originConnectionID.uuidString),
                "detached_age_ms": .double(busyContext.detachedAge.mcpMilliseconds),
                "last_handler_phase": .string(busyContext.handlerPhase ?? "unreported"),
                "released_provider_count": .int(busyContext.releasedProviderCount)
            ]
            if let recoveryAfter = busyContext.recoveryAfter {
                let recoveryAfterMilliseconds = max(
                    0,
                    Int(recoveryAfter.mcpMilliseconds.rounded(.up))
                )
                busyMetadata["retry_after_ms"] = .int(recoveryAfterMilliseconds)
            }
            errorMetadata = busyMetadata
        case MCPToolExecutionDispatchError.structureSettlementWindowUnresolved:
            code = "tool_execution_structure_settlement_window_unresolved"
            message = "\(toolName) requires a resolved window before its settlement policy can be selected."
            outcome = "executionStructureSettlementWindowUnresolved"
            shouldForceDisconnect = false
            errorMetadata = ["retryable": .bool(false)]
        case is MCPDomainAdmissionDeadline.Expired,
             MCPToolExecutionWatchdogError.admissionEnvelopeExpired:
            code = "tool_execution_admission_timeout"
            message = "Tool '\(toolName)' could not enter its provider while preserving the export execution envelope."
            outcome = "executionAdmissionTimeout"
            shouldForceDisconnect = false
            errorMetadata = [
                "retryable": .bool(true),
                "mutation_state": .string("not_applied"),
                "operation_id": .string(promptExportOperationID),
                "tool": .string(toolName),
                "cancellation_origin": .string(
                    promptExportExecutionEnvelope?.cancellationOrigin.rawValue
                        ?? MCPToolExecutionCancellationOrigin.serverExportEnvelope.rawValue
                ),
                "settlement": .string("admission_timeout")
            ]
        case let MCPToolExecutionWatchdogError.executionTimedOut(settlement):
            code = "tool_execution_timeout"
            message = "Tool '\(toolName)' exceeded its \(selectedDeadlineDescription)-second execution contract and settled as \(settlement.rawValue) during cancellation grace."
            outcome = "executionTimeout"
            shouldForceDisconnect = false
            errorMetadata = [
                "cancellation_origin": .string(MCPToolExecutionCancellationOrigin.watchdogDeadline.rawValue),
                "settlement": .string(settlement.rawValue)
            ].merging(
                promptExportMutationObservation?.errorMetadata(toolName: toolName) ?? [:],
                uniquingKeysWith: { _, authorityValue in authorityValue }
            )
        case MCPToolExecutionWatchdogError.executionDetached:
            let mutationOutcomeMayStillReconcile = toolName == MCPWindowToolName.fileActions
            code = "tool_execution_timeout"
            message = mutationOutcomeMayStillReconcile
                ? "Tool '\(toolName)' exceeded its \(selectedDeadlineDescription)-second execution contract. Watchdog cancellation did not settle the mutation provider during grace, so it was detached for eventual reconciliation. Inspect the filesystem before issuing another mutation."
                : "Tool '\(toolName)' exceeded its \(selectedDeadlineDescription)-second execution contract. Watchdog cancellation did not settle the read-only provider during grace, so it was detached for eventual cleanup."
            outcome = "executionDetached"
            shouldForceDisconnect = false
            errorMetadata = [
                "retryable": .bool(!mutationOutcomeMayStillReconcile),
                "cancellation_origin": .string(MCPToolExecutionCancellationOrigin.watchdogDeadline.rawValue),
                "settlement": .string("detached")
            ]
        case MCPToolExecutionWatchdogError.cleanupUnresponsive:
            code = "tool_execution_cleanup_unresponsive"
            message = "Tool '\(toolName)' exceeded its \(selectedDeadlineDescription)-second execution contract and did not stop during cancellation grace. The MCP connection was force-disconnected."
            outcome = "executionCleanupUnresponsive"
            shouldForceDisconnect = true
            errorMetadata = [
                "retryable": .bool(false),
                "cancellation_origin": .string(MCPToolExecutionCancellationOrigin.watchdogDeadline.rawValue),
                "settlement": .string("force_disconnect")
            ].merging(
                promptExportMutationObservation?.errorMetadata(toolName: toolName) ?? [:],
                uniquingKeysWith: { _, authorityValue in authorityValue }
            )
        case let protectedError as DomainProtectedMutationError
            where promptExportMutationObservation != nil:
            let settlement = protectedError.settlement
            code = "protected_mutation_indeterminate_after_commit"
            message = protectedError.localizedDescription
            outcome = "protectedMutationIndeterminateAfterCommit"
            shouldForceDisconnect = false
            errorMetadata = [
                "mutation_state": .string(settlement.state.rawValue),
                "retryable": .bool(false),
                "operation_id": .string(settlement.operationID),
                "tool": .string(toolName),
                "settlement": .string("error")
            ]
        default:
            return nil
        }

        return Self(code: code, message: message, outcome: outcome, shouldForceDisconnect: shouldForceDisconnect, errorMetadata: errorMetadata, isAdmissionExpiry: isAdmissionExpiry, limitReachedWindowID: limitReachedWindowID)
    }
}
