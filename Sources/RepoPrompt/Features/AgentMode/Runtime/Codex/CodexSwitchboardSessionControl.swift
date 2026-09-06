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

    var blocksDispatch: Bool {
        isPreparing || isTransactionInFlight || core?.blocksDispatch != false
    }

    var statusText: String {
        if isPreparing { return "Preparing private account pairing…" }
        switch state {
        case .waitingIdle: return "Account selection saved; waiting for an idle session."
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
        defer { isTransactionInFlight = false
            isPreparing = false
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
        let expectedEpoch = epoch
        isTransactionInFlight = true
        defer { isTransactionInFlight = false }
        do {
            let lease = try await runtime.reserve()
            do {
                try checkIdentity(expectedEpoch)
                let grant = try await bridge.poll(lastSeenRevision: lastSeenRevision)
                try checkIdentity(expectedEpoch)
                if let grant {
                    lastSeenRevision = grant.revision
                    selectedGrant = grant
                    await core.submit(grant)
                } else {
                    await core.retryAtIdleBoundary()
                }
                try checkIdentity(expectedEpoch)
                if case let .waitingIdle(reason) = core.state, let selectedGrant {
                    try await bridge.status(
                        adoptionID: selectedGrant.adoptionID,
                        expectedRevision: selectedGrant.revision,
                        state: "waiting_idle",
                        reason: reason.rawValue
                    )
                    try checkIdentity(expectedEpoch)
                }
                await runtime.finish(lease, !core.blocksDispatch)
            } catch {
                core.suspend(.bridgeUnavailable)
                await runtime.finish(lease, false)
                throw error
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
        defer { isTransactionInFlight = false }
        let lease = try await runtime.reserve()
        do {
            try checkIdentity(expectedEpoch)
            let grant = try await core.refresh(previousAccountID: previousAccountID)
            try checkIdentity(expectedEpoch)
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
        guard epoch == expectedEpoch, let scope, runtime?.admission()?.scope == scope,
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
        pollingTask?.cancel()
    }

    func revoke() {
        guard cleanupTask == nil else { return }
        authorization.invalidate()
        epoch = UUID()
        pollingTask?.cancel()
        core?.revoke()
        selectedGrant = nil
        state = .revoked
        isPreparing = false
        let bridge = bridge
        self.bridge = nil
        let runtime = runtime
        cleanupTask = Task { [mutex] in
            await bridge?.revoke()
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
        pollingTask?.cancel()
        if let bridge { Task { await bridge.revoke() } }
    }
}
