import Foundation

/// A neutral cancellation token for synchronous event observations.
///
/// Cancellation is idempotent and also runs on deinitialization, matching the
/// lifetime behavior of the Combine token this replaces at the Core boundary.
package final class RuntimeObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    fileprivate init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    package func cancel() {
        lock.lock()
        let cancellation = cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }

    deinit {
        cancel()
    }
}

/// A small synchronous event stream used for ordered in-process Core ingress.
package struct OrderedEventStream<Event: Sendable>: @unchecked Sendable {
    fileprivate let subscribe: (@escaping (Event) -> Void) -> RuntimeObservation

    package func sink(receiveValue: @escaping (Event) -> Void) -> RuntimeObservation {
        subscribe(receiveValue)
    }
}

/// Lock-backed broadcaster whose sends preserve observer registration order.
/// Callbacks run synchronously on the sender before `send` returns.
package final class OrderedEventBroadcaster<Event: Sendable>: @unchecked Sendable {
    private final class Observer: @unchecked Sendable {
        let id: UUID
        private let lock = NSRecursiveLock()
        private var receiveValue: ((Event) -> Void)?

        init(id: UUID, receiveValue: @escaping (Event) -> Void) {
            self.id = id
            self.receiveValue = receiveValue
        }

        func offer(_ event: Event) {
            lock.lock()
            defer { lock.unlock() }
            receiveValue?(event)
        }

        func cancel() {
            lock.lock()
            receiveValue = nil
            lock.unlock()
        }
    }

    private let lock = NSLock()
    private let deliveryLock = NSRecursiveLock()
    private var observers: [Observer] = []

    package init() {}

    package func stream() -> OrderedEventStream<Event> {
        OrderedEventStream { [weak self] receiveValue in
            guard let self else { return RuntimeObservation(cancellation: {}) }
            return addObserver(receiveValue)
        }
    }

    package func send(_ event: Event) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        lock.lock()
        let currentObservers = observers
        lock.unlock()
        currentObservers.forEach { $0.offer(event) }
    }

    private func addObserver(_ receiveValue: @escaping (Event) -> Void) -> RuntimeObservation {
        let id = UUID()
        let observer = Observer(id: id, receiveValue: receiveValue)
        lock.lock()
        observers.append(observer)
        lock.unlock()
        return RuntimeObservation { [weak self, observer] in
            observer.cancel()
            self?.removeObserver(id: id)
        }
    }

    private func removeObserver(id: UUID) {
        lock.lock()
        observers.removeAll { $0.id == id }
        lock.unlock()
    }
}
