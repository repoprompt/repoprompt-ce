import Foundation

/// Ephemeral controller-owned receipt, never persisted or inferred from a Void update.
/// The lifetime prevents reset generation counters from reviving an old process's receipt.
package struct NativeAgentRuntimeConfigurationProof: Equatable {
    package let lifetime: UUID
    package let intentGeneration: UInt64
    package let requestGeneration: UInt64

    package init(lifetime: UUID, intentGeneration: UInt64, requestGeneration: UInt64) {
        self.lifetime = lifetime
        self.intentGeneration = intentGeneration
        self.requestGeneration = requestGeneration
    }
}

/// Ephemeral failure authority for one controller lifetime/intent, never an application receipt.
package struct NativeAgentRuntimeConfigurationFailure: Error, LocalizedError {
    package let underlyingError: any Error
    package let lifetime: UUID
    package let intentGeneration: UInt64
    package let requestGeneration: UInt64

    package init(underlyingError: any Error, lifetime: UUID, intentGeneration: UInt64, requestGeneration: UInt64) {
        self.underlyingError = underlyingError
        self.lifetime = lifetime
        self.intentGeneration = intentGeneration
        self.requestGeneration = requestGeneration
    }

    package var errorDescription: String? {
        underlyingError.localizedDescription
    }
}

package enum NativeAgentRuntimeConfigurationApplication: Equatable {
    case applied(NativeAgentRuntimeConfigurationProof)
    case appliedButSuperseded
    case superseded
    case notReady
}

/// Distinguishes turn authorization from provider settings that landed after newer intent.
package enum NativeAgentRuntimeTurnConfigurationOutcome: Equatable {
    case applied, appliedButSuperseded, superseded
}
