import Foundation

package final class FileSystemDeltaPublicationSubscription: @unchecked Sendable {
    private let cancellation: @Sendable () -> Void
    private let lock = NSLock()
    private var isCancelled = false

    package init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    package func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        lock.unlock()
        cancellation()
    }

    deinit {
        cancel()
    }
}

/// Single-consumer callback publication seam. Delivery is synchronous: `publish`
/// returns only after the subscriber has accepted or rejected the publication.
package final class FileSystemDeltaPublicationHub: @unchecked Sendable {
    package typealias Handler = @Sendable (FileSystemDeltaPublication) -> Bool

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var handler: Handler?

    package func subscribe(_ handler: @escaping Handler) -> FileSystemDeltaPublicationSubscription {
        lock.lock()
        generation &+= 1
        let subscriptionGeneration = generation
        self.handler = handler
        lock.unlock()
        return FileSystemDeltaPublicationSubscription { [weak self] in
            self?.cancel(generation: subscriptionGeneration)
        }
    }

    package func close() {
        lock.lock()
        generation &+= 1
        handler = nil
        lock.unlock()
    }

    @discardableResult
    package func publish(_ publication: FileSystemDeltaPublication) -> Bool {
        lock.lock()
        let current = handler
        lock.unlock()
        return current?(publication) ?? false
    }

    private func cancel(generation expectedGeneration: UInt64) {
        lock.lock()
        if generation == expectedGeneration {
            generation &+= 1
            handler = nil
        }
        lock.unlock()
    }
}
