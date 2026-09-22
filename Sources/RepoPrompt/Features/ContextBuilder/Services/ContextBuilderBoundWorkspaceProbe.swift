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
        try Task.checkCancellation()
        return try await CancellableProbe.run { complete in
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
                complete(result)
            }
            #if DEBUG
                workerStarted?(worker)
            #endif
            return worker
        }
    }
}
