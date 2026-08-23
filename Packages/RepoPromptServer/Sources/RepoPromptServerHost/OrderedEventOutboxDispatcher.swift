import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptRuntimeModel
import RepoPromptServicePersistence

public struct OrderedEventOutboxDispatcherSnapshot: Sendable, Equatable {
    public let running: Bool
    public let lastDispatchedCursor: ServiceCursor?
    public let consecutiveFailures: Int64
    public let lastDiagnosticCode: String?
    public let pendingCount: Int64
    public let oldestPendingAgeSeconds: Double?
}

public struct OrderedEventOutboxDispatcherHooks: Sendable {
    public let afterPublishBeforeDispatchedMarker: @Sendable (EventEnvelope) async throws -> Void

    public init(
        afterPublishBeforeDispatchedMarker: @escaping @Sendable (EventEnvelope) async throws -> Void = { _ in }
    ) {
        self.afterPublishBeforeDispatchedMarker = afterPublishBeforeDispatchedMarker
    }

    public static let none = OrderedEventOutboxDispatcherHooks()
}

/// The only live publisher for one leased authority namespace. It deliberately
/// reads and marks one global sequence at a time: an unresolved N is never
/// bypassed by N+1. Publication is at-least-once across the publish/mark crash
/// window; every subscriber is cursor-gated by `ServiceEventHub`.
public actor OrderedEventOutboxDispatcher {
    private let store: SQLiteServiceStore
    private let hub: ServiceEventHub
    private let hooks: OrderedEventOutboxDispatcherHooks
    private let batchLimit: Int
    private var task: Task<Void, Never>?
    private var stopping = false
    private var lastDispatchedCursor: ServiceCursor?
    private var consecutiveFailures: Int64 = 0
    private var lastDiagnosticCode: String?

    public init(
        store: SQLiteServiceStore,
        hub: ServiceEventHub,
        batchLimit: Int = 128,
        hooks: OrderedEventOutboxDispatcherHooks = .none
    ) {
        self.store = store
        self.hub = hub
        self.batchLimit = max(1, min(batchLimit, 1_024))
        self.hooks = hooks
    }

    public func drainStartupWatermark(_ watermark: ServiceCursor) async throws {
        while !Task.isCancelled {
            guard let pending = try await store.nextPendingEventOutboxRecord(
                maximumGlobalSequence: watermark.globalSequence
            ) else { return }
            guard pending.event.cursor.storeID == watermark.storeID else {
                throw ServiceAPIError(
                    code: .cursorExpired,
                    message: "Outbox startup watermark store identity changed",
                    cursor: watermark
                )
            }
            try await dispatch(pending)
        }
        throw CancellationError()
    }

    public func start() {
        guard task == nil else { return }
        stopping = false
        task = Task { await self.run() }
    }

    public func stop(drain: Bool = true) async {
        stopping = true
        let worker = task
        worker?.cancel()
        await worker?.value
        task = nil
        if drain {
            while !Task.isCancelled {
                do {
                    guard let pending = try await store.nextPendingEventOutboxRecord() else { break }
                    try await dispatch(pending)
                } catch {
                    break
                }
            }
        }
    }

    public func snapshot(now: Date = Date()) async -> OrderedEventOutboxDispatcherSnapshot {
        let outbox = try? await store.eventOutboxOperationalSnapshot(now: now)
        return OrderedEventOutboxDispatcherSnapshot(
            running: task != nil && !stopping,
            lastDispatchedCursor: lastDispatchedCursor,
            consecutiveFailures: consecutiveFailures,
            lastDiagnosticCode: lastDiagnosticCode,
            pendingCount: outbox?.pendingCount ?? -1,
            oldestPendingAgeSeconds: outbox?.oldestPendingAgeSeconds
        )
    }

    private func run() async {
        while !Task.isCancelled, !stopping {
            do {
                var processed = 0
                while processed < batchLimit, !Task.isCancelled, !stopping,
                      let pending = try await store.nextPendingEventOutboxRecord()
                {
                    try await dispatch(pending)
                    processed += 1
                }
                if processed == 0 { try await Task.sleep(for: .milliseconds(25)) }
                await Task.yield()
            } catch is CancellationError {
                break
            } catch {
                consecutiveFailures += 1
                let code = (error as? ServiceAPIError)?.code.rawValue ?? "event_outbox_dispatch_failed"
                lastDiagnosticCode = code
                try? await Task.sleep(for: .milliseconds(min(1_000, 25 * Int(consecutiveFailures))))
            }
        }
    }

    private func dispatch(_ pending: PendingEventOutboxRecord) async throws {
        do {
            await hub.publish(pending.event)
            try await hooks.afterPublishBeforeDispatchedMarker(pending.event)
            try await store.markEventOutboxDispatched(pending.event.cursor)
            lastDispatchedCursor = pending.event.cursor
            consecutiveFailures = 0
            lastDiagnosticCode = nil
        } catch {
            let code = (error as? ServiceAPIError)?.code.rawValue ?? "event_outbox_dispatch_failed"
            try? await store.recordEventOutboxDispatchFailure(pending.event.cursor, diagnosticCode: code)
            throw error
        }
    }
}
