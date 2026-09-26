import Foundation

// SEARCH-HELPER: codex quota service, account rate limits, observe-only, opt-in, no polling
//
// Account-scoped Codex usage quota service.
//
// Independence from Agent Mode is the point of this type: it uses its own non-agent
// app-server client, so a quota reading never requires — and never creates — a conversation,
// thread, or Agent Mode session. Because it owns its client, its notification stream is also
// free of the thread-ID guard that `CodexNativeSessionController` applies to session-scoped
// notifications, which would otherwise drop account-scoped notifications outright.
//
// Cost discipline:
//  - Nothing starts unless the feature is explicitly enabled AND something is observing.
//  - There is no timer and no polling loop. Refresh is notification-driven, plus bounded
//    lifecycle triggers (first observer, explicit user refresh, foreground after a gap).
//  - Reads are single-flighted; a read already in flight is awaited rather than duplicated.
//  - Publication is equality-gated: an unchanged merged snapshot publishes nothing.
//
// This service is observe-only. It must not be consulted by routing or model selection.

/// Minimal transport surface required for quota reads, so tests can substitute a fake.
protocol CodexQuotaAppServerClient: Sendable {
    func startIfNeeded() async throws
    func subscribeNotifications() async -> AsyncStream<CodexAppServerClient.Notification>
    func request(method: String, params: [String: Any]?, timeout: TimeInterval?) async throws -> [String: Any]
    func stop() async
}

extension CodexAppServerClient: CodexQuotaAppServerClient {}

/// Observable status of the Codex quota feature. Small, immutable, and `Equatable` so the
/// UI layer can equality-gate publication.
enum CodexQuotaStatus: Equatable {
    /// Feature is off. No client, process, subscription, or polling exists.
    case disabled
    /// Enabled, but nothing has been observed yet. Never rendered as a zero or a full bar.
    case idle
    case loading
    case loaded(ProviderQuotaSnapshot)
    /// Provider could not report. Carries a user-safe reason with no account values.
    case unavailable(reason: String)
}

actor CodexProviderQuotaService {
    static let shared = CodexProviderQuotaService(
        clientFactory: { CodexProviderHelpers.makeOwnedNonAgentAppServerClient() },
        accountIDProvider: { await CodexManagedAuthRecoveryService.shared.managedAccountSnapshot()?.accountID }
    )

    /// Minimum gap before a foreground trigger is allowed to spend a read.
    static let foregroundRefreshMinimumGap: TimeInterval = 5 * 60

    private let clientFactory: @Sendable () -> any CodexQuotaAppServerClient
    private let accountIDProvider: @Sendable () async -> String?
    private let requestTimeout: TimeInterval
    private let now: @Sendable () -> Date

    /// Identifies one read so a late completion cannot clear a newer read's registration.
    private struct InFlightRead {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var isEnabled = false
    private var client: (any CodexQuotaAppServerClient)?
    private var notificationTask: Task<Void, Never>?
    private var primingTask: Task<Void, Never>?
    private var inFlightRead: InFlightRead?
    /// Bumped by every teardown. A read that spans a teardown is stale on completion and
    /// must not adopt, clear, or leak state belonging to the transport that replaced it.
    private var transportGeneration: UInt64 = 0
    private var snapshot: ProviderQuotaSnapshot?
    private var status: CodexQuotaStatus = .disabled
    private var continuations: [UUID: AsyncStream<CodexQuotaStatus>.Continuation] = [:]
    private var lastReadStartedAt: Date?
    #if DEBUG
        private var readCount = 0
        private var clientStartCount = 0
    #endif

    init(
        clientFactory: @escaping @Sendable () -> any CodexQuotaAppServerClient,
        accountIDProvider: @escaping @Sendable () async -> String?,
        requestTimeout: TimeInterval = 20,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clientFactory = clientFactory
        self.accountIDProvider = accountIDProvider
        self.requestTimeout = requestTimeout
        self.now = now
    }

    // MARK: - Observation

    /// Subscribe to status updates.
    ///
    /// The current status is yielded immediately. The transport is only started once the
    /// feature is enabled and at least one observer exists.
    func subscribe() -> AsyncStream<CodexQuotaStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CodexQuotaStatus>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        startIfPossible()
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        continuations[id] = nil
        // No observation means no reason to hold a process open.
        if continuations.isEmpty {
            teardownTransport()
        }
    }

    // MARK: - Lifecycle triggers

    /// Applies the opt-in setting. Disabling tears down the client, process, and
    /// subscription, and discards the snapshot.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            publish(.idle)
            startIfPossible()
        } else {
            snapshot = nil
            lastReadStartedAt = nil
            teardownTransport()
            publish(.disabled)
        }
    }

    /// Explicit user refresh.
    ///
    /// Requires a live observer: a refresh raced against surface teardown must not construct
    /// or retain a transport that nothing is watching and nothing will later stop.
    func refreshNow() async {
        guard isEnabled, !continuations.isEmpty else { return }
        // A previously failed notification loop is re-established here rather than by a timer.
        startIfPossible()
        await performRead()
    }

    /// Bounded foreground trigger: spends a read only after a meaningful gap.
    func refreshOnForeground() async {
        guard isEnabled, !continuations.isEmpty else { return }
        if let lastReadStartedAt,
           now().timeIntervalSince(lastReadStartedAt) < Self.foregroundRefreshMinimumGap
        {
            return
        }
        // An ended notification stream discards its client. Foreground recovery must restore
        // push observation as well as perform one read, otherwise the replacement client
        // becomes read-only until another explicit refresh or surface reactivation.
        startIfPossible()
        await performRead()
    }

    /// Account switch or sign-out. The prior account's snapshot is discarded rather than
    /// migrated, and the transport is torn down.
    func handleSignOutOrAccountChange() {
        snapshot = nil
        lastReadStartedAt = nil
        teardownTransport()
        publish(isEnabled ? .idle : .disabled)
    }

    /// Restarts observation after a managed-auth transition only when the feature is still
    /// enabled and a UI subscriber is still alive. This deliberately does not create a
    /// background process for an unobserved settings surface.
    func resumeAfterManagedAuthentication() {
        startIfPossible()
    }

    /// App-termination fence. The persisted preference is owned by settings; this only stops
    /// the in-memory service and its owned app-server process.
    func shutdown() {
        isEnabled = false
        snapshot = nil
        lastReadStartedAt = nil
        teardownTransport()
        publish(.disabled)
    }

    // MARK: - Transport

    private func startIfPossible() {
        guard isEnabled, !continuations.isEmpty else { return }
        guard notificationTask == nil else { return }

        let client = client ?? clientFactory()
        self.client = client

        // Subscribe before priming so an update arriving between transport start and the
        // first read is not lost.
        notificationTask = Task { [weak self] in
            guard let self else { return }
            await runNotificationLoop(client: client)
        }
        let generation = transportGeneration
        primingTask = Task { [weak self] in
            guard let self else { return }
            await performRead(expectedGeneration: generation)
            await finishPrimingRead(generation: generation)
        }
    }

    private func finishPrimingRead(generation: UInt64) {
        guard transportGeneration == generation else { return }
        primingTask = nil
    }

    private func runNotificationLoop(client: any CodexQuotaAppServerClient) async {
        do {
            try await client.startIfNeeded()
        } catch {
            handleTransportFailure(error, generation: transportGeneration)
            await discardNotificationClient(client)
            return
        }
        #if DEBUG
            clientStartCount += 1
        #endif
        let stream = await client.subscribeNotifications()
        for await notification in stream {
            if Task.isCancelled { return }
            guard notification.method == CodexProviderQuotaMapper.updatedNotificationMethod else { continue }
            await ingestNotification(notification)
        }
        await discardNotificationClient(client)
    }

    /// Drops an unexpectedly terminated transport rather than retaining a potentially sticky
    /// failed client. A later explicit/lifecycle trigger creates a fresh isolated client;
    /// nothing retries autonomously, so this cannot become a polling loop.
    private func discardNotificationClient(_ client: any CodexQuotaAppServerClient) async {
        guard !Task.isCancelled else { return }
        // Retiring this transport invalidates any read still riding on it.
        transportGeneration &+= 1
        notificationTask = nil
        primingTask?.cancel()
        primingTask = nil
        self.client = nil
        await client.stop()
    }

    private func ingestNotification(_ notification: CodexAppServerClient.Notification) async {
        guard isEnabled else { return }
        let generation = transportGeneration
        let accountID = await accountIDProvider()
        // `accountIDProvider` suspends; a teardown may have landed meanwhile.
        guard isEnabled, transportGeneration == generation else { return }
        guard let delta = CodexProviderQuotaMapper.mapUpdatedNotification(
            params: notification.params,
            fallbackAccountID: accountID,
            observedAt: now()
        ) else { return }
        apply(delta)
    }

    private func teardownTransport() {
        transportGeneration &+= 1
        notificationTask?.cancel()
        notificationTask = nil
        primingTask?.cancel()
        primingTask = nil
        inFlightRead?.task.cancel()
        inFlightRead = nil
        let client = client
        self.client = nil
        guard let client else { return }
        Task { await client.stop() }
    }

    // MARK: - Reads

    /// Issues one account read.
    ///
    /// Every caller requires a live observer. An unobserved read would construct a transport
    /// that no `removeSubscriber` teardown will ever reclaim, so the observer check is the
    /// single admission point rather than a per-caller decision.
    private func performRead(expectedGeneration: UInt64? = nil) async {
        guard !Task.isCancelled, isEnabled, !continuations.isEmpty else { return }
        if let expectedGeneration, expectedGeneration != transportGeneration { return }
        if let inFlightRead {
            // Single-flight: join the in-flight read instead of issuing a duplicate.
            await inFlightRead.task.value
            return
        }

        if snapshot == nil {
            publish(.loading)
        }
        lastReadStartedAt = now()

        let generation = transportGeneration
        let installedClientForThisRead = client == nil
        let readClient = client ?? clientFactory()
        client = readClient

        let readID = UUID()
        let task = Task { [weak self, requestTimeout] in
            guard let self else { return }
            do {
                try await readClient.startIfNeeded()
                try Task.checkCancellation()
                let response = try await readClient.request(
                    method: CodexProviderQuotaMapper.readMethod,
                    params: nil,
                    timeout: requestTimeout
                )
                await handleReadResponse(response, generation: generation)
            } catch {
                await handleTransportFailure(error, generation: generation)
            }
        }
        inFlightRead = InFlightRead(id: readID, task: task)
        #if DEBUG
            readCount += 1
        #endif
        await task.value

        // Only clear the registration this call created. After a teardown/restart the field
        // may already hold a newer read, and clearing it would unfence that read's
        // single-flight guarantee.
        if inFlightRead?.id == readID {
            inFlightRead = nil
        }

        // A teardown that interleaved with this read has already stopped whatever `client`
        // held at the time. If this read is the one that installed the transport, stop it
        // here too so an interleave cannot leave a live process behind. `stop()` is safe to
        // call on an already-stopped transport.
        if installedClientForThisRead, transportGeneration != generation {
            await readClient.stop()
        }
    }

    private func handleReadResponse(_ response: [String: Any], generation: UInt64) async {
        guard isEnabled, transportGeneration == generation else { return }
        let accountID = await accountIDProvider()
        // `accountIDProvider` suspends; re-check the fence before publishing.
        guard isEnabled, transportGeneration == generation else { return }
        guard let delta = CodexProviderQuotaMapper.mapReadResponse(
            response,
            fallbackAccountID: accountID,
            observedAt: now()
        ) else {
            publish(.unavailable(reason: "Codex did not report usage limits for this account."))
            return
        }
        apply(delta)
    }

    private func handleTransportFailure(_ error: Error, generation: UInt64) {
        guard isEnabled, transportGeneration == generation else { return }
        // Keep a previously observed snapshot; it becomes stale via its own horizon rather
        // than being replaced by an error state.
        if snapshot == nil {
            publish(.unavailable(reason: Self.userSafeFailureReason(error)))
        }
    }

    /// Failure text must never carry account values. Transport errors are reduced to a
    /// generic, user-safe sentence.
    static func userSafeFailureReason(_ error: Error) -> String {
        if error is CancellationError {
            return "Usage lookup was cancelled."
        }
        return "Usage limits are not available right now."
    }

    private func apply(_ delta: ProviderQuotaSnapshotDelta) {
        switch ProviderQuotaMerge.apply(delta, to: snapshot) {
        case .accountMismatch:
            // The reading belongs to a different account: discard the old one entirely and
            // start from this delta rather than merging across accounts.
            if case let .merged(fresh) = ProviderQuotaMerge.apply(delta, to: nil) {
                snapshot = fresh
                publish(.loaded(fresh))
            }
        case let .merged(merged):
            snapshot = merged
            publish(.loaded(merged))
        }
    }

    // MARK: - Publication

    /// Equality-gated: an unchanged status publishes nothing, so observers never see a
    /// redundant update.
    private func publish(_ newStatus: CodexQuotaStatus) {
        guard newStatus != status else { return }
        status = newStatus
        for continuation in continuations.values {
            continuation.yield(newStatus)
        }
    }

    #if DEBUG
        func test_status() -> CodexQuotaStatus {
            status
        }

        func test_readCount() -> Int {
            readCount
        }

        func test_clientStartCount() -> Int {
            clientStartCount
        }

        func test_hasTransport() -> Bool {
            client != nil
        }

        func test_subscriberCount() -> Int {
            continuations.count
        }

        func test_transportGeneration() -> UInt64 {
            transportGeneration
        }

        func test_hasInFlightRead() -> Bool {
            inFlightRead != nil
        }
    #endif
}
