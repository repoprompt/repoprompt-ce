import Dispatch
import Foundation

/// Optional observations only. Callbacks cannot grant file or root authority.
/// App diagnostics are adapted at composition; the library's default is inert.
package struct FileSystemRuntimeHooks {
    package let preferenceEnabled: @Sendable (String) -> Bool
    package let servicePublication: @Sendable (UUID, FileSystemDeltaPublicationSource, [FileSystemDelta]) -> Void
    package let readFileDiskReadRecorder: @Sendable () -> @Sendable (Int, Int) -> Void
    package let captureReadMetrics: @Sendable () -> FileSystemReadMetrics.Context?

    package init(
        preferenceEnabled: @escaping @Sendable (String) -> Bool = { _ in false },
        servicePublication: @escaping @Sendable (UUID, FileSystemDeltaPublicationSource, [FileSystemDelta]) -> Void = { _, _, _ in },
        readFileDiskReadRecorder: @escaping @Sendable () -> @Sendable (Int, Int) -> Void = { { _, _ in } },
        captureReadMetrics: @escaping @Sendable () -> FileSystemReadMetrics.Context? = { nil }
    ) {
        self.preferenceEnabled = preferenceEnabled
        self.servicePublication = servicePublication
        self.readFileDiskReadRecorder = readFileDiskReadRecorder
        self.captureReadMetrics = captureReadMetrics
    }

    private static let storage = Storage()

    package static var current: Self {
        storage.snapshot()
    }

    package static func install(_ hooks: Self) {
        storage.install(hooks)
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var hooks = FileSystemRuntimeHooks()

        func snapshot() -> FileSystemRuntimeHooks {
            lock.lock()
            defer { lock.unlock() }
            return hooks
        }

        func install(_ hooks: FileSystemRuntimeHooks) {
            lock.lock()
            self.hooks = hooks
            lock.unlock()
        }
    }
}

/// A host-owned task-local projection, captured before detached physical work.
/// This does not create tasks or change permit/cancellation ownership.
package protocol FileSystemReadAttribution: Sendable {
    func withAttribution<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value
}

package enum FileSystemReadMetrics {
    /// Captured on the request side, then explicitly carried into detached work.
    package struct Context {
        private let attribution: (any FileSystemReadAttribution)?
        private let recordSchedulerRequestCallback: @Sendable (String) -> Void
        private let recordSchedulerEnqueueCallback: @Sendable (String) -> Void
        private let recordSchedulerGrantCallback: @Sendable (String, UInt64) -> Void
        private let recordSchedulerCompletionCallback: @Sendable (String, UInt64, Bool, Bool) -> Void
        private let recordBenchmarkContentReadWorkCallback: @Sendable (UInt64, UInt64, Bool) -> Void

        package init(
            attribution: (any FileSystemReadAttribution)? = nil,
            recordSchedulerRequest: @escaping @Sendable (String) -> Void,
            recordSchedulerEnqueue: @escaping @Sendable (String) -> Void,
            recordSchedulerGrant: @escaping @Sendable (String, UInt64) -> Void,
            recordSchedulerCompletion: @escaping @Sendable (String, UInt64, Bool, Bool) -> Void,
            recordBenchmarkContentReadWork: @escaping @Sendable (UInt64, UInt64, Bool) -> Void
        ) {
            self.attribution = attribution
            recordSchedulerRequestCallback = recordSchedulerRequest
            recordSchedulerEnqueueCallback = recordSchedulerEnqueue
            recordSchedulerGrantCallback = recordSchedulerGrant
            recordSchedulerCompletionCallback = recordSchedulerCompletion
            recordBenchmarkContentReadWorkCallback = recordBenchmarkContentReadWork
        }

        package func withAttribution<Value: Sendable>(
            _ operation: @Sendable () async throws -> Value
        ) async throws -> Value {
            if let attribution {
                return try await attribution.withAttribution(operation)
            }
            return try await operation()
        }

        package func recordSchedulerRequest(workload: String) {
            recordSchedulerRequestCallback(workload)
        }

        package func recordSchedulerEnqueue(workload: String) {
            recordSchedulerEnqueueCallback(workload)
        }

        package func recordSchedulerGrant(workload: String, waitNanoseconds: UInt64) {
            recordSchedulerGrantCallback(workload, waitNanoseconds)
        }

        package func recordSchedulerCompletion(workload: String, executionNanoseconds: UInt64, cancelled: Bool, failed: Bool) {
            recordSchedulerCompletionCallback(workload, executionNanoseconds, cancelled, failed)
        }

        package func recordBenchmarkContentReadWork(waitMicroseconds: UInt64, executionMicroseconds: UInt64, overloaded: Bool) {
            recordBenchmarkContentReadWorkCallback(waitMicroseconds, executionMicroseconds, overloaded)
        }
    }

    @TaskLocal package static var currentContext: Context?

    package static func capture() -> Context? {
        currentContext ?? FileSystemRuntimeHooks.current.captureReadMetrics()
    }

    package static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    package static func elapsed(since start: UInt64, through end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}
