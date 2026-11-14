import Foundation
import RepoPromptCodexProvider
import RepoPromptProcess

extension CodexAppServerClient {
    #if DEBUG
        static func testProcessEnvironmentForCurrentLaunch(baseEnvironment: [String: String]) -> [String: String] {
            DomainChildLaunchEnvironmentBridge.mergingCurrentCarrier(into: baseEnvironment)
        }
    #endif

    init(
        writeFrameHandler: @escaping @Sendable (Int32, Data) throws -> Void = { descriptor, frame in
            try FDWriteSupport.writeAll(frame, to: descriptor)
        },
        livenessProbe: @escaping @Sendable (SpawnedProcess) -> Bool = { process in
            CodexAppServerClient.defaultProcessAppearsAlive(process)
        },
        processSpawnPreparation: @escaping @Sendable () async throws -> Void = {},
        computerUseRuntimeUnavailableMessage: @escaping @Sendable (URL) -> String? = { CodexComputerUseWorkflow.runtimeUnavailableMessage(executableURL: $0) },
        processEnvironmentBuilder: @escaping @Sendable (ProcessEnvironmentRequest) async -> ProcessEnvironmentResult = {
            await ProcessEnvironmentBuilder.build($0)
        },
        runtimeStatePreparer: @escaping @Sendable (CodexRuntimeAuthority.Runtime) throws -> Void = {
            try $0.prepareState()
        },
        launchSnapshot: CodexRuntimeAuthority.LaunchSnapshot = CodexRuntimeAuthority.currentLaunchSnapshot(),
        provisionsRepoPromptMCPOnStart: Bool = true,
        optOutNotificationMethods: [String] = [],
        processExitObserverFactory: @escaping @Sendable (pid_t) -> ChildProcessExitObserver = {
            ChildProcessExitObserver.observe(pid: $0)
        },
        expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar = .serverNetworkManager,
        faultInjection: FaultInjection = .init()
    ) {
        self.init(
            launchHost: CodexAppServerAppLaunchHost(
                computerUseRuntimeUnavailableMessage: computerUseRuntimeUnavailableMessage,
                processEnvironmentBuilder: processEnvironmentBuilder,
                runtimeStatePreparer: runtimeStatePreparer,
                launchSnapshot: launchSnapshot
            ),
            writeFrameHandler: writeFrameHandler,
            livenessProbe: livenessProbe,
            processSpawnPreparation: processSpawnPreparation,
            provisionsRepoPromptMCPOnStart: provisionsRepoPromptMCPOnStart,
            optOutNotificationMethods: optOutNotificationMethods,
            processExitObserverFactory: processExitObserverFactory,
            expectedAgentPIDRegistrar: expectedAgentPIDRegistrar,
            faultInjection: faultInjection
        )
    }

    static func computerUseProcessConfigArgs(
        computerUseEnabled: Bool,
        serverEntries: [MCPIntegrationHelper.CodexServerEntry]
    ) throws -> [String] {
        let reserved = serverEntries.filter { $0.normalizedName.caseInsensitiveCompare("computer-use") == .orderedSame }
        guard !computerUseEnabled || reserved.isEmpty else {
            throw ClientError.executableUnavailable(CodexComputerUseWorkflow.collisionMessage)
        }
        var args = reserved.flatMap { ["-c", "mcp_servers.\($0.cliPathComponent).enabled=false"] }
        if computerUseEnabled {
            args += ["-c", "approval_policy=\"on-request\"", "-c", "approvals_reviewer=\"user\""]
        }
        return args
    }
}

extension CodexAppServerClient.ExpectedAgentPIDRegistrar {
    /// Capture the originating policy, never resolve a run's current registration at cleanup.
    static func serverNetworkManager(registration: MCPRunRoutingCleanupReceipt) -> CodexAppServerClient.ExpectedAgentPIDRegistrar {
        .init(
            register: { pid, clientName, runID in
                await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: clientName, runID: runID, registration: registration)
            },
            clear: { pid, clientName, runID in
                await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: clientName, runID: runID, registration: registration)
            }
        )
    }

    static let serverNetworkManager = CodexAppServerClient.ExpectedAgentPIDRegistrar(
        register: { pid, clientName, runID in
            await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: clientName, runID: runID)
        },
        clear: { pid, clientName, runID in
            await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: clientName, runID: runID)
        }
    )
}

struct CodexAppServerAppLaunchHost: CodexAppServerLaunchHost {
    let computerUseRuntimeUnavailableMessage: @Sendable (URL) -> String?
    let processEnvironmentBuilder: @Sendable (ProcessEnvironmentRequest) async -> ProcessEnvironmentResult
    let runtimeStatePreparer: @Sendable (CodexRuntimeAuthority.Runtime) throws -> Void
    let launchSnapshot: CodexRuntimeAuthority.LaunchSnapshot

    var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func buildEnvironment(enableDebugLogging: Bool) async -> [String: String] {
        let environmentResult = await processEnvironmentBuilder(
            ProcessEnvironmentRequest(purpose: .codexAppServer, enableDebugLogging: enableDebugLogging)
        )
        return environmentResult.environment
    }

    func resolveRuntime(commandName: String, environment: [String: String], additionalPathHints: [String], enableDebugLogging: Bool) -> CodexProviderExecutableResolution {
        CodexProviderHelpers.resolveCodexExecutable(
            commandName: commandName,
            environment: environment,
            additionalPathHints: additionalPathHints,
            launchSnapshot: launchSnapshot,
            logger: enableDebugLogging ? { print("[CodexAppServer] \($0)") } : nil
        )
    }

    func prepareState(for runtime: CodexProviderRuntime.Runtime) throws {
        try runtimeStatePreparer(runtime)
    }

    func processEnvironmentForCurrentLaunch(_ baseEnvironment: [String: String]) -> [String: String] {
        DomainChildLaunchEnvironmentBridge.mergingCurrentCarrier(into: baseEnvironment)
    }

    func filterEnvironment(_ environment: [String: String], explicitOverrides: [String: String]) async -> [String: String] {
        await ProviderEnvironmentFiltering.filter(environment, for: .codexExec, explicitOverrides: explicitOverrides)
    }

    func baseProcessArguments(runtime: CodexProviderRuntime.Runtime, provisionsRepoPromptMCP: Bool, featurePolicy: CodexProcessConfiguration.FeaturePolicy, reasoningSummary: CodexProcessConfiguration.ReasoningSummary?) throws -> [String] {
        if provisionsRepoPromptMCP {
            let provisioning = CodexIntegrationConfiguration.ensureServerForDiscovery(runtime: runtime)
            guard provisioning.success else {
                throw CodexAppServerClient.ClientError.executableUnavailable(
                    provisioning.errorMessage ?? "RepoPrompt could not prepare its owned Codex configuration."
                )
            }
        }
        return CodexOverrides.cliConfigArgs(
            toolPolicy: .init(
                toolOutputTokenLimit: MCPIntegrationHelper.desiredCodexToolOutputTokenLimit,
                modelReasoningSummary: reasoningSummary
            ),
            featurePolicy: featurePolicy
        )
    }

    func computerUseProcessArguments(runtime: CodexProviderRuntime.Runtime) throws -> [String] {
        // Probe the actual executable afresh, not cached UI admission or provenance.
        if let message = computerUseRuntimeUnavailableMessage(runtime.executableURL) {
            throw CodexAppServerClient.ClientError.executableUnavailable(message)
        }
        // Synchronous actual armed-runtime config read; no suspension until spawn.
        let runtimeConfigURL = runtime.statePaths.codexHome.appendingPathComponent("config.toml")
        let runtimeConfig = if FileManager.default.fileExists(atPath: runtimeConfigURL.path) {
            try String(contentsOf: runtimeConfigURL, encoding: .utf8)
        } else {
            ""
        }
        return try CodexAppServerClient.computerUseProcessConfigArgs(
            computerUseEnabled: true,
            serverEntries: CodexIntegrationConfiguration.mcpServerEntries(from: runtimeConfig)
        )
    }
}
