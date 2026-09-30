import Foundation

struct ClaudeCodeExternalMCPStatusProbeResult: Equatable {
    enum Status: Equatable {
        case connected
        case notConnected
        case unavailable
    }

    let status: Status
}

/// Claude Code owns its Figma MCP configuration and OAuth session. RepoPrompt can inspect the
/// provider-reported status and request provider-owned credential logout, but it never reads,
/// copies, persists, or injects that session.
struct ClaudeCodeExternalMCPProviderAdapter: ExternalMCPProviderAdapter {
    typealias StatusProbe = @Sendable (
        ExternalMCPProviderRuntimeContext,
        ExternalMCPIntegrationDefinition
    ) async -> ClaudeCodeExternalMCPStatusProbeResult
    typealias LogoutOperation = @Sendable (
        ExternalMCPProviderRuntimeContext,
        ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPCleanupReceipt

    static let figmaRemoteMCPURL = "https://mcp.figma.com/mcp"
    static let figmaPluginServerID = "plugin:figma:figma"
    static let figmaLogoutArguments = ["mcp", "logout", figmaPluginServerID]

    let runtimeProvider: ExternalMCPRuntimeProvider = .claudeCode
    private let statusProbe: StatusProbe?
    private let logoutOperation: LogoutOperation?

    init(
        statusProbe: StatusProbe? = nil,
        logoutOperation: LogoutOperation? = nil
    ) {
        self.statusProbe = statusProbe ?? Self.defaultStatusProbe
        self.logoutOperation = logoutOperation ?? Self.defaultLogoutOperation
    }

    func capabilities(in context: ExternalMCPProviderRuntimeContext) async -> ExternalMCPCapabilityDescriptor {
        guard eligibleContext(context) else { return .unsupported }
        return .init(
            statusVerification: statusProbe == nil ? .unsupported : .providerNative,
            credentialLogout: logoutOperation == nil ? .unsupported : .providerNative
        )
    }

    func discoverExisting(in _: ExternalMCPProviderRuntimeContext) async -> ExternalMCPDiscoveryResult {
        .init(status: .unsupported, definition: nil)
    }

    func authenticate(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPAuthenticationResult {
        .init(
            status: .unsupported,
            snapshot: unsupportedSnapshot(
                for: integration,
                diagnostic: "Claude Code Figma authentication remains provider-owned."
            )
        )
    }

    func refreshStatus(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPRuntimeSnapshot {
        guard eligibleContext(context),
              integration.isSupportedDefinition,
              integration.repoPromptActivation == .enabled,
              !context.cancellationToken.isCancelled
        else {
            return unsupportedSnapshot(for: integration, diagnostic: "Claude Code Figma status context is unavailable.")
        }

        guard let statusProbe else {
            return unsupportedSnapshot(for: integration, diagnostic: "Claude Code Figma proof is not registered.")
        }
        let probe = await statusProbe(context, integration)
        guard !context.cancellationToken.isCancelled else {
            return unsupportedSnapshot(for: integration, diagnostic: "Claude Code Figma status check was cancelled.")
        }
        switch probe.status {
        case .connected:
            return .init(
                integrationID: integration.integrationID,
                connection: .connected,
                authentication: .providerOwned,
                verifiedAt: Date()
            )
        case .notConnected:
            return .init(
                integrationID: integration.integrationID,
                connection: .disconnected,
                authentication: .unknown,
                diagnostics: ["Claude Code reports that the Figma MCP server is not connected."]
            )
        case .unavailable:
            return unsupportedSnapshot(for: integration, diagnostic: "Claude Code Figma status is unavailable.")
        }
    }

    func applyRuntimeAccess(
        in context: ExternalMCPProviderRuntimeContext,
        decision: ExternalMCPAccessDecision
    ) async -> ExternalMCPRuntimeBindingResult {
        guard !decision.isAllowed else {
            return .init(
                lease: nil,
                decision: .denied(
                    integrationID: decision.integrationID,
                    runtimeIdentity: context.identity,
                    revision: context.coordinatorRevision,
                    reason: context.cancellationToken.isCancelled ? .cancelled : .unsupported,
                    verifiedSnapshot: decision.verifiedSnapshot
                )
            )
        }
        return .init(lease: nil, decision: decision)
    }

    func disconnect(
        in context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPDisconnectResult {
        guard eligibleContext(context),
              integration.isSupportedDefinition,
              integration.repoPromptActivation == .enabled,
              !context.cancellationToken.isCancelled,
              let logoutOperation
        else {
            return .init(
                receipt: .init(
                    outcome: context.cancellationToken.isCancelled ? .cancelled : .unsupported,
                    detail: "Claude Code Figma credential logout is unavailable in this context."
                ),
                snapshot: .disconnected(integrationID: integration.integrationID)
            )
        }

        let receipt = await logoutOperation(context, integration)
        let settledReceipt: ExternalMCPCleanupReceipt = if context.cancellationToken.isCancelled || Task.isCancelled {
            .init(outcome: .cancelled, detail: "Claude Code Figma credential logout was cancelled.")
        } else {
            receipt
        }
        return .init(
            receipt: settledReceipt,
            snapshot: .disconnected(integrationID: integration.integrationID)
        )
    }

    static func parseMCPListOutput(
        _ output: String,
        exitStatus _: Int32
    ) -> ClaudeCodeExternalMCPStatusProbeResult {
        // Claude may report a nonzero process status around provider-owned browser/auth state;
        // only the exact canonical record below can establish a connected status.
        let serverRecords = output
            .split(whereSeparator: \.isNewline)
            .map { stripANSI(String($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("\(figmaPluginServerID):") }
        guard serverRecords.count == 1, let record = serverRecords.first else {
            return serverRecords.isEmpty ? .init(status: .notConnected) : .init(status: .unavailable)
        }

        let lowercasedRecord = record.lowercased()
        guard let separator = lowercasedRecord.range(of: " - ", options: .backwards) else {
            return .init(status: .unavailable)
        }
        let serverDescription = String(record[..<separator.lowerBound])
        let expectedPrefix = "\(figmaPluginServerID): "
        guard serverDescription.hasPrefix(expectedPrefix) else {
            return .init(status: .unavailable)
        }
        let endpointAndTransport = String(serverDescription.dropFirst(expectedPrefix.count))
        let httpSuffix = " (http)"
        guard endpointAndTransport.lowercased().hasSuffix(httpSuffix) else {
            return .init(status: .unavailable)
        }
        let endpoint = String(endpointAndTransport.dropLast(httpSuffix.count))
        guard endpoint == figmaRemoteMCPURL else {
            return .init(status: .unavailable)
        }

        let terminalStatus = lowercasedRecord[separator.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard terminalStatus == "✔ connected" || terminalStatus == "✓ connected" else {
            return .init(status: .notConnected)
        }
        return .init(status: .connected)
    }

    static func statusProbeConfiguration(executableIdentity: String) -> CLIProcessConfiguration {
        CLIProcessConfiguration(
            command: executableIdentity,
            workingDirectory: nil,
            additionalPaths: CLILaunchProfiles.claudeCode.supplementalSearchPaths,
            launchPurpose: .cliRunner,
            shellLookupMode: .fallbackOnly,
            captureStdoutTailBytes: 16 * 1024,
            captureStderrTailBytes: 16 * 1024
        )
    }

    static func logoutConfiguration(executableIdentity: String) -> CLIProcessConfiguration {
        statusProbeConfiguration(executableIdentity: executableIdentity)
    }

    private static func defaultStatusProbe(
        context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ClaudeCodeExternalMCPStatusProbeResult {
        guard context.identity.provider == .claudeCode,
              integration.isSupportedDefinition,
              integration.repoPromptActivation == .enabled,
              !context.cancellationToken.isCancelled
        else { return .init(status: .unavailable) }

        do {
            var processConfig = Self.statusProbeConfiguration(
                executableIdentity: context.identity.executableIdentity
            )
            processConfig.discardOutput = false
            let result = try await CLIProcessRunner(config: processConfig).run(
                args: ["mcp", "list"],
                stdin: nil,
                outputMode: .none,
                timeout: 20,
                cancelChildOnTaskCancellation: true
            )
            guard !context.cancellationToken.isCancelled, !Task.isCancelled else {
                return .init(status: .unavailable)
            }
            guard let output = String(data: result.stdout + result.stderr, encoding: .utf8) else {
                return .init(status: .unavailable)
            }
            return parseMCPListOutput(output, exitStatus: result.status)
        } catch is CancellationError {
            return .init(status: .unavailable)
        } catch {
            return .init(status: .unavailable)
        }
    }

    private static func defaultLogoutOperation(
        context: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPCleanupReceipt {
        guard context.identity.provider == .claudeCode,
              integration.isSupportedDefinition,
              integration.repoPromptActivation == .enabled,
              !context.cancellationToken.isCancelled
        else {
            return .init(outcome: .unsupported, detail: "Claude Code Figma credential logout context is unavailable.")
        }

        do {
            var processConfig = Self.logoutConfiguration(
                executableIdentity: context.identity.executableIdentity
            )
            processConfig.discardOutput = true
            let result = try await CLIProcessRunner(config: processConfig).run(
                args: Self.figmaLogoutArguments,
                stdin: nil,
                outputMode: .none,
                timeout: 20,
                cancelChildOnTaskCancellation: true
            )
            guard !context.cancellationToken.isCancelled, !Task.isCancelled else {
                return .init(outcome: .cancelled, detail: "Claude Code Figma credential logout was cancelled.")
            }
            if result.timedOut {
                return .init(outcome: .indeterminate, detail: "Claude Code Figma credential logout timed out.")
            }
            guard result.status == 0 else {
                return .init(outcome: .failed, detail: "Claude Code did not confirm Figma credential logout.")
            }
            return .init(outcome: .completed, detail: "Claude Code cleared its Figma MCP OAuth credentials.")
        } catch is CancellationError {
            return .init(outcome: .cancelled, detail: "Claude Code Figma credential logout was cancelled.")
        } catch {
            return .init(outcome: .failed, detail: "Claude Code Figma credential logout could not be completed.")
        }
    }

    private func eligibleContext(_ context: ExternalMCPProviderRuntimeContext) -> Bool {
        context.identity.provider == .claudeCode
            && context.identity.runtimeKind == .nativeCLI
            && context.sessionClass == .discovery
            && context.isolation == .userNative
            && Self.isClaudeExecutableIdentity(context.identity.executableIdentity)
    }

    private static func isClaudeExecutableIdentity(_ identity: String) -> Bool {
        guard identity == AgentProviderKind.claudeCode.commandName || identity.hasPrefix("/") else {
            return false
        }
        guard identity == AgentProviderKind.claudeCode.commandName ||
            URL(fileURLWithPath: identity).standardizedFileURL.path == identity
        else {
            return false
        }

        let pathComponents = URL(fileURLWithPath: identity).pathComponents
        let isCanonicalClaudeExecutable = CLILaunchProfiles.claudeCode.preferredBasenames.contains(
            URL(fileURLWithPath: identity).lastPathComponent
        )
        let isOfficialVersionedClaudeExecutable = pathComponents.dropLast().suffix(4).elementsEqual([
            ".local", "share", "claude", "versions"
        ])
        return isCanonicalClaudeExecutable || isOfficialVersionedClaudeExecutable
    }

    private func unsupportedSnapshot(
        for integration: ExternalMCPIntegrationDefinition,
        diagnostic: String
    ) -> ExternalMCPRuntimeSnapshot {
        .init(
            integrationID: integration.integrationID,
            connection: .unavailable,
            authentication: .unsupported,
            diagnostics: [diagnostic]
        )
    }

    private static func stripANSI(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x1B {
                index += 1
                if index < scalars.count, scalars[index].value == 0x5B {
                    index += 1
                    while index < scalars.count {
                        let value = scalars[index].value
                        index += 1
                        if (0x40 ... 0x7E).contains(value) { break }
                    }
                }
                continue
            }
            if scalar.value >= 0x20 || scalar.value == 0x09 {
                result.append(scalar)
            }
            index += 1
        }
        return String(result)
    }
}
