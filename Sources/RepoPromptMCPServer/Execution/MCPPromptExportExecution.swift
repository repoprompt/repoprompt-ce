// Exported Swift 5 package values need explicit cross-module Sendable contracts.
// swiftformat:disable redundantSendable
import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared

package struct PromptExportExecutionEnvelope: Sendable {
    package let admissionDeadline: MCPDomainAdmissionDeadline
    package let cleanupNotAfter: Duration
    package let responseDeliveryDeadline: MCPExportResponseDeliveryDeadlineRegistry.Deadline
    package let cancellationOrigin: MCPToolExecutionCancellationOrigin

    package init(
        admissionDeadline: MCPDomainAdmissionDeadline,
        cleanupNotAfter: Duration,
        responseDeliveryDeadline: MCPExportResponseDeliveryDeadlineRegistry.Deadline,
        cancellationOrigin: MCPToolExecutionCancellationOrigin
    ) {
        self.admissionDeadline = admissionDeadline
        self.cleanupNotAfter = cleanupNotAfter
        self.responseDeliveryDeadline = responseDeliveryDeadline
        self.cancellationOrigin = cancellationOrigin
    }
}

/// Transfers the host's synchronous provider-entry instant to the async watchdog owner.
/// The watchdog's initial clock read and deadline sleep are rebased to that instant so
/// admission consumes none of the provider's declared execution budget.
package final class PromptExportProviderEntryBridge: @unchecked Sendable {
    package struct ProviderEntry {
        package let watchdogEnvironment: MCPToolExecutionWatchdogEnvironment
        package let cleanupNotAfter: Duration?
    }

    package enum InitialEvent {
        case providerEntered(ProviderEntry)
        case providerEntryRejected
        case hostCompleted
        case cancelled
    }

    private final class RebasedWatchdogTiming: @unchecked Sendable {
        private let lock = NSLock()
        private var providerEntryForInitialRead: Duration?
        private var deadlineNotAfterForInitialSleep: Duration?
        private let baseNow: @Sendable () -> Duration
        private let baseSleep: @Sendable (Duration) async throws -> Void

        init(
            providerEntry: Duration,
            executionDeadline: Duration,
            now: @escaping @Sendable () -> Duration,
            sleep: @escaping @Sendable (Duration) async throws -> Void
        ) {
            providerEntryForInitialRead = providerEntry
            deadlineNotAfterForInitialSleep = providerEntry + executionDeadline
            baseNow = now
            baseSleep = sleep
        }

        func read() -> Duration {
            lock.lock()
            if let providerEntry = providerEntryForInitialRead {
                providerEntryForInitialRead = nil
                lock.unlock()
                return providerEntry
            }
            lock.unlock()
            return baseNow()
        }

        func sleep(_ duration: Duration) async throws {
            lock.lock()
            let deadlineNotAfter = deadlineNotAfterForInitialSleep
            deadlineNotAfterForInitialSleep = nil
            lock.unlock()

            guard let deadlineNotAfter else {
                try await baseSleep(duration)
                return
            }
            // Duration-based sleep must subtract watchdog installation time to preserve
            // the provider-entry instant as the absolute execution deadline origin.
            let remaining = deadlineNotAfter - baseNow()
            try await baseSleep(remaining > .zero ? remaining : .zero)
        }
    }

    private let lock = NSLock()
    private let environment: MCPToolExecutionWatchdogEnvironment
    private let executionDeadline: Duration
    private let cancellationGrace: Duration
    private let outerCleanupNotAfter: Duration?
    private var initialEvent: InitialEvent?
    private var hostCompletionInstant: Duration?
    private var waiter: CheckedContinuation<InitialEvent, Never>?

    package init(
        environment: MCPToolExecutionWatchdogEnvironment,
        executionDeadline: Duration,
        cancellationGrace: Duration,
        outerCleanupNotAfter: Duration?
    ) {
        self.environment = environment
        self.executionDeadline = executionDeadline
        self.cancellationGrace = cancellationGrace
        self.outerCleanupNotAfter = outerCleanupNotAfter
    }

    package func providerWillEnter() throws {
        let providerEntry = environment.now()
        let requestedCleanupNotAfter = providerEntry + executionDeadline + cancellationGrace
        if let outerCleanupNotAfter, requestedCleanupNotAfter > outerCleanupNotAfter {
            guard resolve(.providerEntryRejected) else { throw CancellationError() }
            throw MCPToolExecutionWatchdogError.admissionEnvelopeExpired
        }
        let cleanupNotAfter = outerCleanupNotAfter.map { _ in requestedCleanupNotAfter }

        let rebasedTiming = RebasedWatchdogTiming(
            providerEntry: providerEntry,
            executionDeadline: executionDeadline,
            now: environment.now,
            sleep: environment.sleep
        )
        let watchdogEnvironment = MCPToolExecutionWatchdogEnvironment(
            now: { rebasedTiming.read() },
            sleep: { try await rebasedTiming.sleep($0) },
            eventDidProduce: environment.eventDidProduce,
            beforeEventConsumption: environment.beforeEventConsumption,
            beforeCleanupGraceTaskRegistration: environment.beforeCleanupGraceTaskRegistration,
            beforeDetachActivation: environment.beforeDetachActivation
        )
        guard resolve(.providerEntered(ProviderEntry(
            watchdogEnvironment: watchdogEnvironment,
            cleanupNotAfter: cleanupNotAfter
        ))) else {
            throw CancellationError()
        }
    }

    package func hostDidComplete(at instant: Duration) {
        lock.lock()
        precondition(hostCompletionInstant == nil, "Prompt export host completed more than once")
        hostCompletionInstant = instant
        lock.unlock()
        _ = resolve(.hostCompleted)
    }

    package func recordedHostCompletionInstant() -> Duration? {
        lock.lock()
        defer { lock.unlock() }
        return hostCompletionInstant
    }

    package func cancel() {
        _ = resolve(.cancelled)
    }

    package func waitForInitialEvent() async -> InitialEvent {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let initialEvent {
                lock.unlock()
                continuation.resume(returning: initialEvent)
                return
            }
            precondition(waiter == nil, "Prompt export provider-entry bridge has multiple waiters")
            waiter = continuation
            lock.unlock()
        }
    }

    @discardableResult
    private func resolve(_ event: InitialEvent) -> Bool {
        lock.lock()
        guard initialEvent == nil else {
            lock.unlock()
            return false
        }
        initialEvent = event
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: event)
        return true
    }
}

package final class PromptExportMutationSettlementObservation: @unchecked Sendable {
    package init() {}
    private let lock = NSLock()
    private var settlement: DomainProtectedMutationSettlement?

    package func record(_ settlement: DomainProtectedMutationSettlement) {
        lock.lock()
        if self.settlement == nil || self.settlement?.state == .unknown {
            self.settlement = settlement
        }
        lock.unlock()
    }

    package func snapshot() -> DomainProtectedMutationSettlement? {
        lock.lock()
        defer { lock.unlock() }
        return settlement
    }

    package func errorMetadata(toolName: String) -> [String: Value] {
        let settlement = snapshot()
        var metadata: [String: Value] = [
            "mutation_state": .string(settlement?.state.rawValue ?? "unknown"),
            "retryable": .bool(settlement?.state == .notApplied),
            "tool": .string(toolName)
        ]
        if let settlement {
            metadata["operation_id"] = .string(settlement.operationID)
        }
        return metadata
    }
}

package final class PromptExportPublicationAuthorityObservation: @unchecked Sendable {
    package init() {}
    private let lock = NSLock()
    private var authorization: MCPToolDispatchAuthorization?

    package func bind(_ authorization: MCPToolDispatchAuthorization) {
        lock.lock()
        self.authorization = authorization
        lock.unlock()
    }

    package func snapshot() -> MCPToolDispatchAuthorization? {
        lock.lock()
        defer { lock.unlock() }
        return authorization
    }
}

package struct PromptExportPublicationAuthorityLost: Error {}
