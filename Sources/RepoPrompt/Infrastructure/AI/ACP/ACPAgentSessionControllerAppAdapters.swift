import Darwin
import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptProcess
import RepoPromptSettingsCore

final class ACPAgentSessionAppHost: ACPAgentSessionHost, @unchecked Sendable {
    private let routingLock = NSLock()
    private var routingCleanupReceipt: MCPRunRoutingCleanupReceipt?
    private var routingCleanupTail: Task<Void, Never>?
    private var resourceShutdownTask: Task<Void, Never>?

    fileprivate func retainRoutingCleanup(_ receipt: MCPRunRoutingCleanupReceipt) -> Bool {
        routingLock.withLock {
            guard resourceShutdownTask == nil, receipt.routeOwner != nil, !receipt.isConsumed,
                  receipt.managerIdentity == ObjectIdentifier(ServerNetworkManager.shared)
            else { return false }
            if let origin = routingCleanupReceipt {
                guard origin.runID == receipt.runID, origin.routeOwner === receipt.routeOwner else { return false }
                if origin == receipt { return true }
            }
            let previous = routingCleanupReceipt
            let predecessor = routingCleanupTail
            routingCleanupReceipt = receipt
            if let previous {
                routingCleanupTail = Task {
                    await predecessor?.value
                    await ServerNetworkManager.shared.cleanupRunRoutingState(ownedBy: previous)
                }
            }
            return true
        }
    }

    #if DEBUG
        func test_originatingRoutingCleanupReceipt() -> MCPRunRoutingCleanupReceipt? {
            routingLock.withLock { routingCleanupReceipt }
        }
    #endif

    func finishControllerResources() async {
        let task = routingLock.withLock { () -> Task<Void, Never> in
            if let resourceShutdownTask { return resourceShutdownTask }
            let receipt = routingCleanupReceipt
            let predecessor = routingCleanupTail
            routingCleanupReceipt = nil
            routingCleanupTail = nil
            let task = Task {
                await predecessor?.value
                if let receipt { await ServerNetworkManager.shared.cleanupRunRoutingState(ownedBy: receipt) }
            }
            resourceShutdownTask = task
            return task
        }
        await task.value
    }

    var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    var repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration {
        .repoPrompt
    }

    func preflightInjectedMCPServers(in sessionConfiguration: ACPSessionConfiguration) throws {
        for server in sessionConfiguration.mcpServers {
            try server.validateACPLaunchCommand(workingDirectory: sessionConfiguration.workingDirectory)
        }
    }

    func preflightInjectedMCPServers(in sessionConfiguration: ACPSessionConfiguration, environment: [String: String]) throws {
        for server in sessionConfiguration.mcpServers {
            let resolvedBareCommandPath = try Self.resolvedBareACPCommandPath(
                for: server.command,
                serverName: server.name,
                environment: environment
            )
            try server.validateACPLaunchCommand(
                workingDirectory: sessionConfiguration.workingDirectory,
                resolvedBareCommandPath: resolvedBareCommandPath
            )
        }
    }

    private static func resolvedBareACPCommandPath(
        for command: String,
        serverName: String,
        environment: [String: String]
    ) throws -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.range(of: #"[/~]"#, options: .regularExpression) == nil else { return nil }
        let resolved = CommandPathResolver.resolve(
            trimmed,
            environment: environment,
            additionalPaths: [],
            preferredBasenames: [trimmed]
        )
        guard resolved != trimmed else {
            throw RepoPromptMCPServerConfiguration.ACPCommandValidationError.unresolvedCommand(serverName: serverName, command: trimmed)
        }
        return resolved
    }

    var cursorAutoModelRaw: String {
        AgentModel.cursorAuto.rawValue
    }

    func mcpClientNameHint(for kind: AgentProviderKind) -> String? {
        kind.mcpClientNameHint
    }

    func displayName(for kind: AgentProviderKind) -> String {
        kind.displayName
    }

    func normalizedModelParameterSelections(_ selections: [ACPModelParameterSelection]) -> [ACPModelParameterSelection] {
        ACPModelParameterSelection.normalized(selections)
    }

    func canonicalParameterModelRaw(_ raw: String, providerID: ACPProviderID) -> String {
        ACPModelParameterIdentity.canonicalBaseModelRaw(raw, providerID: providerID)
    }

    func parameterIdentityMatches(_ selection: ACPModelParameterSelection, providerID: ACPProviderID, baseModelRaw: String, kind: ACPModelParameterKind) -> Bool {
        selection.identity == ACPModelParameterIdentity(providerID: providerID, baseModelRaw: baseModelRaw, kind: kind)
    }

    func recognizedDevinPermissionMode(_ mode: String?) -> Bool {
        DevinAgentToolPreferences.PermissionLevel.isRecognizedCLIPermissionMode(mode)
    }

    func normalizedDevinPermissionMode(_ mode: String?) -> String? {
        DevinAgentToolPreferences.PermissionLevel.from(cliPermissionMode: mode).cliPermissionMode
    }

    func devinThinkingSelection(for model: String) -> ACPDevinThinkingSelection? {
        guard let entry = DevinModelCatalog.current.entry(matching: model), let thinking = entry.thinking else { return nil }
        return ACPDevinThinkingSelection(advertisedModelRaw: entry.advertisedModelRaw, configID: thinking.configID, choiceRaw: thinking.choiceRaw)
    }

    func grokDecomposition(raw: String, options: [AgentModelOption]) -> ACPGrokModelDecomposition? {
        guard let result = GrokBuildModelSpecifier.decompose(raw: raw, options: options) else { return nil }
        return ACPGrokModelDecomposition(base: result.base, explicitEffort: result.explicitEffort)
    }

    func grokCompoundRaw(base: String, effort: CodexReasoningEffort?) -> String {
        GrokBuildModelSpecifier(baseModel: base, reasoningEffort: effort).compoundRaw
    }

    func resolvedModelSnapshot(for providerID: ACPProviderID) -> ACPDiscoveredSessionModels? {
        AgentModelCatalogRuntime.shared.acpRegistry.resolvedSnapshot(for: providerID)
    }

    func publishDiscoveredModels(_ models: ACPDiscoveredSessionModels, for providerID: ACPProviderID) {
        _ = AgentModelCatalogRuntime.shared.acpRegistry.updateDiscoveredModels(models, for: providerID)
    }

    func filterEnvironment(_ environment: [String: String], launchConfiguration: ACPLaunchConfiguration, kind: AgentProviderKind) async -> [String: String] {
        await ProviderEnvironmentFiltering.filterACP(environment, launchConfiguration: launchConfiguration, for: kind)
    }

    func mergingCurrentCarrier(into environment: [String: String]) -> [String: String] {
        DomainChildLaunchEnvironmentBridge.mergingCurrentCarrier(into: environment)
    }

    func registerExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID?) async {
        let origin = routingLock.withLock { (closed: resourceShutdownTask != nil, receipt: routingCleanupReceipt) }
        guard !origin.closed else { return }
        await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: clientName, runID: runID, registration: origin.receipt)
    }

    func clearExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID?) async {
        let origin = routingLock.withLock { (closed: resourceShutdownTask != nil, receipt: routingCleanupReceipt) }
        guard !origin.closed else { return }
        await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: clientName, runID: runID, registration: origin.receipt)
    }

    func permissionIsAutoSelectable(optionID: String?, providerID: ACPProviderID) -> Bool {
        ACPPermissionOptionPolicy.isAutoSelectable(optionID: optionID, for: providerID)
    }

    func permissionOneTimeAllow(options: [(optionID: String, kind: String)], providerID: ACPProviderID) -> String? {
        ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(options: options, providerID: providerID)
    }

    func permissionOneTimeReject(options: [(optionID: String, kind: String)]) -> String? {
        ACPPermissionOptionPolicy.overseerOneTimeRejectOptionID(options: options)
    }

    #if DEBUG
        func diagnosticErrorKind(_ error: Error) -> String {
            if error is ExecutableFileIdentityError { return "executable_identity" }
            if error is CursorACPLaunchResolutionError || error is OpenCodeACPLaunchResolutionError { return "launch_resolution" }
            if error is CLIProcessRunnerError { return "process_runner" }
            if error is CancellationError { return "cancelled" }
            return "other"
        }

        func recordRunRoutingEvent(runID: UUID, event: String, fields: [String: String]) async {
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(runID: runID, event: event, fields: fields)
        }
    #endif
}

extension ACPAgentSessionController: MCPRunRoutingCleanupRetaining {
    func retainRoutingCleanup(_ receipt: MCPRunRoutingCleanupReceipt) -> Bool {
        guard let host = hostForRoutingHandoff(expectedRunID: receipt.runID) as? ACPAgentSessionAppHost else { return false }
        return host.retainRoutingCleanup(receipt)
    }

    /// Cursor persists bracket overrides in existing model strings; ACP requires separate exact model/config calls.
    func applyCursorModelSelection(
        _ raw: String,
        overrides: [CursorAIModelCatalog.ModelSpecifier.Override] = []
    ) async throws {
        let specifier = try CursorAIModelCatalog.ModelSpecifier(raw: raw)
        try await setSessionModel(specifier.baseModelRaw)
        var encoded = raw
        for override in overrides {
            guard let updated = try CursorAIModelCatalog.ModelSpecifier(raw: encoded).replacing(configID: override.configID, valueRaw: override.valueRaw) else {
                throw CursorAIModelCatalog.ModelSpecifier.invalid(override.configID)
            }
            encoded = updated
        }
        let values = try CursorAIModelCatalog.ModelSpecifier(raw: encoded).selections(in: currentDiscoveredSessionModels())
        let selections = values.map {
            ACPModelParameterSelection(providerID: .cursor, baseModelRaw: $0.baseModelRaw, kind: $0.kind, configID: $0.configID, valueRaw: $0.valueRaw)
        }
        let report = try await applySessionModelParameterSelections(selections)
        try report.validateNoSkippedSelections()
    }

    init(
        provider: any ACPAgentProvider,
        runRequest: ACPRunRequest,
        diagnosticSink: DiagnosticSink? = nil,
        requestTimeouts: RequestTimeouts = .default,
        allowsProviderProcessLaunchForTesting: Bool = false
    ) throws {
        try self.init(provider: provider, runRequest: runRequest, host: ACPAgentSessionAppHost(), diagnosticSink: diagnosticSink, requestTimeouts: requestTimeouts, allowsProviderProcessLaunchForTesting: allowsProviderProcessLaunchForTesting)
    }
}
