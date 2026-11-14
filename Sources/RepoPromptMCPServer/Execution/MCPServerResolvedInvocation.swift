// Exported Swift 5 package values need explicit cross-module Sendable contracts.
// swiftformat:disable redundantSendable
import Foundation
import MCP
import RepoPromptDomainRuntime

/// The resolved, admitted host call. No resolution fallback or second execution
/// envelope is introduced here. The host still fences registry/runtime generations
/// and owns provider entry, cancellation, and drain.
package struct MCPServerResolvedInvocation: Sendable {
    private let host: @Sendable () async -> MCPDomainHost
    private let invocationID: UUID
    private let connectionID: UUID
    private let resolution: MCPDomainHostResolution
    private let arguments: [String: Value]
    private let securityContext: DomainToolInvocationSecurityContext
    private let admittedContext: MCPDomainAdmittedContext?
    private let admissionDeadline: MCPDomainAdmissionDeadline?

    package init(
        host: @escaping @Sendable () async -> MCPDomainHost,
        invocationID: UUID,
        connectionID: UUID,
        resolution: MCPDomainHostResolution,
        arguments: [String: Value],
        securityContext: DomainToolInvocationSecurityContext,
        admittedContext: MCPDomainAdmittedContext?,
        admissionDeadline: MCPDomainAdmissionDeadline?
    ) {
        self.host = host
        self.invocationID = invocationID
        self.connectionID = connectionID
        self.resolution = resolution
        self.arguments = arguments
        self.securityContext = securityContext
        self.admittedContext = admittedContext
        self.admissionDeadline = admissionDeadline
    }

    package func invoke(
        context: ToolInvocationContext,
        providerEntry: PromptExportProviderEntryBridge?,
        diagnosticSink: @escaping @Sendable (MCPInvocationContextFailure) -> Void,
        testOperation: @Sendable () async -> (@Sendable () async throws -> Value)? = { nil }
    ) async throws -> Value {
        try await MCPInvocationContextBridge.$diagnosticSink.withValue(diagnosticSink) {
            try await MCPInvocationContextBridge.withInvocation(context) {
                #if DEBUG
                    if let operation = await testOperation() {
                        try providerEntry?.providerWillEnter()
                        MCPLifecycleDiagnostics.shared.record(.providerEntered, connectionID: connectionID, invocationID: invocationID)
                        defer {
                            MCPLifecycleDiagnostics.shared.record(.providerReturning, connectionID: connectionID, invocationID: invocationID)
                        }
                        return try await operation()
                    }
                #endif
                return try await host().invoke(MCPDomainHostInvocation(
                    invocationID: invocationID,
                    connectionID: connectionID,
                    resolution: resolution,
                    arguments: arguments,
                    securityContext: securityContext,
                    admittedContext: admittedContext,
                    admissionDeadline: admissionDeadline,
                    onProviderEntry: {
                        try providerEntry?.providerWillEnter()
                        MCPLifecycleDiagnostics.shared.record(.providerEntered, connectionID: connectionID, invocationID: invocationID)
                    },
                    onProviderReturn: {
                        MCPLifecycleDiagnostics.shared.record(.providerReturning, connectionID: connectionID, invocationID: invocationID)
                    }
                ))
            }
        }
    }
}
