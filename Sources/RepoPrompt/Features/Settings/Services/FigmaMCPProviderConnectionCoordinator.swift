import AppKit
import Combine
import Foundation

@MainActor
protocol ApplicationTerminationObserving: AnyObject {
    func observeApplicationTermination(_ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol
    func removeApplicationTerminationObserver(_ token: NSObjectProtocol)
}

@MainActor
final class NSApplicationTerminationObserver: ApplicationTerminationObserving {
    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func observeApplicationTermination(_ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in handler() }
        }
    }

    func removeApplicationTerminationObserver(_ token: NSObjectProtocol) {
        notificationCenter.removeObserver(token)
    }
}

enum FigmaMCPProviderLoginNotice: Equatable {
    case processCompletedWithoutProof
    case providerProcessFailed
    case authorizationSessionClosed
    case timedOutAuthenticationStateUnknown
    case cancelledAuthenticationStateUnknown
    case credentialLogoutUnverified
    case targetUnavailable
}

enum FigmaMCPProviderConnectionFailure: Equatable {
    case launchFailed
    case staleAttempt
    case verificationFailed
}

struct FigmaMCPProviderLoginAttempt: Equatable, Identifiable {
    let provider: ExternalMCPRuntimeProvider
    let target: ExternalMCPIntegrationTarget
    let providerTargetIdentifier: String
    let credentialContext: FigmaMCPProviderCredentialContext
    let attemptID: UUID
    let ownerID: String?
    let evidenceID: String
    let capabilityRevision: String
    let executableIdentity: String
    let executableVersion: String?
    let startedAt: Date
    let deadline: Date
    let operationGeneration: UInt64

    var id: UUID {
        attemptID
    }
}

enum FigmaMCPProviderConnectionState: Equatable {
    case notVerified(loginAvailability: FigmaMCPProviderLoginAvailability, notice: FigmaMCPProviderLoginNotice?)
    case unavailable(String)
    case authorizing(FigmaMCPProviderLoginAttempt)
    case verifyingAfterAuthorization(FigmaMCPProviderLoginAttempt)
    case checking
    case needsLogin
    case connected(FigmaMCPVerifiedProviderStatus)
    case failed(FigmaMCPProviderConnectionFailure)
    case unsupported
}

struct FigmaMCPProviderConnectionCoordinatorTiming {
    let sleep: @Sendable (UInt64) async -> Void
    let terminationDrainTimeoutNanoseconds: UInt64

    init(
        sleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        terminationDrainTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.sleep = sleep
        self.terminationDrainTimeoutNanoseconds = terminationDrainTimeoutNanoseconds
    }
}

enum FigmaMCPProviderStatusRecheckPurpose: Equatable {
    case refresh
    case testConnection
}

/// Owns provider-native login attempts once per application. Process exit is never authentication
/// proof; only applyVerifiedStatus may publish Connected after its complete proof fence succeeds.
@MainActor
final class FigmaMCPProviderConnectionCoordinator: ObservableObject {
    static let defaultLoginTimeout: TimeInterval = 5 * 60

    @Published private(set) var states: [ExternalMCPRuntimeProvider: FigmaMCPProviderConnectionState] = [:]

    private enum CancellationIntent {
        case none, user, timeout, termination
    }

    private enum NeutralRevisionSource {
        case provider(ExternalMCPRuntimeProvider)
        case all
    }

    private struct StructuredStatusResult {
        let outcome: FigmaMCPProviderStructuredStatusOutcome
        let coordinatorRevision: UInt64
    }

    private final class RegistrationReplacementFence: @unchecked Sendable {
        private let lock = NSLock()
        private var generations: [ExternalMCPRuntimeProvider: UInt64] = [:]

        func advance(for provider: ExternalMCPRuntimeProvider) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            let next = (generations[provider] ?? 0) &+ 1
            generations[provider] = next
            return next
        }

        func current(for provider: ExternalMCPRuntimeProvider) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return generations[provider] ?? 0
        }
    }

    private enum Completion {
        case exited(Int32), authorizationSessionClosed, launchFailed, timedOut, cancelled, busy
        case targetResolution(FigmaMCPProviderTargetResolution)
        case availability(FigmaMCPProviderLoginAvailability)
        case stale

        init(_ settlement: FigmaMCPProviderLoginSettlement) {
            switch settlement {
            case let .exited(status): self = .exited(status)
            case .authorizationSessionClosed: self = .authorizationSessionClosed
            case .launchFailed: self = .launchFailed
            case .timedOut: self = .timedOut
            case .cancelled: self = .cancelled
            case .busy: self = .busy
            }
        }
    }

    @MainActor
    private final class StartResultLatch {
        private var resolved = false
        private var result: UUID?
        private var waiters: [CheckedContinuation<UUID?, Never>] = []

        func wait() async -> UUID? {
            if resolved { return result }
            return await withCheckedContinuation { continuation in
                if resolved { continuation.resume(returning: result) }
                else { waiters.append(continuation) }
            }
        }

        func resolve(_ result: UUID?) {
            guard !resolved else { return }
            resolved = true
            self.result = result
            let waiters = waiters
            self.waiters.removeAll()
            waiters.forEach { $0.resume(returning: result) }
        }
    }

    @MainActor
    private final class TerminationDrainLatch {
        private var remaining: Int
        private var expired = false
        private var waiter: CheckedContinuation<Void, Never>?

        init(remaining: Int) {
            self.remaining = remaining
        }

        func wait() async {
            guard remaining > 0, !expired else { return }
            await withCheckedContinuation { continuation in
                if remaining == 0 || expired { continuation.resume() }
                else { waiter = continuation }
            }
        }

        func markFinished() {
            guard !expired, remaining > 0 else { return }
            remaining -= 1
            if remaining == 0 {
                waiter?.resume()
                waiter = nil
            }
        }

        func expire() {
            guard !expired else { return }
            expired = true
            waiter?.resume()
            waiter = nil
        }
    }

    @MainActor
    private final class ActiveAttempt {
        let provider: ExternalMCPRuntimeProvider
        let target: ExternalMCPIntegrationTarget
        let attemptID: UUID
        let ownerID: String?
        let startedAt: Date
        let deadline: Date
        let timeoutNanoseconds: UInt64
        let driver: any FigmaMCPProviderLoginDriving
        let resolver: any FigmaMCPProviderTargetResolving
        let evidence: FigmaMCPProviderCapabilityEvidence
        let driverIdentity: ObjectIdentifier
        let operationGeneration: UInt64
        let registrationReplacementGeneration: UInt64
        let startResult: StartResultLatch

        var resolution: FigmaMCPProviderTargetResolution?
        var context: FigmaMCPProviderLoginAttemptContext?
        var reservationReady = false
        var beginEntered = false
        var cancellationDispatched = false
        var cancellationTask: Task<Void, Never>?
        var pipelineTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var intent = CancellationIntent.none
        var terminal = false

        init(
            provider: ExternalMCPRuntimeProvider,
            target: ExternalMCPIntegrationTarget,
            attemptID: UUID,
            ownerID: String?,
            startedAt: Date,
            deadline: Date,
            timeoutNanoseconds: UInt64,
            driver: any FigmaMCPProviderLoginDriving,
            resolver: any FigmaMCPProviderTargetResolving,
            evidence: FigmaMCPProviderCapabilityEvidence,
            driverIdentity: ObjectIdentifier,
            operationGeneration: UInt64,
            registrationReplacementGeneration: UInt64,
            startResult: StartResultLatch
        ) {
            self.provider = provider
            self.target = target
            self.attemptID = attemptID
            self.ownerID = ownerID
            self.startedAt = startedAt
            self.deadline = deadline
            self.timeoutNanoseconds = timeoutNanoseconds
            self.driver = driver
            self.resolver = resolver
            self.evidence = evidence
            self.driverIdentity = driverIdentity
            self.operationGeneration = operationGeneration
            self.registrationReplacementGeneration = registrationReplacementGeneration
            self.startResult = startResult
        }
    }

    let registry: ExternalMCPAdapterRegistry
    private let statusCoordinator: ExternalMCPIntegrationCoordinator
    private let sessionController: FigmaMCPProviderTerminalHandoff.SessionController
    private let terminationObserver: any ApplicationTerminationObserving
    private let timing: FigmaMCPProviderConnectionCoordinatorTiming
    private let registrationLookup: @MainActor (ExternalMCPRuntimeProvider) -> ExternalMCPProviderRegistration?
    private let registrationReplacementFence = RegistrationReplacementFence()
    private var terminationObserverToken: NSObjectProtocol?
    private var observers = Set<String>()
    private var availabilityTasks: [ExternalMCPRuntimeProvider: Task<Void, Never>] = [:]
    private var statusTasks: [ExternalMCPRuntimeProvider: Task<Void, Never>] = [:]
    private var pendingStatusRechecks = Set<ExternalMCPRuntimeProvider>()
    private var statusRecheckPurposes: [ExternalMCPRuntimeProvider: FigmaMCPProviderStatusRecheckPurpose] = [:]
    private var proofExpiryTasks: [ExternalMCPRuntimeProvider: Task<Void, Never>] = [:]
    private var statusRevisions: [ExternalMCPRuntimeProvider: UInt64] = [:]
    private var availabilityGenerations: [ExternalMCPRuntimeProvider: UInt64] = [:]
    private var availabilityTaskRegistrationGenerations: [ExternalMCPRuntimeProvider: UInt64] = [:]
    private var statusTaskRegistrationGenerations: [ExternalMCPRuntimeProvider: UInt64] = [:]
    private var activeAttempts: [ExternalMCPRuntimeProvider: ActiveAttempt] = [:]
    private var providerGenerations: [ExternalMCPRuntimeProvider: UInt64] = [:]
    private var providerGenerationRegistrationGenerations: [ExternalMCPRuntimeProvider: UInt64] = [:]
    private var terminationStarted = false
    private var terminationDrainTask: Task<Void, Never>?
    private var neutralRevisionSources: [UInt64: NeutralRevisionSource] = [:]

    init(
        registry: ExternalMCPAdapterRegistry,
        sessionController: FigmaMCPProviderTerminalHandoff.SessionController,
        terminationObserver: (any ApplicationTerminationObserving)? = nil,
        timing: FigmaMCPProviderConnectionCoordinatorTiming = .init(),
        statusCoordinator: ExternalMCPIntegrationCoordinator? = nil,
        registrationLookup: (@MainActor (ExternalMCPRuntimeProvider) -> ExternalMCPProviderRegistration?)? = nil
    ) {
        self.registry = registry
        self.sessionController = sessionController
        self.statusCoordinator = statusCoordinator ?? ExternalMCPIntegrationCoordinator(registry: registry)
        self.timing = timing
        self.registrationLookup = registrationLookup ?? { provider in registry.registration(for: provider) }
        let observer = terminationObserver ?? NSApplicationTerminationObserver()
        self.terminationObserver = observer
        let token = observer.observeApplicationTermination { [weak self] in self?.applicationWillTerminate() }
        terminationObserverToken = token
        let previousReplacementHandler = registry.onRegistrationReplacement
        let replacementFence = registrationReplacementFence
        registry.onRegistrationReplacement = { [weak self, replacementFence] provider in
            let replacementGeneration = replacementFence.advance(for: provider)
            previousReplacementHandler?(provider)
            Task { @MainActor in
                self?.registrationWasReplaced(
                    for: provider,
                    replacementGeneration: replacementGeneration
                )
            }
        }
    }

    func activate(observerID: String) {
        guard !terminationStarted else { return }
        let wasObserving = !observers.isEmpty
        observers.insert(observerID)
        guard !wasObserving else { return }
        for provider in registry.registeredProviders where provider != .codex && provider != .cursor {
            let generation = nextAvailabilityGeneration(for: provider)
            availabilityTasks[provider]?.cancel()
            let registrationGeneration = registrationReplacementFence.current(for: provider)
            availabilityTaskRegistrationGenerations[provider] = registrationGeneration
            availabilityTasks[provider] = Task { @MainActor [weak self] in
                await self?.refreshAvailability(
                    for: provider,
                    generation: generation,
                    registrationGeneration: registrationGeneration
                )
            }
        }
    }

    func activate(observerID: Int) {
        activate(observerID: String(observerID))
    }

    func deactivate(observerID: String) {
        observers.remove(observerID)
        guard observers.isEmpty else { return }
        availabilityTasks.values.forEach { $0.cancel() }
        availabilityTasks.removeAll()
        statusTasks.values.forEach { $0.cancel() }
        for provider in statusTasks.keys {
            providerGenerations[provider, default: 0] &+= 1
        }
        statusTasks.removeAll()
        statusTaskRegistrationGenerations.removeAll()
        pendingStatusRechecks.removeAll()
        for provider in Array(availabilityGenerations.keys) {
            availabilityGenerations[provider, default: 0] &+= 1
        }
    }

    func deactivate(observerID: Int) {
        deactivate(observerID: String(observerID))
    }

    var observingSettings: Bool {
        !observers.isEmpty
    }

    @discardableResult
    func beginLogin(
        provider: ExternalMCPRuntimeProvider,
        ownerID: String? = nil,
        now: Date = Date()
    ) async -> UUID? {
        guard !terminationStarted, provider != .codex, provider != .cursor else { return nil }
        if let active = activeAttempts[provider], !active.terminal {
            return active.context == nil ? await active.startResult.wait() : active.attemptID
        }
        guard let registration = registrationLookup(provider),
              registration.provider == provider,
              case let .verified(evidence) = registration.figmaCapabilities.loginSupport,
              let driver = registration.loginDriver,
              driver.runtimeProvider == provider,
              let resolver = registration.targetResolver,
              let driverIdentity = referenceIdentity(of: driver)
        else { return nil }

        statusTasks.removeValue(forKey: provider)?.cancel()
        statusTaskRegistrationGenerations.removeValue(forKey: provider)
        pendingStatusRechecks.remove(provider)
        // A new login attempt clears any previously published provider proof immediately.
        invalidateNeutralRevision(for: provider)
        let requestedTimeout = (driver as? any FigmaMCPProviderSubprocessLoginTimeoutProviding)?.loginTimeout
        let timeout = effectiveTimeout(requestedTimeout)
        let timeoutNanoseconds = clampedSleepNanoseconds(timeout)
        let generation = nextGeneration(for: provider)
        let active = ActiveAttempt(
            provider: provider,
            target: .figma,
            attemptID: UUID(),
            ownerID: ownerID,
            startedAt: now,
            deadline: now.addingTimeInterval(timeout),
            timeoutNanoseconds: timeoutNanoseconds,
            driver: driver,
            resolver: resolver,
            evidence: evidence,
            driverIdentity: driverIdentity,
            operationGeneration: generation,
            registrationReplacementGeneration: registrationReplacementFence.current(for: provider),
            startResult: StartResultLatch()
        )
        activeAttempts[provider] = active
        invalidateAvailability(for: provider)
        cancelProofExpiry(for: provider)
        statusRecheckPurposes.removeValue(forKey: provider)
        states[provider] = .checking
        let timing = timing
        active.timeoutTask = Task { @MainActor [weak self, active, timing] in
            if active.timeoutNanoseconds > 0 { await timing.sleep(active.timeoutNanoseconds) }
            self?.timeout(active)
        }
        active.pipelineTask = Task { @MainActor [weak self, active] in await self?.runPipeline(active) }
        if timeoutNanoseconds == 0 { self.timeout(active) }
        return await active.startResult.wait()
    }

    @discardableResult
    func startLogin(
        provider: ExternalMCPRuntimeProvider,
        ownerID: String? = nil,
        now: Date = Date()
    ) async -> UUID? {
        await beginLogin(provider: provider, ownerID: ownerID, now: now)
    }

    func cancelLogin(provider: ExternalMCPRuntimeProvider, attemptID: UUID? = nil) async {
        guard provider != .cursor,
              let active = activeAttempts[provider],
              attemptID == nil || active.attemptID == attemptID,
              !active.terminal
        else { return }
        // Commit intent and retire the generation before the first suspension.
        active.intent = .user
        retireGeneration(for: provider, expected: active.operationGeneration)
        terminalize(active, completion: .cancelled, retiresGeneration: false)
        await active.cancellationTask?.value
    }

    func cancelLogin(provider: ExternalMCPRuntimeProvider, attemptID: UUID) async {
        await cancelLogin(provider: provider, attemptID: Optional(attemptID))
    }

    func state(for provider: ExternalMCPRuntimeProvider) -> FigmaMCPProviderConnectionState? {
        states[provider]
    }

    /// Starts one shared, provider-keyed structured status recheck for a row whose provider-owned
    /// authentication may have changed externally. Settings never creates a second status authority
    /// or performs provider-specific probing.
    @discardableResult
    func recheckStatus(
        provider: ExternalMCPRuntimeProvider,
        purpose: FigmaMCPProviderStatusRecheckPurpose = .refresh
    ) -> Bool {
        guard !terminationStarted,
              !observers.isEmpty,
              provider != .codex,
              provider != .cursor,
              activeAttempts[provider] == nil,
              let registration = registrationLookup(provider),
              case .verified = registration.figmaCapabilities.proofSupport,
              registration.structuredProofChecker != nil || registration.structuredStatusChecker != nil,
              let resolver = registration.targetResolver
        else { return false }

        if statusTasks[provider] != nil {
            pendingStatusRechecks.insert(provider)
            return true
        }

        switch states[provider] {
        case .connected, .needsLogin, .notVerified, .failed:
            break
        case .checking, .authorizing, .verifyingAfterAuthorization, .unavailable, .unsupported, nil:
            return false
        }

        let generation = nextGeneration(for: provider)
        let registrationGeneration = registrationReplacementFence.current(for: provider)
        cancelProofExpiry(for: provider)
        invalidateNeutralRevision(for: provider)
        statusRecheckPurposes[provider] = purpose
        states[provider] = .checking
        statusTaskRegistrationGenerations[provider] = registrationGeneration
        statusTasks[provider] = Task { @MainActor [weak self] in
            await self?.runStructuredRecheck(
                provider: provider,
                resolver: resolver,
                generation: generation,
                registrationGeneration: registrationGeneration
            )
        }
        return true
    }

    func statusRecheckPurpose(
        for provider: ExternalMCPRuntimeProvider
    ) -> FigmaMCPProviderStatusRecheckPurpose? {
        statusRecheckPurposes[provider]
    }

    /// Requests provider-owned credential logout and publishes a new row state only after the
    /// provider's structured status checker revalidates the result.
    func canSignOut(provider: ExternalMCPRuntimeProvider) -> Bool {
        let stateAllowsSignOut: Bool = switch states[provider] {
        case .connected:
            true
        case let .notVerified(_, notice):
            notice == .credentialLogoutUnverified
        default:
            false
        }
        guard stateAllowsSignOut,
              !terminationStarted,
              !observers.isEmpty,
              provider != .codex,
              provider != .cursor,
              activeAttempts[provider] == nil,
              statusTasks[provider] == nil,
              let registration = registrationLookup(provider),
              registration.provider == provider,
              registration.adapter.runtimeProvider == provider,
              case .verified = registration.figmaCapabilities.revocationSupport,
              case .verified = registration.figmaCapabilities.proofSupport,
              registration.structuredProofChecker != nil || registration.structuredStatusChecker != nil,
              registration.targetResolver != nil
        else { return false }
        return true
    }

    @discardableResult
    func signOut(provider: ExternalMCPRuntimeProvider) -> Bool {
        guard canSignOut(provider: provider),
              let registration = registrationLookup(provider),
              let resolver = registration.targetResolver
        else { return false }

        let generation = nextGeneration(for: provider)
        let registrationGeneration = registrationReplacementFence.current(for: provider)
        cancelProofExpiry(for: provider)
        invalidateNeutralRevision(for: provider)
        statusRecheckPurposes.removeValue(forKey: provider)
        states[provider] = .checking
        statusTaskRegistrationGenerations[provider] = registrationGeneration
        statusTasks[provider] = Task { @MainActor [weak self] in
            await self?.runProviderSignOut(
                provider: provider,
                registration: registration,
                resolver: resolver,
                generation: generation,
                registrationGeneration: registrationGeneration
            )
        }
        return true
    }

    func activeAttempt(for provider: ExternalMCPRuntimeProvider) -> FigmaMCPProviderLoginAttempt? {
        guard let active = activeAttempts[provider], let context = active.context else { return nil }
        return .init(
            provider: context.provider,
            target: context.target,
            providerTargetIdentifier: context.providerTargetIdentifier,
            credentialContext: context.credentialContext,
            attemptID: context.attemptID,
            ownerID: active.ownerID,
            evidenceID: context.evidenceID,
            capabilityRevision: context.capabilityRevision,
            executableIdentity: context.executableIdentity,
            executableVersion: context.executableVersion,
            startedAt: active.startedAt,
            deadline: active.deadline,
            operationGeneration: context.operationGeneration
        )
    }

    @discardableResult
    func applyVerifiedStatus(
        _ proof: FigmaMCPVerifiedProviderStatus,
        provider: ExternalMCPRuntimeProvider,
        targetResolution: FigmaMCPProviderTargetResolution,
        operationGeneration: UInt64
    ) -> Bool {
        guard !terminationStarted,
              provider != .codex,
              provider != .cursor,
              activeAttempts[provider] == nil,
              let registration = registrationLookup(provider),
              registration.provider == provider,
              case let .verified(evidence) = registration.figmaCapabilities.proofSupport,
              proofMatches(proof, provider: provider, target: .figma, resolution: targetResolution, evidence: evidence, operationGeneration: operationGeneration)
        else { return false }
        cancelProofExpiry(for: provider)
        invalidateNeutralRevision(for: provider)
        states[provider] = .connected(proof)
        scheduleProofExpiry(for: provider, proof: proof)
        return true
    }

    func applicationWillTerminate() {
        guard !terminationStarted else { return }
        terminationStarted = true
        invalidateNeutralRevisionForAll()
        availabilityTasks.values.forEach { $0.cancel() }
        availabilityTasks.removeAll()
        availabilityTaskRegistrationGenerations.removeAll()
        let statusProviders = Array(statusTasks.keys)
        statusTasks.values.forEach { $0.cancel() }
        statusTasks.removeAll()
        statusTaskRegistrationGenerations.removeAll()
        pendingStatusRechecks.removeAll()
        for provider in statusProviders {
            providerGenerations[provider, default: 0] &+= 1
        }
        proofExpiryTasks.values.forEach { $0.cancel() }
        proofExpiryTasks.removeAll()
        for provider in Array(availabilityGenerations.keys) {
            availabilityGenerations[provider, default: 0] &+= 1
        }

        let attempts = Array(activeAttempts.values)
        for active in attempts {
            active.intent = .termination
            retireGeneration(for: active.provider, expected: active.operationGeneration)
            terminalize(active, completion: .cancelled, retiresGeneration: false, suppressPublication: true)
        }

        let drainAttempts = attempts.filter { $0.reservationReady || $0.beginEntered }
        let latch = TerminationDrainLatch(remaining: drainAttempts.count)
        if drainAttempts.isEmpty {
            latch.expire()
        } else {
            for active in drainAttempts {
                Task { @MainActor in
                    await active.cancellationTask?.value
                    await active.pipelineTask?.value
                    latch.markFinished()
                }
            }
            Task { @MainActor in
                await timing.sleep(timing.terminationDrainTimeoutNanoseconds)
                latch.expire()
            }
        }
        terminationDrainTask = Task { @MainActor in await latch.wait() }
    }

    func awaitApplicationTermination() async {
        await terminationDrainTask?.value
        if let token = terminationObserverToken {
            terminationObserver.removeApplicationTerminationObserver(token)
            terminationObserverToken = nil
        }
    }

    private func runPipeline(_ active: ActiveAttempt) async {
        if let reserver = active.driver as? any FigmaMCPProviderSubprocessAttemptReserving {
            let reservation = await reserver.reserveAttempt(active.attemptID)
            guard !shouldStopPipeline(active) else { return }
            switch reservation {
            case .reserved:
                active.reservationReady = true
            case .busy:
                terminalize(active, completion: .busy, retiresGeneration: true)
                return
            case .cancelled:
                terminalize(active, completion: .cancelled, retiresGeneration: true)
                return
            }
        } else {
            guard !shouldStopPipeline(active) else { return }
        }

        let resolution = await active.resolver.resolveTarget(for: active.target)
        guard !shouldStopPipeline(active) else { return }
        guard case .resolved = resolution else {
            terminalize(active, completion: .targetResolution(resolution), retiresGeneration: true)
            return
        }
        active.resolution = resolution

        let availability = await active.driver.evaluateAvailability(provider: active.provider, target: active.target)
        guard !shouldStopPipeline(active) else { return }
        guard availability == .available else {
            terminalize(active, completion: .availability(availability), retiresGeneration: true)
            return
        }

        let executableIdentity: String
        if let executableResolver = active.driver as? any FigmaMCPProviderSubprocessExecutableResolving {
            let currentVersion = await executableResolver.currentExecutableVersion()
            guard let resolvedIdentity = await executableResolver.executableIdentity(),
                  await executableResolver.supportsExecutableVersion(currentVersion)
            else {
                terminalize(active, completion: .availability(.unavailable("The provider executable is unavailable or unsupported.")), retiresGeneration: true)
                return
            }
            executableIdentity = resolvedIdentity
            guard !shouldStopPipeline(active) else { return }
        } else {
            executableIdentity = "unknown"
        }

        guard currentAuthorityMatches(active) else {
            terminalize(active, completion: .stale, retiresGeneration: true)
            return
        }
        active.context = await FigmaMCPProviderLoginAttemptContext(
            provider: active.provider,
            target: active.target,
            providerTargetIdentifier: resolvedIdentifier(from: resolution),
            credentialContext: resolvedCredentialContext(from: resolution),
            attemptID: active.attemptID,
            evidenceID: active.evidence.evidenceID,
            capabilityRevision: active.evidence.capabilityRevision,
            executableIdentity: executableIdentity,
            executableVersion: currentExecutableVersion(for: active.driver),
            operationGeneration: active.operationGeneration
        )
        guard !shouldStopPipeline(active) else { return }
        states[active.provider] = .authorizing(makeAttempt(from: active))
        active.startResult.resolve(active.attemptID)
        if !(active.driver is any FigmaMCPProviderSubprocessAttemptReserving) { active.reservationReady = true }
        guard !shouldStopPipeline(active) else { return }
        active.beginEntered = true
        let settlement = await active.driver.beginLogin(
            provider: active.provider,
            target: active.target,
            attemptContext: active.context!
        )
        guard !shouldStopPipeline(active) else { return }
        let completion = Completion(settlement)
        if case .authorizationSessionClosed = completion {
            // Losing the owned authorization surface is a definitive lifecycle event, but not
            // authentication proof. Settle immediately instead of waiting on provider status.
            terminalize(active, completion: completion, retiresGeneration: true)
            return
        }

        guard await revalidateForSettlement(active) else {
            if isLiveIgnoringAuthority(active) { terminalize(active, completion: .stale, retiresGeneration: true) }
            return
        }
        let mayCheckClaudeProofAfterExit = active.provider == .claudeCode && isNaturalExit(completion)
        let shouldCheckStructuredStatus = if case let .exited(status) = completion {
            status == 0 || mayCheckClaudeProofAfterExit
        } else {
            false
        }
        if shouldCheckStructuredStatus, let resolution = active.resolution {
            states[active.provider] = .verifyingAfterAuthorization(makeAttempt(from: active))
            if let statusResult = await structuredStatus(
                provider: active.provider,
                target: active.target,
                resolution: resolution,
                operationGeneration: active.operationGeneration,
                registrationGeneration: active.registrationReplacementGeneration
            ) {
                guard isLiveIgnoringAuthority(active), await revalidateExecutableVersion(active) else {
                    if isLiveIgnoringAuthority(active) { terminalize(active, completion: .stale, retiresGeneration: true) }
                    return
                }
                terminalize(active, completion: completion, retiresGeneration: false, suppressPublication: true)
                await publishStructuredOutcome(
                    statusResult.outcome,
                    provider: active.provider,
                    proofResolution: resolution,
                    operationGeneration: active.operationGeneration,
                    registrationGeneration: active.registrationReplacementGeneration,
                    coordinatorRevision: statusResult.coordinatorRevision,
                    loginAttemptID: active.attemptID,
                    processSettlement: true
                )
                return
            }
        }

        if mayCheckClaudeProofAfterExit {
            // A provider-owned browser flow may settle nonzero even though the provider-side
            // authentication state is usable. Without exact structured proof, remain neutral and
            // never claim either success or a command failure.
            terminalize(
                active,
                completion: completion,
                retiresGeneration: completionRetiresGeneration(completion),
                processExitNotice: .processCompletedWithoutProof
            )
        } else {
            terminalize(active, completion: completion, retiresGeneration: completionRetiresGeneration(completion))
        }
    }

    private func shouldStopPipeline(_ active: ActiveAttempt) -> Bool {
        guard !isLiveIgnoringAuthority(active) else {
            if !currentAuthorityMatches(active) { terminalize(active, completion: .stale, retiresGeneration: true)
                return true
            }
            return false
        }
        requestCancellationIfReady(active)
        return true
    }

    private func isLiveIgnoringAuthority(_ active: ActiveAttempt) -> Bool {
        !terminationStarted
            && activeAttempts[active.provider] === active
            && !active.terminal
            && active.intent == .none
            && providerGenerations[active.provider] == active.operationGeneration
    }

    private func revalidateForSettlement(_ active: ActiveAttempt) async -> Bool {
        guard isLiveIgnoringAuthority(active), currentAuthorityMatches(active), let originalResolution = active.resolution else { return false }
        guard let resolver = registrationLookup(active.provider)?.targetResolver else { return false }
        let currentResolution = await resolver.resolveTarget(for: active.target)
        guard isLiveIgnoringAuthority(active), currentResolution == originalResolution else { return false }
        if let currentDriver = registrationLookup(active.provider)?.loginDriver as? any FigmaMCPProviderSubprocessExecutableResolving,
           let context = active.context
        {
            let currentIdentity = await currentDriver.executableIdentity()
            let currentVersion = await currentDriver.currentExecutableVersion()
            guard isLiveIgnoringAuthority(active),
                  currentIdentity == context.executableIdentity,
                  currentVersion == context.executableVersion,
                  await currentDriver.supportsExecutableVersion(currentVersion)
            else { return false }
        }
        return currentAuthorityMatches(active)
    }

    private func revalidateExecutableVersion(_ active: ActiveAttempt) async -> Bool {
        guard let context = active.context,
              let executableResolver = active.driver as? any FigmaMCPProviderSubprocessExecutableResolving
        else { return true }
        let currentVersion = await executableResolver.currentExecutableVersion()
        let supportsCurrentVersion = await executableResolver.supportsExecutableVersion(currentVersion)
        return currentVersion == context.executableVersion && supportsCurrentVersion
    }

    private func runProviderSignOut(
        provider: ExternalMCPRuntimeProvider,
        registration: ExternalMCPProviderRegistration,
        resolver: any FigmaMCPProviderTargetResolving,
        generation: UInt64,
        registrationGeneration: UInt64
    ) async {
        defer {
            finishStatusTask(
                provider: provider,
                generation: generation,
                registrationGeneration: registrationGeneration,
                requiresObserver: false
            )
        }
        guard !terminationStarted,
              !observers.isEmpty,
              activeAttempts[provider] == nil,
              providerGenerations[provider] == generation,
              registrationReplacementFence.current(for: provider) == registrationGeneration
        else { return }

        let resolution = await resolver.resolveTarget(for: .figma)
        guard !Task.isCancelled,
              !terminationStarted,
              !observers.isEmpty,
              activeAttempts[provider] == nil,
              providerGenerations[provider] == generation,
              registrationReplacementFence.current(for: provider) == registrationGeneration
        else { return }
        guard case .resolved = resolution else {
            applyTargetResolutionFailure(provider: provider, resolution: resolution)
            return
        }

        let coordinatorRevision = await statusCoordinator.activeRevision()
        let executableIdentity = await currentExecutableIdentity(for: registration.loginDriver)
        let executableVersion = await currentExecutableVersion(for: registration.loginDriver)
        let cancellationToken = ExternalMCPCancellationToken()
        guard await supportsExecutableVersion(executableVersion, registration: registration),
              let context = makeStatusContext(
                  provider: provider,
                  revision: coordinatorRevision,
                  executableIdentity: executableIdentity,
                  executableVersion: executableVersion,
                  cancellationToken: cancellationToken
              )
        else {
            states[provider] = .notVerified(loginAvailability: .available, notice: nil)
            return
        }

        _ = await withTaskCancellationHandler {
            await registration.adapter.disconnect(in: context, integration: .figma())
        } onCancel: {
            cancellationToken.cancel()
        }
        guard !Task.isCancelled,
              !cancellationToken.isCancelled,
              !terminationStarted,
              !observers.isEmpty,
              activeAttempts[provider] == nil,
              providerGenerations[provider] == generation,
              registrationReplacementFence.current(for: provider) == registrationGeneration,
              let currentRegistration = registrationLookup(provider),
              currentRegistration.provider == provider,
              case let .verified(currentRevocationEvidence) = currentRegistration.figmaCapabilities.revocationSupport,
              case let .verified(expectedRevocationEvidence) = registration.figmaCapabilities.revocationSupport,
              currentRevocationEvidence == expectedRevocationEvidence,
              await currentExecutableIdentity(for: currentRegistration.loginDriver) == executableIdentity,
              await currentExecutableVersion(for: currentRegistration.loginDriver) == executableVersion,
              await supportsExecutableVersion(executableVersion, registration: currentRegistration)
        else { return }

        guard let statusResult = await structuredStatus(
            provider: provider,
            target: .figma,
            resolution: resolution,
            operationGeneration: generation,
            registrationGeneration: registrationGeneration
        ) else {
            states[provider] = .notVerified(
                loginAvailability: .available,
                notice: .credentialLogoutUnverified
            )
            return
        }
        guard statusResult.outcome != .unknown, statusResult.outcome != .stale else {
            states[provider] = .notVerified(
                loginAvailability: .available,
                notice: .credentialLogoutUnverified
            )
            return
        }
        await publishStructuredOutcome(
            statusResult.outcome,
            provider: provider,
            proofResolution: resolution,
            operationGeneration: generation,
            registrationGeneration: registrationGeneration,
            coordinatorRevision: statusResult.coordinatorRevision,
            requiresObserver: true
        )
    }

    private func runStructuredRecheck(
        provider: ExternalMCPRuntimeProvider,
        resolver: any FigmaMCPProviderTargetResolving,
        generation: UInt64,
        registrationGeneration: UInt64
    ) async {
        defer {
            finishStatusTask(
                provider: provider,
                generation: generation,
                registrationGeneration: registrationGeneration,
                requiresObserver: true
            )
        }
        guard !terminationStarted, !observers.isEmpty, activeAttempts[provider] == nil,
              providerGenerations[provider] == generation,
              registrationReplacementFence.current(for: provider) == registrationGeneration
        else { return }

        let resolution = await resolver.resolveTarget(for: .figma)
        guard !terminationStarted, !observers.isEmpty, activeAttempts[provider] == nil,
              providerGenerations[provider] == generation,
              registrationReplacementFence.current(for: provider) == registrationGeneration
        else { return }
        guard case .resolved = resolution else {
            applyTargetResolutionFailure(provider: provider, resolution: resolution)
            return
        }
        guard let statusResult = await structuredStatus(
            provider: provider,
            target: .figma,
            resolution: resolution,
            operationGeneration: generation,
            registrationGeneration: registrationGeneration
        ) else {
            guard !terminationStarted, !observers.isEmpty, activeAttempts[provider] == nil,
                  providerGenerations[provider] == generation,
                  registrationReplacementFence.current(for: provider) == registrationGeneration
            else { return }
            invalidateNeutralRevision(for: provider)
            states[provider] = .notVerified(loginAvailability: .available, notice: nil)
            return
        }
        guard !terminationStarted, !observers.isEmpty, activeAttempts[provider] == nil,
              providerGenerations[provider] == generation,
              registrationReplacementFence.current(for: provider) == registrationGeneration
        else { return }
        await publishStructuredOutcome(
            statusResult.outcome,
            provider: provider,
            proofResolution: resolution,
            operationGeneration: generation,
            registrationGeneration: registrationGeneration,
            coordinatorRevision: statusResult.coordinatorRevision,
            requiresObserver: true
        )
        guard !terminationStarted, !observers.isEmpty, activeAttempts[provider] == nil,
              providerGenerations[provider] == generation,
              registrationReplacementFence.current(for: provider) == registrationGeneration,
              case .checking = states[provider]
        else { return }
        invalidateNeutralRevision(for: provider)
        states[provider] = .notVerified(loginAvailability: .available, notice: nil)
    }

    private func finishStatusTask(
        provider: ExternalMCPRuntimeProvider,
        generation: UInt64,
        registrationGeneration: UInt64,
        requiresObserver: Bool
    ) {
        guard !terminationStarted,
              !requiresObserver || !observers.isEmpty,
              providerGenerations[provider] == generation,
              registrationReplacementFence.current(for: provider) == registrationGeneration
        else { return }
        statusTasks.removeValue(forKey: provider)
        statusTaskRegistrationGenerations.removeValue(forKey: provider)
        guard pendingStatusRechecks.remove(provider) != nil else { return }
        if case .checking = states[provider] {
            invalidateNeutralRevision(for: provider)
            states[provider] = .notVerified(loginAvailability: .available, notice: nil)
        }
        _ = recheckStatus(provider: provider)
    }

    private func nextStatusRevision(for provider: ExternalMCPRuntimeProvider) -> UInt64 {
        let next = (statusRevisions[provider] ?? 0) &+ 1
        statusRevisions[provider] = next
        return next
    }

    private func isCurrentStatusRevision(_ revision: UInt64, for provider: ExternalMCPRuntimeProvider) -> Bool {
        statusRevisions[provider] == revision
    }

    private func invalidateNeutralRevision(for provider: ExternalMCPRuntimeProvider) {
        let revision = statusCoordinator.invalidateRevision()
        neutralRevisionSources[revision] = .provider(provider)
    }

    private func invalidateNeutralRevisionForAll() {
        let revision = statusCoordinator.invalidateRevision()
        neutralRevisionSources[revision] = .all
    }

    private func neutralRevisionIsCurrent(
        _ candidate: UInt64,
        for provider: ExternalMCPRuntimeProvider
    ) async -> Bool {
        let current = await statusCoordinator.currentRevision()
        guard current != candidate, candidate < current else { return current == candidate }
        var revision = candidate &+ 1
        while revision <= current {
            guard let source = neutralRevisionSources[revision] else { return false }
            switch source {
            case let .provider(sourceProvider) where sourceProvider == provider:
                return false
            case .all:
                return false
            default:
                break
            }
            if revision == UInt64.max { break }
            revision &+= 1
        }
        return true
    }

    private func cancelProofExpiry(for provider: ExternalMCPRuntimeProvider) {
        proofExpiryTasks.removeValue(forKey: provider)?.cancel()
    }

    private func scheduleProofExpiry(
        for provider: ExternalMCPRuntimeProvider,
        proof: FigmaMCPVerifiedProviderStatus
    ) {
        cancelProofExpiry(for: provider)
        let nanoseconds = clampedProofExpiryNanoseconds(for: proof)
        let timing = timing
        proofExpiryTasks[provider] = Task { @MainActor [weak self, timing] in
            if nanoseconds > 0 { await timing.sleep(nanoseconds) }
            guard let self,
                  !Task.isCancelled,
                  !terminationStarted,
                  case let .connected(currentProof) = states[provider],
                  currentProof == proof,
                  providerGenerations[provider] == proof.operationGeneration
            else { return }
            proofExpiryTasks.removeValue(forKey: provider)
            // A validity deadline means the proof must be renewed, not that the provider became
            // unauthenticated. While Settings is observing, immediately run the same structured
            // provider check used by Test Connection. Otherwise invalidate the expired proof so a
            // later activation cannot display stale Connected state while its new check is pending.
            if !observers.isEmpty, recheckStatus(provider: provider) { return }
            invalidateNeutralRevision(for: provider)
            retireGeneration(for: provider, expected: proof.operationGeneration)
            states[provider] = .notVerified(loginAvailability: .available, notice: nil)
        }
    }

    private func structuredStatus(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget,
        resolution expectedResolution: FigmaMCPProviderTargetResolution,
        operationGeneration: UInt64,
        registrationGeneration: UInt64
    ) async -> StructuredStatusResult? {
        var cancellationToken: ExternalMCPCancellationToken?
        return await withTaskCancellationHandler(operation: { () -> StructuredStatusResult? in
            guard target == .figma,
                  provider != .codex,
                  provider != .cursor,
                  !terminationStarted,
                  providerGenerations[provider] == operationGeneration,
                  registrationReplacementFence.current(for: provider) == registrationGeneration,
                  let registration = registrationLookup(provider),
                  case let .verified(evidence) = registration.figmaCapabilities.proofSupport,
                  let resolver = registration.targetResolver,
                  resolver.runtimeProvider == provider
            else { return nil }

            let checker: FigmaMCPStructuredStatusChecker? = if let structuredStatusChecker = registration.structuredStatusChecker {
                structuredStatusChecker
            } else if let proofChecker = registration.structuredProofChecker {
                { target, resolution, context, generation in
                    let proof = await proofChecker(target, resolution, context, generation)
                    return proof.map(FigmaMCPProviderStructuredStatusOutcome.verified) ?? .unknown
                }
            } else {
                nil
            }
            guard let checker else { return nil }
            let coordinatorRevision = await statusCoordinator.activeRevision()
            guard !terminationStarted,
                  providerGenerations[provider] == operationGeneration,
                  registrationReplacementFence.current(for: provider) == registrationGeneration,
                  await neutralRevisionIsCurrent(coordinatorRevision, for: provider)
            else { return .init(outcome: .stale, coordinatorRevision: coordinatorRevision) }

            let currentResolution = await resolver.resolveTarget(for: target)
            guard !terminationStarted,
                  providerGenerations[provider] == operationGeneration,
                  registrationReplacementFence.current(for: provider) == registrationGeneration,
                  await neutralRevisionIsCurrent(coordinatorRevision, for: provider)
            else { return .init(outcome: .stale, coordinatorRevision: coordinatorRevision) }
            guard currentResolution == expectedResolution else {
                return .init(outcome: .stale, coordinatorRevision: coordinatorRevision)
            }

            guard !terminationStarted,
                  providerGenerations[provider] == operationGeneration,
                  registrationReplacementFence.current(for: provider) == registrationGeneration
            else { return .init(outcome: .stale, coordinatorRevision: coordinatorRevision) }
            let statusRevision = nextStatusRevision(for: provider)
            let token = ExternalMCPCancellationToken()
            cancellationToken = token
            let executableIdentity = await currentExecutableIdentity(for: registration.loginDriver)
            let executableVersion = await currentExecutableVersion(for: registration.loginDriver)
            guard !terminationStarted,
                  providerGenerations[provider] == operationGeneration,
                  registrationReplacementFence.current(for: provider) == registrationGeneration,
                  await neutralRevisionIsCurrent(coordinatorRevision, for: provider),
                  await supportsExecutableVersion(executableVersion, registration: registration),
                  let context = makeStatusContext(
                      provider: provider,
                      revision: coordinatorRevision,
                      executableIdentity: executableIdentity,
                      executableVersion: executableVersion,
                      cancellationToken: token
                  )
            else { return .init(outcome: .stale, coordinatorRevision: coordinatorRevision) }

            // Provider generation and status revision are checked immediately before entering
            // provider code and again after it returns. This keeps providers independent while
            // preserving the publication fence for the provider being checked.
            let outcome = await checker(target, currentResolution, context, operationGeneration)
            guard !token.isCancelled,
                  !terminationStarted,
                  providerGenerations[provider] == operationGeneration,
                  registrationReplacementFence.current(for: provider) == registrationGeneration,
                  isCurrentStatusRevision(statusRevision, for: provider),
                  await neutralRevisionIsCurrent(coordinatorRevision, for: provider)
            else { return .init(outcome: .stale, coordinatorRevision: coordinatorRevision) }
            let currentIdentity = await currentExecutableIdentity(for: registration.loginDriver)
            let currentVersion = await currentExecutableVersion(for: registration.loginDriver)
            guard !terminationStarted,
                  providerGenerations[provider] == operationGeneration,
                  registrationReplacementFence.current(for: provider) == registrationGeneration,
                  await neutralRevisionIsCurrent(coordinatorRevision, for: provider),
                  currentIdentity == executableIdentity,
                  currentVersion == executableVersion,
                  await supportsExecutableVersion(currentVersion, registration: registration)
            else { return .init(outcome: .stale, coordinatorRevision: coordinatorRevision) }
            guard !terminationStarted,
                  providerGenerations[provider] == operationGeneration,
                  registrationReplacementFence.current(for: provider) == registrationGeneration,
                  let currentRegistration = registrationLookup(provider),
                  currentRegistration.provider == provider,
                  case let .verified(currentEvidence) = currentRegistration.figmaCapabilities.proofSupport,
                  currentEvidence == evidence
            else { return .init(outcome: .stale, coordinatorRevision: coordinatorRevision) }
            if case let .verified(proof) = outcome {
                guard proof.executableIdentity == nil || proof.executableIdentity == context.identity.executableIdentity,
                      proof.executableVersion == nil || proof.executableVersion == executableVersion
                else { return .init(outcome: .stale, coordinatorRevision: coordinatorRevision) }
            }
            return .init(outcome: outcome, coordinatorRevision: coordinatorRevision)
        }, onCancel: {
            cancellationToken?.cancel()
        })
    }

    private func publishStructuredOutcome(
        _ outcome: FigmaMCPProviderStructuredStatusOutcome,
        provider: ExternalMCPRuntimeProvider,
        proofResolution: FigmaMCPProviderTargetResolution,
        operationGeneration: UInt64,
        registrationGeneration: UInt64,
        coordinatorRevision: UInt64,
        requiresObserver: Bool = false,
        loginAttemptID: UUID? = nil,
        processSettlement: Bool = false
    ) async {
        guard !terminationStarted,
              !requiresObserver || !observers.isEmpty,
              activeAttempts[provider] == nil,
              providerGenerations[provider] == operationGeneration,
              registrationReplacementFence.current(for: provider) == registrationGeneration,
              await neutralRevisionIsCurrent(coordinatorRevision, for: provider)
        else { return }

        switch outcome {
        case let .verified(proof):
            guard await applyVerifiedStatusAfterRevalidation(
                proof,
                provider: provider,
                targetResolution: proofResolution,
                operationGeneration: operationGeneration,
                registrationGeneration: registrationGeneration,
                coordinatorRevision: coordinatorRevision,
                requiresObserver: requiresObserver
            ) else {
                guard !terminationStarted,
                      !requiresObserver || !observers.isEmpty,
                      providerGenerations[provider] == operationGeneration,
                      registrationReplacementFence.current(for: provider) == registrationGeneration,
                      await neutralRevisionIsCurrent(coordinatorRevision, for: provider)
                else { return }
                states[provider] = .notVerified(
                    loginAvailability: .available,
                    notice: processSettlement ? .processCompletedWithoutProof : nil
                )
                return
            }
            if let loginAttemptID {
                Task {
                    await FigmaMCPProviderTerminalHandoff.closeAfterVerifiedConnection(
                        provider: provider,
                        attemptID: loginAttemptID,
                        sessionController: sessionController
                    )
                }
            }
        case .unauthenticated, .expired:
            cancelProofExpiry(for: provider)
            invalidateNeutralRevision(for: provider)
            states[provider] = .needsLogin
        case .unknown, .stale:
            cancelProofExpiry(for: provider)
            invalidateNeutralRevision(for: provider)
            states[provider] = .notVerified(
                loginAvailability: .available,
                notice: processSettlement ? .processCompletedWithoutProof : nil
            )
        }
    }

    private func applyVerifiedStatusAfterRevalidation(
        _ proof: FigmaMCPVerifiedProviderStatus,
        provider: ExternalMCPRuntimeProvider,
        targetResolution: FigmaMCPProviderTargetResolution,
        operationGeneration: UInt64,
        registrationGeneration: UInt64,
        coordinatorRevision: UInt64,
        requiresObserver: Bool
    ) async -> Bool {
        guard !terminationStarted,
              !requiresObserver || !observers.isEmpty,
              activeAttempts[provider] == nil,
              providerGenerations[provider] == operationGeneration,
              registrationReplacementFence.current(for: provider) == registrationGeneration,
              await neutralRevisionIsCurrent(coordinatorRevision, for: provider),
              let registration = registrationLookup(provider),
              let resolver = registration.targetResolver,
              await resolver.resolveTarget(for: .figma) == targetResolution,
              !terminationStarted,
              !requiresObserver || !observers.isEmpty,
              providerGenerations[provider] == operationGeneration,
              registrationReplacementFence.current(for: provider) == registrationGeneration,
              await neutralRevisionIsCurrent(coordinatorRevision, for: provider)
        else { return false }
        return applyVerifiedStatus(
            proof,
            provider: provider,
            targetResolution: targetResolution,
            operationGeneration: operationGeneration
        )
    }

    private func registrationWasReplaced(
        for provider: ExternalMCPRuntimeProvider,
        replacementGeneration: UInt64
    ) {
        guard provider != .codex,
              provider != .cursor,
              registrationReplacementFence.current(for: provider) == replacementGeneration
        else { return }

        // A newer attempt or status operation may have been installed after replace() synchronously
        // advanced the replacement fence but before this main-actor callback ran. Only retire work
        // captured before this replacement; never let an old callback terminate newer work.
        let activeIsOlder = activeAttempts[provider].map {
            $0.registrationReplacementGeneration < replacementGeneration
        } ?? false
        let hasNewerProviderOperation = providerGenerationRegistrationGenerations[provider] == replacementGeneration
        if activeIsOlder, let active = activeAttempts[provider] {
            providerGenerations[provider, default: 0] &+= 1
            active.intent = .termination
            terminalize(active, completion: .stale, retiresGeneration: true)
        } else if activeAttempts[provider] == nil, !hasNewerProviderOperation {
            providerGenerations[provider, default: 0] &+= 1
        }

        availabilityGenerations[provider, default: 0] &+= 1
        if availabilityTaskRegistrationGenerations[provider].map({ $0 < replacementGeneration }) == true {
            availabilityTasks.removeValue(forKey: provider)?.cancel()
            availabilityTaskRegistrationGenerations.removeValue(forKey: provider)
        }
        if statusTaskRegistrationGenerations[provider].map({ $0 < replacementGeneration }) == true {
            statusTasks.removeValue(forKey: provider)?.cancel()
            statusTaskRegistrationGenerations.removeValue(forKey: provider)
        }
        pendingStatusRechecks.remove(provider)
        guard activeAttempts[provider] == nil,
              !hasNewerProviderOperation
        else { return }
        cancelProofExpiry(for: provider)
        invalidateNeutralRevision(for: provider)
        states[provider] = .notVerified(loginAvailability: .available, notice: nil)
    }

    private func makeStatusContext(
        provider: ExternalMCPRuntimeProvider,
        revision: UInt64,
        executableIdentity: String?,
        executableVersion: String?,
        cancellationToken: ExternalMCPCancellationToken
    ) -> ExternalMCPProviderRuntimeContext? {
        let profile: (AgentProviderKind, ExternalMCPRuntimeKind, ExternalMCPSessionClass, ExternalMCPIsolationMode)? = switch provider {
        case .claudeCode: (.claudeCode, .nativeCLI, .discovery, .userNative)
        case .openCode: (.openCode, .acp, .topLevel, .ceIsolated)
        case .cursor: (.cursor, .acp, .topLevel, .ceIsolated)
        case .devin:
            if let registration = registrationLookup(.devin),
               case .verified = registration.figmaCapabilities.loginSupport,
               case .verified = registration.figmaCapabilities.proofSupport,
               registration.targetResolver != nil,
               registration.structuredStatusChecker != nil || registration.structuredProofChecker != nil
            {
                // Only an injected verified registration can supply this testable context;
                // production Devin has no resolver, driver, checker, or proof capability.
                (.devin, .acp, .topLevel, .ceIsolated)
            } else {
                nil
            }
        case .grokBuild, .codex, .antigravity: nil
        }
        guard let profile else { return nil }
        return ExternalMCPProviderRuntimeContext(
            identity: .init(
                provider: provider,
                runtimeKind: profile.1,
                executableIdentity: executableIdentity ?? profile.0.commandName,
                executableVersion: executableVersion
            ),
            sessionClass: profile.2,
            isolation: profile.3,
            coordinatorRevision: revision,
            cancellationToken: cancellationToken
        )
    }

    private func currentExecutableIdentity(
        for driver: (any FigmaMCPProviderLoginDriving)?
    ) async -> String? {
        guard let resolver = driver as? any FigmaMCPProviderSubprocessExecutableResolving else {
            return nil
        }
        return await resolver.executableIdentity()
    }

    private func currentExecutableVersion(
        for driver: (any FigmaMCPProviderLoginDriving)?
    ) async -> String? {
        guard let resolver = driver as? any FigmaMCPProviderSubprocessExecutableResolving else {
            return nil
        }
        return await resolver.currentExecutableVersion()
    }

    private func supportsExecutableVersion(
        _ version: String?,
        registration: ExternalMCPProviderRegistration
    ) async -> Bool {
        guard let resolver = registration.loginDriver as? any FigmaMCPProviderSubprocessExecutableResolving else {
            return true
        }
        return await resolver.supportsExecutableVersion(version)
    }

    private func timeout(_ active: ActiveAttempt) {
        guard activeAttempts[active.provider] === active, !active.terminal else { return }
        active.intent = .timeout
        retireGeneration(for: active.provider, expected: active.operationGeneration)
        terminalize(active, completion: .timedOut, retiresGeneration: false)
    }

    private func terminalize(
        _ active: ActiveAttempt,
        completion: Completion,
        retiresGeneration: Bool,
        suppressPublication: Bool = false,
        processExitNotice: FigmaMCPProviderLoginNotice? = nil
    ) {
        guard activeAttempts[active.provider] === active, !active.terminal else { return }
        active.terminal = true
        active.timeoutTask?.cancel()
        active.pipelineTask?.cancel()
        if retiresGeneration { retireGeneration(for: active.provider, expected: active.operationGeneration) }
        let effective: Completion = switch active.intent {
        case .termination, .user: .cancelled
        case .timeout: .timedOut
        case .none: completion
        }
        active.startResult.resolve(active.context == nil ? nil : active.attemptID)
        activeAttempts.removeValue(forKey: active.provider)
        if active.intent != .none || shouldRequestCancellation(for: completion) { requestCancellationIfReady(active) }
        guard !suppressPublication, active.intent != .termination else { return }
        switch effective {
        case let .exited(status):
            states[active.provider] = .notVerified(
                loginAvailability: .available,
                notice: processExitNotice ?? (status == 0 ? .processCompletedWithoutProof : .providerProcessFailed)
            )
        case .authorizationSessionClosed:
            states[active.provider] = .notVerified(
                loginAvailability: .available,
                notice: .authorizationSessionClosed
            )
        case .launchFailed: states[active.provider] = .unavailable("The provider Figma login could not be launched.")
        case .timedOut: states[active.provider] = .notVerified(loginAvailability: .available, notice: .timedOutAuthenticationStateUnknown)
        case .cancelled: states[active.provider] = .notVerified(loginAvailability: .available, notice: .cancelledAuthenticationStateUnknown)
        case .busy: states[active.provider] = .unavailable("Another provider Figma login is already active.")
        case let .targetResolution(resolution): applyTargetResolutionFailure(provider: active.provider, resolution: resolution)
        case let .availability(availability): applyAvailability(availability, provider: active.provider)
        case .stale: states[active.provider] = .failed(.staleAttempt)
        }
    }

    private func currentAuthorityMatches(_ active: ActiveAttempt) -> Bool {
        guard let registration = registrationLookup(active.provider),
              registration.provider == active.provider,
              case let .verified(evidence) = registration.figmaCapabilities.loginSupport,
              evidence == active.evidence,
              let driver = registration.loginDriver,
              driver.runtimeProvider == active.provider,
              referenceIdentity(of: driver) == active.driverIdentity,
              registration.targetResolver != nil,
              registrationReplacementFence.current(for: active.provider) == active.registrationReplacementGeneration
        else { return false }
        return true
    }

    private func requestCancellationIfReady(_ active: ActiveAttempt) {
        guard active.reservationReady || active.beginEntered, !active.cancellationDispatched else { return }
        active.cancellationDispatched = true
        let driver = active.driver
        let provider = active.provider
        let attemptID = active.attemptID
        active.cancellationTask = Task { await driver.cancelLogin(provider: provider, attemptID: attemptID) }
    }

    private func isNaturalExit(_ completion: Completion) -> Bool {
        if case .exited = completion { return true }
        return false
    }

    private func completionRetiresGeneration(_ completion: Completion) -> Bool {
        !isNaturalExit(completion)
    }

    private func shouldRequestCancellation(for completion: Completion) -> Bool {
        switch completion {
        case .exited, .authorizationSessionClosed, .timedOut, .cancelled, .busy:
            false
        case .launchFailed, .targetResolution, .availability, .stale:
            true
        }
    }

    private func makeAttempt(from active: ActiveAttempt) -> FigmaMCPProviderLoginAttempt {
        let context = active.context!
        return .init(
            provider: context.provider,
            target: context.target,
            providerTargetIdentifier: context.providerTargetIdentifier,
            credentialContext: context.credentialContext,
            attemptID: context.attemptID,
            ownerID: active.ownerID,
            evidenceID: context.evidenceID,
            capabilityRevision: context.capabilityRevision,
            executableIdentity: context.executableIdentity,
            executableVersion: context.executableVersion,
            startedAt: active.startedAt,
            deadline: active.deadline,
            operationGeneration: context.operationGeneration
        )
    }

    private func applyAvailability(
        _ availability: FigmaMCPProviderLoginAvailability,
        provider: ExternalMCPRuntimeProvider,
        availabilityGeneration: UInt64? = nil,
        registrationGeneration: UInt64? = nil
    ) {
        guard !terminationStarted,
              activeAttempts[provider] == nil,
              availabilityGeneration.map({ availabilityGenerations[provider] == $0 }) ?? true,
              registrationGeneration.map({ registrationReplacementFence.current(for: provider) == $0 }) ?? true
        else { return }
        invalidateNeutralRevision(for: provider)
        cancelProofExpiry(for: provider)
        switch availability {
        case .available: states[provider] = .notVerified(loginAvailability: .available, notice: nil)
        case let .missingTarget(reason): states[provider] = .notVerified(loginAvailability: availability, notice: reason == .noCanonicalMatch ? .targetUnavailable : nil)
        case let .ambiguousTarget(count): states[provider] = .notVerified(loginAvailability: .ambiguousTarget(count), notice: .targetUnavailable)
        case let .untrustedCredentialContext(reason): states[provider] = .notVerified(loginAvailability: .untrustedCredentialContext(reason), notice: .targetUnavailable)
        case let .unavailable(reason): states[provider] = .unavailable(reason)
        }
    }

    private func applyTargetResolutionFailure(
        provider: ExternalMCPRuntimeProvider,
        resolution: FigmaMCPProviderTargetResolution,
        availabilityGeneration: UInt64? = nil,
        registrationGeneration: UInt64? = nil
    ) {
        guard !terminationStarted,
              activeAttempts[provider] == nil,
              availabilityGeneration.map({ availabilityGenerations[provider] == $0 }) ?? true,
              registrationGeneration.map({ registrationReplacementFence.current(for: provider) == $0 }) ?? true
        else { return }
        invalidateNeutralRevision(for: provider)
        cancelProofExpiry(for: provider)
        switch resolution {
        case let .missing(reason): states[provider] = .notVerified(loginAvailability: .missingTarget(reason), notice: .targetUnavailable)
        case let .ambiguous(count): states[provider] = .notVerified(loginAvailability: .ambiguousTarget(count), notice: .targetUnavailable)
        case let .untrustedCredentialContext(reason): states[provider] = .notVerified(loginAvailability: .untrustedCredentialContext(reason), notice: .targetUnavailable)
        case .resolved: break
        }
    }

    private func refreshAvailability(
        for provider: ExternalMCPRuntimeProvider,
        generation: UInt64,
        registrationGeneration: UInt64
    ) async {
        guard provider != .codex, provider != .cursor, !terminationStarted, !Task.isCancelled, activeAttempts[provider] == nil,
              availabilityGenerations[provider] == generation,
              registrationReplacementFence.current(for: provider) == registrationGeneration,
              let registration = registrationLookup(provider)
        else { return }

        let hasVerifiedProof: Bool = if case .verified = registration.figmaCapabilities.proofSupport {
            registration.structuredProofChecker != nil || registration.structuredStatusChecker != nil
        } else {
            false
        }
        let hasVerifiedLogin: Bool = if case .verified = registration.figmaCapabilities.loginSupport {
            registration.loginDriver != nil && registration.targetResolver != nil
        } else {
            false
        }

        guard hasVerifiedProof || hasVerifiedLogin else {
            switch registration.figmaCapabilities.loginSupport {
            case .unsupported: states[provider] = .unsupported
            case let .unverified(reason): states[provider] = .unavailable(unverifiedLoginMessage(reason))
            case .codexManaged, .verified: states[provider] = .unavailable("Provider Figma status is not configured.")
            }
            return
        }

        var resolution: FigmaMCPProviderTargetResolution?
        if hasVerifiedLogin {
            guard let driver = registration.loginDriver,
                  let resolver = registration.targetResolver
            else { return }
            let loginResolution = await resolver.resolveTarget(for: .figma)
            guard !Task.isCancelled, !terminationStarted, activeAttempts[provider] == nil,
                  availabilityGenerations[provider] == generation,
                  registrationReplacementFence.current(for: provider) == registrationGeneration
            else { return }
            guard case .resolved = loginResolution else {
                applyTargetResolutionFailure(
                    provider: provider,
                    resolution: loginResolution,
                    availabilityGeneration: generation,
                    registrationGeneration: registrationGeneration
                )
                return
            }
            let availability = await driver.evaluateAvailability(provider: provider, target: .figma)
            guard !Task.isCancelled, !terminationStarted, activeAttempts[provider] == nil,
                  availabilityGenerations[provider] == generation,
                  registrationReplacementFence.current(for: provider) == registrationGeneration
            else { return }
            guard availability == .available else {
                applyAvailability(
                    availability,
                    provider: provider,
                    availabilityGeneration: generation,
                    registrationGeneration: registrationGeneration
                )
                return
            }
            resolution = loginResolution
        }

        guard hasVerifiedProof else {
            cancelProofExpiry(for: provider)
            invalidateNeutralRevision(for: provider)
            states[provider] = .notVerified(loginAvailability: .available, notice: nil)
            return
        }

        if resolution == nil {
            guard let resolver = registration.targetResolver else { return }
            let proofResolution = await resolver.resolveTarget(for: .figma)
            guard !Task.isCancelled, !terminationStarted, activeAttempts[provider] == nil,
                  availabilityGenerations[provider] == generation,
                  registrationReplacementFence.current(for: provider) == registrationGeneration
            else { return }
            guard case .resolved = proofResolution else {
                applyTargetResolutionFailure(
                    provider: provider,
                    resolution: proofResolution,
                    availabilityGeneration: generation,
                    registrationGeneration: registrationGeneration
                )
                return
            }
            resolution = proofResolution
        }

        guard let resolution else { return }
        cancelProofExpiry(for: provider)
        statusRecheckPurposes.removeValue(forKey: provider)
        states[provider] = .checking
        let operationGeneration = nextGeneration(for: provider)
        guard let statusResult = await structuredStatus(
            provider: provider,
            target: .figma,
            resolution: resolution,
            operationGeneration: operationGeneration,
            registrationGeneration: registrationGeneration
        ) else {
            guard !Task.isCancelled, !terminationStarted, availabilityGenerations[provider] == generation,
                  registrationReplacementFence.current(for: provider) == registrationGeneration,
                  providerGenerations[provider] == operationGeneration
            else { return }
            states[provider] = .notVerified(loginAvailability: .available, notice: nil)
            return
        }
        guard !Task.isCancelled, !terminationStarted, activeAttempts[provider] == nil,
              availabilityGenerations[provider] == generation,
              providerGenerations[provider] == operationGeneration,
              registrationReplacementFence.current(for: provider) == registrationGeneration
        else { return }
        await publishStructuredOutcome(
            statusResult.outcome,
            provider: provider,
            proofResolution: resolution,
            operationGeneration: operationGeneration,
            registrationGeneration: registrationGeneration,
            coordinatorRevision: statusResult.coordinatorRevision,
            requiresObserver: true
        )
    }

    private func unverifiedLoginMessage(_ reason: FigmaMCPProviderCapabilityReason) -> String {
        if reason == .liveGatePending {
            return "Figma MCP login is currently pending verification for this provider"
        }
        return "Provider Figma login is pending its evidence gate (\(reason))."
    }

    private func nextGeneration(for provider: ExternalMCPRuntimeProvider) -> UInt64 {
        let next = (providerGenerations[provider] ?? 0) &+ 1
        providerGenerations[provider] = next
        providerGenerationRegistrationGenerations[provider] = registrationReplacementFence.current(for: provider)
        return next
    }

    private func retireGeneration(for provider: ExternalMCPRuntimeProvider, expected: UInt64) {
        guard providerGenerations[provider] == expected else { return }
        providerGenerations[provider] = expected &+ 1
    }

    private func nextAvailabilityGeneration(for provider: ExternalMCPRuntimeProvider) -> UInt64 {
        let next = (availabilityGenerations[provider] ?? 0) &+ 1
        availabilityGenerations[provider] = next
        return next
    }

    private func invalidateAvailability(for provider: ExternalMCPRuntimeProvider) {
        availabilityGenerations[provider, default: 0] &+= 1
        availabilityTasks[provider]?.cancel()
        availabilityTasks.removeValue(forKey: provider)
        availabilityTaskRegistrationGenerations.removeValue(forKey: provider)
    }

    /// Keep Task.sleep inputs in-band with UInt64 nanoseconds by clamping non-finite or
    /// out-of-range delays to safe bounds. Distant futures (including Date.distantFuture) are
    /// bounded to the largest representable UInt64 nanosecond delay while preserving existing
    /// immediate-expiration behavior for non-positive delays.
    private func clampedSleepNanoseconds(_ interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 0 }
        let scaled = interval * 1_000_000_000
        if !scaled.isFinite || scaled >= Double(UInt64.max) { return UInt64.max }
        return UInt64(scaled)
    }

    private func clampedProofExpiryNanoseconds(for proof: FigmaMCPVerifiedProviderStatus) -> UInt64 {
        clampedSleepNanoseconds(proof.validUntil.timeIntervalSinceNow)
    }

    private func effectiveTimeout(_ requested: TimeInterval?) -> TimeInterval {
        guard let requested, requested.isFinite, requested >= 0 else { return Self.defaultLoginTimeout }
        return min(requested, Self.defaultLoginTimeout)
    }

    private func referenceIdentity(of driver: any FigmaMCPProviderLoginDriving) -> ObjectIdentifier? {
        guard Mirror(reflecting: driver).displayStyle == .class else { return nil }
        return ObjectIdentifier(driver as AnyObject)
    }

    private func resolvedIdentifier(from resolution: FigmaMCPProviderTargetResolution) -> String {
        guard case let .resolved(identifier, _, _) = resolution else { return "" }
        return identifier
    }

    private func resolvedCredentialContext(from resolution: FigmaMCPProviderTargetResolution) -> FigmaMCPProviderCredentialContext {
        guard case let .resolved(_, _, credentialContext) = resolution else { return .providerDefaultUserProfile }
        return credentialContext
    }

    private func proofMatches(
        _ proof: FigmaMCPVerifiedProviderStatus,
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget,
        resolution: FigmaMCPProviderTargetResolution,
        evidence: FigmaMCPProviderCapabilityEvidence,
        operationGeneration: UInt64
    ) -> Bool {
        guard case let .resolved(identifier, _, credentialContext) = resolution else { return false }
        let snapshot = proof.sanitizedSnapshot
        return proof.runtimeProvider == provider
            && proof.canonicalTarget == target
            && proof.providerTargetIdentifier == identifier
            && proof.credentialContext == credentialContext
            && proof.evidenceID == evidence.evidenceID
            && proof.capabilityRevision == evidence.capabilityRevision
            && proof.operationGeneration == operationGeneration
            && providerGenerations[provider, default: 0] == operationGeneration
            && snapshot.integrationID == target.integrationID
            && proof.observedAt <= Date().addingTimeInterval(1)
            && proof.validUntil > Date()
            && snapshot.connection == .connected
            && snapshot.authentication == .providerOwned
    }
}
