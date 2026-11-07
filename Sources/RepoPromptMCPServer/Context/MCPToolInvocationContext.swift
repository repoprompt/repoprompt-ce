// Exported Swift 5 package values need explicit cross-module Sendable contracts.
// swiftformat:disable redundantSendable
import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared

package typealias MCPTabContextHint = RepoPromptShared.MCPTabContextHint

package typealias MCPRequestMetadata = RepoPromptShared.MCPRequestMetadata

package struct MCPWindowToolDispatchIdentity: Sendable {
    package let windowID: Int
    package let windowStateIdentity: ObjectIdentifier
    package let serverViewModelIdentity: ObjectIdentifier
    package let catalogRegistrationHandle: MCPDomainToolRegistrationHandle
    package var modelRouteToken: AgentSessionLinkRunCatalogRouteToken?

    package init(
        windowID: Int,
        windowStateIdentity: ObjectIdentifier,
        serverViewModelIdentity: ObjectIdentifier,
        catalogRegistrationHandle: MCPDomainToolRegistrationHandle,
        modelRouteToken: AgentSessionLinkRunCatalogRouteToken? = nil
    ) {
        self.windowID = windowID
        self.windowStateIdentity = windowStateIdentity
        self.serverViewModelIdentity = serverViewModelIdentity
        self.catalogRegistrationHandle = catalogRegistrationHandle
        self.modelRouteToken = modelRouteToken
    }
}

/// Immutable policy admission for a queued internal-management call. The manager is
/// the sole policy owner; this value confers no delegation-scope authority.
package struct MCPToolPolicyAdmissionToken: Sendable {
    package let connectionID: UUID
    package let connectionIdentity: ObjectIdentifier
    package let lifecycleGeneration: UInt64
    package let policyGeneration: UInt64
    package let runID: UUID?
    package let runRoutingAuthorityGeneration: UInt64?
    package let runPolicyRevision: UUID?

    package init(
        connectionID: UUID,
        connectionIdentity: ObjectIdentifier,
        lifecycleGeneration: UInt64,
        policyGeneration: UInt64,
        runID: UUID?,
        runRoutingAuthorityGeneration: UInt64?,
        runPolicyRevision: UUID?
    ) {
        self.connectionID = connectionID
        self.connectionIdentity = connectionIdentity
        self.lifecycleGeneration = lifecycleGeneration
        self.policyGeneration = policyGeneration
        self.runID = runID
        self.runRoutingAuthorityGeneration = runRoutingAuthorityGeneration
        self.runPolicyRevision = runPolicyRevision
    }
}

package struct MCPToolDispatchAuthorization: Sendable {
    package let connectionID: UUID
    package let connectionIdentity: ObjectIdentifier
    package let lifecycleGeneration: UInt64
    package let windowIdentity: MCPWindowToolDispatchIdentity?
    package var policyAdmissionToken: MCPToolPolicyAdmissionToken?

    package init(
        connectionID: UUID,
        connectionIdentity: ObjectIdentifier,
        lifecycleGeneration: UInt64,
        windowIdentity: MCPWindowToolDispatchIdentity?,
        policyAdmissionToken: MCPToolPolicyAdmissionToken? = nil
    ) {
        self.connectionID = connectionID
        self.connectionIdentity = connectionIdentity
        self.lifecycleGeneration = lifecycleGeneration
        self.windowIdentity = windowIdentity
        self.policyAdmissionToken = policyAdmissionToken
    }
}

/// Immutable app-host evidence carried across the unchanged canonical args-only binding.
/// DomainRuntime remains the owner of admission, cancellation, settlement, and delivery.
package struct ToolInvocationContext: Sendable {
    package enum Origin: Sendable {
        case network
        case trustedLocal
    }

    package let origin: Origin
    package let invocationID: UUID
    /// Correlation only. Existing host/transport identities remain the deduplication authority.
    package let requestID: JSONRPCBridgeID?
    package let toolName: String
    package let metadata: MCPRequestMetadata
    package let dispatchAuthorization: MCPToolDispatchAuthorization?
    /// Candidate native association supplied by Claude Code request metadata. Not host authority.
    /// Live presence/equality with stream tool_use_id is an unverified external assumption.
    package let claudeToolUseID: String?
    /// Pinned Codex request correlation only; never admission or host invocation authority.
    package let codexCallID: String?
    package let codexThreadID: String?

    package init(
        origin: Origin,
        invocationID: UUID,
        requestID: JSONRPCBridgeID?,
        toolName: String,
        metadata: MCPRequestMetadata,
        dispatchAuthorization: MCPToolDispatchAuthorization?,
        claudeToolUseID: String? = nil,
        codexCallID: String? = nil,
        codexThreadID: String? = nil
    ) {
        self.origin = origin
        self.invocationID = invocationID
        self.requestID = requestID
        self.toolName = toolName
        self.metadata = metadata
        self.dispatchAuthorization = dispatchAuthorization
        self.claudeToolUseID = claudeToolUseID
        self.codexCallID = codexCallID
        self.codexThreadID = codexThreadID
    }

    package static func candidateClaudeToolUseID(_ value: MCP.Value?) -> String? {
        correlationString(value)
    }

    package static func correlationString(_ value: MCP.Value?) -> String? {
        guard case let .string(raw)? = value, !raw.isEmpty,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return raw
    }

    package var connectionID: UUID? {
        metadata.connectionID
    }

    package func withDispatchAuthorization(
        _ authorization: MCPToolDispatchAuthorization,
        explicitWindowRoutingHint: MCPExplicitWindowRoutingHint?
    ) -> Self {
        Self(
            origin: origin,
            invocationID: invocationID,
            requestID: requestID,
            toolName: toolName,
            metadata: MCPRequestMetadata(
                connectionID: metadata.connectionID,
                clientName: metadata.clientName,
                windowID: authorization.windowIdentity?.windowID ?? metadata.windowID,
                runPurpose: metadata.runPurpose,
                tabContextHint: metadata.tabContextHint,
                explicitWindowRoutingHint: explicitWindowRoutingHint,
                invocationID: metadata.invocationID,
                requestID: metadata.requestID
            ),
            dispatchAuthorization: authorization,
            claudeToolUseID: claudeToolUseID,
            codexCallID: codexCallID,
            codexThreadID: codexThreadID
        )
    }

    package static func trustedLocal(toolName: String, metadata: MCPRequestMetadata) -> Self {
        let invocationID = metadata.invocationID ?? UUID()
        return Self(
            origin: .trustedLocal,
            invocationID: invocationID,
            requestID: metadata.requestID,
            toolName: toolName,
            metadata: metadata,
            dispatchAuthorization: nil
        )
    }
}

package enum MCPInvocationContextFailure: Error, Equatable {
    case missingExpectedContext
    case toolMismatch
    case connectionMismatch
    case windowMismatch
    case missingAuthorization
}

/// The single app-binding ingress bridge. Capture before callbacks/detached tasks, then
/// forward the value explicitly; those hops must not rely on TaskLocal inheritance.
package enum MCPInvocationContextBridge {
    // Boxed: runtime-sized payloads must not use `@TaskLocal` directly (#1039).
    package static let currentTaskLocal = BoxedTaskLocal<ToolInvocationContext?>(nil)
    package static var current: ToolInvocationContext? {
        currentTaskLocal.get()
    }

    @TaskLocal package static var diagnosticSink: (@Sendable (MCPInvocationContextFailure) -> Void)?

    package static func require(
        toolName: String,
        expectedWindowID: Int? = nil,
        diagnosticSink: @Sendable (MCPInvocationContextFailure) -> Void
    ) throws -> ToolInvocationContext {
        guard let context = current else { throw failure(.missingExpectedContext, fallback: diagnosticSink) }
        guard context.toolName == toolName else { throw failure(.toolMismatch, fallback: diagnosticSink) }
        switch context.origin {
        case .network:
            guard let connectionID = context.connectionID,
                  context.metadata.invocationID == context.invocationID
            else { throw failure(.connectionMismatch, fallback: diagnosticSink) }
            if let authorization = context.dispatchAuthorization {
                guard authorization.connectionID == connectionID else { throw failure(.connectionMismatch, fallback: diagnosticSink) }
            }
            if let expectedWindowID {
                guard let authorization = context.dispatchAuthorization else { throw failure(.missingAuthorization, fallback: diagnosticSink) }
                guard authorization.windowIdentity?.windowID == expectedWindowID,
                      context.metadata.windowID == expectedWindowID
                else { throw failure(.windowMismatch, fallback: diagnosticSink) }
            }
        case .trustedLocal:
            if let expectedWindowID, let windowID = context.metadata.windowID, windowID != expectedWindowID {
                throw failure(.windowMismatch, fallback: diagnosticSink)
            }
        }
        return context
    }

    package static func withInvocation<T>(
        _ context: ToolInvocationContext,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await currentTaskLocal.withValue(context, operation: operation)
    }

    private static func failure(
        _ failure: MCPInvocationContextFailure,
        fallback: @Sendable (MCPInvocationContextFailure) -> Void
    ) -> MCPInvocationContextFailure {
        #if DEBUG
            if let diagnosticSink {
                diagnosticSink(failure)
            } else {
                fallback(failure)
            }
        #endif
        return failure
    }
}

package typealias MCPToolInvocationValidator = @Sendable (
    _ context: ToolInvocationContext,
    _ expectedWindowID: Int,
    _ expectedServerViewModelIdentity: ObjectIdentifier
) async -> Bool
