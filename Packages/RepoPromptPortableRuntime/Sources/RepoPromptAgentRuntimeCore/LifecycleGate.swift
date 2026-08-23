import Foundation
import RepoPromptRuntimeModel

public struct RunBindingIdentity: Codable, Hashable, Sendable {
    public let runID: UUID
    public let generation: Int64
    public let turnEpoch: Int64
    public let connectionGeneration: Int64
    public init(runID: UUID, generation: Int64, turnEpoch: Int64, connectionGeneration: Int64) {
        self.runID = runID
        self.generation = generation
        self.turnEpoch = turnEpoch
        self.connectionGeneration = connectionGeneration
    }
}

public enum LifecycleAcceptance: Equatable, Sendable { case accepted, staleGeneration, staleTurnEpoch, staleConnection, terminalAlreadySettled }

public struct AgentRunLifecycleGate: Sendable {
    public private(set) var binding: RunBindingIdentity
    public private(set) var terminalEvent: EventType?

    public init(binding: RunBindingIdentity) {
        self.binding = binding
    }

    public mutating func accept(binding candidate: RunBindingIdentity, terminal: EventType? = nil) -> LifecycleAcceptance {
        guard terminalEvent == nil else { return .terminalAlreadySettled }
        guard candidate.generation == binding.generation else { return .staleGeneration }
        guard candidate.turnEpoch == binding.turnEpoch else { return .staleTurnEpoch }
        guard candidate.connectionGeneration == binding.connectionGeneration else { return .staleConnection }
        if let terminal { terminalEvent = terminal }
        return .accepted
    }

    public mutating func advanceTurn(runID: UUID) {
        binding = RunBindingIdentity(runID: runID, generation: binding.generation, turnEpoch: binding.turnEpoch + 1, connectionGeneration: binding.connectionGeneration)
    }
}
