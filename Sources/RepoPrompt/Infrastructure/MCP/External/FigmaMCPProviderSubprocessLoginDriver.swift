import Foundation

/// The reviewed provider-specific portion of a provider-owned login command. Descriptors own
/// evidence and argument shape; this shared driver owns only safe process execution.
struct FigmaMCPProviderSubprocessLoginDescriptor {
    let provider: ExternalMCPRuntimeProvider
    let command: String
    let additionalPaths: [String]
    let timeout: TimeInterval
    /// Version gates are descriptor-owned; the observed version is supplied by the driver.
    let minimumSupportedVersion: String?
    let requiredExecutableVersion: String?
    let executableVersion: String?
    let arguments: @Sendable (String) -> [String]

    var minimumSupportedExecutableVersion: String? {
        minimumSupportedVersion
    }

    init(
        provider: ExternalMCPRuntimeProvider,
        command: String,
        additionalPaths: [String] = [],
        timeout: TimeInterval = 5 * 60,
        minimumSupportedVersion: String? = nil,
        requiredExecutableVersion: String? = nil,
        executableVersion: String? = nil,
        arguments: @escaping @Sendable (String) -> [String]
    ) {
        self.provider = provider
        self.command = command
        self.additionalPaths = additionalPaths
        self.timeout = timeout
        self.minimumSupportedVersion = minimumSupportedVersion
        self.requiredExecutableVersion = requiredExecutableVersion
        self.executableVersion = executableVersion
        self.arguments = arguments
    }
}

struct FigmaMCPProviderLoginProcessInvocation: @unchecked Sendable {
    let attemptID: UUID
    let configuration: CLIProcessConfiguration
    let arguments: [String]
    let timeout: TimeInterval
}

enum FigmaMCPProviderLoginProcessInterruption: Equatable {
    case authorizationSessionClosed
}

struct FigmaMCPProviderLoginProcessResult: Equatable {
    let status: Int32
    let timedOut: Bool
    let interruption: FigmaMCPProviderLoginProcessInterruption?

    init(
        status: Int32,
        timedOut: Bool,
        interruption: FigmaMCPProviderLoginProcessInterruption? = nil
    ) {
        self.status = status
        self.timedOut = timedOut
        self.interruption = interruption
    }
}

/// Exact nonsecret launch material retained for one login attempt. Post-login observations must
/// consume this value rather than independently resolving a potentially different executable or
/// ambient environment.
struct FigmaMCPProviderResolvedLoginLaunch: @unchecked Sendable {
    let executableEntryPath: String
    let executableIdentity: ExecutableFileIdentity
    let environment: [String: String]
    let executableVersion: String?
}

enum FigmaMCPProviderSubprocessAttemptReservation: Equatable {
    case reserved
    case busy
    case cancelled
}

/// Lets the app-lifetime coordinator capture the absolute executable identity in the attempt
/// fence without adding executable concerns to the shared login contract.
protocol FigmaMCPProviderSubprocessExecutableResolving: Sendable {
    func executableIdentity() async -> String?
    /// Kept as a synchronous compatibility property for existing callers and descriptors.
    var executableVersion: String? { get }
    func currentExecutableVersion() async -> String?
    func supportsExecutableVersion(_ version: String?) async -> Bool
}

protocol FigmaMCPProviderSubprocessLoginTimeoutProviding: Sendable {
    var loginTimeout: TimeInterval { get }
}

protocol FigmaMCPProviderSubprocessAttemptReserving: Sendable {
    func reserveAttempt(_ attemptID: UUID) async -> FigmaMCPProviderSubprocessAttemptReservation
}

private final class FigmaMCPProviderSubprocessLoginLeaseRegistry: @unchecked Sendable {
    private struct Owner: Equatable {
        let driverID: UUID
        let attemptID: UUID
    }

    private let lock = NSLock()
    private var owners: [ExternalMCPRuntimeProvider: Owner] = [:]

    func acquire(provider: ExternalMCPRuntimeProvider, driverID: UUID, attemptID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let candidate = Owner(driverID: driverID, attemptID: attemptID)
        if let owner = owners[provider] { return owner == candidate }
        owners[provider] = candidate
        return true
    }

    func release(provider: ExternalMCPRuntimeProvider, driverID: UUID, attemptID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard owners[provider] == Owner(driverID: driverID, attemptID: attemptID) else { return }
        owners.removeValue(forKey: provider)
    }
}

/// Direct, opaque provider login launcher. It never reads stdout/stderr and never interprets a
/// successful process as authentication proof.
actor FigmaMCPProviderSubprocessLoginDriver: FigmaMCPProviderLoginDriving,
    FigmaMCPProviderSubprocessExecutableResolving,
    FigmaMCPProviderSubprocessLoginTimeoutProviding,
    FigmaMCPProviderSubprocessAttemptReserving
{
    typealias EnvironmentBuilder = @Sendable (ProcessEnvironmentRequest) async -> ProcessEnvironmentResult
    typealias ProcessRunner = @Sendable (FigmaMCPProviderLoginProcessInvocation) async throws -> FigmaMCPProviderLoginProcessResult
    typealias ExecutableVersionResolver = @Sendable () async -> String?
    typealias ExecutableVersionProbe = @Sendable (String, [String: String]) async -> String?

    let runtimeProvider: ExternalMCPRuntimeProvider
    let executableVersion: String?
    let loginTimeout: TimeInterval

    private let descriptor: FigmaMCPProviderSubprocessLoginDescriptor
    private let inheritedEnvironment: [String: String]
    private let environmentBuilder: EnvironmentBuilder
    private let processRunner: ProcessRunner
    private let executableVersionResolver: ExecutableVersionResolver
    private let executableVersionProbe: ExecutableVersionProbe?
    private static let sharedLeaseRegistry = FigmaMCPProviderSubprocessLoginLeaseRegistry()

    private let leaseOwnerID = UUID()
    private var activeTasks: [UUID: Task<FigmaMCPProviderLoginSettlement, Never>] = [:]
    private var preparedLaunches: [UUID: FigmaMCPProviderResolvedLoginLaunch] = [:]
    private var pendingAttemptIDs = Set<UUID>()
    private var leasedAttemptIDs = Set<UUID>()
    private var cancelledAttemptIDs = Set<UUID>()

    init(
        descriptor: FigmaMCPProviderSubprocessLoginDescriptor,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        environmentBuilder: @escaping EnvironmentBuilder = { request in
            await ProcessEnvironmentBuilder.build(request)
        },
        executableVersionResolver: @escaping ExecutableVersionResolver = { nil },
        executableVersionProbe: ExecutableVersionProbe? = nil,
        processRunner: @escaping ProcessRunner = { invocation in
            let result = try await CLIProcessRunner(config: invocation.configuration).run(
                args: invocation.arguments,
                stdin: nil,
                outputMode: .none,
                timeout: invocation.timeout,
                cancelChildOnTaskCancellation: true
            )
            return .init(status: result.status, timedOut: result.timedOut)
        }
    ) {
        runtimeProvider = descriptor.provider
        executableVersion = descriptor.executableVersion
        loginTimeout = descriptor.timeout
        self.descriptor = descriptor
        self.inheritedEnvironment = inheritedEnvironment
        self.environmentBuilder = environmentBuilder
        self.processRunner = processRunner
        self.executableVersionResolver = executableVersionResolver
        self.executableVersionProbe = executableVersionProbe
    }

    func evaluateAvailability(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget
    ) async -> FigmaMCPProviderLoginAvailability {
        guard provider == runtimeProvider, target == .figma else {
            return .unavailable("The provider login descriptor does not match this Figma target.")
        }
        guard !Task.isCancelled,
              let launch = await resolveLaunch(credentialContext: .providerDefaultUserProfile),
              !Task.isCancelled,
              isSupportedVersion(launch.executableVersion)
        else {
            return .unavailable("The provider executable is unavailable or unsupported.")
        }
        return .available
    }

    /// Resolves and retains the exact launch selected for this attempt. Callers must reserve first;
    /// cancellation and the shared provider lease are therefore established before any preflight
    /// suspension can race a Settings-window teardown.
    func prepareAttempt(
        _ attemptID: UUID,
        credentialContext: FigmaMCPProviderCredentialContext
    ) async -> FigmaMCPProviderResolvedLoginLaunch? {
        guard pendingAttemptIDs.contains(attemptID),
              leasedAttemptIDs.contains(attemptID),
              !cancelledAttemptIDs.contains(attemptID),
              !Task.isCancelled
        else { return nil }
        guard let launch = await resolveLaunch(credentialContext: credentialContext),
              !Task.isCancelled,
              pendingAttemptIDs.contains(attemptID),
              leasedAttemptIDs.contains(attemptID),
              !cancelledAttemptIDs.contains(attemptID),
              isSupportedVersion(launch.executableVersion)
        else { return nil }
        preparedLaunches[attemptID] = launch
        return launch
    }

    func beginLogin(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget,
        attemptContext: FigmaMCPProviderLoginAttemptContext
    ) async -> FigmaMCPProviderLoginSettlement {
        guard provider == runtimeProvider,
              target == .figma,
              attemptContext.provider == runtimeProvider,
              attemptContext.target == .figma,
              !attemptContext.providerTargetIdentifier.isEmpty
        else {
            return .launchFailed
        }

        let attemptID = attemptContext.attemptID
        if cancelledAttemptIDs.remove(attemptID) != nil {
            releaseLease(for: attemptID)
            return .cancelled
        }
        if !leasedAttemptIDs.contains(attemptID) {
            guard Self.sharedLeaseRegistry.acquire(
                provider: runtimeProvider,
                driverID: leaseOwnerID,
                attemptID: attemptID
            ) else {
                return .busy
            }
            leasedAttemptIDs.insert(attemptID)
        }
        pendingAttemptIDs.insert(attemptID)

        let processRunner = processRunner
        let descriptor = descriptor
        let preparedLaunch = preparedLaunches.removeValue(forKey: attemptID)
        let launch: FigmaMCPProviderResolvedLoginLaunch
        if let preparedLaunch {
            launch = preparedLaunch
        } else {
            guard !Task.isCancelled,
                  let resolvedLaunch = await resolveLaunch(credentialContext: attemptContext.credentialContext),
                  !Task.isCancelled
            else {
                releaseLease(for: attemptID)
                pendingAttemptIDs.remove(attemptID)
                return Task.isCancelled ? .cancelled : .launchFailed
            }
            launch = resolvedLaunch
        }
        guard launch.executableIdentity.canonicalPath == attemptContext.executableIdentity,
              attemptContext.executableVersion == nil || launch.executableVersion == attemptContext.executableVersion,
              isSupportedVersion(launch.executableVersion),
              !Task.isCancelled
        else {
            releaseLease(for: attemptID)
            pendingAttemptIDs.remove(attemptID)
            return Task.isCancelled ? .cancelled : .launchFailed
        }

        let task = Task { () -> FigmaMCPProviderLoginSettlement in
            guard !Task.isCancelled else { return .cancelled }
            do {
                var configuration = try CLIProcessConfiguration.validatedFigmaProviderLogin(
                    executablePath: launch.executableIdentity.canonicalPath
                )
                configuration.environment = launch.environment
                let arguments = descriptor.arguments(attemptContext.providerTargetIdentifier)
                guard !Task.isCancelled else { return .cancelled }
                // Revalidate both the resolved command entry and its canonical target immediately
                // before the pathname-based spawn. A symlink entry must not silently retarget.
                try launch.executableIdentity.validateForTrustedPathLaunch(
                    atPath: launch.executableEntryPath
                )
                try launch.executableIdentity.validateForTrustedPathLaunch(
                    atPath: launch.executableIdentity.canonicalPath
                )
                let result = try await processRunner(.init(
                    attemptID: attemptID,
                    configuration: configuration,
                    arguments: arguments,
                    timeout: descriptor.timeout
                ))
                guard !Task.isCancelled else { return .cancelled }
                if result.timedOut { return .timedOut }
                if result.interruption == .authorizationSessionClosed {
                    return .authorizationSessionClosed
                }
                return .exited(status: result.status)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return Task.isCancelled ? .cancelled : .launchFailed
            }
        }
        activeTasks[attemptID] = task
        let settlement = await task.value
        activeTasks.removeValue(forKey: attemptID)
        pendingAttemptIDs.remove(attemptID)
        preparedLaunches.removeValue(forKey: attemptID)
        cancelledAttemptIDs.remove(attemptID)
        releaseLease(for: attemptID)
        return settlement
    }

    func reserveAttempt(_ attemptID: UUID) async -> FigmaMCPProviderSubprocessAttemptReservation {
        if cancelledAttemptIDs.contains(attemptID) { return .cancelled }
        if leasedAttemptIDs.contains(attemptID) {
            pendingAttemptIDs.insert(attemptID)
            return .reserved
        }
        guard Self.sharedLeaseRegistry.acquire(
            provider: runtimeProvider,
            driverID: leaseOwnerID,
            attemptID: attemptID
        ) else {
            return .busy
        }
        leasedAttemptIDs.insert(attemptID)
        pendingAttemptIDs.insert(attemptID)
        return .reserved
    }

    func cancelLogin(
        provider: ExternalMCPRuntimeProvider,
        attemptID: UUID
    ) async {
        guard provider == runtimeProvider else { return }
        // Preserve cancellation even when it arrives before reserveAttempt's actor hop.
        cancelledAttemptIDs.insert(attemptID)
        if let task = activeTasks[attemptID] {
            task.cancel()
        } else {
            preparedLaunches.removeValue(forKey: attemptID)
            pendingAttemptIDs.remove(attemptID)
            releaseLease(for: attemptID)
        }
    }

    func currentExecutableVersion() async -> String? {
        guard !Task.isCancelled,
              let launch = await resolveLaunch(credentialContext: .providerDefaultUserProfile),
              !Task.isCancelled
        else { return nil }
        return launch.executableVersion
    }

    func supportsExecutableVersion(_ version: String?) async -> Bool {
        isSupportedVersion(version)
    }

    func executableIdentity() async -> String? {
        guard !Task.isCancelled,
              let launch = await resolveLaunch(credentialContext: .providerDefaultUserProfile),
              !Task.isCancelled
        else { return nil }
        return launch.executableIdentity.canonicalPath
    }

    private func resolveLaunch(
        credentialContext: FigmaMCPProviderCredentialContext
    ) async -> FigmaMCPProviderResolvedLoginLaunch? {
        guard !Task.isCancelled else { return nil }
        var environment = await environmentBuilder(ProcessEnvironmentRequest(
            purpose: .figmaProviderLogin,
            inheritedEnvironment: inheritedEnvironment
        )).environment
        guard !Task.isCancelled,
              Self.ensureDefaultProfileHomeIfNeeded(
                  for: credentialContext,
                  environment: &environment
              ),
              let executable = Self.resolveExecutableIdentity(
                  command: descriptor.command,
                  environment: environment,
                  additionalPaths: descriptor.additionalPaths
              )
        else { return nil }
        let version = await Self.resolveExecutableVersion(
            for: executable,
            environment: environment,
            probe: executableVersionProbe,
            fallback: executableVersionResolver,
            descriptorVersion: descriptor.executableVersion
        )
        guard !Task.isCancelled else { return nil }
        return .init(
            executableEntryPath: executable.path,
            executableIdentity: executable.identity,
            environment: environment,
            executableVersion: version
        )
    }

    private func isSupportedVersion(_ version: String?) -> Bool {
        if let required = descriptor.requiredExecutableVersion {
            return version == required
                && Self.isSupportedVersion(version, minimum: descriptor.minimumSupportedVersion)
        }
        if descriptor.minimumSupportedVersion != nil {
            return Self.isSupportedVersion(version, minimum: descriptor.minimumSupportedVersion)
        }
        if runtimeProvider == .openCode || runtimeProvider == .cursor {
            return version.flatMap(VersionComponents.init) != nil
        }
        return true
    }

    private func releaseLease(for attemptID: UUID) {
        guard leasedAttemptIDs.remove(attemptID) != nil else { return }
        Self.sharedLeaseRegistry.release(
            provider: runtimeProvider,
            driverID: leaseOwnerID,
            attemptID: attemptID
        )
    }

    private static func resolveExecutableVersion(
        for executable: ResolvedExecutable,
        environment: [String: String],
        probe: ExecutableVersionProbe?,
        fallback: @escaping ExecutableVersionResolver,
        descriptorVersion: String?
    ) async -> String? {
        if let probe {
            let probedVersion = await probe(executable.identity.canonicalPath, environment)
            guard !Task.isCancelled else { return nil }
            if let probedVersion { return probedVersion }
        }
        let fallbackVersion = await fallback()
        guard !Task.isCancelled else { return nil }
        if let fallbackVersion { return fallbackVersion }
        return descriptorVersion
    }

    private static func isSupportedVersion(_ version: String?, minimum: String?) -> Bool {
        guard let minimum else { return true }
        guard let version,
              let observed = VersionComponents(version),
              let required = VersionComponents(minimum)
        else { return false }
        return observed >= required
    }

    private static func ensureDefaultProfileHomeIfNeeded(
        for credentialContext: FigmaMCPProviderCredentialContext,
        environment: inout [String: String]
    ) -> Bool {
        guard credentialContext == .providerDefaultUserProfile else { return true }
        guard let canonicalHome = ProcessEnvironmentBuilder.canonicalDefaultUserHome else { return false }
        environment["HOME"] = canonicalHome
        return true
    }

    private struct ResolvedExecutable {
        let path: String
        let identity: ExecutableFileIdentity
    }

    private static func resolveExecutableIdentity(
        command: String,
        environment: [String: String],
        additionalPaths: [String]
    ) -> ResolvedExecutable? {
        let resolved = CommandPathResolver.resolve(
            command,
            environment: environment,
            additionalPaths: additionalPaths,
            shellLookupMode: .disabled
        )
        guard resolved.hasPrefix("/"),
              let identity = try? ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: resolved)
        else {
            return nil
        }
        return ResolvedExecutable(path: resolved, identity: identity)
    }
}

private struct VersionComponents: Comparable {
    let components: [Int]

    init?(_ rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        components = values
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        zip(lhs.components, rhs.components).first { $0 != $1 }.map { $0.0 < $0.1 } ?? false
    }
}
