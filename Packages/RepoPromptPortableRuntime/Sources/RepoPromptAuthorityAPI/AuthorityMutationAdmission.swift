import Foundation
import RepoPromptRuntimeModel

/// Transport-neutral snapshot of host-owned mutation admission.
public struct AuthorityMutationGateSnapshot: Codable, Hashable, Sendable {
    public let acceptingMutations: Bool
    public let acceptingReads: Bool
    public let acceptingSubscriptions: Bool
    public let inFlightMutations: Int
    public let inFlightReads: Int
    public let mutationGeneration: UInt64
    public let readGeneration: UInt64
    public let drainStartedAt: Date?
    public let drainTimedOut: Bool

    public init(
        acceptingMutations: Bool,
        acceptingReads: Bool,
        acceptingSubscriptions: Bool,
        inFlightMutations: Int,
        inFlightReads: Int,
        mutationGeneration: UInt64,
        readGeneration: UInt64,
        drainStartedAt: Date?,
        drainTimedOut: Bool
    ) {
        self.acceptingMutations = acceptingMutations
        self.acceptingReads = acceptingReads
        self.acceptingSubscriptions = acceptingSubscriptions
        self.inFlightMutations = inFlightMutations
        self.inFlightReads = inFlightReads
        self.mutationGeneration = mutationGeneration
        self.readGeneration = readGeneration
        self.drainStartedAt = drainStartedAt
        self.drainTimedOut = drainTimedOut
    }
}

public protocol AuthorityReadAdmitting: Sendable {
    func performRead<Result: Sendable>(
        generation: UInt64,
        subscription: Bool,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result
}

/// Host-issued read/subscription fence. Ordinary reads remain valid while the
/// host drains admitted mutations; subscriptions are rejected as soon as drain
/// begins, and both are invalidated before store close.
public struct AuthorityReadCapability: Sendable {
    public let generation: UInt64
    public let subscription: Bool
    private let admission: any AuthorityReadAdmitting

    public init(
        generation: UInt64,
        subscription: Bool,
        admission: any AuthorityReadAdmitting
    ) {
        self.generation = generation
        self.subscription = subscription
        self.admission = admission
    }

    public func perform<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try await admission.performRead(
            generation: generation,
            subscription: subscription,
            operation: operation
        )
    }
}

/// Implemented by the authority host. Transports receive this interface rather
/// than a store or authority constructor, so all mutation admission shares one fence.
public protocol AuthorityMutationAdmitting: Sendable {
    func mutationGeneration() async -> UInt64
    func performMutation<Result: Sendable>(
        generation: UInt64,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result
    func snapshot() async -> AuthorityMutationGateSnapshot
}

/// Host-issued capability. A retained capability becomes unusable as soon as
/// draining advances the generation.
public struct AuthorityMutationCapability: Sendable {
    public let generation: UInt64
    private let admission: any AuthorityMutationAdmitting

    public init(generation: UInt64, admission: any AuthorityMutationAdmitting) {
        self.generation = generation
        self.admission = admission
    }

    public func perform<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try await admission.performMutation(generation: generation, operation: operation)
    }
}
