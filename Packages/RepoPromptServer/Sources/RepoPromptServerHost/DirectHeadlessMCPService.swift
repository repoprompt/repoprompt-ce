import Crypto
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Logging
import MCP
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptDomainRuntime
import RepoPromptHeadlessRuntime
import RepoPromptRuntimeModel
import RepoPromptWorkspaceRuntimeCore

private let directHeadlessCLIVersion = "1.3.0"

actor DirectHeadlessMCPService {
    struct PreparedRuntime {
        let runtime: MCPDomainRuntime
        let scopeID: DomainStandaloneScopeID
        let connectionID: UUID
        let connectionGeneration: UInt64
        let installation: MCPDomainStandaloneToolInstallation
        let context: DirectHeadlessDomainContext
        let principal: DomainClientPrincipal
        let childEndpoint: DirectHeadlessChildEndpoint
        let childLaunchCoordinator: DirectHeadlessChildLaunchCoordinator
        let providerCoordinator: DirectHeadlessProviderCoordinator
        let authorityHost: RepoPromptAuthorityHost
        let mutationCapability: AuthorityMutationCapability
        let readCapability: AuthorityReadCapability
    }

    struct ConnectionContext {
        let connectionID: UUID
        let connectionGeneration: UInt64
        let principal: DomainClientPrincipal
        let policyProfile: MCPClientToolPolicyProfile
        let restrictedToolNames: Set<String>
        let additionalToolNames: Set<String>
        let ephemeralGrantedOperations: Set<String>
    }

    static let topLevelDefaultMutationOperations: Set<String> = [
        "manage_selection.add",
        "manage_selection.remove",
        "manage_selection.set",
        "manage_selection.clear",
        "manage_selection.promote",
        "manage_selection.demote",
        "prompt.set",
        "prompt.append",
        "prompt.clear",
        "prompt.select_preset"
    ]

    private let logger: Logger
    private let environment: [String: String]
    private let currentDirectory: URL

    init(
        logger: Logger = Logger(label: "com.repoprompt.ce.mcp.headless"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) {
        self.logger = logger
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    func prepareRuntime() async throws -> PreparedRuntime {
        let locations = try DirectHeadlessRuntimeLocationResolver.resolve(
            environment: environment,
            currentDirectory: currentDirectory
        )
        for directory in [
            locations.storageDirectory,
            locations.workspaceStorageDirectory,
            locations.eventDirectory,
            locations.temporaryDirectory
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let namespace = try AuthorityNamespaceDescriptor(
            storageRoot: locations.storageDirectory.path,
            databasePath: locations.storageDirectory.appendingPathComponent("repoprompt.sqlite").path,
            profile: locations.profileIdentifier,
            servingMode: .directHeadless
        )
        let childLaunchCoordinator = DirectHeadlessChildLaunchCoordinator()
        let runtime = MCPDomainRuntime(configuration: DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: locations.profileIdentifier,
            storageDirectory: locations.storageDirectory,
            workspaceStorageDirectory: locations.workspaceStorageDirectory,
            eventDirectory: locations.eventDirectory,
            temporaryDirectory: locations.temporaryDirectory,
            hostDrainTimeout: .seconds(5)
        ), prepareChildLaunch: { toolName, arguments, securityContext in
            try await childLaunchCoordinator.prepare(
                toolName: toolName,
                arguments: arguments,
                securityContext: securityContext
            )
        })
        let authorityHost = try await RepoPromptAuthorityHostFactory.startDirectHeadless(
            configuration: .init(namespace: namespace),
            runtime: runtime
        )
        let mutationCapability = await authorityHost.mutationGate.capability()
        let readCapability = await authorityHost.mutationGate.readCapability()
        do {
            let workingDirectories = locations.workingDirectories
            if locations.mayBootstrapIsolatedWorkspace {
                try await ensureExplicitIsolatedWorkspace(
                    runtime: runtime,
                    roots: workingDirectories
                )
            }
            let initialRoute = try await DirectHeadlessWorktreeRouting.resolveInitialRoute(
                workingDirectories: workingDirectories,
                catalog: runtime.workspaceStore.snapshot()
            )

            let scopeID = DomainStandaloneScopeID()
            let connectionID = UUID()
            let scope = try await runtime.standaloneScopeCoordinator.register(
                scopeID: scopeID,
                connectionID: connectionID,
                workingDirectories: initialRoute.bindingWorkingDirectories
            )
            let context = DirectHeadlessDomainContext(
                runtime: runtime,
                scopeID: scopeID,
                processRootOverlay: initialRoute.rootOverlay
            )
            let settingsStore = DomainDirectSettingsStore(
                persistence: runtime.persistenceCoordinator,
                profileIdentifier: runtime.configuration.profileIdentifier
            )
            let workspace = DirectHeadlessWorkspaceBackend(context: context)
            let global = DirectHeadlessGlobalBackend(
                runtime: runtime,
                scopeID: scopeID,
                context: context,
                settingsStore: settingsStore
            )
            let providerCoordinator = DirectHeadlessProviderCoordinator(
                runtime: runtime,
                context: context,
                settingsStore: settingsStore,
                environment: environment
            )
            let backends = MCPDomainStandaloneCapabilityBackends(
                global: global,
                workspace: workspace,
                filesystem: DirectHeadlessFilesystemBackend(context: context),
                conversation: DirectHeadlessConversationBackend(coordinator: providerCoordinator),
                versionControl: DirectHeadlessVersionControlBackend(runtime: runtime, context: context),
                agent: DirectHeadlessAgentBackend(coordinator: providerCoordinator),
                history: DirectHeadlessHistoryBackend(runtime: runtime)
            )
            let installation = try await MCPDomainStandaloneToolInstaller.install(
                runtime: runtime,
                scopeID: scopeID,
                backends: backends
            )
            let privateEndpointDirectory = URL(
                fileURLWithPath: "/tmp/rpce-h-\(geteuid())-\(runtime.identity.runtimeID.uuidString.prefix(8))",
                isDirectory: true
            )
            let childEndpoint = DirectHeadlessChildEndpoint(
                directory: privateEndpointDirectory,
                logger: logger
            )
            await childLaunchCoordinator.configure(
                runtime: runtime,
                endpointDescriptor: childEndpoint.socketURL.path
            )
            let parentProcessID = getppid()
            let verifiedFingerprint = Self.verifiedExecutableFingerprint(processID: parentProcessID)
            let principal = DomainClientPrincipal(
                principalID: connectionID,
                stableKey: "headless-stdio:\(parentProcessID)",
                displayName: environment["REPOPROMPT_MCP_CLIENT_NAME"] ?? "headless-stdio-client",
                kind: .runScoped,
                assurance: verifiedFingerprint == nil ? .displayNameOnly : .verifiedProcess,
                processID: verifiedFingerprint == nil ? nil : parentProcessID,
                runID: scopeID.rawValue,
                provider: "direct-stdio",
                verifiedIdentityFingerprint: verifiedFingerprint,
                claimedProcessID: nil
            )
            return PreparedRuntime(
                runtime: runtime,
                scopeID: scopeID,
                connectionID: connectionID,
                connectionGeneration: scope.registration.generation,
                installation: installation,
                context: context,
                principal: principal,
                childEndpoint: childEndpoint,
                childLaunchCoordinator: childLaunchCoordinator,
                providerCoordinator: providerCoordinator,
                authorityHost: authorityHost,
                mutationCapability: mutationCapability,
                readCapability: readCapability
            )
        } catch {
            _ = await authorityHost.shutdown(
                reason: "direct_headless_prepare_failed",
                deadline: .seconds(5)
            )
            throw error
        }
    }

    private func installHandlers(
        server: Server,
        prepared: PreparedRuntime,
        connection: ConnectionContext
    ) async {
        let classification = MCPClientToolPolicyCatalog.classification(for: connection.policyProfile)
        let serving = DirectHeadlessAdapterServing(
            prepared: prepared,
            connection: connection
        )
        await server.withMethodHandler(ListTools.self) { _ in
            let visibleNames = try await serving.advertisedToolNames(isRootSession: true)
            let tools = MCPDomainCanonicalToolDefinitions.definitions.compactMap { definition -> MCP.Tool? in
                guard visibleNames.contains(definition.name) else { return nil }
                let projected = definition.annotations.projected(
                    for: classification.annotationProfile
                )
                return MCP.Tool(
                    name: definition.name,
                    description: definition.description,
                    inputSchema: definition.inputSchema,
                    annotations: .init(
                        title: projected.title,
                        readOnlyHint: projected.readOnlyHint,
                        destructiveHint: projected.destructiveHint,
                        idempotentHint: projected.idempotentHint,
                        openWorldHint: projected.openWorldHint
                    )
                )
            }
            return ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                let visibleNames = try await serving.advertisedToolNames(isRootSession: true)
                guard visibleNames.contains(params.name) else {
                    return Self.errorResult("Tool is unavailable for this client policy: \(params.name)")
                }
                let arguments = try Self.validatedCallArguments(
                    toolName: params.name,
                    arguments: params.arguments ?? [:]
                )
                let encoded = try JSONEncoder().encode(arguments)
                let result = try await serving.invoke(
                    toolName: params.name,
                    argumentsJSON: encoded,
                    binding: .init(
                        sessionID: prepared.scopeID.rawValue,
                        actor: .init(
                            userID: connection.principal.stableKey
                                ?? "headless-\(connection.connectionID.uuidString)",
                            username: connection.principal.displayName,
                            displayName: connection.principal.displayName
                        )
                    )
                )
                return Self.successResult(try JSONDecoder().decode(Value.self, from: result))
            } catch {
                return Self.errorResult(String(describing: error))
            }
        }
    }

    fileprivate static func visibleToolNames(_ connection: ConnectionContext) -> Set<String> {
        let classification = MCPClientToolPolicyCatalog.classification(for: connection.policyProfile)
        let restrictedNames = MCPDomainToolCatalog
            .toolNames(for: classification.restrictedCapabilities)
            .union(connection.restrictedToolNames)
        let additionalNames = MCPDomainToolCatalog
            .toolNames(for: classification.grantedCapabilities)
            .union(connection.additionalToolNames)
        return Set(MCPDomainToolCatalog.orderedToolNames.filter { toolName in
            !restrictedNames.contains(toolName)
                && (
                    !MCPClientToolPolicyCatalog.policyGatedToolNames.contains(toolName)
                        || additionalNames.contains(toolName)
                )
                && MCPClientToolPolicyCatalog.shouldAdvertise(
                    toolName: toolName,
                    role: classification.role,
                    allowsAgentExternalControlTools: classification.allowsAgentExternalControlTools
                )
        })
    }

    func startPrivateChildEndpoint(_ prepared: PreparedRuntime) async throws {
        try await prepared.childEndpoint.start { [weak self] fd, peerPID, handshake in
            await self?.servePrivateChild(
                fd: fd,
                peerPID: peerPID,
                handshake: handshake,
                prepared: prepared
            )
        }
    }

    private func servePrivateChild(
        fd: Int32,
        peerPID: Int32?,
        handshake: DirectHeadlessChildEndpoint.Handshake,
        prepared: PreparedRuntime
    ) async {
        let connectionID = UUID()
        let redemption = await prepared.runtime.routingCoordinator.redeemLaunchToken(
            material: handshake.launchToken,
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            connectionID: connectionID,
            processID: peerPID,
            clientPrincipal: handshake.clientPrincipal,
            providerIdentifier: handshake.providerIdentifier
        )
        guard case let .accepted(accepted) = redemption,
              case let .runScoped(runID, _) = accepted.binding.binding,
              runID == handshake.runID
        else {
            logger.warning("Rejected private child launch token", metadata: ["result": "\(redemption)"])
            DirectHeadlessPOSIX.shutdownReadWrite(fd)
            return
        }

        let principal = DomainClientPrincipal(
            principalID: UUID(),
            stableKey: handshake.clientPrincipal,
            displayName: handshake.providerIdentifier,
            kind: .runScoped,
            assurance: .hostLaunchToken,
            processID: peerPID,
            runID: handshake.runID,
            provider: handshake.providerIdentifier,
            claimedProcessID: nil
        )
        let connection = ConnectionContext(
            connectionID: connectionID,
            connectionGeneration: accepted.binding.registration.generation,
            principal: principal,
            policyProfile: Self.childPolicyProfile(providerIdentifier: handshake.providerIdentifier),
            restrictedToolNames: accepted.restrictedTools,
            additionalToolNames: accepted.additionalTools,
            ephemeralGrantedOperations: []
        )
        let server = Server(
            name: "RepoPrompt CE",
            version: directHeadlessCLIVersion,
            title: "RepoPrompt CE Headless Child",
            instructions: "Private run-scoped RepoPrompt MCP domain endpoint.",
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .init(strict: true, responseSendTimeout: .seconds(5))
        )
        await installHandlers(server: server, prepared: prepared, connection: connection)
        let transport = MCPStdioServerTransport(
            stdinFD: fd,
            stdoutFD: fd,
            writeStallTimeout: .seconds(5),
            logger: logger
        )
        do {
            try await server.start(transport: transport)
            _ = await transport.waitUntilTerminal()
            let deliveryDrained = await transport.waitForDeliveryDrain(
                timeout: prepared.runtime.configuration.hostDrainTimeout
            )
            if !deliveryDrained {
                logger.warning("Private child delivery drain reached its bound")
            }
            await server.stop()
            await server.waitUntilCompleted()
        } catch {
            logger.warning("Private child MCP connection failed", metadata: ["error": "\(error)"])
        }
        await server.stop()
        await prepared.runtime.domainHost.cancelInvocations(
            connectionID: connectionID,
            connectionGeneration: accepted.binding.registration.generation
        )
        await prepared.runtime.domainHost.releaseConnection(
            connectionID: connectionID,
            connectionGeneration: accepted.binding.registration.generation
        )
        _ = await prepared.runtime.routingCoordinator.unregisterConnection(
            accepted.binding.registration,
            operationID: UUID()
        )
    }

    static func securityContext(
        prepared: PreparedRuntime,
        connection: ConnectionContext,
        invocationID: UUID
    ) async -> DomainToolInvocationSecurityContext {
        let snapshot = try? await prepared.context.snapshot(
            connectionID: connection.connectionID,
            sessionID: connection.principal.runID
        )
        return DomainToolInvocationSecurityContext(
            principal: connection.principal,
            connectionID: connection.connectionID,
            connectionGeneration: connection.connectionGeneration,
            invocationID: invocationID,
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            workspaceID: snapshot?.identity.workspaceID,
            workspaceRevision: snapshot?.workspace.revisions.workingRevision,
            authorizedCanonicalRoots: Set(snapshot?.roots.map(\.path) ?? []),
            hasAuthoritativeRoutingContext: snapshot != nil,
            ephemeralGrantedToolNames: connection.additionalToolNames,
            ephemeralGrantedOperations: connection.ephemeralGrantedOperations
        )
    }

    /// Binds the kernel-observed parent PID to the executable identity currently on disk.
    /// Display names and initialize metadata never participate in mutation authority.
    nonisolated static func verifiedExecutableFingerprint(processID: Int32) -> String? {
        let executablePath: String
        #if canImport(Darwin)
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            executablePath = String(cString: buffer)
        #elseif canImport(Glibc)
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(
                atPath: "/proc/\(processID)/exe"
            ) else { return nil }
            executablePath = destination
        #else
            return nil
        #endif
        let path = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let material = "\(path)|\(info.st_dev)|\(info.st_ino)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func childPolicyProfile(
        providerIdentifier: String
    ) -> MCPClientToolPolicyProfile {
        let normalized = providerIdentifier.lowercased()
        if normalized.contains("codex") { return .agentModeCodexEngineer }
        if normalized.contains("claude") { return .agentModeClaudeEngineer }
        if normalized.contains("opencode") { return .agentModeOpenCodeEngineer }
        if normalized.contains("cursor") { return .agentModeCursorEngineer }
        if normalized.contains("grok") { return .agentModeGrokBuildEngineer }
        return .agentModeGenericEngineer
    }

    func teardown(_ prepared: PreparedRuntime) async {
        await prepared.childEndpoint.stop()
        await prepared.providerCoordinator.shutdown()
        await prepared.runtime.domainHost.cancelInvocations(
            connectionID: prepared.connectionID,
            connectionGeneration: prepared.connectionGeneration
        )
        await prepared.runtime.standaloneScopeCoordinator.unregister(scopeID: prepared.scopeID)
        await prepared.runtime.domainHost.releaseConnection(
            connectionID: prepared.connectionID,
            connectionGeneration: prepared.connectionGeneration
        )
        await MCPDomainStandaloneToolInstaller.uninstall(prepared.installation, runtime: prepared.runtime)
        _ = await prepared.authorityHost.shutdown(
            reason: "direct_headless_transport_closed",
            deadline: .seconds(5)
        )
    }

    /// Explicit isolated profiles are test/preview sandboxes, so they may bootstrap a
    /// workspace from explicitly supplied roots. The canonical default profile never
    /// persists a workspace synthesized from cwd or other implicit process state.
    private func ensureExplicitIsolatedWorkspace(
        runtime: MCPDomainRuntime,
        roots: [URL]
    ) async throws {
        let catalog = await runtime.workspaceStore.snapshot()
        guard catalog.workspaces.isEmpty else { return }
        let workspaceID = UUID()
        let contextID = UUID()
        let object: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Headless \(roots.first?.lastPathComponent ?? "Workspace")",
            "repoPaths": roots.map(\.path),
            "activeComposeTabID": contextID.uuidString,
            "composeTabs": [[
                "id": contextID.uuidString,
                "name": "Headless",
                "prompt": "",
                "selectedPaths": []
            ]]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let fileURL = runtime.configuration.workspaceStorageDirectory
            .appendingPathComponent("\(workspaceID.uuidString).json", isDirectory: false)
        let document = try DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL)
        let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: catalog.catalogRevision,
            origin: .standalone,
            command: .createWorkspace(document)
        ))
        guard outcome.disposition == .applied || outcome.disposition == .deduplicated else {
            throw DirectHeadlessDomainContext.Error.stateConflict(
                outcome.diagnostic ?? outcome.errorCode?.rawValue ?? outcome.disposition.rawValue
            )
        }
    }

    private static func successResult(_ value: Value) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
            ?? String(describing: value)
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    nonisolated static func validatedCallArguments(
        toolName: String,
        arguments: [String: Value]
    ) throws -> [String: Value] {
        let supportedOperations: Set<String>
        switch toolName {
        case "agent_run":
            supportedOperations = ["start", "poll", "wait", "cancel"]
        case "agent_explore":
            supportedOperations = ["start", "poll", "wait", "cancel"]
        default:
            return arguments
        }
        guard let operation = arguments["op"]?.stringValue,
              supportedOperations.contains(operation)
        else {
            throw MCPError.invalidParams("\(toolName) requires a supported string op")
        }
        return arguments
    }
}

private actor DirectHeadlessAdapterServing: RepoPromptMCPServing {
    private let prepared: DirectHeadlessMCPService.PreparedRuntime
    private let connection: DirectHeadlessMCPService.ConnectionContext

    init(
        prepared: DirectHeadlessMCPService.PreparedRuntime,
        connection: DirectHeadlessMCPService.ConnectionContext
    ) {
        self.prepared = prepared
        self.connection = connection
    }

    func projectSnapshot(id _: UUID) async throws -> ProjectSnapshot {
        throw ServiceAPIError(code: .capabilityMissing, message: "Direct-headless project snapshots use canonical MCP tools")
    }

    func sessionSnapshot(id _: UUID) async throws -> SessionSnapshot {
        throw ServiceAPIError(code: .capabilityMissing, message: "Direct-headless session snapshots use canonical MCP tools")
    }

    func events(after _: ServiceCursor?, limit _: Int) async throws -> EventPage {
        throw ServiceAPIError(code: .capabilityMissing, message: "Direct-headless event replay is unavailable")
    }

    func advertisedToolNames(isRootSession _: Bool) async throws -> Set<String> {
        try await prepared.readCapability.perform { [connection] in
            DirectHeadlessMCPService.visibleToolNames(connection)
        }
    }

    func invoke(
        toolName: String,
        argumentsJSON: Data,
        binding _: AuthorityMCPBinding
    ) async throws -> Data {
        guard DirectHeadlessMCPService.visibleToolNames(connection).contains(toolName) else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Tool is unavailable for this client policy")
        }
        let decoded = try JSONDecoder().decode([String: Value].self, from: argumentsJSON)
        let arguments = try DirectHeadlessMCPService.validatedCallArguments(
            toolName: toolName,
            arguments: decoded
        )
        let scope: MCPDomainToolRegistrationScope = MCPGlobalToolName.orderedToolNames.contains(toolName)
            ? .application
            : .standalone(id: prepared.scopeID)
        guard let resolved = await prepared.runtime.toolRegistry.resolve(
            toolName: toolName,
            scope: scope
        ) else {
            throw MCPDomainHostError.scopeUnavailable(toolName: toolName, scope: scope)
        }
        let registration = try await prepared.runtime.routingCoordinator.currentRegistration(
            connectionID: connection.connectionID
        )
        guard registration.runtimeID == prepared.runtime.identity.runtimeID,
              registration.generation == connection.connectionGeneration,
              await prepared.runtime.toolRegistry.isActive(resolved.handle)
        else {
            throw MCPDomainHostError.connectionRegistrationInvalid
        }
        let security = await DirectHeadlessMCPService.securityContext(
            prepared: prepared,
            connection: connection,
            invocationID: UUID()
        )
        let value = try await prepared.mutationCapability.perform {
            try await MCPDomainInvocationSecurityContext.$current.withValue(security) {
                try await resolved.binding(arguments)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// Host-owned direct-headless lifetime. The private executable combines this
/// opaque serving capability with `RepoPromptMCPAdapter`; the Host target never
/// imports or constructs that transport adapter.
public actor RepoPromptDirectHeadlessComposition {
    public nonisolated let serving: any RepoPromptMCPServing
    public nonisolated let binding: AuthorityMCPBinding
    public nonisolated let isRootSession = true

    private let runtime: AuthorityServerRuntime
    private var stopped = false

    private init(
        runtime: AuthorityServerRuntime,
        serving: any RepoPromptMCPServing,
        binding: AuthorityMCPBinding
    ) {
        self.runtime = runtime
        self.serving = serving
        self.binding = binding
    }

    public static func start(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) async throws -> RepoPromptDirectHeadlessComposition {
        let locations = try DirectHeadlessRuntimeLocationResolver.resolve(
            environment: environment,
            currentDirectory: currentDirectory
        )
        try FileManager.default.createDirectory(
            at: locations.storageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stateRoot = try canonicalExistingDirectory(locations.storageDirectory)
        let directories = DirectHeadlessAuthorityDirectories(root: stateRoot)
        for directory in directories.all {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let namespace = try AuthorityNamespaceDescriptor(
            storageRoot: stateRoot.path,
            databasePath: stateRoot.appendingPathComponent("repoprompt.sqlite").path,
            profile: locations.profileIdentifier,
            servingMode: .directHeadless
        )
        let runtime = try await RepoPromptAuthorityHostFactory.startServer(
            configuration: .init(
                host: .init(namespace: namespace),
                worktreeDirectory: directories.worktrees.path,
                artifactDirectory: directories.artifacts.path,
                projectDirectory: directories.projects.path,
                providerHomeDirectory: directories.providerHomes.path,
                providerExecutables: [:],
                enabledProviders: [],
                enabledDirectProviders: [],
                providerVersions: [:],
                providerProtocols: [:],
                providerCredentialSources: [:],
                providerAuthenticationStatusFiles: [:],
                providerModelCatalogFiles: [:],
                providerVaultKey: nil,
                providerVaultDecryptionKeys: [],
                providerVaultFilePath: stateRoot.appendingPathComponent("provider-credentials.vault").path,
                restoreActivationTokenPath: environment["REPOPROMPT_RESTORE_ACTIVATION_TOKEN_FILE"],
                projectSourcePolicy: .disabled,
                projectSourceGitCredentials: try ProjectSourceGitCredentials()
            )
        )
        do {
            let actor = ExternalActor(
                userID: "direct-headless:\(locations.profileIdentifier)",
                username: "direct-headless",
                displayName: "RepoPrompt Direct Headless"
            )
            let project = try await launchProject(
                authority: runtime.authority,
                roots: locations.workingDirectories,
                actor: actor,
                namespaceID: namespace.namespaceID
            )
            // The private helper reuses one session for the same authority/project
            // instead of accumulating a new visible private session on every launch.
            let sessionIdentity = "\(namespace.namespaceID):\(project.projectID.uuidString)"
            let session = try await runtime.authority.createSession(
                input: .init(
                    projectID: project.projectID,
                    provider: .codex,
                    visibility: .privateSession
                ),
                externalActor: actor,
                idempotencyKey: "direct-headless-session:\(sessionIdentity)",
                requestDigest: sessionIdentity
            )
            let serving = try await runtime.host.makeMCPService(
                portalSettings: runtime.portalDesktopSettings,
                toolPolicy: .direct
            )
            return RepoPromptDirectHeadlessComposition(
                runtime: runtime,
                serving: serving,
                binding: .init(sessionID: session.sessionID, actor: actor)
            )
        } catch {
            _ = await runtime.host.shutdown(reason: "direct_headless_composition_failed")
            throw error
        }
    }

    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        _ = await runtime.host.shutdown(reason: "direct_headless_transport_closed")
    }

    private static func launchProject(
        authority: RepoPromptHeadlessAuthority,
        roots: [URL],
        actor: ExternalActor,
        namespaceID: String
    ) async throws -> ProjectSnapshot {
        let canonicalRoots = roots.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        let desiredPaths = Set(canonicalRoots.map(\.path))
        if let existing = await authority.projectSnapshots().first(where: { project in
            project.roots.count == desiredPaths.count
                && Set(project.roots.map(\.canonicalPath)) == desiredPaths
        }) {
            return existing
        }
        let input = CreateProjectInput(
            name: canonicalRoots.first?.lastPathComponent.isEmpty == false
                ? "Headless \(canonicalRoots[0].lastPathComponent)"
                : "Direct Headless",
            roots: canonicalRoots.enumerated().map { index, root in
                .init(
                    logicalName: root.lastPathComponent.isEmpty ? "root-\(index + 1)" : root.lastPathComponent,
                    path: root.path,
                    writable: true
                )
            }
        )
        let key = "direct-headless-project:\(namespaceID)"
        return try await authority.createProject(
            input: input,
            externalActor: actor,
            idempotencyKey: key,
            requestDigest: desiredPaths.sorted().joined(separator: "\u{0}")
        )
    }

    private static func canonicalExistingDirectory(_ directory: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(directory.path, &buffer) != nil else {
            throw ServiceAPIError(
                code: .rootUnauthorized,
                message: "Direct-headless authority root could not be canonicalized"
            )
        }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
}

private struct DirectHeadlessAuthorityDirectories {
    let worktrees: URL
    let artifacts: URL
    let projects: URL
    let providerHomes: URL

    init(root: URL) {
        worktrees = root.appendingPathComponent("AuthorityWorktrees", isDirectory: true)
        artifacts = root.appendingPathComponent("AuthorityArtifacts", isDirectory: true)
        projects = root.appendingPathComponent("AuthorityProjects", isDirectory: true)
        providerHomes = root.appendingPathComponent("AuthorityProviderHomes", isDirectory: true)
    }

    var all: [URL] { [worktrees, artifacts, projects, providerHomes] }
}

public enum RepoPromptDirectHeadlessChildBridgeRunner {
    public static func isRequested() -> Bool {
        DirectHeadlessChildBridge.isRequested()
    }

    public static func run() async throws {
        try await DirectHeadlessChildBridge.run()
    }
}
