import Foundation

/// Filesystem-only checks for an immutable bound Context Builder invocation.
/// This never consults workspace presentation or reconciles primary roots.
struct ContextBuilderBoundWorkspaceProbe {
    enum Operation { case availability, executionDirectory, providerDirectory }

    #if DEBUG
        enum Phase { case beforeFileSystem, afterFileSystem, workerFinished }
        struct Event {
            let id: UUID
            let operation: Operation
            let phase: Phase
        }

        typealias Checkpoint = @Sendable (Event) -> Void
        private let checkpoint: Checkpoint?
        private let workerStarted: (@Sendable (Task<Void, Never>) -> Void)?

        init(checkpoint: @escaping Checkpoint, workerStarted: (@Sendable (Task<Void, Never>) -> Void)? = nil) {
            self.checkpoint = checkpoint
            self.workerStarted = workerStarted
        }
    #endif

    init() {
        #if DEBUG
            checkpoint = nil
            workerStarted = nil
        #endif
    }

    func validate(bindings: [AgentSessionWorktreeBinding], providerPath: String) async throws {
        try await run(.availability) {
            for binding in bindings {
                try Task.checkCancellation()
                do {
                    try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable([binding])
                } catch {
                    throw ContextBuilderWorkspaceContextError.unavailableWorktreeProjection
                }
            }
            try Task.checkCancellation()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: providerPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ContextBuilderWorkspaceContextError.unavailableProviderWorkspace
            }
        }
    }

    func effectiveWorkspacePath(bindings: [AgentSessionWorktreeBinding], fallback: String?) async throws -> String? {
        try await run(.executionDirectory) {
            try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(bindings: bindings, fallbackWorkspacePath: fallback)
        }
    }

    func directoryExists(at path: String) async throws -> Bool {
        try await run(.providerDirectory) {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private func run<Value: Sendable>(
        _ operation: Operation,
        body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let settlement = Settlement<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                settlement.install(continuation)
                let worker = Task.detached(priority: .utility) { [self] in
                    #if DEBUG
                        let id = UUID()
                        defer { checkpoint?(.init(id: id, operation: operation, phase: .workerFinished)) }
                    #endif
                    let result: Result<Value, Error>
                    do {
                        try Task.checkCancellation()
                        #if DEBUG
                            checkpoint?(.init(id: id, operation: operation, phase: .beforeFileSystem))
                        #endif
                        try Task.checkCancellation()
                        let value = try body()
                        #if DEBUG
                            checkpoint?(.init(id: id, operation: operation, phase: .afterFileSystem))
                        #endif
                        try Task.checkCancellation()
                        result = .success(value)
                    } catch { result = .failure(error) }
                    settlement.complete(result)
                }
                #if DEBUG
                    workerStarted?(worker)
                #endif
                settlement.attach(worker)
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            settlement.cancel()
        }
    }

    /// Cancellation settles the consumer, not an uninterruptible filesystem syscall.
    /// The worker owns only frozen inputs and this latch until its late result is discarded.
    private final class Settlement<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?
        private var continuation: CheckedContinuation<Value, Error>?
        private var worker: Task<Void, Never>?

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            let ready = lock.withLock { () -> Result<Value, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil as Result<Value, Error>?
            }
            if let ready { continuation.resume(with: ready) }
        }

        func attach(_ worker: Task<Void, Never>) {
            let settled = lock.withLock {
                guard result == nil else { return true }
                self.worker = worker
                return false
            }
            if settled { worker.cancel() }
        }

        func complete(_ result: Result<Value, Error>) {
            let pending = lock.withLock {
                worker = nil
                guard self.result == nil else { return nil as CheckedContinuation<Value, Error>? }
                self.result = result
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(with: result)
        }

        func cancel() {
            let (pending, worker) = lock.withLock {
                let worker = self.worker
                self.worker = nil
                guard result == nil else { return (nil as CheckedContinuation<Value, Error>?, worker) }
                result = .failure(CancellationError())
                let pending = continuation
                continuation = nil
                return (pending, worker)
            }
            worker?.cancel()
            pending?.resume(throwing: CancellationError())
        }
    }
}
