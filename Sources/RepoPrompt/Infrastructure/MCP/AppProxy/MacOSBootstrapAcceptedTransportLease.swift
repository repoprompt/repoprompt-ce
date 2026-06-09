import Darwin
import Foundation
import RepoPromptCore
import RepoPromptPOSIXSupport

/// App-owned accepted-socket lease behind Core's opaque app-proxy transport contracts.
package final class MacOSBootstrapAcceptedTransportLease: MCPAppProxyAcceptedTransportLease, MCPAppProxyAcceptedTransport, @unchecked Sendable {
    private enum Ownership: Equatable {
        case listenerOwned
        case admissionReserved
        case listenerOwnedClosing
        case publishing
        case transferred
        case claimed
        case closed
    }

    package let fileDescriptor: Int32

    private let lock = NSLock()
    private var ownership: Ownership = .listenerOwned
    private var activeIOLeases = 0
    private var shutdownInProgress = false
    private var closeRequestedDuringPublication = false
    #if DEBUG
        private let debugBeforeInitiatingShutdown: (() -> Void)?
    #endif

    package init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        #if DEBUG
            debugBeforeInitiatingShutdown = nil
        #endif
    }

    #if DEBUG
        package init(fileDescriptor: Int32, debugBeforeInitiatingShutdown: @escaping () -> Void) {
            self.fileDescriptor = fileDescriptor
            self.debugBeforeInitiatingShutdown = debugBeforeInitiatingShutdown
        }
    #endif

    package var state: MCPAppProxyAcceptedTransportLeaseState {
        lock.lock()
        defer { lock.unlock() }
        switch ownership {
        case .listenerOwned:
            return .listenerOwned
        case .admissionReserved, .publishing:
            return .admissionReserved
        case .transferred, .claimed:
            return .transferred
        case .listenerOwnedClosing, .closed:
            return .closed
        }
    }

    package func isListenerOwnedOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch ownership {
        case .listenerOwned, .admissionReserved:
            return true
        case .listenerOwnedClosing, .publishing, .transferred, .claimed, .closed:
            return false
        }
    }

    /// Runs one blocking syscall while preventing descriptor close/reuse underneath it.
    package func withListenerOwnedIOLease<T>(_ body: (Int32) -> T) -> T? {
        lock.lock()
        switch ownership {
        case .listenerOwned, .admissionReserved:
            activeIOLeases += 1
            lock.unlock()
        case .listenerOwnedClosing, .publishing, .transferred, .claimed, .closed:
            lock.unlock()
            return nil
        }

        let result = body(fileDescriptor)
        releaseIOLease()
        return result
    }

    package func reserveForAdmission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ownership == .listenerOwned else { return false }
        ownership = .admissionReserved
        return true
    }

    package func transfer(
        publish: @Sendable (any MCPAppProxyAcceptedTransport) -> Bool
    ) -> Bool {
        lock.lock()
        guard ownership == .admissionReserved, activeIOLeases == 0 else {
            lock.unlock()
            return false
        }
        ownership = .publishing
        closeRequestedDuringPublication = false
        lock.unlock()

        let wasPublished = publish(self)

        lock.lock()
        guard ownership == .publishing else {
            lock.unlock()
            return false
        }
        let shouldClose = !wasPublished || closeRequestedDuringPublication
        if shouldClose {
            ownership = .closed
        } else {
            ownership = .transferred
        }
        lock.unlock()

        if shouldClose {
            closeNativeTransport()
        }
        return wasPublished && !shouldClose
    }

    package func rollback() {
        close()
    }

    package func close() {
        lock.lock()
        switch ownership {
        case .listenerOwned, .admissionReserved:
            ownership = .listenerOwnedClosing
            shutdownInProgress = true
            lock.unlock()

            #if DEBUG
                debugBeforeInitiatingShutdown?()
            #endif
            POSIXDescriptorSupport.shutdownSocketReadWrite(fileDescriptor)

            lock.lock()
            shutdownInProgress = false
            let shouldClose = activeIOLeases == 0 && ownership == .listenerOwnedClosing
            if shouldClose {
                ownership = .closed
            }
            lock.unlock()

            if shouldClose {
                Darwin.close(fileDescriptor)
            }
        case .transferred:
            ownership = .closed
            lock.unlock()
            closeNativeTransport()
        case .publishing:
            closeRequestedDuringPublication = true
            lock.unlock()
        case .listenerOwnedClosing, .claimed, .closed:
            lock.unlock()
        }
    }

    /// Claims the native descriptor once, immediately before the existing app transport adopts it.
    package func claimConnectedFileDescriptor() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard ownership == .transferred else { return nil }
        ownership = .claimed
        return fileDescriptor
    }

    private func releaseIOLease() {
        lock.lock()
        activeIOLeases -= 1
        let shouldClose = activeIOLeases == 0
            && ownership == .listenerOwnedClosing
            && !shutdownInProgress
        if shouldClose {
            ownership = .closed
        }
        lock.unlock()

        if shouldClose {
            Darwin.close(fileDescriptor)
        }
    }

    private func closeNativeTransport() {
        POSIXDescriptorSupport.shutdownSocketReadWrite(fileDescriptor)
        Darwin.close(fileDescriptor)
    }
}
