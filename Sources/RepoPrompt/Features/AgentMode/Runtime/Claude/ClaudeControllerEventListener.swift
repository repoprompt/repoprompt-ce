import Foundation

typealias ClaudeAttemptEventReservation = (listener: ClaudeControllerEventListener, subscription: ClaudeAttemptEventSubscription)

enum ClaudeAttemptEvent {
    case native(NativeAgentRuntimeEvent)
    case steeringReleased(protectedIDs: Set<UUID>, inputWasAttempted: Bool)
    case settlementRecheck
}

/// One recoverable inbox per attempt. Cancelling its waiter never cancels the controller iterator.
@MainActor
final class ClaudeAttemptEventSubscription {
    private var events: [ClaudeAttemptEvent] = []
    private var head = 0
    private var waiter: CheckedContinuation<ClaudeAttemptEvent?, Never>?
    private(set) var isClosed = false
    private var isFinished = false
    private var inputHandoffs = 0
    #if DEBUG
        var test_onDelivery: ((NativeAgentRuntimeEvent) -> Void)?
    #endif

    func append(_ event: ClaudeAttemptEvent) {
        guard !isClosed else { return }
        if let waiter, inputHandoffs == 0 {
            self.waiter = nil
            #if DEBUG
                if case let .native(native) = event { test_onDelivery?(native) }
            #endif
            waiter.resume(returning: event)
        } else {
            events.append(event)
        }
    }

    func next() async -> ClaudeAttemptEvent? {
        guard !Task.isCancelled, !isClosed else { return nil }
        if inputHandoffs == 0, head < events.count {
            let event = events[head]
            head += 1
            if head >= 256, head >= events.count / 2 {
                events.removeFirst(head)
                head = 0
            }
            #if DEBUG
                if case let .native(native) = event { test_onDelivery?(native) }
            #endif
            return event
        }
        guard !isFinished || inputHandoffs > 0 else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: {
            Task { @MainActor in
                self.waiter?.resume(returning: nil)
                self.waiter = nil
            }
        }
    }

    var pendingApprovalIDs: [String] {
        events[head...].compactMap { event in
            guard case let .native(.approvalRequest(request)) = event,
                  case let .claudeControl(id) = request.requestID else { return nil }
            return id
        }
    }

    func cancelPendingApproval(_ id: String) {
        for index in head ..< events.count {
            guard case let .native(.approvalRequest(request)) = events[index],
                  request.requestID == .claudeControl(id) else { continue }
            events[index] = .native(.approvalCancelled(requestID: id))
        }
    }

    func beginInputHandoff() {
        inputHandoffs += 1
    }

    func endInputHandoff() {
        inputHandoffs -= 1
        guard inputHandoffs == 0, !isClosed, let waiter else { return }
        self.waiter = nil
        if head < events.count {
            let event = events[head]
            head += 1
            #if DEBUG
                if case let .native(native) = event { test_onDelivery?(native) }
            #endif
            waiter.resume(returning: event)
        } else if isFinished {
            waiter.resume(returning: nil)
        } else {
            self.waiter = waiter
        }
    }

    func finish() {
        isFinished = true
        guard inputHandoffs == 0 else { return }
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func attachTransport() {
        guard !isClosed else { return }
        isFinished = false
    }

    func discardPending() {
        events.removeAll()
        head = 0
    }

    @discardableResult
    func close() -> [ClaudeAttemptEvent] {
        guard !isClosed else { return [] }
        isClosed = true
        let tail = Array(events[head...])
        events.removeAll()
        head = 0
        waiter?.resume(returning: nil)
        waiter = nil
        return tail
    }
}

/// The only controller-stream iterator. Ownership changes return unread live events here,
/// before terminal publication suspends; idle history is never retained.
@MainActor
final class ClaudeControllerEventListener {
    var adoptionTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var installationID = UUID()
    private var controllerID: ObjectIdentifier?
    private var generation: UInt64?
    private(set) var subscription: ClaudeAttemptEventSubscription?
    private(set) var pendingProviderTurnID: UUID?
    private var handoff: [NativeAgentRuntimeEvent] = []
    private(set) var providerTurnIDs: Set<UUID> = []
    var runtimeFailure: String?
    var installationWitness: UUID {
        installationID
    }

    var onProviderTurn: ((UUID) -> Void)?
    var onIdleEvent: ((NativeAgentRuntimeEvent) -> Void)?
    var onStreamEnd: ((UUID) async -> Void)?
    var onBusyChanged: (() -> Void)?
    private var publishedBusy = false
    private var publishingSubscription: ObjectIdentifier?
    private var publicationWaiters: [CheckedContinuation<Void, Never>] = []
    var isCurrent: () -> Bool

    init(isCurrent: @escaping () -> Bool) {
        self.isCurrent = isCurrent
    }

    var isBusy: Bool {
        pendingProviderTurnID != nil || !providerTurnIDs.isEmpty
    }

    #if DEBUG
        var test_onDelivery: ((NativeAgentRuntimeEvent) -> Void)?
        var test_onReceive: ((NativeAgentRuntimeEvent) -> Void)?
        var test_handoffCount: Int {
            handoff.count
        }
    #endif

    func hasInstallation(_ id: UUID) -> Bool {
        installationID == id
    }

    func awaitTerminalPublication() async {
        guard publishingSubscription != nil else { return }
        await withCheckedContinuation { publicationWaiters.append($0) }
    }

    func terminalPublished(for inbox: ClaudeAttemptEventSubscription) {
        guard publishingSubscription == ObjectIdentifier(inbox) else { return }
        publishingSubscription = nil
        let waiters = publicationWaiters
        publicationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func matches(controller: any NativeAgentRuntimeControlling, handle: NativeAgentRuntimeEventStreamHandle) -> Bool {
        controllerID == ObjectIdentifier(controller) && generation == handle.generation
    }

    func install(controller: any NativeAgentRuntimeControlling, handle: NativeAgentRuntimeEventStreamHandle) {
        let identity = ObjectIdentifier(controller)
        guard controllerID != identity || generation != handle.generation else { return }
        task?.cancel()
        controllerID = identity
        generation = handle.generation
        subscription?.attachTransport()
        runtimeFailure = nil
        let installation = UUID()
        installationID = installation
        task = Task { [weak self] in
            for await event in handle.stream {
                guard let self, !Task.isCancelled, installationID == installation, isCurrent() else { return }
                receive(event)
            }
            guard let self, !Task.isCancelled, installationID == installation, isCurrent() else { return }
            await onStreamEnd?(installation)
        }
    }

    func reserve() -> ClaudeAttemptEventSubscription? {
        guard subscription == nil else { return nil }
        let inbox = ClaudeAttemptEventSubscription()
        #if DEBUG
            inbox.test_onDelivery = { [weak self] event in self?.test_onDelivery?(event) }
        #endif
        subscription = inbox
        if pendingProviderTurnID != nil {
            pendingProviderTurnID = nil
            let events = handoff
            handoff.removeAll()
            for event in events {
                inbox.append(.native(event))
            }
            publishBusyIfChanged()
        }
        return inbox
    }

    func close(_ inbox: ClaudeAttemptEventSubscription, returningTail: Bool) {
        guard subscription === inbox else { inbox.close()
            return
        }
        subscription = nil
        if returningTail, isCurrent() { publishingSubscription = ObjectIdentifier(inbox) }
        let tail = inbox.close()
        if returningTail, isCurrent() {
            for item in tail {
                if case let .native(event) = item { route(event) }
            }
        }
    }

    func detachTransport() {
        subscription?.discardPending()
        handoff.removeAll()
        pendingProviderTurnID = nil
        providerTurnIDs.removeAll()
        publishBusyIfChanged()
        installationID = UUID()
        task?.cancel()
        task = nil
        controllerID = nil
        generation = nil
    }

    func retire() {
        adoptionTask?.cancel()
        adoptionTask = nil
        installationID = UUID()
        task?.cancel()
        task = nil
        subscription?.close()
        subscription = nil
        publishingSubscription = nil
        let waiters = publicationWaiters
        publicationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        handoff.removeAll()
        pendingProviderTurnID = nil
        providerTurnIDs.removeAll()
        publishBusyIfChanged()
    }

    func receive(_ event: NativeAgentRuntimeEvent) {
        guard isCurrent() else { return }
        #if DEBUG
            test_onReceive?(event)
        #endif
        switch event {
        case let .providerTurnStarted(id): providerTurnIDs.insert(id)
        case let .turnsCompleted(ids, _): providerTurnIDs.subtract(ids)
        case let .turnCompleted(id, _): providerTurnIDs.remove(id)
        default: break
        }
        route(event)
        publishBusyIfChanged()
    }

    private func publishBusyIfChanged() {
        guard publishedBusy != isBusy else { return }
        publishedBusy = isBusy
        onBusyChanged?()
    }

    var pendingApprovalIDs: [String] {
        (subscription?.pendingApprovalIDs ?? []) + handoff.compactMap { event in
            guard case let .approvalRequest(request) = event,
                  case let .claudeControl(id) = request.requestID else { return nil }
            return id
        }
    }

    private func route(_ event: NativeAgentRuntimeEvent) {
        if let subscription {
            subscription.append(.native(event))
        } else if pendingProviderTurnID != nil {
            handoff.append(event)
        } else if case let .providerTurnStarted(id) = event {
            pendingProviderTurnID = id
            handoff.append(event)
            onProviderTurn?(id)
        } else {
            onIdleEvent?(event)
        }
    }
}
