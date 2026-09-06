import Foundation

enum CursorACPLaunchCandidate: CaseIterable, Equatable {
    case cursorAgentACP
    case agentACP

    var command: String {
        switch self {
        case .cursorAgentACP:
            CLILaunchProfiles.cursor.commandName
        case .agentACP:
            "agent"
        }
    }

    var launchArguments: [String] {
        ["--approve-mcps", "acp"]
    }

    var helpArguments: [String] {
        ["acp", "--help"]
    }
}

struct CursorACPResolvedLaunch: Equatable {
    let candidate: CursorACPLaunchCandidate
    let command: String
    let arguments: [String]
    let additionalPathHints: [String]
    let environment: [String: String]
    let executableIdentity: ExecutableFileIdentity
}

private struct CursorACPPathCandidate {
    let path: String
    let entrypoint: CursorACPLaunchCandidate
}

enum CursorACPLaunchResolutionError: Error, Equatable, LocalizedError {
    case missingConfiguredCommand
    case unsafeConfiguredCommand(String)
    case exactPathNotFound(String)
    case noValidLaunchCandidate(String, [String], ShellEnvironmentSource?)
    case environmentDiscoveryRequired(String)
    case unsafeApplicationPath(String)
    case unsafeCanonicalBasename(String)
    case unverifiedAgentAlias(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguredCommand:
            "Cursor Agent CLI launch requires `cursor-agent`, a verified `agent`, or an absolute path to either executable."
        case let .unsafeConfiguredCommand(command):
            "Refusing unsafe Cursor ACP command `\(command)`. Configure `cursor-agent` or the Cursor `agent` executable."
        case let .exactPathNotFound(command):
            "Cursor Agent CLI was not found as a valid executable regular file for `\(command)`. Install Cursor Agent CLI or configure an absolute `cursor-agent` or `agent` path."
        case let .noValidLaunchCandidate(command, failures, source):
            AgentCLILaunchDiagnostics.appendFallbackEnvironmentHint(
                to: "Cursor Agent CLI was not found as a valid executable regular file for `\(command)`. Tried: \(failures.joined(separator: "; "))",
                source: source
            )
        case let .environmentDiscoveryRequired(command):
            "Cursor Agent CLI discovery or identity verification has not completed for `\(command)`. Run the Cursor ACP support preflight before launching a generic `agent` entrypoint."
        case let .unsafeApplicationPath(path):
            "Refusing Cursor ACP executable inside an application bundle: \(path)"
        case let .unsafeCanonicalBasename(path):
            "Refusing Cursor ACP executable whose canonical basename is `cursor`: \(path)"
        case let .unverifiedAgentAlias(path):
            "Refusing automatic Cursor ACP `agent` fallback because it does not resolve to a canonical `cursor-agent` executable: \(path)"
        }
    }
}

final class CursorACPLaunchResolver: @unchecked Sendable {
    typealias EnvironmentProvider = @Sendable (_ enableDebugLogging: Bool) async -> ACPLaunchEnvironment
    typealias SupplementalPathProvider = @Sendable (_ configuredPaths: [String]) -> [String]
    typealias ProbeRunner = @Sendable (
        _ launch: CursorACPResolvedLaunch,
        _ config: CursorAgentConfig,
        _ timeout: TimeInterval,
        _ timeoutCleanupPolicy: ProcessTermination.TimeoutCleanupPolicy
    ) async throws -> CLIProcessRunner.Result
    typealias NowProvider = @Sendable () -> TimeInterval
    typealias DeadlineWaiter = @Sendable (_ deadline: TimeInterval) async -> Void

    private enum ProbeProducerOutcome: @unchecked Sendable {
        case success(CLIProcessRunner.Result)
        case failure(Error)
        case cancelled
    }

    private enum ProbeLogicalOutcome: @unchecked Sendable {
        case producer(ProbeProducerOutcome)
        case deadline
        case cancelled
    }

    /// Owns one physical probe independently of the logical waiter's lifetime.
    ///
    /// A timeout or cancellation retires the logical result immediately, but the producer task
    /// remains retained here until its existing cancellation/child-cleanup path settles. A late
    /// producer result can therefore never be mistaken for the current logical attempt.
    private final class ProbeAttempt: @unchecked Sendable {
        private enum State: Equatable {
            case active
            case draining
            case settled
        }

        private let lock = NSLock()
        private let onSettled: @Sendable (ProbeAttempt) -> Void
        private var state: State = .active
        private var producerTask: Task<ProbeProducerOutcome, Never>?
        private var deadlineTask: Task<Void, Never>?
        private var producerOutcome: ProbeProducerOutcome?
        private var logicalOutcome: ProbeLogicalOutcome?
        private var logicalContinuation: CheckedContinuation<ProbeLogicalOutcome, Never>?

        init(onSettled: @escaping @Sendable (ProbeAttempt) -> Void) {
            self.onSettled = onSettled
        }

        var isSettled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return state == .settled
        }

        func installProducer(_ task: Task<ProbeProducerOutcome, Never>) {
            let shouldCancel: Bool
            lock.lock()
            guard state != .settled else {
                lock.unlock()
                return
            }
            producerTask = task
            shouldCancel = state == .draining
            lock.unlock()
            if shouldCancel {
                task.cancel()
            }
        }

        func installDeadlineTask(_ task: Task<Void, Never>) {
            lock.lock()
            guard state == .active, logicalOutcome == nil else {
                lock.unlock()
                task.cancel()
                return
            }
            deadlineTask = task
            lock.unlock()
        }

        func wait() async -> ProbeLogicalOutcome {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<ProbeLogicalOutcome, Never>) in
                    var immediateOutcome: ProbeLogicalOutcome?
                    lock.lock()
                    if let logicalOutcome {
                        immediateOutcome = logicalOutcome
                    } else {
                        logicalContinuation = continuation
                    }
                    lock.unlock()
                    if let immediateOutcome {
                        continuation.resume(returning: immediateOutcome)
                    }
                }
            } onCancel: { [weak self] in
                self?.cancelForLogicalCancellation()
            }
        }

        func deadlineReached() {
            finishLogical(.deadline)
        }

        func producerDidSettle(_ outcome: ProbeProducerOutcome) {
            var continuation: CheckedContinuation<ProbeLogicalOutcome, Never>?
            var shouldNotifySettled = false
            var deadlineTaskToCancel: Task<Void, Never>?
            lock.lock()
            guard producerOutcome == nil else {
                lock.unlock()
                return
            }
            producerOutcome = outcome
            if state != .settled {
                state = .settled
                shouldNotifySettled = true
                producerTask = nil
            }
            if logicalOutcome == nil {
                let completed = ProbeLogicalOutcome.producer(outcome)
                logicalOutcome = completed
                continuation = logicalContinuation
                logicalContinuation = nil
            }
            deadlineTaskToCancel = deadlineTask
            deadlineTask = nil
            lock.unlock()

            deadlineTaskToCancel?.cancel()
            if shouldNotifySettled {
                onSettled(self)
            }
            if let continuation {
                continuation.resume(returning: .producer(outcome))
            }
        }

        private func cancelForLogicalCancellation() {
            finishLogical(.cancelled)
        }

        private func finishLogical(_ outcome: ProbeLogicalOutcome) {
            var continuation: CheckedContinuation<ProbeLogicalOutcome, Never>?
            var producerTaskToCancel: Task<ProbeProducerOutcome, Never>?
            var deadlineTaskToCancel: Task<Void, Never>?
            lock.lock()
            guard logicalOutcome == nil else {
                lock.unlock()
                return
            }
            logicalOutcome = outcome
            if state == .active {
                state = .draining
                producerTaskToCancel = producerTask
            }
            deadlineTaskToCancel = deadlineTask
            deadlineTask = nil
            continuation = logicalContinuation
            logicalContinuation = nil
            lock.unlock()

            producerTaskToCancel?.cancel()
            deadlineTaskToCancel?.cancel()
            continuation?.resume(returning: outcome)
        }
    }

    private static let maximumAggregateProbeDuration: TimeInterval = 24 * 60 * 60

    private static func defaultDeadlineWaiter(_ deadline: TimeInterval) async {
        let now = ProcessInfo.processInfo.systemUptime
        guard now.isFinite, deadline.isFinite else { return }
        let remaining = deadline - now
        guard remaining.isFinite, remaining > 0 else { return }
        let cappedRemaining = min(remaining, maximumAggregateProbeDuration)
        let nanoseconds = max(UInt64(1), UInt64(cappedRemaining * 1_000_000_000))
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private final class ProbeOwnership: @unchecked Sendable {
        let probeMutex = AsyncMutex()
        private let lock = NSLock()
        private var ownedProbeAttempt: ProbeAttempt?
        #if DEBUG
            private var settlementWaiters: [(ProbeAttempt, CheckedContinuation<Void, Never>)] = []
        #endif

        func beginProbeAttempt() -> ProbeAttempt? {
            lock.lock()
            if let existing = ownedProbeAttempt {
                guard existing.isSettled else {
                    lock.unlock()
                    return nil
                }
                ownedProbeAttempt = nil
            }

            let attempt = ProbeAttempt(onSettled: { [weak self] attempt in
                self?.probeAttemptDidSettle(attempt)
            })
            ownedProbeAttempt = attempt
            lock.unlock()
            return attempt
        }

        func hasPendingProbeAttempt() -> Bool {
            lock.lock()
            let attempt = ownedProbeAttempt
            lock.unlock()
            guard let attempt else { return false }
            if attempt.isSettled {
                probeAttemptDidSettle(attempt)
                return false
            }
            return true
        }

        private func probeAttemptDidSettle(_ attempt: ProbeAttempt) {
            var readyWaiters: [CheckedContinuation<Void, Never>] = []
            lock.lock()
            if ownedProbeAttempt === attempt {
                ownedProbeAttempt = nil
            }
            #if DEBUG
                var remainingWaiters: [(ProbeAttempt, CheckedContinuation<Void, Never>)] = []
                for (waitingAttempt, continuation) in settlementWaiters {
                    if waitingAttempt === attempt {
                        readyWaiters.append(continuation)
                    } else {
                        remainingWaiters.append((waitingAttempt, continuation))
                    }
                }
                settlementWaiters = remainingWaiters
            #endif
            lock.unlock()
            readyWaiters.forEach { $0.resume() }
        }

        #if DEBUG
            func waitForProbeAttemptSettlementForTesting() async {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    guard let attempt = ownedProbeAttempt, !attempt.isSettled else {
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    settlementWaiters.append((attempt, continuation))
                    lock.unlock()
                }
            }
        #endif
    }

    private let environmentProvider: EnvironmentProvider
    private let supplementalPathProvider: SupplementalPathProvider
    private let probeRunner: ProbeRunner
    private let nowProvider: NowProvider
    private let deadlineWaiter: DeadlineWaiter
    private let aggregateProbeTimeout: TimeInterval
    private let lock = NSLock()
    private var cachedLaunchByKey: [String: CursorACPResolvedLaunch] = [:]
    private let probeOwnership: ProbeOwnership
    /// Provider factories may create a fresh resolver for each discovery; only physical probe
    /// ownership is shared across those default instances. Launch caches stay resolver-local.
    private static let sharedDefaultProbeOwnership = ProbeOwnership()

    private init(
        launchEnvironmentProvider: @escaping EnvironmentProvider,
        supplementalPathProvider: @escaping SupplementalPathProvider,
        probeRunner: @escaping ProbeRunner,
        nowProvider: @escaping NowProvider,
        deadlineWaiter: @escaping DeadlineWaiter,
        aggregateProbeTimeout: TimeInterval,
        probeOwnership: ProbeOwnership
    ) {
        environmentProvider = launchEnvironmentProvider
        self.supplementalPathProvider = supplementalPathProvider
        self.probeRunner = probeRunner
        self.nowProvider = nowProvider
        self.deadlineWaiter = deadlineWaiter
        self.aggregateProbeTimeout = aggregateProbeTimeout
        self.probeOwnership = probeOwnership
    }

    convenience init() {
        self.init(
            launchEnvironmentProvider: { enableDebugLogging in
                let result = await ProcessEnvironmentBuilder.build(
                    ProcessEnvironmentRequest(
                        purpose: .acpAgent(providerID: ACPProviderID.cursor.rawValue),
                        enableDebugLogging: enableDebugLogging
                    )
                )
                return ACPLaunchEnvironment(
                    environment: result.environment,
                    shellEnvironmentSource: result.shellEnvironmentSource
                )
            },
            supplementalPathProvider: {
                CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults($0)
            },
            probeRunner: { launch, config, timeout, timeoutCleanupPolicy in
                try await CursorACPLaunchResolver.runProbe(
                    launch: launch,
                    config: config,
                    timeout: timeout,
                    timeoutCleanupPolicy: timeoutCleanupPolicy
                )
            },
            nowProvider: { ProcessInfo.processInfo.systemUptime },
            deadlineWaiter: CursorACPLaunchResolver.defaultDeadlineWaiter,
            aggregateProbeTimeout: 10,
            probeOwnership: Self.sharedDefaultProbeOwnership
        )
    }

    convenience init(
        environmentProvider: @escaping @Sendable (_ enableDebugLogging: Bool) async -> [String: String],
        supplementalPathProvider: @escaping SupplementalPathProvider = {
            CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults($0)
        },
        probeRunner: @escaping ProbeRunner = { launch, config, timeout, timeoutCleanupPolicy in
            try await CursorACPLaunchResolver.runProbe(
                launch: launch,
                config: config,
                timeout: timeout,
                timeoutCleanupPolicy: timeoutCleanupPolicy
            )
        },
        nowProvider: @escaping NowProvider = { ProcessInfo.processInfo.systemUptime },
        deadlineWaiter: @escaping DeadlineWaiter = CursorACPLaunchResolver.defaultDeadlineWaiter,
        aggregateProbeTimeout: TimeInterval = 10
    ) {
        self.init(
            launchEnvironmentProvider: { enableDebugLogging in
                await ACPLaunchEnvironment(environment: environmentProvider(enableDebugLogging))
            },
            supplementalPathProvider: supplementalPathProvider,
            probeRunner: probeRunner,
            nowProvider: nowProvider,
            deadlineWaiter: deadlineWaiter,
            aggregateProbeTimeout: aggregateProbeTimeout,
            probeOwnership: ProbeOwnership()
        )
    }

    convenience init(
        launchEnvironmentProvider: @escaping EnvironmentProvider,
        supplementalPathProvider: @escaping SupplementalPathProvider = {
            CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults($0)
        },
        probeRunner: @escaping ProbeRunner = { launch, config, timeout, timeoutCleanupPolicy in
            try await CursorACPLaunchResolver.runProbe(
                launch: launch,
                config: config,
                timeout: timeout,
                timeoutCleanupPolicy: timeoutCleanupPolicy
            )
        },
        nowProvider: @escaping NowProvider = { ProcessInfo.processInfo.systemUptime },
        deadlineWaiter: @escaping DeadlineWaiter = CursorACPLaunchResolver.defaultDeadlineWaiter,
        aggregateProbeTimeout: TimeInterval = 10
    ) {
        self.init(
            launchEnvironmentProvider: launchEnvironmentProvider,
            supplementalPathProvider: supplementalPathProvider,
            probeRunner: probeRunner,
            nowProvider: nowProvider,
            deadlineWaiter: deadlineWaiter,
            aggregateProbeTimeout: aggregateProbeTimeout,
            probeOwnership: ProbeOwnership()
        )
    }

    #if DEBUG
        convenience init(
            environmentProvider: @escaping @Sendable (_ enableDebugLogging: Bool) async -> [String: String],
            supplementalPathProvider: @escaping SupplementalPathProvider,
            probeRunner: @escaping ProbeRunner,
            nowProvider: @escaping NowProvider,
            deadlineWaiter: @escaping DeadlineWaiter,
            aggregateProbeTimeout: TimeInterval = 10,
            sharingProbeOwnershipWith resolver: CursorACPLaunchResolver
        ) {
            self.init(
                launchEnvironmentProvider: { enableDebugLogging in
                    await ACPLaunchEnvironment(environment: environmentProvider(enableDebugLogging))
                },
                supplementalPathProvider: supplementalPathProvider,
                probeRunner: probeRunner,
                nowProvider: nowProvider,
                deadlineWaiter: deadlineWaiter,
                aggregateProbeTimeout: aggregateProbeTimeout,
                probeOwnership: resolver.probeOwnership
            )
        }
    #endif

    func resolvedLaunch(for config: CursorAgentConfig) throws -> CursorACPResolvedLaunch {
        let key = cacheKey(for: config)
        if let cached = cachedLaunch(forKey: key) {
            do {
                try cached.executableIdentity.validateForTrustedPathLaunch(atPath: cached.command)
                return cached
            } catch {
                invalidate(key: key)
                throw error
            }
        }

        let configuredCommand = try validatedConfiguredCommand(config)
        if (configuredCommand as NSString).lastPathComponent.caseInsensitiveCompare(
            CursorACPLaunchCandidate.agentACP.command
        ) == .orderedSame {
            throw CursorACPLaunchResolutionError.environmentDiscoveryRequired(configuredCommand)
        }

        let launch = try resolveExplicitLaunch(for: config)
        if launch.candidate == .agentACP {
            throw CursorACPLaunchResolutionError.environmentDiscoveryRequired(configuredCommand)
        }
        cache(launch, key: key)
        return launch
    }

    func probeSupport(for config: CursorAgentConfig) async throws -> ACPSupportResult {
        try await probeOwnership.probeMutex.withLock { [self] in
            try await probeSupportSerially(for: config)
        }
    }

    private func probeSupportSerially(for config: CursorAgentConfig) async throws -> ACPSupportResult {
        let key = cacheKey(for: config)
        invalidate(key: key)
        do {
            try Task.checkCancellation()
            guard !probeOwnership.hasPendingProbeAttempt() else {
                return .unsupported(reason: "Cursor Agent CLI ACP preflight cleanup is still pending.")
            }

            // Resolve from the current effective environment on every support check. The cache only
            // bridges this successful probe to the immediately following launch configuration.
            let configuredCommand = try validatedConfiguredCommand(config)
            let launchEnvironment = await environmentProvider(config.enableDebugLogging)
            try Task.checkCancellation()
            let effectiveHints = supplementalPathProvider(config.additionalPathHints)
            var stages = launchStages(configuredCommand: configuredCommand, commandSelection: config.commandSelection).makeIterator()
            var launches: [CursorACPResolvedLaunch] = []
            var seenCanonicalPaths = Set<String>()
            var failures: [String] = []
            var aggregateDeadline: TimeInterval?
            let timeoutCleanupPolicy = ProcessTermination.currentTimeoutCleanupPolicy()
            let cleanupAllowance = timeoutCleanupPolicy.maximumDuration
            guard cleanupAllowance.isFinite, cleanupAllowance >= 0 else {
                return .unsupported(reason: "Cursor Agent CLI ACP preflight has an invalid timeout cleanup policy.")
            }

            probeLoop: while true {
                try Task.checkCancellation()
                if launches.isEmpty {
                    // Discover the secondary name only after every primary candidate has failed.
                    guard let stage = stages.next() else { break }
                    let discoveryStarted = aggregateDeadline.map { _ in nowProvider() }
                    do {
                        launches = try resolveLaunchesForProbe(
                            for: config,
                            configuredCommand: configuredCommand,
                            stage: stage,
                            launchEnvironment: launchEnvironment,
                            effectiveHints: effectiveHints
                        )
                    } catch {
                        failures.append(error.localizedDescription)
                    }
                    // Discovery was outside the capability budget before staged lookup. Keep it
                    // outside, without replenishing time already spent on failed probes.
                    if let discoveryStarted, let deadline = aggregateDeadline {
                        let discoveryDuration = nowProvider() - discoveryStarted
                        let adjustedDeadline = deadline + discoveryDuration
                        guard discoveryStarted.isFinite, discoveryDuration.isFinite,
                              discoveryDuration >= 0, adjustedDeadline.isFinite
                        else {
                            return .unsupported(reason: "Cursor Agent CLI ACP preflight could not account for discovery duration.")
                        }
                        aggregateDeadline = adjustedDeadline
                    }
                    if launches.isEmpty { continue }
                }
                try Task.checkCancellation()
                let launch = launches.removeFirst()
                guard seenCanonicalPaths.insert(launch.command).inserted else { continue }
                guard let deadline = aggregateDeadline ?? aggregateProbeDeadline() else {
                    return .unsupported(reason: "Cursor Agent CLI ACP preflight could not establish a valid aggregate deadline.")
                }
                aggregateDeadline = deadline
                let now = nowProvider()
                let remainingExecutionTimeout = deadline - now - cleanupAllowance
                guard now.isFinite, remainingExecutionTimeout.isFinite, remainingExecutionTimeout > 0 else {
                    failures.append("Cursor Agent CLI ACP preflight exceeded its aggregate timeout.")
                    break
                }

                guard let attempt = probeOwnership.beginProbeAttempt() else {
                    failures.append("Cursor Agent CLI ACP preflight cleanup is still pending.")
                    break
                }

                let probeRunner = probeRunner
                let producerTask = Task<ProbeProducerOutcome, Never> {
                    let outcome: ProbeProducerOutcome
                    do {
                        outcome = try await .success(probeRunner(
                            launch,
                            config,
                            remainingExecutionTimeout,
                            timeoutCleanupPolicy
                        ))
                    } catch is CancellationError {
                        outcome = .cancelled
                    } catch {
                        outcome = .failure(error)
                    }
                    attempt.producerDidSettle(outcome)
                    return outcome
                }
                attempt.installProducer(producerTask)

                let deadlineTask = Task { [deadlineWaiter, deadline, attempt] in
                    await deadlineWaiter(deadline)
                    guard !Task.isCancelled else { return }
                    attempt.deadlineReached()
                }
                attempt.installDeadlineTask(deadlineTask)

                let logicalOutcome = await attempt.wait()
                let result: CLIProcessRunner.Result
                switch logicalOutcome {
                case .cancelled:
                    invalidate(key: key)
                    throw CancellationError()
                case .deadline:
                    failures.append(
                        "Cursor Agent CLI ACP preflight exceeded its aggregate timeout while probe cleanup remains pending."
                    )
                    break probeLoop
                case let .producer(.cancelled):
                    throw CancellationError()
                case let .producer(.failure(error)):
                    failures.append("\(launch.command): \(error.localizedDescription)")
                    continue
                case let .producer(.success(producerResult)):
                    result = producerResult
                }

                guard !result.timedOut, result.status == 0 else {
                    failures.append(
                        result.timedOut
                            ? "Cursor Agent CLI ACP preflight timed out: `\(launch.candidate.command) acp --help`."
                            : "Cursor Agent CLI ACP preflight failed: `\(launch.candidate.command) acp --help` exited with status \(result.status)."
                    )
                    continue
                }

                let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
                let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
                let combined = "\(stdout)\n\(stderr)"
                guard advertisesCursorACP(combined, candidate: launch.candidate) else {
                    failures.append(
                        "Cursor Agent CLI ACP preflight failed: `\(launch.candidate.command) acp --help` did not prove Cursor ACP support."
                    )
                    continue
                }

                do {
                    try launch.executableIdentity.validateForTrustedPathLaunch(atPath: launch.command)
                } catch {
                    failures.append("\(launch.command): \(error.localizedDescription)")
                    continue
                }
                try Task.checkCancellation()
                let cacheNow = nowProvider()
                guard cacheNow.isFinite, cacheNow < deadline else {
                    failures.append("Cursor Agent CLI ACP preflight exceeded its aggregate timeout.")
                    break probeLoop
                }
                cache(launch, key: key)
                return .supported
            }

            return .unsupported(
                reason: failures.joined(separator: " ")
            )
        } catch is CancellationError {
            invalidate(key: key)
            throw CancellationError()
        } catch {
            invalidate(key: key)
            return .unsupported(reason: error.localizedDescription)
        }
    }

    private func aggregateProbeDeadline() -> TimeInterval? {
        let now = nowProvider()
        guard now.isFinite, aggregateProbeTimeout.isFinite else { return nil }
        let duration = min(max(aggregateProbeTimeout, 0), Self.maximumAggregateProbeDuration)
        let deadline = now + duration
        guard deadline.isFinite else { return nil }
        return deadline
    }

    #if DEBUG
        func waitForProbeAttemptSettlementForTesting() async {
            await probeOwnership.waitForProbeAttemptSettlementForTesting()
        }
    #endif

    private func resolveLaunchesForProbe(
        for config: CursorAgentConfig,
        configuredCommand: String,
        stage: CursorACPLaunchCandidate,
        launchEnvironment: ACPLaunchEnvironment,
        effectiveHints: [String]
    ) throws -> [CursorACPResolvedLaunch] {
        let environment = launchEnvironment.environment
        if configuredCommand.contains("/") {
            return try [resolveExplicitLaunch(
                for: config,
                environment: environment,
                shellEnvironmentSource: launchEnvironment.shellEnvironmentSource
            )]
        }

        return try validLaunches(
            candidates: launchCandidates(
                stage: stage,
                additionalPathHints: effectiveHints,
                environment: environment
            ),
            configuredCommand: configuredCommand,
            commandSelection: config.commandSelection,
            additionalPathHints: effectiveHints,
            environment: environment,
            shellEnvironmentSource: launchEnvironment.shellEnvironmentSource
        )
    }

    private func resolveExplicitLaunch(
        for config: CursorAgentConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellEnvironmentSource: ShellEnvironmentSource? = nil
    ) throws -> CursorACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        guard configuredCommand.contains("/") else {
            throw CursorACPLaunchResolutionError.environmentDiscoveryRequired(configuredCommand)
        }
        let effectiveHints = supplementalPathProvider(config.additionalPathHints)
        do {
            return try validatedLaunch(
                entryPath: CommandPathResolver.expandPath(configuredCommand, environment: environment),
                configuredCommand: configuredCommand,
                additionalPathHints: effectiveHints,
                environment: environment
            )
        } catch {
            // Explicit-path failures intentionally keep their specific errors
            // (exactPathNotFound / unsafeApplicationPath / unsafeCanonicalBasename) and omit the
            // fallback-PATH hint: an exact configured path does not depend on PATH discovery.
            // Still record the same resolution-failure telemetry OpenCode emits for explicit paths.
            AgentCLILaunchDiagnostics.recordPathResolutionFailure(
                providerKind: .cursor,
                shellEnvironmentSource: shellEnvironmentSource,
                candidateCount: 1
            )
            throw error
        }
    }

    private func validatedConfiguredCommand(_ config: CursorAgentConfig) throws -> String {
        let configuredCommand = config.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredCommand.isEmpty else {
            throw CursorACPLaunchResolutionError.missingConfiguredCommand
        }
        let supportedCommands = Set(CursorACPLaunchCandidate.allCases.map { $0.command.lowercased() })
        let configuredBasename = (configuredCommand as NSString).lastPathComponent.lowercased()
        guard supportedCommands.contains(configuredBasename) else {
            throw CursorACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
        }
        if configuredCommand.contains("/") {
            return configuredCommand
        } else if configuredCommand.caseInsensitiveCompare(configuredBasename) != .orderedSame {
            throw CursorACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
        }
        return configuredCommand
    }

    private func validatedLaunch(
        entryPath: String,
        configuredCommand: String,
        additionalPathHints: [String],
        environment: [String: String],
        preserveValidationError: Bool = false
    ) throws -> CursorACPResolvedLaunch {
        let entryBasename = (entryPath as NSString).lastPathComponent.lowercased()
        guard entryPath.hasPrefix("/"),
              CursorACPLaunchCandidate.allCases.contains(where: { $0.command.lowercased() == entryBasename })
        else {
            throw CursorACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        let identity: ExecutableFileIdentity
        do {
            identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: entryPath)
        } catch {
            if preserveValidationError {
                throw error
            }
            throw CursorACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        if identity.canonicalPath.split(separator: "/").contains(where: { $0.lowercased().hasSuffix(".app") }) {
            throw CursorACPLaunchResolutionError.unsafeApplicationPath(identity.canonicalPath)
        }
        if (identity.canonicalPath as NSString).lastPathComponent.caseInsensitiveCompare("cursor") == .orderedSame {
            throw CursorACPLaunchResolutionError.unsafeCanonicalBasename(identity.canonicalPath)
        }
        let canonicalBasename = (identity.canonicalPath as NSString).lastPathComponent
        let candidate: CursorACPLaunchCandidate = canonicalBasename.caseInsensitiveCompare(
            CursorACPLaunchCandidate.cursorAgentACP.command
        ) == .orderedSame ? .cursorAgentACP : .agentACP

        return CursorACPResolvedLaunch(
            candidate: candidate,
            command: identity.canonicalPath,
            arguments: candidate.launchArguments,
            additionalPathHints: additionalPathHints,
            environment: environment,
            executableIdentity: identity
        )
    }

    private func advertisesCursorACP(_ output: String, candidate: CursorACPLaunchCandidate) -> Bool {
        switch candidate {
        case .cursorAgentACP:
            output.localizedCaseInsensitiveContains("acp")
                || output.localizedCaseInsensitiveContains("agent client protocol")
        case .agentACP:
            output.localizedCaseInsensitiveContains("usage: agent acp")
                && output.localizedCaseInsensitiveContains("cursor agent")
                && output.localizedCaseInsensitiveContains("agent client protocol")
        }
    }

    private func launchCandidates(
        stage: CursorACPLaunchCandidate,
        additionalPathHints: [String],
        environment: [String: String]
    ) -> [CursorACPPathCandidate] {
        var candidates: [CursorACPPathCandidate] = []
        var seen = Set<String>()

        func append(_ candidate: String, entrypoint: CursorACPLaunchCandidate) {
            let expanded = CommandPathResolver.expandPath(candidate, environment: environment)
            guard !expanded.isEmpty,
                  expanded.hasPrefix("/"),
                  seen.insert(expanded).inserted
            else { return }
            candidates.append(CursorACPPathCandidate(path: expanded, entrypoint: entrypoint))
        }

        let launchCandidate = stage
        append(
            CommandPathResolver.resolve(
                launchCandidate.command,
                environment: environment,
                additionalPaths: additionalPathHints,
                preferredBasenames: [launchCandidate.command],
                shellLookupMode: .fallbackOnly
            ),
            entrypoint: launchCandidate
        )
        for directory in CommandPathResolver.mergedPathComponents(
            environment: environment,
            additionalPaths: additionalPathHints
        ) {
            append(
                (directory as NSString).appendingPathComponent(launchCandidate.command),
                entrypoint: launchCandidate
            )
        }
        return candidates
    }

    private func launchStages(
        configuredCommand: String,
        commandSelection: CursorAgentCommandSelection
    ) -> [CursorACPLaunchCandidate] {
        let basename = (configuredCommand as NSString).lastPathComponent.lowercased()
        switch commandSelection {
        case .automatic:
            return [.cursorAgentACP, .agentACP]
        case .exact:
            return basename == CursorACPLaunchCandidate.agentACP.command ? [.agentACP] : [.cursorAgentACP]
        }
    }

    private func validLaunches(
        candidates: [CursorACPPathCandidate],
        configuredCommand: String,
        commandSelection: CursorAgentCommandSelection,
        additionalPathHints: [String],
        environment: [String: String],
        shellEnvironmentSource: ShellEnvironmentSource?
    ) throws -> [CursorACPResolvedLaunch] {
        var failures: [String] = []
        var launches: [CursorACPResolvedLaunch] = []
        for candidate in candidates {
            do {
                let launch = try validatedLaunch(
                    entryPath: candidate.path,
                    configuredCommand: configuredCommand,
                    additionalPathHints: additionalPathHints,
                    environment: environment,
                    preserveValidationError: true
                )
                if commandSelection == .automatic,
                   launch.candidate == .agentACP
                {
                    throw CursorACPLaunchResolutionError.unverifiedAgentAlias(
                        launch.executableIdentity.canonicalPath
                    )
                }
                launches.append(launch)
            } catch {
                failures.append("\(candidate.path): \(error.localizedDescription)")
            }
        }
        if !launches.isEmpty {
            return launches
        }
        if failures.isEmpty {
            throw CursorACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }
        AgentCLILaunchDiagnostics.recordPathResolutionFailure(
            providerKind: .cursor,
            shellEnvironmentSource: shellEnvironmentSource,
            candidateCount: candidates.count
        )
        throw CursorACPLaunchResolutionError.noValidLaunchCandidate(configuredCommand, failures, shellEnvironmentSource)
    }

    private func cachedLaunch(forKey key: String) -> CursorACPResolvedLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLaunchByKey[key]
    }

    private func cache(_ launch: CursorACPResolvedLaunch, key: String) {
        lock.lock()
        cachedLaunchByKey[key] = launch
        lock.unlock()
    }

    private func invalidate(key: String) {
        lock.lock()
        cachedLaunchByKey.removeValue(forKey: key)
        lock.unlock()
    }

    private func cacheKey(for config: CursorAgentConfig) -> String {
        let selectionKey = switch config.commandSelection {
        case .automatic:
            "automatic"
        case let .exact(commandName):
            "exact:\(commandName)"
        }
        return ([selectionKey] + config.additionalPathHints).joined(separator: "\u{1F}")
    }

    private static func runProbe(
        launch: CursorACPResolvedLaunch,
        config: CursorAgentConfig,
        timeout: TimeInterval,
        timeoutCleanupPolicy: ProcessTermination.TimeoutCleanupPolicy
    ) async throws -> CLIProcessRunner.Result {
        let processConfig = CLIProcessConfiguration(
            command: launch.command,
            environment: launch.environment,
            additionalPaths: [],
            enableDebugLogging: config.enableDebugLogging,
            shellLookupMode: .fallbackOnly
        )
        return try await CLIProcessRunner(config: processConfig).run(
            args: launch.candidate.helpArguments,
            stdin: nil,
            outputMode: .none,
            timeout: timeout,
            timeoutCleanupPolicy: timeoutCleanupPolicy,
            additionalRemovedKeys: ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"],
            cancelChildOnTaskCancellation: true
        )
    }
}
