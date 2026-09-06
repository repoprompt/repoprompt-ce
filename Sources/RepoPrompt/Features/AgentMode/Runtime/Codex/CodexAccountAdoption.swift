import Combine
import Foundation

/// Linearizes consent revocation against the actual child-process write. The
/// protected body must remain synchronous and must never call external code.
final class CodexAccountAdoptionAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        valid = false
    }

    func withAuthorization<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { throw CodexAccountAdoptionReason.revoked }
        return try body()
    }
}

/// Account adoption is a separate authority from MCP routing and ordinary login.
/// This value contains no credentials and is pinned to one live native controller.
struct CodexAccountAdoptionScope: Equatable {
    let consentID: UUID
    let sessionID: UUID
    let controllerGeneration: UUID
    let threadID: String
}

struct CodexAccountAdoptionGrant: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let adoptionID: UUID
    let selectionID: UUID
    let revision: Int64
    let expiresAt: Date
    let accountID: String
    let email: String?
    let plan: String?
    let accessToken: String

    var description: String {
        "CodexAccountAdoptionGrant(redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

enum CodexAccountAdoptionReason: String, Error {
    case busy
    case pendingInteraction = "pending_interaction"
    case activeTools = "active_tools"
    case activeChildren = "active_children"
    case queuedDispatch = "queued_dispatch"
    case runtimeUnavailable = "runtime_unavailable"
    case unsupportedRuntime = "unsupported_runtime"
    case transportUnverified = "transport_unverified"
    case identityChanged = "identity_changed"
    case grantExpired = "grant_expired"
    case bridgeUnavailable = "bridge_unavailable"
    case mutationUnconfirmed = "mutation_unconfirmed"
    case revoked
}

enum CodexAccountAdoptionState: Equatable {
    case waitingIdle(CodexAccountAdoptionReason)
    case applying
    case appliedUnverified(revision: Int64)
    case failedUnknown(CodexAccountAdoptionReason)
    case revoked
}

struct CodexAccountAdoptionAdmission {
    let scope: CodexAccountAdoptionScope
    let isExplicitRootCodexSession: Bool
    let isManagedHTTPBackend: Bool
    let isIdle: Bool
    let hasPendingInteraction: Bool
    let hasActiveTools: Bool
    let hasActiveChildren: Bool
    let hasQueuedDispatch: Bool
    let hasRecoveryOrReconnect: Bool
}

/// `managedHTTP` must be established from effective backend configuration, never
/// synthesized from launch arguments. Unknown/non-idle runtime state is ineligible.
struct CodexAccountAdoptionRuntimeProof {
    let threadID: String
    let loadedThreadIDs: [String]
    let isAuthoritativelyIdle: Bool
    let hasInProgressTools: Bool
    let managedHTTP: Bool
    let pinnedRuntime: Bool
}

struct CodexAccountAdoptionLoginReceipt {
    let externalTokenLogin: Bool
    let isChatGPTAccount: Bool
    let email: String?
}

/// Reservations and identity checks remain on the main actor alongside session
/// dispatch. Dependencies carry secrets only to an authenticated bridge or the
/// exact owning runtime; external errors are never surfaced verbatim.
@MainActor
final class CodexAccountAdoption: ObservableObject {
    struct Dependencies {
        let admission: () -> CodexAccountAdoptionAdmission?
        let inspectRuntime: () async throws -> CodexAccountAdoptionRuntimeProof
        let install: (CodexAccountAdoptionGrant) async throws -> CodexAccountAdoptionLoginReceipt
        let renew: (CodexAccountAdoptionGrant, String) async throws -> CodexAccountAdoptionGrant
        let now: () -> Date
        let beginApplication: (CodexAccountAdoptionGrant) async throws -> Void
        let acknowledgeApplication: (CodexAccountAdoptionGrant) async throws -> Void
    }

    let scope: CodexAccountAdoptionScope
    private let dependencies: Dependencies
    @Published private(set) var state: CodexAccountAdoptionState = .waitingIdle(.runtimeUnavailable)
    private(set) var blocksDispatch = true
    private(set) var reservesController = false
    private var pending: CodexAccountAdoptionGrant?
    private var applied: CodexAccountAdoptionGrant?
    private var highestRevision: Int64 = 0
    private var isRevoked = false
    private var isTerminal = false
    private var refreshInFlight = false

    var appliedAccountLabel: String? {
        applied.map { $0.email ?? $0.accountID }
    }

    var appliedRevision: Int64? {
        applied?.revision
    }

    init(scope: CodexAccountAdoptionScope, dependencies: Dependencies) {
        self.scope = scope
        self.dependencies = dependencies
    }

    func submit(_ grant: CodexAccountAdoptionGrant) async {
        queue(grant)
        await retryAtIdleBoundary()
    }

    func queue(_ grant: CodexAccountAdoptionGrant) {
        guard !isRevoked, !isTerminal, grant.revision > highestRevision else { return }
        highestRevision = grant.revision
        pending = grant
        blocksDispatch = true
    }

    func isReadyForApplication() -> Bool {
        guard !isRevoked, !isTerminal, !reservesController, !refreshInFlight,
              let grant = pending else { return false }
        do {
            try validateGrant(grant)
            try validateAdmission()
            return true
        } catch let reason as CodexAccountAdoptionReason {
            handlePreMutationFailure(reason)
            return false
        } catch {
            fail(.runtimeUnavailable)
            return false
        }
    }

    func retryAtIdleBoundary() async {
        guard isReadyForApplication(), let grant = pending else { return }
        reservesController = true
        blocksDispatch = true
        state = .applying
        var mutationDispatched = false
        defer { reservesController = false }
        do {
            let before = try await dependencies.inspectRuntime()
            try validateAdmission()
            try validateGrant(grant)
            try validateRuntime(before)
            try Task.checkCancellation()
            // Newer manual selections may supersede a not-yet-dispatched grant.
            guard pending?.revision == grant.revision else {
                state = .waitingIdle(.busy)
                return
            }
            try await dependencies.beginApplication(grant)
            try validateAdmission()
            try validateGrant(grant)
            try Task.checkCancellation()
            guard pending?.revision == grant.revision else {
                state = .waitingIdle(.busy)
                return
            }
            pending = nil
            mutationDispatched = true
            let receipt = try await dependencies.install(grant)
            try validateAdmission()
            try validateGrant(grant)
            guard receipt.externalTokenLogin, receipt.isChatGPTAccount,
                  receipt.email == nil || receipt.email == grant.email
            else {
                throw CodexAccountAdoptionReason.identityChanged
            }
            let after = try await dependencies.inspectRuntime()
            try validateAdmission()
            try validateGrant(grant)
            try validateRuntime(after)
            try Task.checkCancellation()
            try await dependencies.acknowledgeApplication(grant)
            try validateAdmission()
            try validateGrant(grant)
            try Task.checkCancellation()
            applied = grant
            blocksDispatch = pending != nil
            state = pending == nil ? .appliedUnverified(revision: grant.revision) : .waitingIdle(.busy)
        } catch {
            guard !isRevoked else { return }
            if mutationDispatched {
                fail(.mutationUnconfirmed)
            } else if let reason = error as? CodexAccountAdoptionReason {
                handlePreMutationFailure(reason)
            } else {
                fail(.runtimeUnavailable)
            }
        }
    }

    func revoke() {
        isRevoked = true
        pending = nil
        applied = nil
        blocksDispatch = true
        state = .revoked
    }

    func suspend(_ reason: CodexAccountAdoptionReason) {
        guard !isRevoked else { return }
        fail(reason)
    }

    func refresh(previousAccountID: String) async throws -> CodexAccountAdoptionGrant {
        guard !isRevoked, !isTerminal, !reservesController, !refreshInFlight,
              let previous = applied
        else {
            throw CodexAccountAdoptionReason.runtimeUnavailable
        }
        guard previousAccountID == previous.accountID else {
            fail(.identityChanged)
            throw CodexAccountAdoptionReason.identityChanged
        }
        refreshInFlight = true
        reservesController = true
        blocksDispatch = true
        defer {
            refreshInFlight = false
            reservesController = false
        }
        do {
            try validateIdentity()
            let renewed = try await dependencies.renew(previous, previousAccountID)
            try validateIdentity()
            try Task.checkCancellation()
            try validateGrant(renewed)
            guard renewed.accountID == previous.accountID,
                  renewed.adoptionID == previous.adoptionID,
                  renewed.selectionID == previous.selectionID,
                  renewed.revision == previous.revision,
                  renewed.email == previous.email,
                  renewed.accessToken != previous.accessToken,
                  applied?.revision == previous.revision
            else {
                throw CodexAccountAdoptionReason.identityChanged
            }
            applied = renewed
            blocksDispatch = pending != nil
            if pending != nil { state = .waitingIdle(.busy) }
            return renewed
        } catch {
            if !isRevoked { fail(.identityChanged) }
            throw CodexAccountAdoptionReason.identityChanged
        }
    }

    private func validateIdentity() throws {
        guard !isRevoked, !isTerminal else { throw CodexAccountAdoptionReason.revoked }
        guard let admission = dependencies.admission(), admission.scope == scope,
              !scope.threadID.isEmpty else { throw CodexAccountAdoptionReason.identityChanged }
        guard admission.isExplicitRootCodexSession else { throw CodexAccountAdoptionReason.identityChanged }
        guard admission.isManagedHTTPBackend else { throw CodexAccountAdoptionReason.transportUnverified }
    }

    private func validateAdmission() throws {
        try validateIdentity()
        guard let admission = dependencies.admission() else { throw CodexAccountAdoptionReason.identityChanged }
        if admission.hasRecoveryOrReconnect { throw CodexAccountAdoptionReason.runtimeUnavailable }
        if admission.hasPendingInteraction { throw CodexAccountAdoptionReason.pendingInteraction }
        if admission.hasActiveTools { throw CodexAccountAdoptionReason.activeTools }
        if admission.hasActiveChildren { throw CodexAccountAdoptionReason.activeChildren }
        if admission.hasQueuedDispatch { throw CodexAccountAdoptionReason.queuedDispatch }
        if !admission.isIdle { throw CodexAccountAdoptionReason.busy }
    }

    private func validateGrant(_ grant: CodexAccountAdoptionGrant) throws {
        guard grant.expiresAt > dependencies.now() else { throw CodexAccountAdoptionReason.grantExpired }
        guard grant.revision > 0, grant.revision <= 9_007_199_254_740_991,
              !grant.accountID.isEmpty, grant.accountID.utf8.count <= 512,
              !grant.accessToken.isEmpty, grant.accessToken.utf8.count <= 32768,
              !grant.accountID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !grant.accessToken.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
        else { throw CodexAccountAdoptionReason.identityChanged }
    }

    private func validateRuntime(_ proof: CodexAccountAdoptionRuntimeProof) throws {
        guard proof.pinnedRuntime else { throw CodexAccountAdoptionReason.unsupportedRuntime }
        guard proof.managedHTTP else { throw CodexAccountAdoptionReason.transportUnverified }
        guard proof.threadID == scope.threadID, proof.loadedThreadIDs == [scope.threadID]
        else { throw CodexAccountAdoptionReason.identityChanged }
        guard proof.isAuthoritativelyIdle else { throw CodexAccountAdoptionReason.busy }
        guard !proof.hasInProgressTools else { throw CodexAccountAdoptionReason.activeTools }
    }

    private func handlePreMutationFailure(_ reason: CodexAccountAdoptionReason) {
        switch reason {
        case .busy, .pendingInteraction, .activeTools, .activeChildren, .queuedDispatch:
            state = .waitingIdle(reason)
            // Drain already accepted work under the last applied account. The
            // actual idle adoption reservation remains exclusive and blocks sends.
            blocksDispatch = applied == nil
        default:
            fail(reason)
        }
    }

    private func fail(_ reason: CodexAccountAdoptionReason) {
        isTerminal = true
        pending = nil
        applied = nil
        blocksDispatch = true
        state = .failedUnknown(reason)
    }
}
