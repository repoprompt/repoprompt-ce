import Foundation

package enum DomainReadBindingKind: Hashable, Sendable {
    case explicit
    case appPresentation
    case runScoped(runID: UUID)
}

/// Immutable, generation-fenced authority passed to shared read providers.
///
/// The handle deliberately contains no window identity. App presentation may be used while
/// resolving a handle, but every backend call is bound to the resulting workspace/context.
package struct DomainReadContextHandle: Hashable, Sendable {
    package let runtimeID: UUID
    package let runtimeGeneration: UInt64
    package let connectionID: UUID
    package let connectionGeneration: UInt64
    package let context: DomainContextIdentity
    package let workspaceRevision: UInt64
    package let contextRevision: UInt64
    package let routingRevision: UInt64
    package let bindingKind: DomainReadBindingKind

    package init(
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

package enum DomainReadContextResolutionError: Error, Equatable, Sendable {
    case connectionUnavailable
    case staleConnectionGeneration
    case unboundConnection
    case presentationWindowUnavailable
    case presentationContextUnavailable
    case contextUnavailable
    case contextRemoved
    case runtimeGenerationMismatch
}
