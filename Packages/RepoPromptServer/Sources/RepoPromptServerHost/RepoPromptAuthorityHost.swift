import Foundation
import Logging
import RepoPromptAuthorityAPI
import RepoPromptDomainRuntime
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptRuntimeModel

public enum AuthorityHostLifecycleState: Sendable, Equatable {
    case idle
    case acquiringLease
    case validatingStore
    case recoveringResources
    case recoveringProviders
    case recoveringAuthority
    case ready
    case draining
    case quiescingProviders
    case checkpointing
    case closing
    case stopped
    case failed(phase: String, diagnosticCode: String)
}

public struct AuthorityHostConfiguration: Sendable {
    public let namespace: AuthorityNamespaceDescriptor
    public let eventSigningKeyID: String?
    public let eventSigningSecret: Data?
    public let mutationDrainMaximum: Duration
    public let admittedWorkDrainMaximum: Duration
    public let shutdownHooks: AuthorityHostShutdownHooks
    var allowsPendingRestoreRebind = false

    public init(
        namespace: AuthorityNamespaceDescriptor,
        eventSigningKeyID: String? = nil,
        eventSigningSecret: Data? = nil,
        mutationDrainMaximum: Duration = .seconds(15),
        admittedWorkDrainMaximum: Duration = .seconds(15),
        shutdownHooks: AuthorityHostShutdownHooks = .none
    ) {
        self.namespace = namespace
        self.eventSigningKeyID = eventSigningKeyID
        self.eventSigningSecret = eventSigningSecret
        self.mutationDrainMaximum = mutationDrainMaximum
        self.admittedWorkDrainMaximum = admittedWorkDrainMaximum
        self.shutdownHooks = shutdownHooks
    }

    func allowingPendingRestoreRebind() -> Self {
        var copy = self
        copy.allowsPendingRestoreRebind = true
        return copy
    }
}

public enum AuthorityHostShutdownPhase: String, Codable, CaseIterable, Sendable {
    case mutationDrain
    case admittedWorkDrain
    case providerQuiesce
    case directRuntimeDrain
    case durabilityStop
    case durabilitySweep
    case eventOutboxDrain
    case processFencing
    case checkpoint
    case storeClose
}

public enum AuthorityHostShutdownAction: String, Codable, Sendable {
    case mutationAdmissionClosed
    case mutationDrainFinished
    case externalCapabilitiesInvalidated
    case admittedWorkDrainFinished
    case providerQuiesceFinished
    case directRuntimeDrainFinished
    case durabilityStopped
    case durabilitySweepFinished
    case eventOutboxDrained
    case processFencingPersisted
    case checkpointFinished
    case storeClosed
    case leaseReleased
}

public struct AuthorityHostShutdownHooks: Sendable {
    public let beforePhase: @Sendable (AuthorityHostShutdownPhase) -> Void
    public let operationOverride: @Sendable (
        AuthorityHostShutdownPhase
    ) -> (@Sendable () async throws -> Void)?

    public init(
        beforePhase: @escaping @Sendable (AuthorityHostShutdownPhase) -> Void = { _ in },
        operationOverride: @escaping @Sendable (
            AuthorityHostShutdownPhase
        ) -> (@Sendable () async throws -> Void)? = { _ in nil }
    ) {
        self.beforePhase = beforePhase
        self.operationOverride = operationOverride
    }

    public static let none = AuthorityHostShutdownHooks()
}

public struct AuthorityHostShutdownBudget: Sendable {
    public let startedAtTicks: UInt64
    public let deadlineTicks: UInt64
    private let now: @Sendable () -> UInt64

    public init(
        total: Duration = .seconds(30),
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.now = now
        startedAtTicks = now()
        let addition = startedAtTicks.addingReportingOverflow(
            Self.nanoseconds(max(.zero, total))
        )
        deadlineTicks = addition.overflow ? .max : addition.partialValue
    }

    public func remaining() -> Duration {
        let current = now()
        guard current < deadlineTicks else { return .zero }
        return .nanoseconds(Int64(clamping: deadlineTicks - current))
    }

    public func allowance(maximum: Duration) -> Duration {
        min(max(.zero, maximum), remaining())
    }

    public var isExhausted: Bool { remaining() == .zero }

    public func elapsed() -> Duration {
        let current = now()
        guard current > startedAtTicks else { return .zero }
        return .nanoseconds(Int64(clamping: current - startedAtTicks))
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(max(0, components.seconds))
        let subsecond = UInt64(max(0, components.attoseconds / 1_000_000_000))
        let secondsNanos = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if secondsNanos.overflow { return .max }
        return secondsNanos.partialValue.addingReportingOverflow(subsecond).partialValue
    }
}

public struct AuthorityHostShutdownReport: Sendable, Equatable {
    public let clean: Bool
    public let mutationDrainTimedOut: Bool
    public let childDrainTimedOut: Bool
    public let externalTransportDrainTimedOut: Bool
    public let budgetExhausted: Bool
    public let elapsed: Duration
    public let finalState: AuthorityHostLifecycleState
    public let timedOutPhases: [AuthorityHostShutdownPhase]
    public let actions: [AuthorityHostShutdownAction]
    public let leaseReleased: Bool

    public var drainTimedOut: Bool {
        mutationDrainTimedOut || childDrainTimedOut || externalTransportDrainTimedOut
    }
}

public struct AuthorityHostStartupObservation: Sendable, Equatable {
    public let diagnosticCodes: [String]
    public let staleOwnerRecoveries: Int
}

public struct AuthorityHostCapabilities: Sendable {
    public let authority: RepoPromptHeadlessAuthority
    public let store: SQLiteServiceStore
    public let mutationGate: AuthorityMutationGate
    public let eventHub: ServiceEventHub
    public let eventOutboxDispatcher: OrderedEventOutboxDispatcher
}

/// Lifecycle owner shared by the network Server and private direct-headless
/// helper. It deliberately imports no HTTP/TLS/portal modules.
public actor RepoPromptAuthorityHost {
    public nonisolated let instanceID: UUID
    public nonisolated let configuration: AuthorityHostConfiguration
    public nonisolated let mutationGate: AuthorityMutationGate

    private var stateValue: AuthorityHostLifecycleState = .idle
    private var lease: AuthorityNamespaceLease?
    private var storeValue: SQLiteServiceStore?
    private var authorityValue: RepoPromptHeadlessAuthority?
    private var directRuntimeValue: MCPDomainRuntime?
    private var durabilityOperationsValue: DurabilityOperationsService?
    private var eventHubValue: ServiceEventHub?
    private var eventOutboxDispatcherValue: OrderedEventOutboxDispatcher?
    private var startupDiagnosticCodes: [String] = []
    private var staleOwnerRecoveries = 0
    private var shutdownBudget: AuthorityHostShutdownBudget?
    private var shutdownDrainSnapshot: AuthorityMutationGateSnapshot?
    private var lastShutdownReport: AuthorityHostShutdownReport?
    private var shutdownActions: [AuthorityHostShutdownAction] = []
    private var timedOutShutdownPhases: [AuthorityHostShutdownPhase] = []
    private let logger = Logger(label: "com.repoprompt.ce.authority-host")

    private init(configuration: AuthorityHostConfiguration) {
        self.instanceID = UUID()
        self.configuration = configuration
        self.mutationGate = AuthorityMutationGate()
    }

    public static func start(configuration: AuthorityHostConfiguration) async throws -> RepoPromptAuthorityHost {
        let host = RepoPromptAuthorityHost(configuration: configuration)
        try await host.open()
        return host
    }

    private func open() async throws {
        do {
            stateValue = .acquiringLease
            let acquisition = try AuthorityNamespaceLease.acquire(configuration.namespace)
            lease = acquisition.lease
            if acquisition.recoveredStaleOwner {
                startupDiagnosticCodes.append("stale_owner_recovered")
                staleOwnerRecoveries += 1
                logger.warning(
                    "authority_namespace_stale_owner_recovered",
                    metadata: [
                        "namespace": "\(configuration.namespace.namespaceID)",
                        "mode": "\(configuration.namespace.servingMode.rawValue)"
                    ]
                )
            }
            stateValue = .validatingStore
            let eventSigningKey: PersistenceEventSigningKey? = if let keyID = configuration.eventSigningKeyID,
                                                                  let secret = configuration.eventSigningSecret
            {
                PersistenceEventSigningKey(keyID: keyID, secret: secret)
            } else {
                nil
            }
            storeValue = try await SQLiteServiceStore.openForServing(
                storage: .file(configuration.namespace.databasePath),
                eventSigningKey: eventSigningKey,
                namespaceKind: configuration.namespace.servingMode.rawValue,
                databaseIdentityDigest: configuration.namespace.namespaceID,
                allowPendingRestoreRebind: configuration.allowsPendingRestoreRebind
            )
            stateValue = .recoveringResources
        } catch let error as ServiceAPIError {
            stateValue = .failed(phase: "startup", diagnosticCode: error.code.rawValue)
            lease?.release()
            lease = nil
            throw error
        } catch {
            stateValue = .failed(phase: "startup", diagnosticCode: "authority_start_failed")
            lease?.release()
            lease = nil
            throw error
        }
    }

    public func storeForRecovery() throws -> SQLiteServiceStore {
        guard let storeValue else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Authority store is unavailable")
        }
        return storeValue
    }

    public func markRecoveringProviders() { stateValue = .recoveringProviders }
    public func markRecoveringAuthority() { stateValue = .recoveringAuthority }

    public func installRecoveredAuthority(
        _ authority: RepoPromptHeadlessAuthority,
        durabilityOperations: DurabilityOperationsService? = nil,
        eventHub: ServiceEventHub,
        eventOutboxDispatcher: OrderedEventOutboxDispatcher
    ) {
        authorityValue = authority
        durabilityOperationsValue = durabilityOperations
        eventHubValue = eventHub
        eventOutboxDispatcherValue = eventOutboxDispatcher
        stateValue = .ready
    }

    func installDirectHeadlessRuntime(_ runtime: MCPDomainRuntime) throws {
        guard configuration.namespace.servingMode == .directHeadless,
              directRuntimeValue == nil,
              authorityValue == nil
        else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "Direct-headless runtime does not match the authority host mode"
            )
        }
        directRuntimeValue = runtime
        stateValue = .ready
    }

    public func capabilities() throws -> AuthorityHostCapabilities {
        guard stateValue == .ready,
              let authorityValue,
              let storeValue,
              let eventHubValue,
              let eventOutboxDispatcherValue
        else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Authority host is not ready")
        }
        return .init(
            authority: authorityValue,
            store: storeValue,
            mutationGate: mutationGate,
            eventHub: eventHubValue,
            eventOutboxDispatcher: eventOutboxDispatcherValue
        )
    }

    public func lifecycleState() -> AuthorityHostLifecycleState { stateValue }

    public func startupObservation() -> AuthorityHostStartupObservation {
        .init(
            diagnosticCodes: startupDiagnosticCodes,
            staleOwnerRecoveries: staleOwnerRecoveries
        )
    }

    @discardableResult
    public func beginShutdown(using proposedBudget: AuthorityHostShutdownBudget) async -> AuthorityMutationGateSnapshot {
        if let snapshot = shutdownDrainSnapshot { return snapshot }
        let budget = recordShutdownBudget(proposedBudget)
        stateValue = .draining
        await mutationGate.beginDraining()
        recordShutdownAction(.mutationAdmissionClosed)
        configuration.shutdownHooks.beforePhase(.mutationDrain)
        let snapshot = await mutationGate.drain(
            timeout: budget.allowance(maximum: configuration.mutationDrainMaximum)
        )
        if snapshot.drainTimedOut || budget.isExhausted {
            recordShutdownTimeout(.mutationDrain)
        }
        recordShutdownAction(.mutationDrainFinished)
        shutdownDrainSnapshot = snapshot
        return snapshot
    }

    public func shutdown(reason: String, deadline: Duration = .seconds(30)) async -> AuthorityHostShutdownReport {
        await shutdown(
            reason: reason,
            using: AuthorityHostShutdownBudget(total: deadline)
        )
    }

    public func shutdown(
        reason _: String,
        using proposedBudget: AuthorityHostShutdownBudget,
        childDrainTimedOut: Bool = false,
        childWorkUnsettled: Bool = false,
        externalTransportDrainTimedOut: Bool = false
    ) async -> AuthorityHostShutdownReport {
        if let lastShutdownReport { return lastShutdownReport }
        let budget = recordShutdownBudget(proposedBudget)
        let drain = await beginShutdown(using: budget)

        // Transports have stopped accepting work before this entry point. Fence
        // every retained capability, then prove that all work admitted before the
        // fence has returned before any store/checkpoint/lease teardown.
        stateValue = .closing
        recordShutdownAction(.externalCapabilitiesInvalidated)
        configuration.shutdownHooks.beforePhase(.admittedWorkDrain)
        let admittedWork = await mutationGate.closeAndDrain(
            timeout: budget.allowance(maximum: configuration.admittedWorkDrainMaximum)
        )
        let admittedWorkSettled = admittedWork.inFlightMutations == 0 && admittedWork.inFlightReads == 0
        if !admittedWorkSettled || budget.isExhausted {
            recordShutdownTimeout(.admittedWorkDrain)
        } else {
            recordShutdownAction(.admittedWorkDrainFinished)
        }

        var workSettled = admittedWorkSettled && !childWorkUnsettled && !externalTransportDrainTimedOut
        var clean = !drain.drainTimedOut
            && !childDrainTimedOut
            && !externalTransportDrainTimedOut
            && workSettled
            && !budget.isExhausted
        var directRuntimeSettled = directRuntimeValue == nil
        var providerSettled = authorityValue == nil

        stateValue = .quiescingProviders
        if let operation = configuration.shutdownHooks.operationOverride(.providerQuiesce) {
            let outcome = await runShutdownPhase(.providerQuiesce, budget: budget, operation: operation)
            providerSettled = outcome == .completed
            workSettled = workSettled && providerSettled
            clean = clean && providerSettled
            if providerSettled { recordShutdownAction(.providerQuiesceFinished) }
        } else if let authorityValue {
            let outcome = await runShutdownPhase(.providerQuiesce, budget: budget) {
                try await authorityValue.quiesce()
            }
            providerSettled = outcome == .completed
            workSettled = workSettled && providerSettled
            clean = clean && providerSettled
            if providerSettled { recordShutdownAction(.providerQuiesceFinished) }
        }
        if let operation = configuration.shutdownHooks.operationOverride(.directRuntimeDrain) {
            let outcome = await runShutdownPhase(.directRuntimeDrain, budget: budget, operation: operation)
            directRuntimeSettled = outcome == .completed
            workSettled = workSettled && directRuntimeSettled
            clean = clean && directRuntimeSettled
            if directRuntimeSettled { recordShutdownAction(.directRuntimeDrainFinished) }
        } else if let directRuntimeValue {
            let outcome = await runShutdownPhase(.directRuntimeDrain, budget: budget) {
                _ = await directRuntimeValue.shutdown()
            }
            directRuntimeSettled = outcome == .completed
            workSettled = workSettled && directRuntimeSettled
            clean = clean && directRuntimeSettled
            if directRuntimeSettled { recordShutdownAction(.directRuntimeDrainFinished) }
        }
        if let durabilityStop = configuration.shutdownHooks.operationOverride(.durabilityStop)
            ?? durabilityOperationsValue.map({ operations in
                { @Sendable in await operations.stop() }
            })
        {
            let stopped = await runShutdownPhase(.durabilityStop, budget: budget, operation: durabilityStop)
            workSettled = workSettled && stopped == .completed
            clean = clean && stopped == .completed
            if stopped == .completed { recordShutdownAction(.durabilityStopped) }
        }
        if let durabilitySweep = configuration.shutdownHooks.operationOverride(.durabilitySweep)
            ?? durabilityOperationsValue.map({ operations in
                { @Sendable in _ = await operations.runOnce() }
            })
        {
            let swept = await runShutdownPhase(.durabilitySweep, budget: budget, operation: durabilitySweep)
            workSettled = workSettled && swept == .completed
            clean = clean && swept == .completed
            if swept == .completed { recordShutdownAction(.durabilitySweepFinished) }
        }

        if let eventOutboxDispatcherValue {
            let drained = await runShutdownPhase(.eventOutboxDrain, budget: budget) {
                await eventOutboxDispatcherValue.stop(drain: true)
            }
            workSettled = workSettled && drained == .completed
            clean = clean && drained == .completed
            if drained == .completed { recordShutdownAction(.eventOutboxDrained) }
            await eventHubValue?.finish()
        }

        if childDrainTimedOut || externalTransportDrainTimedOut || !providerSettled {
            let fenced = await runShutdownPhase(.processFencing, budget: budget) { [storeValue] in
                guard let storeValue else { return }
                for family in try await storeValue.activeProcessFamilies() {
                    try await storeValue.updateProcessFamilyState(
                        runID: family.runID,
                        state: "shutdown-reconciliation-required"
                    )
                }
            }
            workSettled = workSettled && fenced == .completed
            clean = clean && fenced == .completed
            if fenced == .completed { recordShutdownAction(.processFencingPersisted) }
        }

        stateValue = .checkpointing
        if clean, workSettled, let storeValue {
            let checkpointed = await runShutdownPhase(.checkpoint, budget: budget) {
                try await storeValue.checkpoint()
            }
            workSettled = workSettled && checkpointed == .completed
            clean = checkpointed == .completed
            if checkpointed == .completed { recordShutdownAction(.checkpointFinished) }
        }

        stateValue = .closing
        if budget.isExhausted { clean = false }
        var storeClosed = storeValue == nil && workSettled
        if workSettled, directRuntimeSettled, let storeValue {
            let closeClean = clean
            let closed = await runShutdownPhase(.storeClose, budget: budget) {
                try await storeValue.close(clean: closeClean)
            }
            storeClosed = closed == .completed
            workSettled = workSettled && storeClosed
            clean = clean && storeClosed
            if storeClosed { recordShutdownAction(.storeClosed) }
        }

        var leaseReleased = false
        if storeClosed, directRuntimeSettled, workSettled {
            storeValue = nil
            authorityValue = nil
            directRuntimeValue = nil
            durabilityOperationsValue = nil
            eventHubValue = nil
            eventOutboxDispatcherValue = nil

            // The namespace lease is deliberately the final owned resource released.
            lease?.release()
            lease = nil
            leaseReleased = true
            recordShutdownAction(.leaseReleased)
            stateValue = .stopped
        } else {
            clean = false
            let diagnosticCode = if !workSettled {
                "shutdown_work_unsettled"
            } else if !directRuntimeSettled {
                "runtime_drain_timeout"
            } else {
                "store_close_timeout"
            }
            stateValue = .failed(phase: "closing", diagnosticCode: diagnosticCode)
        }
        let exhausted = budget.isExhausted
        if exhausted { clean = false }
        let report = AuthorityHostShutdownReport(
            clean: clean,
            mutationDrainTimedOut: drain.drainTimedOut,
            childDrainTimedOut: childDrainTimedOut,
            externalTransportDrainTimedOut: externalTransportDrainTimedOut,
            budgetExhausted: exhausted,
            elapsed: budget.elapsed(),
            finalState: stateValue,
            timedOutPhases: timedOutShutdownPhases,
            actions: shutdownActions,
            leaseReleased: leaseReleased
        )
        lastShutdownReport = report
        return report
    }

    private func recordShutdownBudget(_ proposed: AuthorityHostShutdownBudget) -> AuthorityHostShutdownBudget {
        // The first shutdown request owns the one total monotonic deadline.
        // Later callers may observe it, but cannot shorten or extend it.
        if let shutdownBudget { return shutdownBudget }
        shutdownBudget = proposed
        return proposed
    }

    private func recordShutdownAction(_ action: AuthorityHostShutdownAction) {
        if shutdownActions.last != action { shutdownActions.append(action) }
    }

    private func recordShutdownTimeout(_ phase: AuthorityHostShutdownPhase) {
        if !timedOutShutdownPhases.contains(phase) { timedOutShutdownPhases.append(phase) }
    }

    private func runShutdownPhase(
        _ phase: AuthorityHostShutdownPhase,
        budget: AuthorityHostShutdownBudget,
        operation: @escaping @Sendable () async throws -> Void
    ) async -> AuthorityShutdownPhaseOutcome {
        configuration.shutdownHooks.beforePhase(phase)
        guard !budget.isExhausted else {
            recordShutdownTimeout(phase)
            return .timedOut
        }
        let race = AuthorityShutdownPhaseRace()
        let operationTask = Task {
            do {
                try await operation()
                await race.resolve(.completed)
            } catch is CancellationError {
                await race.resolve(.timedOut)
            } catch {
                await race.resolve(.failed)
            }
        }
        let timeout = budget.remaining()
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                await race.resolve(.timedOut)
            } catch {}
        }
        let outcome = await race.wait()
        if outcome == .timedOut { operationTask.cancel() }
        timeoutTask.cancel()
        if outcome != .completed || budget.isExhausted {
            recordShutdownTimeout(phase)
            return outcome == .failed ? .failed : .timedOut
        }
        return .completed
    }

    /// A failed deadline path intentionally retains the lease when the store or
    /// direct runtime could not be fenced. Tests use this only to release their
    /// temporary namespace after asserting the fail-stop contract.
    func forceCleanupAfterFailedShutdownForTesting() async {
        await mutationGate.close()
        if let directRuntimeValue { _ = await directRuntimeValue.shutdown() }
        try? await storeValue?.close(clean: false)
        storeValue = nil
        authorityValue = nil
        directRuntimeValue = nil
        durabilityOperationsValue = nil
        lease?.release()
        lease = nil
        stateValue = .stopped
    }
}

private enum AuthorityShutdownPhaseOutcome: Sendable, Equatable {
    case completed
    case failed
    case timedOut
}

private actor AuthorityShutdownPhaseRace {
    private var outcome: AuthorityShutdownPhaseOutcome?
    private var waiters: [CheckedContinuation<AuthorityShutdownPhaseOutcome, Never>] = []

    func resolve(_ value: AuthorityShutdownPhaseOutcome) {
        guard outcome == nil else { return }
        outcome = value
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume(returning: value) }
    }

    func wait() async -> AuthorityShutdownPhaseOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// The only serving factory allowed to acquire an authority namespace lease.
/// Executables provide outer transport configuration but never open a store or
/// construct a lease themselves.
public enum RepoPromptAuthorityHostFactory {
    public static func start(
        configuration: AuthorityHostConfiguration
    ) async throws -> RepoPromptAuthorityHost {
        try await RepoPromptAuthorityHost.start(configuration: configuration)
    }

    static func startDirectHeadless(
        configuration: AuthorityHostConfiguration,
        runtime: MCPDomainRuntime
    ) async throws -> RepoPromptAuthorityHost {
        let host = try await start(configuration: configuration)
        do {
            try await runtime.start()
            try await host.installDirectHeadlessRuntime(runtime)
            return host
        } catch {
            _ = await host.shutdown(reason: "direct_headless_start_failed", deadline: .seconds(5))
            throw error
        }
    }
}
