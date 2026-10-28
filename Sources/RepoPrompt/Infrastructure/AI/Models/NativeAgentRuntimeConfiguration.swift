import Foundation

/// Ephemeral controller-owned receipt, never persisted or inferred from a Void update.
/// The lifetime prevents reset generation counters from reviving an old process's receipt.
struct NativeAgentRuntimeConfigurationProof: Equatable {
    let lifetime: UUID
    let intentGeneration: UInt64
    let requestGeneration: UInt64
}

/// Ephemeral failure authority for one controller lifetime/intent, never an application receipt.
struct NativeAgentRuntimeConfigurationFailure: Error, LocalizedError {
    let underlyingError: any Error
    let lifetime: UUID
    let intentGeneration: UInt64
    let requestGeneration: UInt64
    var errorDescription: String? {
        underlyingError.localizedDescription
    }
}

enum NativeAgentRuntimeConfigurationApplication: Equatable {
    case applied(NativeAgentRuntimeConfigurationProof)
    case appliedButSuperseded
    case superseded
    case notReady
}

/// Distinguishes turn authorization from provider settings that landed after newer intent.
enum NativeAgentRuntimeTurnConfigurationOutcome: Equatable {
    case applied, appliedButSuperseded, superseded
}
