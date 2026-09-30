import Foundation

enum ExternalMCPBindingOutcome: String, Codable, Equatable {
    case completed
    case cancelled
    case unsupported
    case failed
    case indeterminate
}

struct ExternalMCPCleanupReceipt: Codable, Equatable {
    let outcome: ExternalMCPBindingOutcome
    let detail: String?

    init(outcome: ExternalMCPBindingOutcome, detail: String? = nil) {
        self.outcome = outcome
        self.detail = detail
    }
}

/// An explicit runtime binding lease. Provider adapters may supply teardown, but the lease is
/// always idempotent and reports indeterminate cleanup instead of claiming success.
final class ExternalMCPRuntimeBindingLease: @unchecked Sendable {
    let integrationID: ExternalMCPIntegrationID
    let runtimeIdentity: ExternalMCPProviderRuntimeIdentity
    let sessionClass: ExternalMCPSessionClass
    let bindingID: UUID
    let coordinatorRevision: UInt64
    let isAccepted: Bool
    let cancellationToken: ExternalMCPCancellationToken

    private enum RevocationState {
        case active
        case revoking(Task<ExternalMCPCleanupReceipt, Never>)
        case finished(ExternalMCPCleanupReceipt)
    }

    private let lock = NSLock()
    private let revokeOperation: (@Sendable () async -> ExternalMCPCleanupReceipt)?
    private var revocationState: RevocationState = .active
    private var didRevoke = false
    private var didCompleteTeardown = false

    init(
        integrationID: ExternalMCPIntegrationID,
        runtimeIdentity: ExternalMCPProviderRuntimeIdentity,
        sessionClass: ExternalMCPSessionClass,
        bindingID: UUID = UUID(),
        coordinatorRevision: UInt64,
        isAccepted: Bool,
        cancellationToken: ExternalMCPCancellationToken = ExternalMCPCancellationToken(),
        revokeOperation: (@Sendable () async -> ExternalMCPCleanupReceipt)? = nil
    ) {
        self.integrationID = integrationID
        self.runtimeIdentity = runtimeIdentity
        self.sessionClass = sessionClass
        self.bindingID = bindingID
        self.coordinatorRevision = coordinatorRevision
        self.isAccepted = isAccepted
        self.cancellationToken = cancellationToken
        self.revokeOperation = revokeOperation
    }

    private enum RevocationRequest {
        case immediate(ExternalMCPCleanupReceipt)
        case shared(Task<ExternalMCPCleanupReceipt, Never>)
    }

    func revoke() async -> ExternalMCPCleanupReceipt {
        switch beginOrJoinRevocation() {
        case let .immediate(receipt):
            receipt
        case let .shared(task):
            await settleRevocation(task.value)
        }
    }

    private func beginOrJoinRevocation() -> RevocationRequest {
        lock.lock()
        defer { lock.unlock() }
        switch revocationState {
        case .active:
            cancellationToken.cancel()
            didRevoke = true
            let fallback = ExternalMCPCleanupReceipt(
                outcome: isAccepted ? .indeterminate : .unsupported,
                detail: isAccepted ? "Provider-owned revocation was not configured." : nil
            )
            let operation = revokeOperation
            let task: Task<ExternalMCPCleanupReceipt, Never> = Task {
                await operation?() ?? fallback
            }
            revocationState = .revoking(task)
            return .shared(task)
        case let .revoking(task):
            return .shared(task)
        case let .finished(receipt):
            return .immediate(receipt)
        }
    }

    private func settleRevocation(_ next: ExternalMCPCleanupReceipt) -> ExternalMCPCleanupReceipt {
        lock.lock()
        defer { lock.unlock() }
        if case let .finished(receipt) = revocationState { return receipt }
        revocationState = .finished(next)
        if next.outcome == .completed { didCompleteTeardown = true }
        return next
    }

    func finish(with receipt: ExternalMCPCleanupReceipt) {
        lock.lock()
        defer { lock.unlock() }
        if case .finished = revocationState { return }
        revocationState = .finished(receipt)
        if receipt.outcome == .completed { didCompleteTeardown = true }
    }

    func finish(teardownCompleted: Bool, cleanupReceipt: ExternalMCPCleanupReceipt) {
        lock.lock()
        defer { lock.unlock() }
        if case .finished = revocationState { return }
        didCompleteTeardown = teardownCompleted
        revocationState = .finished(cleanupReceipt)
    }

    var isRevoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRevoke
    }

    var teardownCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCompleteTeardown
    }

    var cleanupReceipt: ExternalMCPCleanupReceipt? {
        lock.lock()
        defer { lock.unlock() }
        if case let .finished(receipt) = revocationState { return receipt }
        return nil
    }
}

struct ExternalMCPDiscoveryResult: Codable, Equatable {
    enum Status: String, Codable, Equatable {
        case found
        case notFound
        case unsupported
        case indeterminate
    }

    let status: Status
    let definition: ExternalMCPIntegrationDefinition?
}

struct ExternalMCPAuthenticationResult: Equatable {
    enum Status: String, Codable, Equatable {
        case authenticated
        case requiresHandoff
        case unsupported
        case cancelled
        case failed
    }

    let status: Status
    /// Immediate browser handoff only; never part of a runtime snapshot or settings document.
    let handoffURL: URL?
    let snapshot: ExternalMCPRuntimeSnapshot

    init(status: Status, handoffURL: URL? = nil, snapshot: ExternalMCPRuntimeSnapshot) {
        self.status = status
        self.handoffURL = handoffURL
        self.snapshot = snapshot
    }
}

struct ExternalMCPRuntimeBindingResult {
    let lease: ExternalMCPRuntimeBindingLease?
    let decision: ExternalMCPAccessDecision
}

struct ExternalMCPDisconnectResult: Codable, Equatable {
    let receipt: ExternalMCPCleanupReceipt
    let snapshot: ExternalMCPRuntimeSnapshot
}

/// Shared implementation for providers whose external-MCP capability is not proven. Provider
/// owner files expose a named adapter type by supplying only their runtime identity, so adding a
/// fail-closed provider cannot accidentally invent auth, config, or child-session behavior.
protocol ExternalMCPFailClosedProviderAdapter: ExternalMCPProviderAdapter {
    var runtimeProvider: ExternalMCPRuntimeProvider { get }
}

extension ExternalMCPFailClosedProviderAdapter {
    func capabilities(in _: ExternalMCPProviderRuntimeContext) async -> ExternalMCPCapabilityDescriptor {
        .unsupported
    }

    func discoverExisting(in _: ExternalMCPProviderRuntimeContext) async -> ExternalMCPDiscoveryResult {
        .init(status: .unsupported, definition: nil)
    }

    func authenticate(
        in _: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPAuthenticationResult {
        .init(
            status: .unsupported,
            snapshot: .init(
                integrationID: integration.integrationID,
                connection: .unavailable,
                authentication: .unsupported,
                diagnostics: ["External MCP support is unavailable for this provider."]
            )
        )
    }

    func refreshStatus(
        in _: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPRuntimeSnapshot {
        .init(
            integrationID: integration.integrationID,
            connection: .unavailable,
            authentication: .unsupported,
            diagnostics: ["External MCP support is unavailable for this provider."]
        )
    }

    func applyRuntimeAccess(
        in context: ExternalMCPProviderRuntimeContext,
        decision: ExternalMCPAccessDecision
    ) async -> ExternalMCPRuntimeBindingResult {
        guard decision.isAllowed else {
            return .init(lease: nil, decision: decision)
        }
        return .init(
            lease: nil,
            decision: .denied(
                integrationID: decision.integrationID,
                runtimeIdentity: context.identity,
                revision: context.coordinatorRevision,
                reason: .unsupported
            )
        )
    }

    func disconnect(
        in _: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPDisconnectResult {
        .init(
            receipt: .init(outcome: .unsupported, detail: "Provider-owned external MCP cleanup is unavailable."),
            snapshot: .disconnected(integrationID: integration.integrationID)
        )
    }
}

/// Generic adapter authentication and status methods remain source-compatible for existing
/// integrations. They are not Figma Settings authority: Figma Connected/runtime access requires
/// the registry's exact structured-proof and runtime-binding capability axes.
protocol ExternalMCPProviderAdapter: Sendable {
    /// The provider runtime this adapter can bind. Integration identity remains separate and
    /// may be routed through more than one runtime provider.
    var runtimeProvider: ExternalMCPRuntimeProvider { get }

    func capabilities(in context: ExternalMCPProviderRuntimeContext) async -> ExternalMCPCapabilityDescriptor
    func discoverExisting(in context: ExternalMCPProviderRuntimeContext) async -> ExternalMCPDiscoveryResult
    func authenticate(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPAuthenticationResult
    func refreshStatus(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPRuntimeSnapshot
    func applyRuntimeAccess(
        in context: ExternalMCPProviderRuntimeContext,
        decision: ExternalMCPAccessDecision
    ) async -> ExternalMCPRuntimeBindingResult
    func disconnect(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPDisconnectResult
}
