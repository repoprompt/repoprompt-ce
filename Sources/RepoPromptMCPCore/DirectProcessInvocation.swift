import Foundation
import MCP
import RepoPromptProcess
import RepoPromptVCS

/// Owns launch admission, the sole child observer, and every pipe until cleanup.
/// Cancellation may arrive before the spawned child is registered with this owner.
final class DirectProcessInvocation: @unchecked Sendable {
    private static let terminalDrainTimeout: TimeInterval = 2

    private final class Child: @unchecked Sendable {
        let process: SpawnedProcess
        let observer: ChildProcessExitObserver
        let pipesClosed = DispatchGroup()
        let stdout: DirectProcessPipeIO
        let stderr: DirectProcessPipeIO?
        let stdin: DirectProcessPipeIO?

        init(
            process: SpawnedProcess,
            separatesStandardError: Bool,
            afterReadingOutput: (@Sendable (Data) -> Void)?
        ) {
            self.process = process
            observer = .observe(pid: process.pid)
            stdout = DirectProcessPipeIO(
                reading: process.stdout, completion: pipesClosed, afterRead: afterReadingOutput
            )
            if separatesStandardError {
                stderr = DirectProcessPipeIO(reading: process.stderr, completion: pipesClosed)
            } else {
                stderr = nil
                // Combined mode routes both child writers to stdout at spawn time.
                try? process.stderr.close()
            }
            if let input = process.stdin {
                stdin = DirectProcessPipeIO(writingTo: input, completion: pipesClosed)
            } else {
                stdin = nil
            }
        }

        func stopPipes() {
            stdin?.stop()
            stdout.stop()
            stderr?.stop()
        }
    }

    private let executable: String
    private let arguments: [String]
    private let input: Data?
    private let environment: [String: String]
    private let currentDirectory: URL?
    private let readBinding: GitReadRepositoryBinding?
    private let isProvider: Bool
    private let allowsProviderProcessLaunchForTesting: Bool
    private let separatesStandardError: Bool
    private let lock = NSLock()
    private let completion = DirectProcessCompletion<Result<DirectProcess.Output, Error>>()
    private var child: Child?
    private var cancellationRequested = false
    private var cancellationCleanupStarted = false
    private var completed = false
    private var terminationTask: Task<Void, Never>?
    #if DEBUG
        private let hooks = DirectProcess.lifecycleHooks
    #endif

    init(
        executable: String,
        arguments: [String],
        input: Data?,
        environment overrides: [String: String],
        currentDirectory: URL?,
        readBinding: GitReadRepositoryBinding?,
        isProvider: Bool,
        allowsProviderProcessLaunchForTesting: Bool,
        separatesStandardError: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.input = input
        self.currentDirectory = currentDirectory
        self.readBinding = readBinding
        self.isProvider = isProvider
        self.allowsProviderProcessLaunchForTesting = allowsProviderProcessLaunchForTesting
        self.separatesStandardError = separatesStandardError
        let sanitized = DirectProcess.childEnvironment(overrides: overrides)
        environment = readBinding?.ownershipProbeEnvironment(sanitized) ?? sanitized
    }

    func run() async throws -> DirectProcess.Output {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            #if DEBUG
                await hooks?.beforeLaunch?()
            #endif
            try Task.checkCancellation()
            try readBinding?.revalidate()
            let process: SpawnedProcess
            #if DEBUG
                process = try ProcessLauncher.onSpawnedOutputWritersForTestingTaskLocal.withValue(hooks?.onSpawnedOutputWriters) {
                    try spawn()
                }
            #else
                process = try spawn()
            #endif
            var afterReadingOutput: (@Sendable (Data) -> Void)?
            #if DEBUG
                afterReadingOutput = hooks?.afterReadingOutput
            #endif
            let owned = Child(
                process: process, separatesStandardError: separatesStandardError,
                afterReadingOutput: afterReadingOutput
            )
            #if DEBUG
                await hooks?.afterSpawnBeforeRegistration?(process.pid)
            #endif
            let mustCancel = lock.withLock {
                child = owned
                if !cancellationRequested {
                    // Admission and pipe registration precede every input write.
                    // Scheduling DispatchIO cannot block this cancellation lock.
                    owned.stdin?.write(input ?? Data())
                    #if DEBUG
                        hooks?.afterInputSubmission?()
                    #endif
                }
                return cancellationRequested
            }
            if mustCancel { cancelOwnedChild(owned) }
            Task.detached { [self, owned] in
                await finalize(owned)
            }
            return try await completion.wait().get()
        } onCancel: {
            requestCancellation()
        }
    }

    private func spawn() throws -> SpawnedProcess {
        try ProcessLauncher.spawn(
            command: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: currentDirectory?.path,
            purpose: isProvider ? .provider : .tool,
            allowsProviderProcessLaunchForTesting: allowsProviderProcessLaunchForTesting,
            mergeStandardError: !separatesStandardError
        )
    }

    private func requestCancellation() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        cancellationRequested = true
        let owned = child
        lock.unlock()
        if let owned { cancelOwnedChild(owned) }
    }

    private func cancelOwnedChild(_ owned: Child) {
        lock.lock()
        guard !cancellationCleanupStarted, !completed else {
            lock.unlock()
            return
        }
        cancellationCleanupStarted = true
        lock.unlock()

        // Pipe cancellation is independent of root liveness. A reaped root may
        // have left writers in descendants or another process retaining an FD.
        owned.stopPipes()
        let termination = terminateFamily(owned)
        Task.detached { [self, owned] in
            await termination.value
            if await owned.observer.wait(timeout: 0) == nil {
                // The finalizer and sole observer retain physical ownership if
                // the OS has not completed termination within the cleanup budget.
                finish(.failure(MCPError.internalError(
                    "Owned process \(owned.process.pid) did not settle after cancellation cleanup."
                )), honorsCancellation: false)
            }
        }
    }

    private func terminateFamily(_ owned: Child) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let terminationTask { return terminationTask }
        let task = Task.detached {
            await ProcessTermination.terminateObservedProcessFamily(
                observer: owned.observer, processGroupID: owned.process.processGroupID,
                sigtermGrace: 1
            )
        }
        terminationTask = task
        return task
    }

    private func finalize(_ owned: Child) async {
        let outcome = await owned.observer.wait()
        #if DEBUG
            await hooks?.afterRootExit?()
        #endif
        // The same cleanup owner handles cancellation and ordinary root exit.
        // Reap completion alone does not release descendants or their pipes.
        await terminateFamily(owned).value
        let drained = await Self.waitForPipes(owned.pipesClosed, timeout: Self.terminalDrainTimeout)
        if !drained {
            owned.stopPipes()
            _ = await Self.waitForPipes(owned.pipesClosed)
        }

        let stdout = Self.text(owned.stdout.snapshot)
        let stderr = Self.text(owned.stderr?.snapshot)
        lock.withLock { child = nil }
        if case let .failed(error)? = outcome {
            finish(.failure(error))
        } else if outcome == nil {
            finish(.failure(MCPError.internalError("Owned process exit could not be observed.")))
        } else if !drained {
            finish(.failure(MCPError.internalError(
                [stdout, stderr, "Process pipes did not finish after the owned process family exited."]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
            )))
        } else if case let .exited(status)? = outcome, status.terminationStatus != 0 {
            finish(.failure(MCPError.internalError(
                [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )))
        } else if let ioError = [owned.stdout.error, owned.stderr?.error ?? 0, owned.stdin?.error ?? 0]
            .first(where: { $0 != 0 })
        {
            finish(.failure(MCPError.internalError("Process pipe operation failed with errno \(ioError).")))
        } else {
            finish(.success(.init(standardOutput: stdout, standardError: stderr)))
        }
    }

    private func finish(_ result: Result<DirectProcess.Output, Error>, honorsCancellation: Bool = true) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let result = cancellationRequested && honorsCancellation
            ? .failure(CancellationError()) : result
        lock.unlock()
        completion.finish(result)
    }

    private static func text(_ snapshot: DirectProcessOutputCapture.Snapshot?) -> String {
        guard let snapshot else { return "" }
        var text = String(decoding: snapshot.data, as: UTF8.self)
        if snapshot.truncated {
            text += "\n[output truncated at \(DirectProcessOutputCapture.outputLimit) bytes]"
        }
        return text
    }

    private static func waitForPipes(_ group: DispatchGroup, timeout: TimeInterval? = nil) async -> Bool {
        let completion = DirectProcessCompletion<Bool>()
        group.notify(queue: .global(qos: .utility)) { completion.finish(true) }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                completion.finish(false)
            }
        }
        return await completion.wait()
    }
}

/// A cancellable operation owns its descriptor until DispatchIO's cleanup callback.
/// No blocking FileHandle read or write can strand the result or a teardown worker.
final class DirectProcessPipeIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RepoPromptMCPCore.directProcessPipe", qos: .userInitiated)
    private let channel: DispatchIO
    private let capture: DirectProcessOutputCapture?
    private var operationError: Int32 = 0

    var snapshot: DirectProcessOutputCapture.Snapshot? {
        capture?.finish { Data() }
    }

    var error: Int32 {
        queue.sync { operationError }
    }

    init(
        reading handle: FileHandle,
        completion: DispatchGroup,
        afterRead: (@Sendable (Data) -> Void)? = nil,
        onSubmitted: (@Sendable () -> Void)? = nil,
        onClosed: (@Sendable () -> Void)? = nil
    ) {
        capture = DirectProcessOutputCapture()
        completion.enter()
        channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
            try? handle.close()
            onClosed?()
            completion.leave()
        }
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: 64 * 1024)
        channel.read(offset: 0, length: Int.max, queue: queue) { [self] done, bytes, error in
            if let bytes, !bytes.isEmpty {
                let data = Data(bytes)
                capture?.consume { data }
                afterRead?(data)
            }
            if error != 0 { operationError = error }
            if done { channel.close() }
        }
        onSubmitted?()
    }

    init(
        writingTo handle: FileHandle,
        completion: DispatchGroup,
        onClosed: (@Sendable () -> Void)? = nil
    ) {
        capture = nil
        completion.enter()
        channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
            try? handle.close()
            onClosed?()
            completion.leave()
        }
    }

    /// The invocation serializes this single submission with cancellation admission.
    func write(_ data: Data) {
        if data.isEmpty {
            channel.close()
        } else {
            let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
            channel.write(offset: 0, data: bytes, queue: queue) { [self] done, _, error in
                if error != 0 { operationError = error }
                if done { channel.close() }
            }
        }
    }

    func stop() {
        channel.close(flags: .stop)
    }
}

private final class DirectProcessCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value {
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                precondition(self.continuation == nil)
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ value: Value) {
        lock.lock()
        guard self.value == nil else {
            lock.unlock()
            return
        }
        self.value = value
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
