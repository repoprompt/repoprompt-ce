import Combine
import Foundation

/// Narrow UI contract for the Codex-managed Figma connection. OAuth and credentials remain
/// owned by Codex; this contract exposes only sanitized connection state and effects.
struct FigmaMCPIntegrationRefreshReceipt: Equatable {
    let snapshot: FigmaMCPIntegrationSnapshot
    let generation: UInt64
    let isAuthoritative: Bool
}

protocol FigmaMCPIntegrationStatusRefreshing: Sendable {
    func refresh(definition: ExternalMCPIntegrationDefinition?) async -> FigmaMCPIntegrationSnapshot
    func refreshWithReceipt(definition: ExternalMCPIntegrationDefinition?) async -> FigmaMCPIntegrationRefreshReceipt
    func cancelStatusRefresh() async
}

protocol FigmaMCPIntegrationManaging: FigmaMCPIntegrationStatusRefreshing {
    func snapshot() async -> FigmaMCPIntegrationSnapshot
    func discoverExistingImport() async -> FigmaMCPImportDiscovery
    func connect(definition: ExternalMCPIntegrationDefinition) async -> (FigmaMCPConnectResult, FigmaMCPAuthorizationRequest?)
    func disconnect(definition: ExternalMCPIntegrationDefinition) async -> FigmaMCPDisconnectResult
    func invalidatePresentationSnapshot() async
    func settleAuthorizationHandoff(id: UUID, disposition: FigmaMCPAuthorizationHandoffDisposition) async
    func cancelCurrentOperation() async
    func connectWithEffects(definition: ExternalMCPIntegrationDefinition) async -> FigmaMCPConnectServiceResult
    func disconnectWithEffects(definition: ExternalMCPIntegrationDefinition) async -> FigmaMCPDisconnectServiceResult
    func removeManagedConfiguration(definition: ExternalMCPIntegrationDefinition) async -> FigmaMCPDisconnectServiceResult
}

extension FigmaMCPIntegrationStatusRefreshing {
    func refreshWithReceipt(
        definition: ExternalMCPIntegrationDefinition?
    ) async -> FigmaMCPIntegrationRefreshReceipt {
        await .init(snapshot: refresh(definition: definition), generation: 0, isAuthoritative: true)
    }
}

extension FigmaMCPIntegrationManaging {
    func connectWithEffects(
        definition: ExternalMCPIntegrationDefinition
    ) async -> FigmaMCPConnectServiceResult {
        let (result, authorizationRequest) = await connect(definition: definition)
        return .init(result: result, authorizationRequest: authorizationRequest, effects: .none)
    }

    func disconnectWithEffects(
        definition: ExternalMCPIntegrationDefinition
    ) async -> FigmaMCPDisconnectServiceResult {
        await .init(result: disconnect(definition: definition), effects: .none)
    }

    func removeManagedConfiguration(
        definition _: ExternalMCPIntegrationDefinition
    ) async -> FigmaMCPDisconnectServiceResult {
        .init(result: .disconnected, effects: .none)
    }
}

extension CodexExternalMCPIntegrationService: FigmaMCPIntegrationManaging {}

enum FigmaMCPIntegrationOperationKind: Equatable {
    case launchRefresh
    case wakeRefresh
    case settingsRefresh
    case test
    case discoverForConnect
    case connect
    case adopt
    case reauthenticate
    case verifyAuthentication
    case signOut
}

struct FigmaMCPIntegrationCoordinatorState: Equatable {
    let definition: ExternalMCPIntegrationDefinition?
    let connection: FigmaMCPIntegrationSnapshot
    let operation: FigmaMCPIntegrationOperationKind?
    let revision: UInt64
    let isCancelling: Bool
    let passiveRefreshPending: Bool

    static let initial = Self(
        definition: nil,
        connection: .notConfigured,
        operation: nil,
        revision: 0,
        isCancelling: false,
        passiveRefreshPending: false
    )
}

typealias MCPIntegrationsSettingsOperationToken = FigmaMCPIntegrationOperationLease

@MainActor
private final class FigmaMCPAuthorizationRefreshRace {
    enum Outcome {
        case refreshed(FigmaMCPIntegrationRefreshReceipt)
        case timedOut
        case cancelled
    }

    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

struct FigmaMCPIntegrationOperationLease: Equatable {
    let id: UUID
    let generation: UInt64
    let ownerID: UUID
    let windowID: Int
    let kind: FigmaMCPIntegrationOperationKind
}

/// App-lifetime coordinator for the single Codex-owned Figma registration.
///
/// All passive lifecycle refreshes and Settings operations use this authority. The actor service
/// performs file/app-server work off the main actor; this main-actor object owns only serialized
/// intent, definition fences, sanitized publication, and revocation.
@MainActor
final class FigmaMCPIntegrationCoordinator: ObservableObject {
    typealias FinalizationCleanup = @MainActor () async -> Void

    let settingsStore: GlobalSettingsStore
    let service: any FigmaMCPIntegrationManaging
    let runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority
    var runtimeAvailabilityAuthority: FigmaMCPRuntimeAvailabilityAuthority {
        runtimeAvailability
    }

    @Published private(set) var state = FigmaMCPIntegrationCoordinatorState.initial
    /// App-lifetime fail-closed fence. It is deliberately transient and never persisted.
    @Published private(set) var credentialRevocationRequired = false
    @Published private(set) var credentialRevocationNotice: String?

    private struct ActiveOperation {
        let lease: FigmaMCPIntegrationOperationLease
        var acceptedDefinitions: [ExternalMCPIntegrationDefinition?]
        var cancellationRequested = false
        var actionRunning = false
        var freshConnectDefinition: ExternalMCPIntegrationDefinition?
        var terminalDisposition: FigmaMCPSettingsTerminalDisposition = .none
    }

    private var generation: UInt64 = 0
    private var activeOperation: ActiveOperation?
    private var cancellationSettlementTask: Task<Void, Never>?
    private var cancellationInFlight = false
    private var passiveRefreshTask: Task<Void, Never>?
    private var passiveSettlementTask: Task<Void, Never>?
    private var passiveSettlementID: UInt64 = 0
    private var passiveRefreshPending = false
    private var terminationStarted = false
    private var cancellables = Set<AnyCancellable>()
    private var externalMCPRevisionInvalidator: (() -> Void)?
    private var authorizationWaitID: UUID?
    private var cancelAuthorizationWait: (() -> Void)?
    private let authorizationCompletionTimeout: Duration

    init(
        settingsStore: GlobalSettingsStore? = nil,
        service: any FigmaMCPIntegrationManaging = CodexExternalMCPIntegrationService(),
        runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority,
        authorizationCompletionTimeout: Duration = .seconds(300)
    ) {
        let settingsStore = settingsStore ?? .shared
        self.settingsStore = settingsStore
        self.service = service
        self.runtimeAvailability = runtimeAvailability
        self.authorizationCompletionTimeout = authorizationCompletionTimeout
        clearStaleCleanupTombstone()
        state = .init(
            definition: currentDefinition,
            connection: .notConfigured,
            operation: nil,
            revision: 0,
            isCancelling: false,
            passiveRefreshPending: false
        )
        settingsStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.storeDidChange() }
            }
            .store(in: &cancellables)
    }

    /// Installs the shared neutral revision fence without changing Codex ownership. The existing
    /// settings-store observation below is the central definition lifecycle hook.
    func installExternalMCPRevisionInvalidator(_ invalidator: @escaping () -> Void) {
        externalMCPRevisionInvalidator = invalidator
    }

    private func invalidateExternalMCPRevision() {
        externalMCPRevisionInvalidator?()
    }

    var currentDefinition: ExternalMCPIntegrationDefinition? {
        guard let definition = settingsStore.externalMCPIntegration(for: .figma),
              definition.repoPromptActivation == .enabled
        else { return nil }
        return definition
    }

    /// Disabled Figma entries from older versions are never meaningful configuration. Remove them
    /// opportunistically without surfacing a retry UI.
    private func clearStaleCleanupTombstone() {
        guard settingsStore.externalMCPIntegration(for: .figma)?.repoPromptActivation == .disabled else { return }
        _ = settingsStore.removeExternalMCPIntegration(for: .figma)
    }

    var hasInteractiveOperation: Bool {
        activeOperation != nil
    }

    var hasInteractiveSettingsOperation: Bool {
        hasInteractiveOperation
    }

    func beginInteractive(
        ownerID: UUID,
        windowID: Int,
        kind: FigmaMCPIntegrationOperationKind,
        expectedDefinition: ExternalMCPIntegrationDefinition?
    ) -> FigmaMCPIntegrationOperationLease? {
        guard !terminationStarted, activeOperation == nil, cancellationSettlementTask == nil else { return nil }
        guard !credentialRevocationRequired || kind == .signOut else { return nil }
        if passiveRefreshTask != nil {
            passiveRefreshPending = false
            beginPassiveCancellation()
        }
        let ticket = runtimeAvailability.beginAuthoritativeRefresh(
            expectedDefinition: expectedDefinition,
            operation: kind
        )
        generation = ticket.generation
        let lease = FigmaMCPIntegrationOperationLease(
            id: UUID(),
            generation: generation,
            ownerID: ownerID,
            windowID: windowID,
            kind: kind
        )
        activeOperation = ActiveOperation(lease: lease, acceptedDefinitions: [expectedDefinition])
        state = .init(
            definition: currentDefinition,
            connection: .init(
                state: .connecting,
                authentication: state.connection.authentication,
                tools: [],
                lastSuccessfulCheck: nil,
                failureMessage: nil
            ),
            operation: kind,
            revision: ticket.generation,
            isCancelling: false,
            passiveRefreshPending: passiveRefreshPending
        )
        return lease
    }

    func waitForPassiveSettlement(_ lease: FigmaMCPIntegrationOperationLease) async {
        guard isOwned(lease), let passiveSettlementTask else { return }
        await passiveSettlementTask.value
        if isOwned(lease) { self.passiveSettlementTask = nil }
    }

    func allowDefinition(_ definition: ExternalMCPIntegrationDefinition?, for lease: FigmaMCPIntegrationOperationLease) {
        guard isOwned(lease),
              !(activeOperation?.acceptedDefinitions.contains(where: { $0 == definition }) ?? true)
        else { return }
        activeOperation?.acceptedDefinitions.append(definition)
    }

    func isCurrent(_ lease: FigmaMCPIntegrationOperationLease) -> Bool {
        guard let activeOperation,
              activeOperation.lease == lease,
              !activeOperation.cancellationRequested,
              activeOperation.lease.generation == generation,
              !terminationStarted
        else { return false }
        return activeOperation.acceptedDefinitions.contains(where: {
            $0 == settingsStore.externalMCPIntegration(for: .figma)
        })
    }

    func isOwned(_ lease: FigmaMCPIntegrationOperationLease) -> Bool {
        activeOperation?.lease == lease
    }

    @discardableResult
    func requestCancellation(
        _ lease: FigmaMCPIntegrationOperationLease,
        cleanup: FinalizationCleanup? = nil
    ) -> Bool {
        guard isOwned(lease), let operation = activeOperation else { return false }
        guard !operation.cancellationRequested else { return true }
        activeOperation?.cancellationRequested = true
        cancelAuthorizationWait?()
        cancellationInFlight = true
        generation &+= 1
        runtimeAvailability.clearForRevision(lease.generation)
        state = .init(
            definition: currentDefinition,
            connection: .notConfigured,
            operation: nil,
            revision: runtimeAvailability.revision,
            isCancelling: true,
            passiveRefreshPending: false
        )
        guard cancellationSettlementTask == nil else { return true }
        let freshConnectDefinition = operation.freshConnectDefinition
        cancellationSettlementTask = Task { @MainActor [weak self, service] in
            await service.cancelCurrentOperation()
            if let self, let freshConnectDefinition {
                await compensateFreshConnect(definition: freshConnectDefinition, invalidatePresentationSnapshot: false)
            }
            if let cleanup { await cleanup() }
            await service.invalidatePresentationSnapshot()
            guard let self,
                  activeOperation?.lease == lease,
                  activeOperation?.cancellationRequested == true
            else { return }
            runtimeAvailability.clearForRevision(lease.generation)
            activeOperation = nil
            completeCancellationSettlement()
        }
        return true
    }

    private func completeCancellationSettlement() {
        cancellationInFlight = false
        cancellationSettlementTask = nil
        let callbacks = availabilityWaiters
        availabilityWaiters.removeAll()
        callbacks.values.forEach { $0() }
        if passiveRefreshPending, activeOperation == nil {
            passiveRefreshPending = false
            requestPassiveRefresh(trigger: .wakeRefresh)
        }
    }

    private func waitForCancellationSettlement() async {
        while cancellationInFlight || cancellationSettlementTask != nil {
            await Task.yield()
        }
    }

    struct FinishOutcome {
        let leaseWasCurrent: Bool
        let runtimePublicationSucceeded: Bool
        let publishedSnapshot: FigmaMCPIntegrationSnapshot
        let finalRevision: UInt64
    }

    @discardableResult
    func finish(
        _ lease: FigmaMCPIntegrationOperationLease,
        connection: FigmaMCPIntegrationSnapshot? = nil,
        publishDefinition: ExternalMCPIntegrationDefinition? = nil
    ) -> FinishOutcome? {
        guard isOwned(lease) else { return nil }
        let leaseWasCurrent = isCurrent(lease)
        let finalConnection = connection ?? state.connection
        let runtimePublicationAccepted: Bool
        if let publishDefinition, !credentialRevocationRequired {
            runtimePublicationAccepted = runtimeAvailability.publish(
                ticketGeneration: lease.generation,
                snapshot: finalConnection,
                definition: publishDefinition
            )
        } else {
            runtimeAvailability.clearForRevision(lease.generation)
            runtimePublicationAccepted = false
        }
        let publishedConnection = runtimePublicationAccepted || finalConnection.state != .connected
            ? finalConnection
            : .init(
                state: .failed,
                authentication: finalConnection.authentication,
                tools: [],
                lastSuccessfulCheck: nil,
                failureMessage: "Figma runtime verification is no longer current."
            )
        activeOperation = nil
        state = .init(
            definition: currentDefinition,
            connection: publishedConnection,
            operation: nil,
            revision: runtimeAvailability.revision,
            isCancelling: false,
            passiveRefreshPending: passiveRefreshPending
        )
        if passiveRefreshPending {
            passiveRefreshPending = false
            requestPassiveRefresh(trigger: .wakeRefresh)
        }
        let callbacks = availabilityWaiters
        availabilityWaiters.removeAll()
        callbacks.values.forEach { $0() }
        return .init(
            leaseWasCurrent: leaseWasCurrent,
            runtimePublicationSucceeded: publishDefinition == nil || runtimePublicationAccepted,
            publishedSnapshot: publishedConnection,
            finalRevision: runtimeAvailability.revision
        )
    }

    func finalizeDeactivation(
        _ lease: FigmaMCPIntegrationOperationLease,
        service _: any FigmaMCPIntegrationManaging,
        cleanup: FinalizationCleanup? = nil
    ) {
        finalizeDeactivation(lease, cleanup: cleanup)
    }

    func finalizeDeactivation(
        _ lease: FigmaMCPIntegrationOperationLease,
        cleanup: FinalizationCleanup? = nil
    ) {
        _ = requestCancellation(lease, cleanup: cleanup)
    }

    func revokeForExplicitDisconnect(revocationID: UUID = UUID()) {
        // Explicit sign-out revokes runtime bindings immediately, but does not cancel the
        // Settings operation that is performing the durable disconnect and compensation. Keep
        // its coordinator lease current until the effect-aware operation settles.
        if activeOperation == nil { generation &+= 1 }
        runtimeAvailability.revokeForExplicitDisconnect(revocationID: revocationID)
        state = .init(
            definition: currentDefinition,
            connection: .notConfigured,
            operation: state.operation,
            revision: runtimeAvailability.revision,
            isCancelling: state.operation != nil,
            passiveRefreshPending: passiveRefreshPending
        )
    }

    func publish(
        _ snapshot: FigmaMCPIntegrationSnapshot,
        definition: ExternalMCPIntegrationDefinition?,
        for lease: FigmaMCPIntegrationOperationLease? = nil
    ) {
        guard !terminationStarted, !credentialRevocationRequired else { return }
        if let lease, !isCurrent(lease) { return }
        guard definition?.repoPromptActivation == .enabled else {
            runtimeAvailability.clearForRevision(lease?.generation ?? generation)
            return
        }
        let accepted = runtimeAvailability.publish(
            ticketGeneration: lease?.generation ?? generation,
            snapshot: snapshot,
            definition: definition
        )
        let publishedSnapshot = accepted || snapshot.state != .connected
            ? snapshot
            : .init(
                state: .failed,
                authentication: snapshot.authentication,
                tools: [],
                lastSuccessfulCheck: nil,
                failureMessage: "Figma runtime verification is no longer current."
            )
        state = .init(
            definition: definition,
            connection: publishedSnapshot,
            operation: state.operation,
            revision: lease?.generation ?? generation,
            isCancelling: false,
            passiveRefreshPending: passiveRefreshPending
        )
    }

    func requestPassiveRefresh(trigger: FigmaMCPIntegrationOperationKind = .launchRefresh) {
        guard !terminationStarted else { return }
        clearStaleCleanupTombstone()
        guard !credentialRevocationRequired else {
            passiveRefreshPending = false
            updatePendingState()
            return
        }
        guard cancellationSettlementTask == nil, !cancellationInFlight else {
            passiveRefreshPending = true
            updatePendingState()
            return
        }
        guard activeOperation == nil else {
            passiveRefreshPending = true
            updatePendingState()
            return
        }
        if let settlement = passiveSettlementTask {
            passiveRefreshPending = true
            updatePendingState()
            scheduleRefreshAfterPassiveSettlement(settlement)
            return
        }
        guard passiveRefreshTask == nil else {
            passiveRefreshPending = true
            updatePendingState()
            return
        }
        guard let definition = currentDefinition,
              definition.repoPromptActivation == .enabled
        else {
            generation &+= 1
            runtimeAvailability.beginAuthoritativeRefresh(
                expectedDefinition: currentDefinition,
                operation: trigger
            )
            state = .init(
                definition: currentDefinition,
                connection: .notConfigured,
                operation: nil,
                revision: generation,
                isCancelling: false,
                passiveRefreshPending: false
            )
            return
        }

        let ticket = runtimeAvailability.beginAuthoritativeRefresh(
            expectedDefinition: definition,
            operation: trigger
        )
        generation = max(generation &+ 1, ticket.generation)
        let refreshGeneration = generation
        state = .init(
            definition: definition,
            connection: .init(
                state: .reconnecting,
                authentication: state.connection.authentication,
                tools: [],
                lastSuccessfulCheck: nil,
                failureMessage: nil
            ),
            operation: trigger,
            revision: ticket.generation,
            isCancelling: false,
            passiveRefreshPending: false
        )
        passiveRefreshTask = Task { @MainActor [weak self, service, settingsStore] in
            defer { self?.passiveRefreshTask = nil }
            let refresh = await service.refreshWithReceipt(definition: definition)
            guard refresh.isAuthoritative else { return }
            let snapshot = refresh.snapshot
            guard let self,
                  !Task.isCancelled,
                  !terminationStarted,
                  activeOperation == nil,
                  generation == refreshGeneration,
                  settingsStore.externalMCPIntegration(for: .figma) == definition
            else { return }
            let accepted = runtimeAvailability.publish(
                ticketGeneration: ticket.generation,
                snapshot: snapshot,
                definition: definition
            )
            let publishedSnapshot = accepted || snapshot.state != .connected
                ? snapshot
                : .init(
                    state: .failed,
                    authentication: snapshot.authentication,
                    tools: [],
                    lastSuccessfulCheck: nil,
                    failureMessage: "Figma runtime verification is no longer current."
                )
            state = .init(
                definition: definition,
                connection: publishedSnapshot,
                operation: nil,
                revision: ticket.generation,
                isCancelling: false,
                passiveRefreshPending: false
            )
            passiveRefreshTask = nil
        }
    }

    func applicationWillSleep() {
        passiveRefreshPending = false
        if passiveRefreshTask != nil { beginPassiveCancellation() }
        if activeOperation != nil {
            // Sleep revokes only the cached passive authority; an interactive OAuth/sign-out
            // operation remains owned by Settings and may publish its own current result.
            runtimeAvailability.clearAvailability()
        } else {
            generation &+= 1
            runtimeAvailability.beginAuthoritativeRefresh(
                expectedDefinition: currentDefinition,
                operation: .wakeRefresh
            )
            state = .init(
                definition: currentDefinition,
                connection: .notConfigured,
                operation: nil,
                revision: generation,
                isCancelling: false,
                passiveRefreshPending: false
            )
        }
    }

    func applicationDidWake() {
        requestPassiveRefresh(trigger: .wakeRefresh)
    }

    /// Awaitable passive refresh seam used by deterministic tests and non-UI callers.
    @discardableResult
    func refreshNow(trigger: FigmaMCPIntegrationOperationKind = .launchRefresh) async -> Bool {
        requestPassiveRefresh(trigger: trigger)
        while passiveRefreshTask != nil || passiveSettlementTask != nil || state.operation != nil {
            await Task.yield()
        }
        return currentDefinition?.repoPromptActivation == .enabled
    }

    func applicationWillTerminate() {
        guard !terminationStarted else { return }
        terminationStarted = true
        passiveRefreshTask?.cancel()
        passiveRefreshTask = nil
        passiveRefreshPending = false
        generation &+= 1
        runtimeAvailability.clearAvailability()
        cancelAuthorizationWait?()
        Task { [service] in
            await service.cancelStatusRefresh()
            if activeOperation != nil { await service.cancelCurrentOperation() }
        }
    }

    /// Compatibility façade used by the window-local Settings presentation adapter. The
    /// coordinator remains the sole owner of the actual operation and waits for any passive
    /// refresh it preempted before the adapter calls the service.
    func beginSettingsOperation(ownerID: UUID, windowID: Int) -> MCPIntegrationsSettingsOperationToken? {
        beginInteractive(
            ownerID: ownerID,
            windowID: windowID,
            kind: .settingsRefresh,
            expectedDefinition: currentDefinition
        )
    }

    func finishSettingsOperation(_ token: MCPIntegrationsSettingsOperationToken) {
        finish(token)
    }

    func notifyWhenSettingsOperationAvailable(
        id: UUID,
        callback: @escaping @MainActor () -> Void
    ) {
        guard activeOperation == nil, cancellationSettlementTask == nil, !cancellationInFlight else {
            availabilityWaiters[id] = callback
            return
        }
        callback()
    }

    func cancelAvailabilityNotification(id: UUID) {
        availabilityWaiters[id] = nil
    }

    private var availabilityWaiters: [UUID: @MainActor () -> Void] = [:]

    private func beginPassiveCancellation() {
        passiveRefreshTask?.cancel()
        passiveRefreshTask = nil
        passiveSettlementID &+= 1
        passiveSettlementTask = Task { [service] in
            await service.cancelStatusRefresh()
        }
    }

    private func scheduleRefreshAfterPassiveSettlement(_ settlement: Task<Void, Never>) {
        let settlementID = passiveSettlementID
        Task { @MainActor [weak self] in
            await settlement.value
            guard let self,
                  passiveSettlementID == settlementID,
                  passiveSettlementTask != nil
            else { return }
            passiveSettlementTask = nil
            guard passiveRefreshPending, activeOperation == nil else { return }
            passiveRefreshPending = false
            requestPassiveRefresh(trigger: .wakeRefresh)
        }
    }

    private func updatePendingState() {
        state = .init(
            definition: currentDefinition,
            connection: state.connection,
            operation: state.operation,
            revision: state.revision,
            isCancelling: state.isCancelling,
            passiveRefreshPending: passiveRefreshPending
        )
    }

    private func storeDidChange() {
        clearStaleCleanupTombstone()
        let latest = currentDefinition
        guard latest != state.definition else { return }
        invalidateExternalMCPRevision()
        if let lease = activeOperation?.lease,
           !(activeOperation?.acceptedDefinitions.contains(where: { $0 == latest }) ?? false)
        {
            _ = requestCancellation(lease)
            return
        }
        state = .init(
            definition: latest,
            connection: latest?.repoPromptActivation == .enabled ? state.connection : .notConfigured,
            operation: state.operation,
            revision: state.revision,
            isCancelling: state.isCancelling,
            passiveRefreshPending: passiveRefreshPending
        )
    }
}

enum FigmaMCPSettingsAction: Equatable {
    case refresh
    case test
    case connect
    case useExistingConnection
    case reauthenticate
    case verifyAuthentication
    case awaitAuthorizationCompletion
    case signOut
}

enum FigmaMCPSettingsVerifiedCompletion: Equatable {
    case loginCompleted
    case signOutCompleted
}

struct FigmaMCPSettingsActionReceipt: Equatable {
    let requestID: UUID
    let leaseID: UUID
    let generation: UInt64
    let ownerID: UUID
    let windowID: Int
    let action: FigmaMCPSettingsAction
    let completion: FigmaMCPSettingsVerifiedCompletion?
}

struct FigmaMCPSettingsActionResponse: Equatable {
    let requestID: UUID
    let result: FigmaMCPSettingsActionResult
    let receipt: FigmaMCPSettingsActionReceipt?
    let coordinatorRevision: UInt64

    init(
        requestID: UUID,
        result: FigmaMCPSettingsActionResult,
        receipt: FigmaMCPSettingsActionReceipt?,
        coordinatorRevision: UInt64 = 0
    ) {
        self.requestID = requestID
        self.result = result
        self.receipt = receipt
        self.coordinatorRevision = coordinatorRevision
    }
}

private enum FigmaMCPSettingsTerminalDisposition: Equatable {
    case none
    case signOutDurablyCompleted
}

struct FigmaMCPSettingsActionResult: Equatable {
    let snapshot: FigmaMCPIntegrationSnapshot
    let notice: String?
    let isError: Bool
    let foundCanonicalImport: Bool
    let authorizationRequest: FigmaMCPAuthorizationRequest?

    static let cancelled = Self(
        snapshot: .notConfigured,
        notice: "Figma operation was cancelled.",
        isError: false,
        foundCanonicalImport: false,
        authorizationRequest: nil
    )

    static let busy = Self(
        snapshot: .notConfigured,
        notice: "Another Figma operation is already in progress. Try again when it finishes.",
        isError: false,
        foundCanonicalImport: false,
        authorizationRequest: nil
    )
}

extension FigmaMCPIntegrationCoordinator {
    private static let missingAuthorizationRequestNotice = "Figma authorization could not be started because Codex did not provide a sign-in link. Choose Connect to try again."

    /// Executes a Settings action under the app-wide operation lease. The Settings view model is
    /// intentionally only a presentation adapter; service calls, durable definition changes,
    /// authority publication, and compensation stay here.
    func performSettingsAction(
        _ action: FigmaMCPSettingsAction,
        requestID: UUID,
        ownerID: UUID,
        windowID: Int
    ) async -> FigmaMCPSettingsActionResponse {
        await waitForCancellationSettlement()
        let expectedDefinition = currentDefinition
        let kind: FigmaMCPIntegrationOperationKind = switch action {
        case .refresh: .settingsRefresh
        case .test: .test
        case .connect: .discoverForConnect
        case .useExistingConnection: .adopt
        case .reauthenticate: .reauthenticate
        case .verifyAuthentication: .verifyAuthentication
        case .awaitAuthorizationCompletion: .verifyAuthentication
        case .signOut: .signOut
        }
        let expected = action == .connect ? nil : expectedDefinition
        guard let lease = beginInteractive(
            ownerID: ownerID,
            windowID: windowID,
            kind: kind,
            expectedDefinition: expected
        ) else {
            return .init(requestID: requestID, result: .busy, receipt: nil, coordinatorRevision: state.revision)
        }
        activeOperation?.actionRunning = true

        await waitForPassiveSettlement(lease)
        let actionResult = await performSettingsActionBody(action, lease: lease)
        guard isOwned(lease), !(activeOperation?.cancellationRequested ?? true) else {
            return .init(requestID: requestID, result: .cancelled, receipt: nil, coordinatorRevision: state.revision)
        }

        let finalDefinition = currentDefinition
        let terminalDisposition = activeOperation?.terminalDisposition ?? .none
        let leaseWasCurrent = isCurrent(lease)
        let loginEligible = [
            FigmaMCPSettingsAction.connect,
            .useExistingConnection,
            .reauthenticate,
            .verifyAuthentication,
            .awaitAuthorizationCompletion
        ].contains(action)
        let authenticatedResult = actionResult.snapshot.state == .connected
            && actionResult.snapshot.authentication == .authenticated
        let mayPublish = leaseWasCurrent
            && finalDefinition?.repoPromptActivation == .enabled
            && authenticatedResult
        let verifiedDefinition = finalDefinition
        let finishOutcome = finish(
            lease,
            connection: sanitizedConnectionSnapshot(actionResult.snapshot),
            publishDefinition: mayPublish ? finalDefinition : nil
        )
        guard let finishOutcome else {
            return .init(requestID: requestID, result: .cancelled, receipt: nil, coordinatorRevision: state.revision)
        }
        guard finishOutcome.leaseWasCurrent, actionResult != .cancelled else {
            return .init(
                requestID: requestID,
                result: actionResult,
                receipt: nil,
                coordinatorRevision: finishOutcome.finalRevision
            )
        }
        if authenticatedResult, !finishOutcome.runtimePublicationSucceeded {
            let failedResult = result(for: finishOutcome.publishedSnapshot, action: action)
            return .init(
                requestID: requestID,
                result: failedResult,
                receipt: nil,
                coordinatorRevision: finishOutcome.finalRevision
            )
        }

        var completion: FigmaMCPSettingsVerifiedCompletion?
        if loginEligible,
           authenticatedResult,
           let verifiedDefinition,
           verifiedDefinition.repoPromptActivation == .enabled,
           currentDefinition == verifiedDefinition,
           state.connection.state == .connected,
           state.connection.authentication == .authenticated,
           runtimeAvailability.hasAuthenticatedRuntime,
           runtimeAvailability.revision == lease.generation
        {
            completion = .loginCompleted
        } else if terminalDisposition == .signOutDurablyCompleted,
                  action == .signOut,
                  currentDefinition == nil,
                  state.definition == nil,
                  state.connection.state == .notConfigured,
                  !runtimeAvailability.hasAuthenticatedRuntime
        {
            completion = .signOutCompleted
        }

        let receipt = FigmaMCPSettingsActionReceipt(
            requestID: requestID,
            leaseID: lease.id,
            generation: lease.generation,
            ownerID: ownerID,
            windowID: windowID,
            action: action,
            completion: completion
        )
        return .init(
            requestID: requestID,
            result: actionResult,
            receipt: receipt,
            coordinatorRevision: finishOutcome.finalRevision
        )
    }

    func settleAuthorizationHandoff(
        _ request: FigmaMCPAuthorizationRequest,
        disposition: FigmaMCPAuthorizationHandoffDisposition
    ) async {
        await settleAuthorizationHandoff(id: request.id, disposition: disposition)
    }

    func settleAuthorizationHandoff(
        id: UUID,
        disposition: FigmaMCPAuthorizationHandoffDisposition
    ) async {
        await service.settleAuthorizationHandoff(id: id, disposition: disposition)
    }

    func cancelSettingsOperation(ownerID: UUID) {
        guard let lease = activeOperation?.lease, lease.ownerID == ownerID else { return }
        _ = requestCancellation(lease)
    }

    func deactivateSettingsOwner(ownerID: UUID) {
        guard let lease = activeOperation?.lease, lease.ownerID == ownerID else { return }
        finalizeDeactivation(lease, service: service)
    }

    private func performSettingsActionBody(
        _ action: FigmaMCPSettingsAction,
        lease: FigmaMCPIntegrationOperationLease
    ) async -> FigmaMCPSettingsActionResult {
        guard isCurrent(lease) else { return .cancelled }

        switch action {
        case .refresh, .test:
            guard let definition = currentDefinition,
                  definition.repoPromptActivation == .enabled
            else {
                return .init(snapshot: .notConfigured, notice: nil, isError: false, foundCanonicalImport: false, authorizationRequest: nil)
            }
            let refresh = await service.refreshWithReceipt(definition: definition)
            guard isCurrent(lease) else { return .cancelled }
            guard refresh.isAuthoritative else { return nonAuthoritativeRefreshResult() }
            return result(for: refresh.snapshot, action: action)

        case .connect:
            guard currentDefinition == nil else { return .cancelled }
            switch await service.discoverExistingImport() {
            case let .available(snapshot):
                guard isCurrent(lease) else { return .cancelled }
                return .init(
                    snapshot: sanitizedConnectionSnapshot(snapshot),
                    notice: "An existing Figma connection was found. Use it to connect RepoPrompt CE.",
                    isError: false,
                    foundCanonicalImport: true,
                    authorizationRequest: nil
                )
            case .unavailable:
                return .init(snapshot: .notConfigured, notice: "RepoPrompt CE could not safely inspect the existing Figma connection. Try again.", isError: true, foundCanonicalImport: false, authorizationRequest: nil)
            case .cancelled:
                return .cancelled
            case .absent:
                guard isCurrent(lease) else { return .cancelled }
                return await connectFresh(lease: lease)
            }

        case .useExistingConnection:
            guard currentDefinition == nil else { return .cancelled }
            let definition = ExternalMCPIntegrationDefinition.adoptedFigmaImport()
            guard settingsStore.setExternalMCPIntegration(definition) else {
                return .init(snapshot: .notConfigured, notice: "RepoPrompt CE could not save the existing Figma connection. It was left unchanged.", isError: true, foundCanonicalImport: true, authorizationRequest: nil)
            }
            allowDefinition(definition, for: lease)
            let refresh = await service.refreshWithReceipt(definition: definition)
            guard isCurrent(lease) else { return .cancelled }
            guard refresh.isAuthoritative else { return nonAuthoritativeRefreshResult() }
            return result(for: refresh.snapshot, action: .refresh, adopted: true)

        case .reauthenticate:
            guard let definition = currentDefinition,
                  definition.repoPromptActivation == .enabled
            else { return .cancelled }
            return await authenticate(definition: definition, lease: lease)

        case .verifyAuthentication:
            guard let definition = currentDefinition,
                  definition.repoPromptActivation == .enabled
            else { return .cancelled }
            let refresh = await service.refreshWithReceipt(definition: definition)
            guard isCurrent(lease) else { return .cancelled }
            guard refresh.isAuthoritative else { return nonAuthoritativeRefreshResult() }
            return result(for: refresh.snapshot, action: .verifyAuthentication)

        case .awaitAuthorizationCompletion:
            guard let definition = currentDefinition,
                  definition.repoPromptActivation == .enabled
            else { return .cancelled }
            return await awaitAuthorizationCompletion(definition: definition, lease: lease)

        case .signOut:
            guard let definition = currentDefinition else {
                // Sign out is idempotent. There is no durable registration or cleanup work to
                // retry, so settle as a normal logged-out state.
                return .init(snapshot: .notConfigured, notice: "Figma is already signed out of RepoPrompt CE.", isError: false, foundCanonicalImport: false, authorizationRequest: nil)
            }
            return await signOut(definition: definition, lease: lease)
        }
    }

    private func connectFresh(lease: FigmaMCPIntegrationOperationLease) async -> FigmaMCPSettingsActionResult {
        let definition = ExternalMCPIntegrationDefinition.figma()
        activeOperation?.freshConnectDefinition = definition
        let connected = await service.connectWithEffects(definition: definition)
        guard isCurrent(lease) else {
            if let authorizationRequest = connected.authorizationRequest {
                await service.settleAuthorizationHandoff(
                    id: authorizationRequest.id,
                    disposition: .abandoned
                )
            }
            if isOwned(lease), !(activeOperation?.cancellationRequested ?? false) {
                await compensateFreshConnect(definition: definition)
            }
            return .cancelled
        }
        switch connected.result {
        case .authorizationRequired:
            guard connected.authorizationRequest != nil else {
                await compensateFreshConnect(definition: definition)
                return .init(
                    snapshot: .notConfigured,
                    notice: Self.missingAuthorizationRequestNotice,
                    isError: true,
                    foundCanonicalImport: false,
                    authorizationRequest: nil
                )
            }
            guard settingsStore.setExternalMCPIntegration(definition) else {
                await compensateFreshConnect(definition: definition)
                return .init(snapshot: .notConfigured, notice: "RepoPrompt CE could not save the Figma connection. Existing Settings were left unchanged.", isError: true, foundCanonicalImport: false, authorizationRequest: nil)
            }
            allowDefinition(definition, for: lease)
            return authenticationResult(connected, notice: "Finish sign-in in your browser, then choose Check Connection.")
        case let .connected(snapshot) where snapshot.state == .connected && snapshot.authentication == .authenticated:
            guard settingsStore.setExternalMCPIntegration(definition) else {
                await compensateFreshConnect(definition: definition)
                return .init(snapshot: .notConfigured, notice: "RepoPrompt CE could not save the Figma connection. Existing Settings were left unchanged.", isError: true, foundCanonicalImport: false, authorizationRequest: nil)
            }
            allowDefinition(definition, for: lease)
            return .init(snapshot: sanitizedConnectionSnapshot(snapshot), notice: "Figma is connected.", isError: false, foundCanonicalImport: false, authorizationRequest: nil)
        case .connected:
            await compensateFreshConnect(definition: definition)
            return .init(snapshot: .notConfigured, notice: "Figma did not confirm an authenticated connection.", isError: true, foundCanonicalImport: false, authorizationRequest: nil)
        case .failed:
            await compensateFreshConnect(definition: definition)
            return .init(snapshot: .notConfigured, notice: "Figma connection could not be completed. Try again.", isError: true, foundCanonicalImport: false, authorizationRequest: nil)
        case .cancelled:
            await compensateFreshConnect(definition: definition)
            return .cancelled
        }
    }

    private func authenticate(
        definition: ExternalMCPIntegrationDefinition,
        lease: FigmaMCPIntegrationOperationLease
    ) async -> FigmaMCPSettingsActionResult {
        let connected = await service.connectWithEffects(definition: definition)
        guard isCurrent(lease) else {
            if let authorizationRequest = connected.authorizationRequest {
                await service.settleAuthorizationHandoff(
                    id: authorizationRequest.id,
                    disposition: .abandoned
                )
            }
            return .cancelled
        }
        if case .authorizationRequired = connected.result,
           connected.authorizationRequest == nil
        {
            return missingAuthorizationRequestResult()
        }
        return authenticationResult(connected, notice: "Finish sign-in in your browser, then choose Check Connection.")
    }

    private func missingAuthorizationRequestResult() -> FigmaMCPSettingsActionResult {
        .init(
            snapshot: .init(state: .authorizationRequired, authentication: .notLoggedIn, tools: [], lastSuccessfulCheck: nil, failureMessage: nil),
            notice: Self.missingAuthorizationRequestNotice,
            isError: true,
            foundCanonicalImport: false,
            authorizationRequest: nil
        )
    }

    private func authenticationResult(
        _ result: FigmaMCPConnectServiceResult,
        notice: String
    ) -> FigmaMCPSettingsActionResult {
        switch result.result {
        case .authorizationRequired:
            .init(
                snapshot: .init(state: .authorizationRequired, authentication: .notLoggedIn, tools: [], lastSuccessfulCheck: nil, failureMessage: nil),
                notice: notice,
                isError: false,
                foundCanonicalImport: false,
                authorizationRequest: result.authorizationRequest
            )
        case let .connected(snapshot) where snapshot.state == .connected && snapshot.authentication == .authenticated:
            .init(snapshot: sanitizedConnectionSnapshot(snapshot), notice: "Figma is connected.", isError: false, foundCanonicalImport: false, authorizationRequest: nil)
        case .connected:
            .init(
                snapshot: .init(state: .failed, authentication: .unknown, tools: [], lastSuccessfulCheck: nil, failureMessage: nil),
                notice: "Figma did not confirm an authenticated connection.",
                isError: true,
                foundCanonicalImport: false,
                authorizationRequest: nil
            )
        case .failed:
            .init(snapshot: .init(state: .failed, authentication: .unknown, tools: [], lastSuccessfulCheck: nil, failureMessage: nil), notice: "Figma authorization could not be completed. Try again.", isError: true, foundCanonicalImport: false, authorizationRequest: nil)
        case .cancelled:
            .cancelled
        }
    }

    private func awaitAuthorizationCompletion(
        definition: ExternalMCPIntegrationDefinition,
        lease: FigmaMCPIntegrationOperationLease
    ) async -> FigmaMCPSettingsActionResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: authorizationCompletionTimeout)
        var delaySeconds = 1

        while true {
            switch await waitForAuthorizationRefresh(definition: definition, deadline: deadline) {
            case .cancelled:
                return .cancelled
            case .timedOut:
                // The status request may complete late. Its race is already fenced, and the
                // service receives a best-effort cancellation without delaying the UI fallback.
                Task { [service] in await service.cancelCurrentOperation() }
                return pendingAuthorizationResult()
            case let .refreshed(refresh):
                guard isCurrent(lease) else { return .cancelled }
                guard refresh.isAuthoritative else { return nonAuthoritativeRefreshResult() }
                let snapshot = refresh.snapshot

                // The refresh-versus-deadline latch has already chosen this authoritative response.
                // If it confirms authentication, do not let a subsequent clock read overwrite it.
                if snapshot.state == .connected, snapshot.authentication == .authenticated {
                    return result(for: snapshot, action: .verifyAuthentication)
                }
                guard clock.now < deadline else {
                    return pendingAuthorizationResult()
                }

                switch (snapshot.state, snapshot.authentication) {
                case (.authorizationRequired, .notLoggedIn), (.expired, .expired):
                    break
                default:
                    return result(for: snapshot, action: .verifyAuthentication)
                }
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            } catch {
                return .cancelled
            }
            delaySeconds = min(delaySeconds * 2, 5)
        }
    }

    private func waitForAuthorizationRefresh(
        definition: ExternalMCPIntegrationDefinition,
        deadline: ContinuousClock.Instant
    ) async -> FigmaMCPAuthorizationRefreshRace.Outcome {
        let race = FigmaMCPAuthorizationRefreshRace()
        let waitID = UUID()
        authorizationWaitID = waitID
        cancelAuthorizationWait = { race.resolve(.cancelled) }
        let refreshTask = Task { @MainActor [service] in
            await race.resolve(.refreshed(service.refreshWithReceipt(definition: definition)))
        }
        let timeoutTask = Task { @MainActor in
            do {
                try await ContinuousClock().sleep(until: deadline)
                race.resolve(.timedOut)
            } catch {
                race.resolve(.cancelled)
            }
        }
        defer {
            refreshTask.cancel()
            timeoutTask.cancel()
            if authorizationWaitID == waitID {
                authorizationWaitID = nil
                cancelAuthorizationWait = nil
            }
        }
        return await race.wait()
    }

    private func nonAuthoritativeRefreshResult() -> FigmaMCPSettingsActionResult {
        .init(
            snapshot: .init(
                state: .failed,
                authentication: .unknown,
                tools: [],
                lastSuccessfulCheck: nil,
                failureMessage: "Figma status was superseded before it could be verified."
            ),
            notice: "Figma status changed while it was being checked. Retry the current action.",
            isError: true,
            foundCanonicalImport: false,
            authorizationRequest: nil
        )
    }

    private func pendingAuthorizationResult() -> FigmaMCPSettingsActionResult {
        .init(
            snapshot: .init(
                state: .authorizationRequired,
                authentication: .notLoggedIn,
                tools: [],
                lastSuccessfulCheck: nil,
                failureMessage: nil
            ),
            notice: "Figma sign-in is still pending. Complete it in your browser, then choose Check Connection.",
            isError: false,
            foundCanonicalImport: false,
            authorizationRequest: nil
        )
    }

    private func signOut(
        definition: ExternalMCPIntegrationDefinition,
        lease: FigmaMCPIntegrationOperationLease
    ) async -> FigmaMCPSettingsActionResult {
        // Runtime/session access is revoked before any potentially blocking credential work.
        revokeForExplicitDisconnect(revocationID: lease.id)
        await runtimeAvailability.awaitExplicitRevocationSettlement()
        await service.invalidatePresentationSnapshot()
        guard isCurrent(lease),
              settingsStore.externalMCPIntegration(for: .figma) == definition
        else { return .cancelled }

        if definition.origin == .adoptedImport {
            credentialRevocationRequired = false
            credentialRevocationNotice = nil
            // Adopted imports are detach-only: no Codex credential or configuration mutation.
            allowDefinition(nil, for: lease)
            guard settingsStore.removeExternalMCPIntegration(for: .figma), isCurrent(lease) else {
                credentialRevocationNotice = "RepoPrompt CE could not remove the saved Figma registration. Figma remains unavailable until Settings can be saved."
                return .init(
                    snapshot: .notConfigured,
                    notice: credentialRevocationNotice,
                    isError: true,
                    foundCanonicalImport: false,
                    authorizationRequest: nil
                )
            }
            let disconnected = await service.disconnectWithEffects(definition: definition)
            guard isCurrent(lease), disconnected.result == .disconnected else {
                credentialRevocationNotice = "Figma was detached from RepoPrompt CE, but its imported connection could not be finalized."
                return .init(snapshot: .notConfigured, notice: credentialRevocationNotice, isError: true, foundCanonicalImport: false, authorizationRequest: nil)
            }
            credentialRevocationRequired = false
            credentialRevocationNotice = nil
            activeOperation?.terminalDisposition = .signOutDurablyCompleted
            return .init(snapshot: .notConfigured, notice: "Signed out of Figma in RepoPrompt CE. Codex sign-in and its configuration were left unchanged.", isError: false, foundCanonicalImport: false, authorizationRequest: nil)
        }

        credentialRevocationRequired = true
        credentialRevocationNotice = nil
        let disconnected = await service.disconnectWithEffects(definition: definition)
        guard isCurrent(lease) else { return .cancelled }

        let logout = disconnected.effects.credentialLogout
        let credentialAbsent = logout.settlement == .settled && logout.outcome == .credentialAbsent
        guard disconnected.result == .disconnected,
              credentialAbsent,
              disconnected.effects.configuration == .verifiedAbsent,
              disconnected.effects.appServer.reload == .settled
        else {
            if credentialAbsent {
                // Credential destruction is a settled success even if later cleanup failed. Keep
                // runtime access revoked, but allow a fresh OAuth recovery instead of trapping the
                // app behind a credential-specific fence.
                credentialRevocationRequired = false
                credentialRevocationNotice = "Figma credentials were removed, but RepoPrompt CE could not remove the saved registration. Sign in again after retrying cleanup."
            } else {
                credentialRevocationNotice = nil
            }
            return .init(
                snapshot: .notConfigured,
                notice: credentialRevocationNotice ?? "RepoPrompt CE stopped Figma access, but Codex did not confirm credential removal. Choose Sign Out to try again.",
                isError: true,
                foundCanonicalImport: false,
                authorizationRequest: nil
            )
        }

        // Settings removal is last. A failed save therefore leaves the definition visible while
        // Codex has already confirmed that the credential is absent.
        allowDefinition(nil, for: lease)
        guard settingsStore.removeExternalMCPIntegration(for: .figma), isCurrent(lease) else {
            credentialRevocationRequired = false
            credentialRevocationNotice = "Figma credentials were removed, but RepoPrompt CE could not remove the saved registration. Sign in again after retrying cleanup."
            return .init(
                snapshot: .notConfigured,
                notice: credentialRevocationNotice,
                isError: true,
                foundCanonicalImport: false,
                authorizationRequest: nil
            )
        }

        credentialRevocationRequired = false
        credentialRevocationNotice = nil
        activeOperation?.terminalDisposition = .signOutDurablyCompleted
        return .init(
            snapshot: .notConfigured,
            notice: "Signed out of Figma in RepoPrompt CE. Codex sign-in and its configuration were left unchanged.",
            isError: false,
            foundCanonicalImport: false,
            authorizationRequest: nil
        )
    }

    private func compensateFreshConnect(
        definition: ExternalMCPIntegrationDefinition,
        invalidatePresentationSnapshot: Bool = true
    ) async {
        // Do not tear down a definition installed by a newer window while compensating a stale
        // fresh-connect attempt. A nil or matching definition means this operation still owns
        // the managed registration it created.
        guard settingsStore.externalMCPIntegration(for: .figma).map({ $0 == definition }) ?? true else {
            return
        }
        _ = await service.removeManagedConfiguration(definition: definition)
        guard settingsStore.externalMCPIntegration(for: .figma).map({ $0 == definition }) ?? true else {
            return
        }
        // Compensation is best effort. Never persist a disabled cleanup marker: an uncertain
        // service state must leave Figma unavailable, not create a Settings retry state.
        _ = settingsStore.removeExternalMCPIntegration(for: .figma)
        if invalidatePresentationSnapshot {
            await service.invalidatePresentationSnapshot()
        }
    }

    private func result(
        for snapshot: FigmaMCPIntegrationSnapshot,
        action: FigmaMCPSettingsAction,
        adopted: Bool = false
    ) -> FigmaMCPSettingsActionResult {
        let snapshot = sanitizedConnectionSnapshot(snapshot)
        switch snapshot.state {
        case .connected where snapshot.authentication == .authenticated:
            return .init(snapshot: sanitizedConnectionSnapshot(snapshot), notice: "Figma is connected.", isError: false, foundCanonicalImport: false, authorizationRequest: nil)
        case .connected:
            return .init(snapshot: .init(state: .failed, authentication: snapshot.authentication, tools: [], lastSuccessfulCheck: nil, failureMessage: nil), notice: "Figma did not confirm an authenticated connection. Retry the current action.", isError: true, foundCanonicalImport: false, authorizationRequest: nil)
        case .authorizationRequired:
            return .init(snapshot: snapshot, notice: action == .test ? "Figma sign-in is required. Choose Connect." : "Figma sign-in is required.", isError: false, foundCanonicalImport: false, authorizationRequest: nil)
        case .expired:
            return .init(snapshot: snapshot, notice: "Figma authorization has expired. Choose Connect.", isError: false, foundCanonicalImport: false, authorizationRequest: nil)
        case .serverUnavailable:
            return .init(snapshot: snapshot, notice: "Figma is unavailable. Check your network, then retry.", isError: true, foundCanonicalImport: false, authorizationRequest: nil)
        case .failed:
            return .init(snapshot: snapshot, notice: "RepoPrompt CE could not verify the Figma connection. Retry the current action.", isError: true, foundCanonicalImport: false, authorizationRequest: nil)
        case .notConfigured, .connecting, .reconnecting:
            return .init(snapshot: snapshot, notice: nil, isError: false, foundCanonicalImport: false, authorizationRequest: nil)
        }
    }

    private func sanitizedConnectionSnapshot(_ snapshot: FigmaMCPIntegrationSnapshot) -> FigmaMCPIntegrationSnapshot {
        guard snapshot.state == .connected, snapshot.authentication == .authenticated else {
            return .init(state: snapshot.state, authentication: snapshot.authentication, tools: [], lastSuccessfulCheck: nil, failureMessage: nil)
        }
        return snapshot
    }
}
