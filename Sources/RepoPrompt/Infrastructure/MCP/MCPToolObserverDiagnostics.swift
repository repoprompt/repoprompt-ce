import Foundation

struct MCPToolObserverAttribution: Equatable {
    let correlationPath: String
    let scannedItemCount: Int
}

#if DEBUG
    final class MCPToolObserverAttributionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var attribution: MCPToolObserverAttribution?

        func record(correlationPath: String, scannedItemCount: Int) {
            lock.lock()
            attribution = MCPToolObserverAttribution(
                correlationPath: correlationPath,
                scannedItemCount: max(0, scannedItemCount)
            )
            lock.unlock()
        }

        func snapshot() -> MCPToolObserverAttribution? {
            lock.lock()
            defer { lock.unlock() }
            return attribution
        }
    }

    enum MCPToolObserverAttributionContext {
        @TaskLocal static var recorder: MCPToolObserverAttributionRecorder?

        static func record(correlationPath: String, scannedItemCount: Int) {
            recorder?.record(
                correlationPath: correlationPath,
                scannedItemCount: scannedItemCount
            )
        }
    }
#else
    enum MCPToolObserverAttributionContext {
        static func record(correlationPath _: String, scannedItemCount _: Int) {}
    }
#endif
