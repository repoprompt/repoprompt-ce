// Exported Swift 5 package values need explicit cross-module Sendable contracts.
// swiftformat:disable redundantSendable
import Foundation
import RepoPromptDomainRuntime

package enum MCPToolDispatchAdmissionError: Error {
    case connectionTerminal
    case windowTerminal
}

/// Live app evidence is rechecked at each existing suspension boundary. This value
/// never caches the answer or introduces a second generation/permission owner.
package struct MCPToolDispatchFence: Sendable {
    package let admissionDeadline: MCPDomainAdmissionDeadline?
    package let isLimiterCurrent: @Sendable () async -> Bool
    package let isAuthorizationCurrent: @Sendable (MCPToolDispatchAuthorization) async -> Bool
    package let isWindowIdentityCurrent: @Sendable (MCPWindowToolDispatchIdentity) async -> Bool

    package init(
        admissionDeadline: MCPDomainAdmissionDeadline?,
        isLimiterCurrent: @escaping @Sendable () async -> Bool,
        isAuthorizationCurrent: @escaping @Sendable (MCPToolDispatchAuthorization) async -> Bool,
        isWindowIdentityCurrent: @escaping @Sendable (MCPWindowToolDispatchIdentity) async -> Bool
    ) {
        self.admissionDeadline = admissionDeadline
        self.isLimiterCurrent = isLimiterCurrent
        self.isAuthorizationCurrent = isAuthorizationCurrent
        self.isWindowIdentityCurrent = isWindowIdentityCurrent
    }

    package func validate(_ authorization: MCPToolDispatchAuthorization?) async throws {
        try admissionDeadline?.check()
        guard await isLimiterCurrent() else { throw MCPToolDispatchAdmissionError.connectionTerminal }
        try admissionDeadline?.check()
        if let authorization {
            guard await isAuthorizationCurrent(authorization) else { throw MCPToolDispatchAdmissionError.connectionTerminal }
            try admissionDeadline?.check()
            if let windowIdentity = authorization.windowIdentity,
               await !isWindowIdentityCurrent(windowIdentity)
            {
                throw MCPToolDispatchAdmissionError.windowTerminal
            }
            try admissionDeadline?.check()
        }
    }
}

/// Presentation of a settlement-limit notice remains an app effect, not server state.
package struct MCPToolExecutionEffects: Sendable {
    package let clearAfterAdmission: @Sendable (Int) async -> Void
    package let clearAfterSettlement: @Sendable (MCPCodeStructureSettlementRegistry.Slot) async -> Void
    #if DEBUG
        package var debugHostCompletion: (@Sendable () async -> (@Sendable (UUID, String, Duration) -> Void)?)?
        package var debugProviderEntry: (@Sendable (UUID, String) async -> Void)?
    #endif

    package init(
        clearAfterAdmission: @escaping @Sendable (Int) async -> Void = { _ in },
        clearAfterSettlement: @escaping @Sendable (MCPCodeStructureSettlementRegistry.Slot) async -> Void = { _ in }
    ) {
        self.clearAfterAdmission = clearAfterAdmission
        self.clearAfterSettlement = clearAfterSettlement
    }
}
