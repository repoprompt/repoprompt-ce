import Foundation
import RepoPromptDomainRuntime

/// Captured before a deferred producer creates a task; never refreshed by that producer.
package struct AgentRunStartStopFence: Equatable {
    package let binding: AgentPersistentSessionBindingIdentity?
    package let cancellationGeneration: UUID
    package let cancellationCount: UInt64
    package let explicitStopGeneration: UUID

    package init(
        binding: AgentPersistentSessionBindingIdentity?,
        cancellationGeneration: UUID,
        cancellationCount: UInt64,
        explicitStopGeneration: UUID
    ) {
        self.binding = binding
        self.cancellationGeneration = cancellationGeneration
        self.cancellationCount = cancellationCount
        self.explicitStopGeneration = explicitStopGeneration
    }
}
