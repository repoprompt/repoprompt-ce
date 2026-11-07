// Exported Swift 5 package values need explicit cross-module Sendable contracts.
// swiftformat:disable redundantSendable
import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

/// Pure request preparation. Formatting a rejected request remains an app adapter
/// concern; the rejection decision cannot read window, policy, or settings state.
package struct MCPToolCallPreparation: Sendable {
    package struct Failure: Sendable {
        package let code: String
        package let message: String
        package let metadata: [String: Value]
    }

    package let isPromptExport: Bool
    package let operationID: String
    private let toolName: String
    private let envelopeState: MCPToolCallDeadlineEnvelopeState

    package init(toolName: String, invocationID: UUID, normalized: NormalizedArgs) {
        self.toolName = toolName
        envelopeState = normalized.executionEnvelopeState
        isPromptExport = (toolName == "prompt" || toolName == "workspace_context")
            && MCPPromptContextOperation.parse(toolName: toolName, arguments: normalized.payload) == .export
        let supplied = normalized.payload["operation_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        operationID = supplied.isEmpty ? invocationID.uuidString : supplied
    }

    package static func normalize(params: [String: Value]?, originalToolName: String, canonicalToolName: String) -> NormalizedArgs {
        EditFlowPerf.measure(EditFlowPerf.Stage.MCPToolCall.normalizeArgs, EditFlowPerf.Dimensions(toolName: canonicalToolName)) {
            MCPToolArgsNormalizer.normalize(params: params, originalToolName: originalToolName, canonicalToolName: canonicalToolName)
        }
    }

    package var invalidEnvelopeFailure: Failure? {
        guard isPromptExport, case .invalid = envelopeState else { return nil }
        return Failure(
            code: "tool_execution_invalid_envelope",
            message: "Tool '\(toolName)' received an invalid execution envelope.",
            metadata: [
                "retryable": .bool(false), "mutation_state": .string("not_applied"),
                "operation_id": .string(operationID), "tool": .string(toolName)
            ]
        )
    }

    package func admissionTimeout(envelope: PromptExportExecutionEnvelope?) -> Failure? {
        guard let envelope else { return nil }
        do {
            try envelope.admissionDeadline.check()
            return nil
        } catch {
            return Failure(
                code: "tool_execution_admission_timeout",
                message: "Tool '\(toolName)' could not enter its provider while preserving the export execution envelope.",
                metadata: [
                    "retryable": .bool(true), "mutation_state": .string("not_applied"),
                    "operation_id": .string(operationID), "tool": .string(toolName),
                    "cancellation_origin": .string(envelope.cancellationOrigin.rawValue), "settlement": .string("admission_timeout")
                ]
            )
        }
    }
}
