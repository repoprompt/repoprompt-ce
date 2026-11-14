import Foundation

/// Lock-backed lifecycle state for one-shot ACP headless providers.
///
/// The headless providers are plain classes used from stream producers, stream
/// termination handlers, and external cleanup owners. This helper keeps task and
/// controller teardown ownership serialized without making provider startup actor
/// isolated.
final class ACPHeadlessProviderLifecycle: @unchecked Sendable {
    struct ControllerHandle {
        let id: UUID
        let cancelAndShutdown: @Sendable () async -> Void
    }

    private enum DisposalTransition {
        case idle
        case wait
        case teardown(task: Task<Void, Never>?, handles: [ControllerHandle])
    }

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeStreamGeneration: UInt64?
    private var streamTask: Task<Void, Never>?
    private var controllerByGeneration: [UInt64: ControllerHandle] = [:]
    private var disposeInProgress = false
    private var disposeWaiters: [CheckedContinuation<Void, Never>] = []
    #if DEBUG
        private let testDidRegisterDisposalWaiter: (@Sendable () -> Void)?

        init(testDidRegisterDisposalWaiter: (@Sendable () -> Void)? = nil) {
            self.testDidRegisterDisposalWaiter = testDidRegisterDisposalWaiter
        }
    #else
        init() {}
    #endif

    func waitForDisposalIfNeeded() async {
        let shouldWait = lock.withLock { disposeInProgress }
        guard shouldWait else { return }

        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = lock.withLock {
                guard disposeInProgress else { return true }
                disposeWaiters.append(continuation)
                return false
            }

            if shouldResumeImmediately {
                continuation.resume()
            } else {
                #if DEBUG
                    testDidRegisterDisposalWaiter?()
                #endif
            }
        }
    }

    @discardableResult
    func startStreamTask(_ makeTask: (_ generation: UInt64) -> Task<Void, Never>) -> UInt64? {
        lock.lock()
        guard !disposeInProgress else {
            lock.unlock()
            return nil
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        streamTask?.cancel()
        activeStreamGeneration = generation
        streamTask = makeTask(generation)
        lock.unlock()
        return generation
    }

    @discardableResult
    func setActiveController(_ handle: ControllerHandle, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !disposeInProgress,
              activeStreamGeneration == generation
        else {
            return false
        }

        controllerByGeneration[generation] = handle
        return true
    }

    func clearActiveController(id: UUID, generation: UInt64) {
        lock.lock()
        if controllerByGeneration[generation]?.id == id {
            controllerByGeneration.removeValue(forKey: generation)
        }
        lock.unlock()
    }

    func clearStreamTask(generation: UInt64) {
        lock.lock()
        if activeStreamGeneration == generation {
            streamTask = nil
            activeStreamGeneration = nil
        }
        lock.unlock()
    }

    func dispose() async {
        let transition = lock.withLock { () -> DisposalTransition in
            if disposeInProgress {
                return .wait
            }

            let task = streamTask
            let handles = Array(controllerByGeneration.values)
            guard task != nil || !handles.isEmpty else {
                streamTask = nil
                activeStreamGeneration = nil
                controllerByGeneration.removeAll()
                return .idle
            }

            disposeInProgress = true
            streamTask = nil
            activeStreamGeneration = nil
            controllerByGeneration.removeAll()
            return .teardown(task: task, handles: handles)
        }

        switch transition {
        case .idle:
            return
        case .wait:
            await waitForDisposalIfNeeded()
        case let .teardown(task, handles):
            task?.cancel()
            for handle in handles {
                await handle.cancelAndShutdown()
            }

            let waiters = lock.withLock {
                disposeInProgress = false
                let waiters = disposeWaiters
                disposeWaiters.removeAll()
                return waiters
            }

            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}
