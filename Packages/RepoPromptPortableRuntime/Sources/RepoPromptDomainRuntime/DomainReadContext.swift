import Foundation

public enum DomainReadBindingKind: Hashable, Sendable {
    case explicit
    case appPresentation
    case runScoped(runID: UUID)
}

/// Immutable, generation-fenced authority passed to shared read providers.
///
/// The handle deliberately contains no window identity. App presentation may be used while
/// resolving a handle, but every backend call is bound to the resulting workspace/context.
public struct DomainReadContextHandle: Hashable, Sendable {
    public let runtimeID: UUID
    public let runtimeGeneration: UInt64
    public let connectionID: UUID
    public let connectionGeneration: UInt64
    public let context: DomainContextIdentity
    public let workspaceRevision: UInt64
    public let contextRevision: UInt64
    public let routingRevision: UInt64
    public let bindingKind: DomainReadBindingKind

    public init(
        runtimeID: UUID,
        runtimeGeneration: UInt64,
        connectionID: UUID,
        connectionGeneration: UInt64,
        context: DomainContextIdentity,
        workspaceRevision: UInt64,
        contextRevision: UInt64,
        routingRevision: UInt64,
        bindingKind: DomainReadBindingKind
    ) {
        self.runtimeID = runtimeID
        self.runtimeGeneration = runtimeGeneration
        self.connectionID = connectionID
        self.connectionGeneration = connectionGeneration
        self.context = context
        self.workspaceRevision = workspaceRevision
        self.contextRevision = contextRevision
        self.routingRevision = routingRevision
        self.bindingKind = bindingKind
    }
}

public enum DomainReadContextResolutionError: Error, Equatable, Sendable {
    case connectionUnavailable
    case staleConnectionGeneration
    case unboundConnection
    case presentationWindowUnavailable
    case presentationContextUnavailable
    case contextUnavailable
    case contextRemoved
    case runtimeGenerationMismatch
}
