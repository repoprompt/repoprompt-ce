import Foundation
import RepoPromptAIContracts
import RepoPromptFoundation
import RepoPromptProcess

extension CursorACPLaunchResolver {
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
                    timeoutCleanupPolicy: timeoutCleanupPolicy,
                    environmentFilter: ProviderEnvironmentFiltering.cliFilter(for: .cursor)
                )
            },
            failureRecorder: Self.recordAppFailure,
            nowProvider: { ProcessInfo.processInfo.systemUptime },
            deadlineWaiter: CursorACPLaunchResolver.defaultDeadlineWaiter,
            aggregateProbeTimeout: 10,
            useSharedProbeOwnership: true
        )
    }

    convenience init(
        environmentProvider: @escaping @Sendable (_ enableDebugLogging: Bool) async -> [String: String],
        supplementalPathProvider: @escaping SupplementalPathProvider = {
            CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults($0)
        },
        probeRunner: ProbeRunner? = nil,
        environmentFilter: @escaping CLIProcessConfiguration.EnvironmentFilter = ProviderEnvironmentFiltering.cliFilter(for: .cursor),
        failureRecorder: @escaping FailureRecorder = CursorACPLaunchResolver.recordAppFailure,
        nowProvider: @escaping NowProvider = { ProcessInfo.processInfo.systemUptime },
        deadlineWaiter: @escaping DeadlineWaiter = CursorACPLaunchResolver.defaultDeadlineWaiter,
        aggregateProbeTimeout: TimeInterval = 10
    ) {
        self.init(
            launchEnvironmentProvider: { enableDebugLogging in
                await ACPLaunchEnvironment(environment: environmentProvider(enableDebugLogging))
            },
            supplementalPathProvider: supplementalPathProvider,
            probeRunner: probeRunner ?? { launch, config, timeout, cleanup in
                try await CursorACPLaunchResolver.runProbe(
                    launch: launch, config: config, timeout: timeout,
                    timeoutCleanupPolicy: cleanup, environmentFilter: environmentFilter
                )
            },
            failureRecorder: failureRecorder,
            nowProvider: nowProvider,
            deadlineWaiter: deadlineWaiter,
            aggregateProbeTimeout: aggregateProbeTimeout,
            useSharedProbeOwnership: false
        )
    }

    convenience init(
        launchEnvironmentProvider: @escaping EnvironmentProvider,
        supplementalPathProvider: @escaping SupplementalPathProvider = {
            CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults($0)
        },
        probeRunner: ProbeRunner? = nil,
        environmentFilter: @escaping CLIProcessConfiguration.EnvironmentFilter = ProviderEnvironmentFiltering.cliFilter(for: .cursor),
        failureRecorder: @escaping FailureRecorder = CursorACPLaunchResolver.recordAppFailure,
        nowProvider: @escaping NowProvider = { ProcessInfo.processInfo.systemUptime },
        deadlineWaiter: @escaping DeadlineWaiter = CursorACPLaunchResolver.defaultDeadlineWaiter,
        aggregateProbeTimeout: TimeInterval = 10
    ) {
        self.init(
            launchEnvironmentProvider: launchEnvironmentProvider,
            supplementalPathProvider: supplementalPathProvider,
            probeRunner: probeRunner ?? { launch, config, timeout, cleanup in
                try await CursorACPLaunchResolver.runProbe(
                    launch: launch, config: config, timeout: timeout,
                    timeoutCleanupPolicy: cleanup, environmentFilter: environmentFilter
                )
            },
            failureRecorder: failureRecorder,
            nowProvider: nowProvider,
            deadlineWaiter: deadlineWaiter,
            aggregateProbeTimeout: aggregateProbeTimeout,
            useSharedProbeOwnership: false
        )
    }

    #if DEBUG
        convenience init(
            environmentProvider: @escaping @Sendable (_ enableDebugLogging: Bool) async -> [String: String],
            supplementalPathProvider: @escaping SupplementalPathProvider,
            probeRunner: @escaping ProbeRunner,
            failureRecorder: @escaping FailureRecorder = CursorACPLaunchResolver.recordAppFailure,
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
                failureRecorder: failureRecorder,
                nowProvider: nowProvider,
                deadlineWaiter: deadlineWaiter,
                aggregateProbeTimeout: aggregateProbeTimeout,
                sharingProbeOwnershipWith: resolver
            )
        }
    #endif

    private static func recordAppFailure(_ source: ShellEnvironmentSource?, _ candidateCount: Int) {
        AgentCLILaunchDiagnostics.recordPathResolutionFailure(
            providerKind: .cursor, shellEnvironmentSource: source, candidateCount: candidateCount
        )
    }
}
