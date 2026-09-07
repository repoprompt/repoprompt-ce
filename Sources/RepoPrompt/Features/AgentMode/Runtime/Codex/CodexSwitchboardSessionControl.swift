import Combine
import Foundation

protocol CodexSwitchboardBridge: Sendable {
    func register(threadID: String?) async throws
    func poll(lastSeenRevision: Int64) async throws -> CodexAccountAdoptionGrant?
    func refresh(previousGrant: CodexAccountAdoptionGrant) async throws -> CodexAccountAdoptionGrant
    func status(adoptionID: UUID, expectedRevision: Int64, state: String, reason: String) async throws
    func revoke() async
}

extension SwitchboardBridgeClient: CodexSwitchboardBridge {}

/// One explicit, in-memory consent. Neither this authority nor its credentials
/// are serialized into Agent Mode persistence or exposed to generic MCP tools.
@MainActor
final class CodexSwitchboardSessionControl: ObservableObject {
    struct Launch {
        let resumeThreadID: String?
        let resolveControl: @MainActor (ObjectIdentifier) -> CodexSwitchboardSessionControl?
    }

    @MainActor final class ControllerReference {
        weak var value: (any CodexSessionControlling)?
    }

    struct Runtime {
        let admission: @MainActor () -> CodexAccountAdoptionAdmission?
        let inspect: @MainActor () async throws -> CodexAccountAdoptionRuntimeProof
        let reserve: @MainActor () async throws -> UUID
        let finish: @MainActor (UUID, Bool) async -> Void
        let install: @MainActor (CodexAccountAdoptionGrant) async throws -> CodexAccountAdoptionLoginReceipt
    }

    @Published private(set) var state: CodexAccountAdoptionState = .waitingIdle(.runtimeUnavailable)
    @Published private(set) var isPreparing = true
    private(set) var isTransactionInFlight = false
    private(set) var scope: CodexAccountAdoptionScope?
    private var core: CodexAccountAdoption?
    private var bridge: (any CodexSwitchboardBridge)?
    private var runtime: Runtime?
    private var observation: AnyCancellable?
    private var pollingTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var epoch = UUID()
    private var lastSeenRevision: Int64 = 0
    private var selectedGrant: CodexAccountAdoptionGrant?
    private let mutex = AsyncMutex()
    let authorization = CodexAccountAdoptionAuthorization()
    /// Called after local admission state settles, not from Published's willSet.
    var availabilityDidChange: (() -> Void)?

    var hasLiveAuthority: Bool {
        guard !isPreparing, !blocksPermanently, core != nil, let scope,
              let admission = runtime?.admission(), admission.scope == scope,
              admission.isExplicitRootCodexSession, admission.isManagedHTTPBackend else { return false }
        return (try? authorization.withAuthorization { true }) == true
    }

    var blocksDispatch: Bool {
        isPreparing || isTransactionInFlight || core?.blocksDispatch != false
    }

    var keepsRuntimeAlive: Bool {
        isPreparing || isTransactionInFlight || !blocksPermanently
    }

    var accountSummary: String? {
        let applied = core?.appliedAccountLabel
        let pending = selectedGrant.flatMap { grant in
            core?.appliedRevision == grant.revision ? nil : (grant.email ?? grant.accountID)
        }
        switch state {
        case .appliedUnverified: return applied.map { "Applied: \($0)" }
        case .waitingIdle, .applying:
            return [applied.map { "Applied: \($0)" }, pending.map { "Pending: \($0)" }].compactMap(\.self).joined(separator: " · ")
        case .failedUnknown, .revoked: return nil
        }
    }

    var statusText: String {
        if isPreparing { return "Preparing private account pairing…" }
        switch state {
        case .waitingIdle:
            return selectedGrant == nil ? "Paired; choose an account in Switchboard." : "Account selection saved; waiting for an idle session."
        case .applying: return "Applying account to this conversation…"
        case .appliedUnverified: return "Account applied; next request unverified."
        case .failedUnknown: return "Account state unknown. Re-pair this conversation to continue."
        case .revoked: return "Pairing revoked. Re-pair this conversation to continue."
        }
    }

    func connect(scope: CodexAccountAdoptionScope, bridge: any CodexSwitchboardBridge, runtime: Runtime) async throws {
        guard core == nil, isPreparing else { throw CodexAccountAdoptionReason.identityChanged }
        self.scope = scope
        self.bridge = bridge
        self.runtime = runtime
        let expectedEpoch = epoch
        let core = CodexAccountAdoption(scope: scope, dependencies: .init(
            admission: runtime.admission,
            inspectRuntime: runtime.inspect,
            install: runtime.install,
            renew: { previous, _ in try await bridge.refresh(previousGrant: previous) },
            now: Date.init,
            beginApplication: { grant in
                try await bridge.status(adoptionID: grant.adoptionID, expectedRevision: grant.revision, state: "applying", reason: "none")
            },
            acknowledgeApplication: { grant in
                try await bridge.status(adoptionID: grant.adoptionID, expectedRevision: grant.revision, state: "applied_unverified", reason: "none")
            }
        ))
        self.core = core
        observation = core.$state.sink { [weak self] state in
            self?.state = state
            switch state {
            case .failedUnknown, .revoked: self?.authorization.invalidate()
            default: break
            }
        }
        isTransactionInFlight = true
        availabilityDidChange?()
        defer { isTransactionInFlight = false
            isPreparing = false
            availabilityDidChange?()
        }
        do {
            let lease = try await runtime.reserve()
            do {
                try checkIdentity(expectedEpoch)
                let proof = try await runtime.inspect()
                try checkIdentity(expectedEpoch)
                guard proof.threadID == scope.threadID, proof.loadedThreadIDs == [scope.threadID],
                      proof.managedHTTP, proof.pinnedRuntime, proof.isAuthoritativelyIdle,
                      !proof.hasInProgressTools else { throw CodexAccountAdoptionReason.transportUnverified }
                try await bridge.register(threadID: scope.threadID)
                try checkIdentity(expectedEpoch)
                await runtime.finish(lease, false)
                try checkIdentity(expectedEpoch)
            } catch {
                await runtime.finish(lease, false)
                throw error
            }
        } catch {
            core.suspend(.bridgeUnavailable)
            await bridge.revoke()
            throw CodexAccountAdoptionReason.bridgeUnavailable
        }
    }

    func startPolling() {
        guard pollingTask == nil, !blocksPermanently else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                guard self?.blocksPermanently == false else { return }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }

    func pollOnce() async {
        do {
            try await mutex.withLock { [weak self] in await self?.pollLocked() }
        } catch {}
    }

    private func pollLocked() async {
        guard !isPreparing, !blocksPermanently, let bridge, let runtime, let core else { return }
        defer { availabilityDidChange?() }
        let expectedEpoch = epoch
        do {
            try checkIdentity(expectedEpoch)
            // Read-only polling never reserves the native backend or blocks Stop,
            // steering, or accepted user work. Only a ready adoption may reserve.
            let grant = try await bridge.poll(lastSeenRevision: lastSeenRevision)
            try checkIdentity(expectedEpoch)
            if let grant {
                lastSeenRevision = grant.revision
                selectedGrant = grant
                core.queue(grant)
            }
            if core.isReadyForApplication() {
                isTransactionInFlight = true
                availabilityDidChange?()
                defer { isTransactionInFlight = false
                    availabilityDidChange?()
                }
                let lease = try await runtime.reserve()
                do {
                    try checkIdentity(expectedEpoch)
                    await core.retryAtIdleBoundary()
                    try checkIdentity(expectedEpoch)
                    await runtime.finish(lease, !core.blocksDispatch)
                } catch {
                    core.suspend(.bridgeUnavailable)
                    await runtime.finish(lease, false)
                    throw error
                }
            }
            if case let .waitingIdle(reason) = core.state, let selectedGrant {
                try await bridge.status(
                    adoptionID: selectedGrant.adoptionID,
                    expectedRevision: selectedGrant.revision,
                    state: "waiting_idle",
                    reason: reason.rawValue
                )
                try checkIdentity(expectedEpoch)
            }
        } catch {
            core.suspend(.bridgeUnavailable)
        }
    }

    func refresh(previousAccountID: String) async throws -> CodexAccountAdoptionGrant {
        try await mutex.withLock { [weak self] in
            guard let self else { throw CodexAccountAdoptionReason.revoked }
            return try await refreshLocked(previousAccountID: previousAccountID)
        }
    }

    private func refreshLocked(previousAccountID: String) async throws -> CodexAccountAdoptionGrant {
        guard !blocksPermanently, let runtime, let core else { throw CodexAccountAdoptionReason.revoked }
        let expectedEpoch = epoch
        isTransactionInFlight = true
        availabilityDidChange?()
        defer { isTransactionInFlight = false
            availabilityDidChange?()
        }
        let lease: UUID
        do { lease = try await runtime.reserve() } catch {
            core.suspend(.runtimeUnavailable)
            throw CodexAccountAdoptionReason.runtimeUnavailable
        }
        do {
            try checkIdentity(expectedEpoch)
            let grant = try await core.refresh(previousAccountID: previousAccountID)
            try checkIdentity(expectedEpoch)
            // Reconcile a waiting destination before releasing the native lease:
            // accepted work must still drain under the freshly renewed account.
            _ = core.isReadyForApplication()
            await runtime.finish(lease, !core.blocksDispatch)
            try checkIdentity(expectedEpoch)
            return grant
        } catch {
            core.suspend(.bridgeUnavailable)
            await runtime.finish(lease, false)
            throw CodexAccountAdoptionReason.bridgeUnavailable
        }
    }

    private func checkIdentity(_ expectedEpoch: UUID) throws {
        guard epoch == expectedEpoch, let scope, let admission = runtime?.admission(), admission.scope == scope,
              admission.isExplicitRootCodexSession, admission.isManagedHTTPBackend,
              state != .revoked else { throw CodexAccountAdoptionReason.identityChanged }
        try Task.checkCancellation()
    }

    private var blocksPermanently: Bool {
        switch state {
        case .revoked, .failedUnknown: true
        default: false
        }
    }

    func runtimeLost() {
        authorization.invalidate()
        epoch = UUID()
        core?.suspend(.runtimeUnavailable)
        state = .failedUnknown(.runtimeUnavailable)
        isPreparing = false
        selectedGrant = nil
        availabilityDidChange?()
        scheduleCleanup()
    }

    func revoke() {
        authorization.invalidate()
        epoch = UUID()
        core?.revoke()
        selectedGrant = nil
        state = .revoked
        isPreparing = false
        availabilityDidChange?()
        scheduleCleanup()
    }

    private func scheduleCleanup() {
        guard cleanupTask == nil else { return }
        let bridge = bridge
        self.bridge = nil
        let runtime = runtime
        let pollingTask = pollingTask
        cleanupTask = Task { [mutex] in
            // Preserve captured remote authority until revocation starts. A
            // canceled poll must not erase it before cleanup can use it.
            await bridge?.revoke()
            pollingTask?.cancel()
            try? await mutex.withLock {
                if let runtime, let lease = try? await runtime.reserve() { await runtime.finish(lease, false) }
            }
        }
    }

    func revokeAndWait() async {
        revoke()
        await cleanupTask?.value
    }

    deinit {
        authorization.invalidate()
        let pollingTask = pollingTask
        if let bridge {
            Task { await bridge.revoke()
                pollingTask?.cancel()
            }
        } else if cleanupTask == nil {
            pollingTask?.cancel()
        }
    }
}
