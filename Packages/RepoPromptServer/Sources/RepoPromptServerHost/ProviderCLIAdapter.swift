import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

enum ProviderCLIProbeEnvironment {
    static func prepare(for kind: ProviderKind) throws -> [String: String] {
        let manager = FileManager.default
        let home = manager.temporaryDirectory
            .appendingPathComponent("repoprompt-provider-probes", isDirectory: true)
            .appendingPathComponent(kind.rawValue, isDirectory: true)
        let config = home.appendingPathComponent(".config", isDirectory: true)
        let cache = home.appendingPathComponent(".cache", isDirectory: true)
        let data = home.appendingPathComponent(".local/share", isDirectory: true)
        for directory in [home, config, cache, data] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return [
            "HOME": home.path,
            "XDG_CONFIG_HOME": config.path,
            "XDG_CACHE_HOME": cache.path,
            "XDG_DATA_HOME": data.path,
            "DISABLE_AUTOUPDATER": "1",
            "CURSOR_AGENT_DISABLE_AUTO_UPDATE": "1"
        ]
    }
}

/// Provider-neutral runtime router. Provider protocol knowledge lives in the
/// individual native runtime controllers, never in this dispatcher.
public actor PortableAgentProviderDispatcher: AgentProviderDispatcher, InteractionDeliveryPort {
    private struct RunRoute: Sendable {
        let kind: ProviderKind
        let exactProviderID: ProviderSettingsID?
    }

    private let runtimes: [ProviderKind: any AgentProviderRuntime]
    private let exactRuntimes: [ProviderSettingsID: any AgentProviderRuntime]
    private let cataloguedConfigurations: [ProviderKind: ProviderCLIConfiguration]
    private var enabledProviders: Set<ProviderKind>
    private var enabledExactProviders: Set<ProviderSettingsID>
    private var runtimeDefaults: [ProviderKind: ProviderRuntimeDefaults]
    private var exactRuntimeDefaults: [ProviderSettingsID: ProviderRuntimeDefaults]
    private var knownRuns: [UUID: RunRoute] = [:]
    private var preflightCache: [ProviderKind: (capability: ProviderCapability, expiresAt: ContinuousClock.Instant)] = [:]
    private var preflightTasks: [ProviderKind: Task<ProviderCapability, Never>] = [:]
    private let preflightCacheDuration: Duration

    public init(
        runtimes: [any AgentProviderRuntime],
        exactRuntimes: [ProviderSettingsID: any AgentProviderRuntime] = [:],
        cataloguedConfigurations: [ProviderCLIConfiguration] = [],
        enabledProviders: Set<ProviderKind>? = nil,
        enabledExactProviders: Set<ProviderSettingsID>? = nil,
        preflightCacheDuration: Duration = .seconds(15)
    ) {
        let initialEnabled = enabledProviders ?? Set(runtimes.map(\.kind))
        self.runtimes = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.kind, $0) })
        self.exactRuntimes = exactRuntimes
        self.cataloguedConfigurations = Dictionary(uniqueKeysWithValues: cataloguedConfigurations.map { ($0.kind, $0) })
        self.enabledProviders = initialEnabled
        let initialExactEnabled = enabledExactProviders ?? Set(exactRuntimes.keys)
        self.enabledExactProviders = initialExactEnabled
        self.preflightCacheDuration = preflightCacheDuration
        runtimeDefaults = Dictionary(uniqueKeysWithValues: runtimes.map {
            ($0.kind, ProviderRuntimeDefaults(enabled: initialEnabled.contains($0.kind)))
        })
        exactRuntimeDefaults = Dictionary(uniqueKeysWithValues: exactRuntimes.keys.map {
            ($0, ProviderRuntimeDefaults(enabled: initialExactEnabled.contains($0)))
        })
    }

    public func capabilities() async -> [ProviderCapability] {
        var values: [ProviderCapability] = []
        for kind in ProviderKind.allCases {
            if kind == .headlessAdapter, !enabledExactProviders.isEmpty {
                values.append(.init(kind: .headlessAdapter, enabled: true, executable: nil, supportsResume: false, supportsSteering: false, protocolVersion: "direct-api-v1"))
            } else if enabledProviders.contains(kind), let runtime = runtimes[kind] {
                await values.append(runtime.capability())
            } else {
                values.append(unavailableCapability(for: kind))
            }
        }
        return values
    }

    public func preflight() async -> [ProviderCapability] {
        await withTaskGroup(of: (ProviderKind, ProviderCapability).self) { group in
            for kind in ProviderKind.allCases {
                group.addTask { (kind, await self.preflight(kind: kind)) }
            }
            var values: [ProviderKind: ProviderCapability] = [:]
            for await (kind, capability) in group {
                values[kind] = capability
            }
            return ProviderKind.allCases.compactMap { values[$0] }
        }
    }

    private func preflight(kind: ProviderKind) async -> ProviderCapability {
        if kind == .headlessAdapter, !enabledExactProviders.isEmpty {
            var anyEnabled = false
            for providerID in enabledExactProviders {
                if let runtime = exactRuntimes[providerID], await runtime.preflight().enabled { anyEnabled = true }
            }
            return .init(kind: .headlessAdapter, enabled: anyEnabled, executable: nil, supportsResume: false, supportsSteering: false, protocolVersion: "direct-api-v1", reasonUnavailable: anyEnabled ? nil : "direct API preflight failed")
        }
        guard enabledProviders.contains(kind) else {
            return unavailableCapability(for: kind)
        }
        return await validate(kind: kind)
    }

    public func validate(kind: ProviderKind) async -> ProviderCapability {
        guard let runtime = runtimes[kind] else {
            return unavailableCapability(for: kind)
        }
        let clock = ContinuousClock()
        if let cached = preflightCache[kind], clock.now < cached.expiresAt {
            return cached.capability
        }
        if let task = preflightTasks[kind] {
            return await task.value
        }
        let task = Task { await runtime.preflight() }
        preflightTasks[kind] = task
        let capability = await task.value
        preflightTasks[kind] = nil
        preflightCache[kind] = (capability, clock.now.advanced(by: preflightCacheDuration))
        return capability
    }

    public func validateEnabled(kind: ProviderKind) async -> ProviderCapability {
        guard enabledProviders.contains(kind) else {
            return unavailableCapability(for: kind)
        }
        return await validate(kind: kind)
    }

    public func recoverProcessFamilies() async throws {
        for runtime in runtimes.values {
            try await runtime.recoverProcessFamilies()
        }
    }

    public func applyRuntimeDefaults(kind: ProviderKind, defaults: ProviderRuntimeDefaults) throws {
        guard runtimes[kind] != nil, cataloguedConfigurations.isEmpty || cataloguedConfigurations[kind] != nil else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Provider is not configured")
        }
        runtimeDefaults[kind] = defaults
        preflightCache[kind] = nil
        if defaults.enabled {
            enabledProviders.insert(kind)
        } else {
            // Existing runs retain their native controller. New admission is
            // rejected immediately without terminating in-flight work.
            enabledProviders.remove(kind)
        }
    }

    public func applyRuntimeDefaults(providerID: ProviderSettingsID, defaults: ProviderRuntimeDefaults) throws {
        guard providerID.isDirectAPI, exactRuntimes[providerID] != nil else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Exact provider runtime is not configured")
        }
        exactRuntimeDefaults[providerID] = defaults
        if defaults.enabled { enabledExactProviders.insert(providerID) }
        else { enabledExactProviders.remove(providerID) }
    }

    public func execute(kind: ProviderKind, model: String?, prompt: String, workingDirectory: String, maximumBytes: Int, runID: UUID?, resumeProviderSessionID: String?, onProviderSessionIdentity: @escaping @Sendable (String) async -> Void) async throws -> ProviderExecutionResult {
        let actualRunID = runID ?? UUID()
        return try await executeStreaming(.init(kind: kind, model: model, prompt: prompt, workingDirectory: workingDirectory, maximumBytes: maximumBytes, runID: actualRunID, resumeProviderSessionID: resumeProviderSessionID)) { event in
            if case let .providerIdentity(identity) = event { await onProviderSessionIdentity(identity) }
        }
    }

    public func executeStreaming(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        let exactProviderID = request.policy.providerSettings["provider.settingsID"].flatMap(ProviderSettingsID.init(rawValue:))
        let runtime: any AgentProviderRuntime
        let defaults: ProviderRuntimeDefaults
        if request.kind == .headlessAdapter, let exactProviderID, exactProviderID.isDirectAPI {
            guard enabledExactProviders.contains(exactProviderID), let exactRuntime = exactRuntimes[exactProviderID] else {
                throw ServiceAPIError(code: .providerUnavailable, message: "Requested direct provider is not configured or is administratively disabled")
            }
            runtime = exactRuntime
            defaults = exactRuntimeDefaults[exactProviderID] ?? ProviderRuntimeDefaults(enabled: true)
        } else {
            guard enabledProviders.contains(request.kind), let kindRuntime = runtimes[request.kind] else {
                let message = cataloguedConfigurations[request.kind] == nil
                    ? "Requested provider is not configured"
                    : "Requested provider is administratively disabled"
                throw ServiceAPIError(code: .providerUnavailable, message: message)
            }
            runtime = kindRuntime
            defaults = runtimeDefaults[request.kind] ?? ProviderRuntimeDefaults(enabled: true)
        }
        knownRuns[request.runID] = RunRoute(kind: request.kind, exactProviderID: exactProviderID)
        return try await runtime.execute(request.applying(defaults: defaults), onEvent: onEvent)
    }

    public func steer(runID: UUID, text: String, targetTurnEpoch: Int64) async throws {
        guard let runtime = await runtime(containing: runID) else {
            throw ServiceAPIError(code: .notFound, message: "Active provider run was not found")
        }
        for _ in 0 ..< 100 {
            if await runtime.hasActiveRun(runID) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await runtime.hasActiveRun(runID) else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider run did not become ready for steering")
        }
        try await runtime.steer(runID: runID, text: text, targetTurnEpoch: targetTurnEpoch)
    }

    public func cancel(runID: UUID) async throws {
        guard let runtime = await runtime(containing: runID) else { return }
        try await runtime.interrupt(runID: runID)
    }

    public func hasActiveRun(_ runID: UUID) async -> Bool {
        guard let runtime = await runtime(containing: runID) else { return false }
        return await runtime.hasActiveRun(runID)
    }

    public func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws {
        guard let runtime = await runtime(containing: runID) else {
            throw ServiceAPIError(code: .notFound, message: "Active provider run was not found")
        }
        try await runtime.deliverInteraction(runID: runID, providerRequestID: providerRequestID, answer: answer)
    }

    public func deliverAnswer(session _: SessionSnapshot, interaction: InteractionSnapshot, answer: Data) async throws {
        guard let runID = interaction.runID,
              let payload = try? JSONDecoder().decode(ProviderInteractionPayload.self, from: interaction.payload)
        else { throw ServiceAPIError(code: .interactionSettled, message: "Provider interaction delivery metadata is unavailable") }
        try await deliverInteraction(runID: runID, providerRequestID: payload.providerRequestID, answer: answer)
    }

    public func prepareRun(kind: ProviderKind, runID: UUID) {
        knownRuns[runID] = RunRoute(kind: kind, exactProviderID: nil)
    }

    public func forgetRun(runID: UUID) {
        knownRuns[runID] = nil
    }

    private func runtime(containing runID: UUID) async -> (any AgentProviderRuntime)? {
        if let route = knownRuns[runID] {
            if let exactProviderID = route.exactProviderID, let runtime = exactRuntimes[exactProviderID] { return runtime }
            if let runtime = runtimes[route.kind] { return runtime }
        }
        for runtime in exactRuntimes.values where await runtime.hasActiveRun(runID) { return runtime }
        for runtime in runtimes.values where await runtime.hasActiveRun(runID) { return runtime }
        return nil
    }

    private func unavailableCapability(for kind: ProviderKind) -> ProviderCapability {
        guard let configuration = cataloguedConfigurations[kind] else {
            return .init(kind: kind, enabled: false, executable: nil, supportsResume: false, supportsSteering: false, reasonUnavailable: "not configured")
        }
        return .init(
            kind: kind,
            enabled: false,
            executable: configuration.executable,
            supportsResume: false,
            supportsSteering: false,
            version: configuration.expectedVersion,
            protocolVersion: configuration.protocolVersion,
            reasonUnavailable: "administratively disabled"
        )
    }
}

/// Compatibility name retained for existing callers. Production construction
/// uses native controllers whenever a process supervision port is supplied.
public actor ProviderCLIAdapter: AgentProviderDispatcher, InteractionDeliveryPort, ProviderRuntimeSettingsAdapting {
    private let dispatcher: PortableAgentProviderDispatcher

    public init(
        configurations: [ProviderCLIConfiguration],
        enabledProviders: Set<ProviderKind>? = nil,
        exactRuntimes: [ProviderSettingsID: any AgentProviderRuntime] = [:],
        enabledExactProviders: Set<ProviderSettingsID>? = nil,
        runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(),
        processPort: PortableProcessSupervisionPort? = nil,
        processStore: SQLiteServiceStore? = nil,
        outputDirectory: String = FileManager.default.temporaryDirectory.appendingPathComponent("repoprompt-provider-output").path,
        ephemeralHomeRoot: String = FileManager.default.temporaryDirectory.appendingPathComponent("repoprompt-provider-homes").path,
        credentialEnvironment: any ProviderProcessEnvironmentProviding = EmptyProviderProcessEnvironment(),
        credentialSource: (any ProviderCredentialSourceProviding)? = nil
    ) {
        let enabledProviders = enabledProviders ?? Set(configurations.map(\.kind))
        let credentialSource = credentialSource ?? StaticProviderCredentialSource(configurations: configurations)
        let runtimes: [any AgentProviderRuntime] = if let processPort {
            configurations.map {
                NativeProviderRuntimeFactory.make(configuration: $0, processPort: processPort, processStore: processStore, outputDirectory: outputDirectory, ephemeralHomeRoot: ephemeralHomeRoot, credentialEnvironment: credentialEnvironment, credentialSource: credentialSource)
            }
        } else {
            // Kept only for deterministic unit tests and legacy embedded callers
            // that do not provide the process authority required by native protocols.
            configurations.map { CommandCompatibilityProviderRuntime(configuration: $0, runner: runner) }
        }
        dispatcher = PortableAgentProviderDispatcher(
            runtimes: runtimes,
            exactRuntimes: exactRuntimes,
            cataloguedConfigurations: configurations,
            enabledProviders: enabledProviders,
            enabledExactProviders: enabledExactProviders
        )
    }

    public init(
        runtimes: [any AgentProviderRuntime],
        exactRuntimes: [ProviderSettingsID: any AgentProviderRuntime] = [:],
        enabledExactProviders: Set<ProviderSettingsID>? = nil,
        preflightCacheDuration: Duration = .seconds(15)
    ) {
        dispatcher = PortableAgentProviderDispatcher(
            runtimes: runtimes,
            exactRuntimes: exactRuntimes,
            enabledExactProviders: enabledExactProviders,
            preflightCacheDuration: preflightCacheDuration
        )
    }

    public func capabilities() async -> [ProviderCapability] {
        await dispatcher.capabilities()
    }

    public func preflight() async -> [ProviderCapability] {
        await dispatcher.preflight()
    }

    public func preflight(kind: ProviderKind) async -> ProviderCapability {
        await dispatcher.validateEnabled(kind: kind)
    }

    public func recoveryPreflight(kind: ProviderKind) async -> ProviderCapability {
        await dispatcher.validate(kind: kind)
    }

    public func recoverProcessFamilies() async throws {
        try await dispatcher.recoverProcessFamilies()
    }

    public func applyRuntimeDefaults(kind: ProviderKind, defaults: ProviderRuntimeDefaults) async throws {
        try await dispatcher.applyRuntimeDefaults(kind: kind, defaults: defaults)
    }

    public func applyRuntimeDefaults(providerID: ProviderSettingsID, defaults: ProviderRuntimeDefaults) async throws {
        try await dispatcher.applyRuntimeDefaults(providerID: providerID, defaults: defaults)
    }

    public func cancel(runID: UUID) async throws {
        try await dispatcher.cancel(runID: runID)
    }

    public func steer(runID: UUID, text: String, targetTurnEpoch: Int64) async throws {
        try await dispatcher.steer(runID: runID, text: text, targetTurnEpoch: targetTurnEpoch)
    }

    public func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws {
        try await dispatcher.deliverInteraction(runID: runID, providerRequestID: providerRequestID, answer: answer)
    }

    public func deliverAnswer(session: SessionSnapshot, interaction: InteractionSnapshot, answer: Data) async throws {
        try await dispatcher.deliverAnswer(session: session, interaction: interaction, answer: answer)
    }

    public func prepareRun(kind: ProviderKind, runID: UUID) async {
        await dispatcher.prepareRun(kind: kind, runID: runID)
    }

    public func forgetRun(runID: UUID) async {
        await dispatcher.forgetRun(runID: runID)
    }

    public func execute(kind: ProviderKind, model: String?, prompt: String, workingDirectory: String, maximumBytes: Int = 8_388_608, runID: UUID? = nil, resumeProviderSessionID: String? = nil, onProviderSessionIdentity: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ProviderExecutionResult {
        try await dispatcher.execute(kind: kind, model: model, prompt: prompt, workingDirectory: workingDirectory, maximumBytes: maximumBytes, runID: runID, resumeProviderSessionID: resumeProviderSessionID, onProviderSessionIdentity: onProviderSessionIdentity)
    }

    public func executeStreaming(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        try await dispatcher.executeStreaming(request, onEvent: onEvent)
    }
}

private actor CommandCompatibilityProviderRuntime: AgentProviderRuntime {
    let kind: ProviderKind
    private let configuration: ProviderCLIConfiguration
    private let runner: any WorkspaceCommandRunning
    private var activeRuns: Set<UUID> = []

    init(configuration: ProviderCLIConfiguration, runner: any WorkspaceCommandRunning) {
        kind = configuration.kind
        self.configuration = configuration
        self.runner = runner
    }

    func capability() -> ProviderCapability {
        let executable = FileManager.default.isExecutableFile(atPath: configuration.executable)
        return .init(kind: kind, enabled: executable, executable: executable ? configuration.executable : nil, supportsResume: kind == .codex || kind == .claudeCompatible, supportsSteering: kind == .codex || kind == .claudeCompatible, version: configuration.expectedVersion, protocolVersion: configuration.protocolVersion, reasonUnavailable: executable ? nil : "configured binary is not executable")
    }

    func preflight() async -> ProviderCapability {
        let base = capability()
        guard base.enabled else { return base }
        if configuration.expectedVersion != nil { return base }
        do {
            let environment = try ProviderCLIProbeEnvironment.prepare(for: kind)
            let output = try await runner.run(
                executable: configuration.executable,
                arguments: ["--version"],
                workingDirectory: FileManager.default.currentDirectoryPath,
                maximumBytes: 65536,
                environment: environment
            )
            return .init(kind: kind, enabled: true, executable: configuration.executable, supportsResume: base.supportsResume, supportsSteering: base.supportsSteering, version: output.split(whereSeparator: \.isNewline).first.map(String.init), protocolVersion: configuration.protocolVersion)
        } catch {
            return .init(kind: kind, enabled: false, executable: configuration.executable, supportsResume: base.supportsResume, supportsSteering: base.supportsSteering, version: configuration.expectedVersion, protocolVersion: configuration.protocolVersion, reasonUnavailable: "provider compatibility preflight failed")
        }
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        activeRuns.insert(request.runID)
        defer { activeRuns.remove(request.runID) }
        let arguments = compatibilityArguments(request)
        let raw = try await runner.run(
            executable: configuration.executable,
            arguments: arguments,
            workingDirectory: request.workingDirectory,
            maximumBytes: request.maximumBytes,
            launchValidation: { try request.validateLaunch() },
            launchAcknowledgement: { try await request.acknowledgeLaunch() }
        )
        let parsed = Self.parse(raw, kind: kind)
        if let identity = parsed.providerSessionID { await onEvent(.providerIdentity(identity)) }
        await onEvent(.assistantFinal(parsed.output))
        await onEvent(.completed(providerSessionID: parsed.providerSessionID))
        return parsed
    }

    func interrupt(runID _: UUID) async throws {}
    func steer(runID: UUID, text _: String, targetTurnEpoch _: Int64) async throws {
        guard activeRuns.contains(runID) else { throw ServiceAPIError(code: .notFound, message: "Compatibility run is not active") }
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        activeRuns.contains(runID)
    }

    private func compatibilityArguments(_ request: ProviderExecutionRequest) -> [String] {
        switch kind {
        case .codex:
            (request.resumeProviderSessionID.map { ["exec", "resume", "--json", "--skip-git-repo-check", $0] } ?? ["exec", "--json", "--skip-git-repo-check", "--color", "never"])
                + (request.model.map { ["--model", $0] } ?? []) + [request.prompt]
        case .claudeCompatible:
            ["--print", "--output-format", "stream-json", "--verbose"] + (request.resumeProviderSessionID.map { ["--resume", $0] } ?? []) + (request.model.map { ["--model", $0] } ?? []) + [request.prompt]
        case .openCodeACP: ["run", request.prompt]
        case .cursorACP: ["--print", request.prompt]
        case .grokBuildACP: ["agent", "--no-leader", request.prompt]
        case .headlessAdapter, .mcp: [request.prompt]
        }
    }

    private nonisolated static func parse(_ output: String, kind: ProviderKind) -> ProviderExecutionResult {
        guard kind == .codex || kind == .claudeCompatible else { return .init(output: output, providerSessionID: nil) }
        var providerSessionID: String?
        var finalText: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            providerSessionID = providerSessionID ?? object["thread_id"] as? String ?? object["session_id"] as? String
            if let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message" { finalText = item["text"] as? String ?? finalText }
            if object["type"] as? String == "result" { finalText = object["result"] as? String ?? finalText }
        }
        return .init(output: finalText ?? output, providerSessionID: providerSessionID)
    }
}
