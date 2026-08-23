import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

enum NativeProviderRuntimeFactory {
    static func make(
        configuration: ProviderCLIConfiguration,
        processPort: PortableProcessSupervisionPort,
        processStore: SQLiteServiceStore?,
        outputDirectory: String,
        ephemeralHomeRoot: String,
        credentialEnvironment: any ProviderProcessEnvironmentProviding,
        credentialSource: any ProviderCredentialSourceProviding
    ) -> any AgentProviderRuntime {
        let support = NativeProviderProcessSupport(
            configuration: configuration,
            processPort: processPort,
            processStore: processStore,
            outputDirectory: outputDirectory,
            ephemeralHomeRoot: ephemeralHomeRoot,
            credentialEnvironment: credentialEnvironment,
            credentialSource: credentialSource
        )
        switch configuration.kind {
        case .codex:
            return CodexAppServerProviderRuntime(support: support)
        case .claudeCompatible:
            return ClaudeNativeProviderRuntime(support: support)
        case .openCodeACP:
            return ACPProviderRuntime(kind: .openCodeACP, arguments: ["acp"], support: support)
        case .cursorACP:
            return ACPProviderRuntime(kind: .cursorACP, arguments: ["--approve-mcps", "acp"], support: support)
        case .grokBuildACP:
            return ACPProviderRuntime(
                kind: .grokBuildACP,
                arguments: ["agent", "--no-leader", "stdio"],
                support: support
            )
        case .headlessAdapter:
            return NormalizedHeadlessProviderRuntime(kind: .headlessAdapter, support: support)
        case .mcp:
            // The bundled adapter otherwise defaults to the desktop bootstrap
            // socket. Linux server execution must select its canonical direct
            // headless backend; third-party MCP servers continue to receive no
            // RepoPrompt-specific arguments.
            let executableName = URL(fileURLWithPath: configuration.executable).lastPathComponent
            let arguments = executableName.hasPrefix("repoprompt-mcp") ? ["--backend", "headless"] : []
            return MCPStdioProviderRuntime(arguments: arguments, support: support)
        }
    }
}

private struct NativeProviderProcessSupport {
    private struct PreparedHome {
        let url: URL
        let resources: [OwnedResourceRecord]
        let baseEnvironment: [String: String]?
        let disposable: Bool
    }

    let configuration: ProviderCLIConfiguration
    let processPort: PortableProcessSupervisionPort
    let processStore: SQLiteServiceStore?
    let outputDirectory: String
    let ephemeralHomeRoot: String
    let credentialEnvironment: any ProviderProcessEnvironmentProviding
    let credentialSource: any ProviderCredentialSourceProviding

    func capability(supportsResume: Bool, supportsSteering: Bool) -> ProviderCapability {
        let executable = FileManager.default.isExecutableFile(atPath: configuration.executable)
        return .init(
            kind: configuration.kind,
            enabled: executable,
            executable: executable ? configuration.executable : nil,
            supportsResume: supportsResume,
            supportsSteering: supportsSteering,
            version: configuration.expectedVersion,
            protocolVersion: configuration.protocolVersion,
            reasonUnavailable: executable ? nil : "configured binary is not executable"
        )
    }

    func preflight(supportsResume: Bool, supportsSteering: Bool, protocolName: String) async -> ProviderCapability {
        let base = capability(supportsResume: supportsResume, supportsSteering: supportsSteering)
        guard base.enabled else { return base }
        if configuration.expectedVersion != nil {
            // Bundled/provider-image runtimes have already been resolved and
            // version-verified by their package authority. The native runtime's
            // protocol-specific preflight below is the meaningful live check.
            return .init(
                kind: configuration.kind,
                enabled: true,
                executable: configuration.executable,
                supportsResume: supportsResume,
                supportsSteering: supportsSteering,
                version: configuration.expectedVersion,
                protocolVersion: configuration.protocolVersion ?? protocolName
            )
        }
        do {
            let runner = LocalWorkspaceCommandRunner()
            let environment = try ProviderCLIProbeEnvironment.prepare(for: configuration.kind)
            let output = try await runner.run(
                executable: configuration.executable,
                arguments: ["--version"],
                workingDirectory: FileManager.default.currentDirectoryPath,
                maximumBytes: 65536,
                environment: environment
            )
            let reported = output.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(kind: configuration.kind, enabled: true, executable: configuration.executable, supportsResume: supportsResume, supportsSteering: supportsSteering, version: reported, protocolVersion: configuration.protocolVersion ?? protocolName)
        } catch {
            return .init(kind: configuration.kind, enabled: false, executable: configuration.executable, supportsResume: supportsResume, supportsSteering: supportsSteering, version: configuration.expectedVersion, protocolVersion: configuration.protocolVersion, reasonUnavailable: "provider preflight failed: \(protocolName) executable probe")
        }
    }

    func makeSession(runID: UUID, arguments: [String], workingDirectory: String, model: String? = nil, policy: ProviderExecutionPolicy = .init(), includeCredentials: Bool = true, launchValidation: @escaping @Sendable () throws -> Void = {}) async throws -> NativeJSONLineProcess {
        let preparedHome = try await prepareProviderHome(runID: runID, includeCredentials: includeCredentials, policy: policy)
        var environment = providerEnvironment(home: preparedHome.url, baseEnvironment: preparedHome.baseEnvironment, workingDirectory: workingDirectory, policy: policy)
        let injected = includeCredentials ? try await credentialEnvironment.environment(for: configuration.kind, model: model, policy: policy) : [:]
        let reserved = Set(["HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "CODEX_HOME", "CODEX_SQLITE_HOME", "CLAUDE_CONFIG_DIR", "PATH", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD"])
        guard injected.keys.allSatisfy({ !reserved.contains($0) }) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider credential environment attempted to override an isolated runtime key")
        }
        environment.merge(injected) { _, injected in injected }
        if injected["ANTHROPIC_BASE_URL"] != nil {
            if injected["ANTHROPIC_AUTH_TOKEN"] != nil {
                environment.removeValue(forKey: "ANTHROPIC_API_KEY")
            }
            if injected["ANTHROPIC_API_KEY"] != nil {
                environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
            }
        }
        let supervisor = ProviderProcessSupervisor(processPort: processPort, store: processStore)
        do {
            return try await NativeJSONLineProcess.launch(
                runID: runID,
                executable: configuration.executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                home: preparedHome.url,
                processPort: processPort,
                supervisor: supervisor,
                outputDirectory: outputDirectory,
                resourceRepository: processStore,
                homeResources: preparedHome.resources,
                disposableHome: preparedHome.disposable,
                launchValidation: launchValidation
            )
        } catch {
            if preparedHome.disposable { try? FileManager.default.removeItem(at: preparedHome.url) }
            for resource in preparedHome.resources {
                let remains = FileManager.default.fileExists(atPath: resource.internalPathIdentity)
                _ = try? await processStore?.transitionOwnedResource(
                    resourceID: resource.resourceID,
                    expectedStates: [.active, .prepared, .preparing],
                    to: remains ? .quarantined : .deleted,
                    observedBytes: nil,
                    contentDigest: nil,
                    cleanupError: remains ? "provider_launch_cleanup_incomplete" : nil
                )
            }
            throw error
        }
    }

    func recover() async throws {
        try await ProviderProcessSupervisor(processPort: processPort, store: processStore).recoverPersistedFamilies()
    }

    private func providerEnvironment(home: URL, baseEnvironment: [String: String]?, workingDirectory: String, policy: ProviderExecutionPolicy) -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let inheritedKeys = ["PATH", "LANG", "LC_ALL", "TERM", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"]
        var environment = baseEnvironment
            ?? Dictionary(uniqueKeysWithValues: inheritedKeys.compactMap { key in source[key].map { (key, $0) } })
        if baseEnvironment == nil {
            environment["HOME"] = home.path
            environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config", isDirectory: true).path
            environment["XDG_CACHE_HOME"] = home.appendingPathComponent(".cache", isDirectory: true).path
            environment["CODEX_HOME"] = home.appendingPathComponent(".codex", isDirectory: true).path
            environment["CODEX_SQLITE_HOME"] = home.appendingPathComponent(".codex-sqlite", isDirectory: true).path
            environment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent(".claude", isDirectory: true).path
        }
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["CURSOR_AGENT_DISABLE_AUTO_UPDATE"] = "1"
        if configuration.kind == .claudeCompatible {
            environment["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
            if policy.providerSettings["claude.toolSearchEnabled"] != "true" {
                environment["ENABLE_TOOL_SEARCH"] = "false"
            }
        }
        if configuration.kind == .claudeCompatible,
           ClaudeCompatibleLaunchResolver.shouldApplyEffort(providerSettings: policy.providerSettings),
           let effort = policy.providerSettings["provider.reasoningEffort"],
           ["low", "medium", "high", "xhigh", "max"].contains(effort)
        {
            environment["CLAUDE_CODE_EFFORT_LEVEL"] = effort
        }
        if configuration.kind == .mcp,
           URL(fileURLWithPath: configuration.executable).lastPathComponent.hasPrefix("repoprompt-mcp")
        {
            // Direct MCP refuses implicit cwd authority. Bind the exact
            // authority-approved provider working directory and keep its
            // standalone SQLite/workspace state inside this run's disposable
            // credential home.
            environment["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR"] = home.appendingPathComponent("mcp-profile", isDirectory: true).path
            environment["REPOPROMPT_MCP_WORKING_DIRS"] = workingDirectory
        }
        return environment
    }

    private func prepareProviderHome(runID: UUID, includeCredentials: Bool, policy: ProviderExecutionPolicy) async throws -> PreparedHome {
        // Desktop durable authority (`AppDomainRuntimeComposition`) gives every
        // provider run its own `ProviderHomes/<runID>` and copies credentials
        // from the managed Codex auth directory. Sharing the live auth home
        // across parent and child Codex processes is a server-only shortcut
        // and races SQLite/config under concurrent `agent_run` spawns.
        return try await prepareEphemeralHome(runID: runID, includeCredentials: includeCredentials, policy: policy)
    }

    private func prepareEphemeralHome(runID: UUID, includeCredentials: Bool, policy: ProviderExecutionPolicy) async throws -> PreparedHome {
        let root = URL(fileURLWithPath: ephemeralHomeRoot, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let home = root.appendingPathComponent(runID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
        var records: [OwnedResourceRecord] = []
        let homeRecord = OwnedResourceRecord(
            kind: .providerHome,
            runID: runID,
            externalID: UUID(),
            internalPathIdentity: home.path,
            lifecycleState: .preparing,
            metadata: ["provider": configuration.kind.rawValue],
            retentionDeadline: Date()
        )
        try await processStore?.reserveOwnedResource(homeRecord)
        records.append(homeRecord)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for child in [".config", ".cache", ".codex", ".codex-sqlite", ".claude", ".grok"] {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(child, isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            _ = try? await processStore?.transitionOwnedResource(resourceID: homeRecord.resourceID, expectedStates: [.preparing], to: .failed, observedBytes: nil, contentDigest: nil, cleanupError: "provider_home_create_failed")
            throw error
        }

        if includeCredentials, let sourcePath = try await credentialSource.sourceDirectory(for: configuration.kind) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDirectory), isDirectory.boolValue else {
                try? FileManager.default.removeItem(at: home)
                _ = try? await processStore?.transitionOwnedResource(resourceID: homeRecord.resourceID, expectedStates: [.preparing], to: .failed, observedBytes: nil, contentDigest: nil, cleanupError: "credential_source_unavailable")
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Configured provider credential source is unavailable")
            }
            let credentialDestination: URL = switch configuration.kind {
            case .codex: home.appendingPathComponent(".codex", isDirectory: true)
            case .claudeCompatible: home.appendingPathComponent(".claude", isDirectory: true)
            case .openCodeACP, .cursorACP: home.appendingPathComponent(".config", isDirectory: true)
            case .grokBuildACP: home.appendingPathComponent(".grok", isDirectory: true)
            case .headlessAdapter, .mcp: home.appendingPathComponent(".credentials", isDirectory: true)
            }
            let credentialRecord = OwnedResourceRecord(
                kind: .providerCredentialCopy,
                runID: runID,
                externalID: UUID(),
                internalPathIdentity: credentialDestination.path,
                lifecycleState: .preparing,
                metadata: ["provider": configuration.kind.rawValue],
                retentionDeadline: Date()
            )
            try await processStore?.reserveOwnedResource(credentialRecord)
            records.append(credentialRecord)
            do {
                try FileManager.default.removeItem(at: credentialDestination)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath, isDirectory: true), to: credentialDestination)
            } catch {
                try? FileManager.default.removeItem(at: home)
                for record in records {
                    _ = try? await processStore?.transitionOwnedResource(resourceID: record.resourceID, expectedStates: [.preparing], to: .failed, observedBytes: nil, contentDigest: nil, cleanupError: "credential_copy_failed")
                }
                throw error
            }
        }
        if configuration.kind == .codex {
            do {
                try CodexRepoPromptMCPConfig.writeIfNeeded(
                    codexHome: home.appendingPathComponent(".codex", isDirectory: true),
                    policy: policy
                )
            } catch {
                try? FileManager.default.removeItem(at: home)
                for record in records {
                    _ = try? await processStore?.transitionOwnedResource(resourceID: record.resourceID, expectedStates: [.preparing], to: .failed, observedBytes: nil, contentDigest: nil, cleanupError: "mcp_config_write_failed")
                }
                throw error
            }
        }
        var activated: [OwnedResourceRecord] = []
        for record in records {
            try await activated.append(processStore?.transitionOwnedResource(resourceID: record.resourceID, expectedStates: [.preparing], to: .active, observedBytes: nil, contentDigest: nil, cleanupError: nil) ?? record.replacing(lifecycleState: .active))
        }
        return PreparedHome(url: home, resources: activated, baseEnvironment: nil, disposable: true)
    }
}

private actor NativeJSONLineProcess {
    private let runID: UUID
    private let captured: PortableProcessSupervisionPort.CapturedProcess
    private let home: URL
    private let processPort: PortableProcessSupervisionPort
    private let supervisor: ProviderProcessSupervisor
    private let resourceRepository: (any OwnedResourceRepository)?
    private let ownedResources: [OwnedResourceRecord]
    private let disposableHome: Bool
    private var offset = 0
    private var buffer = Data()
    private var nextRequestID = 1
    private var finished = false

    private init(runID: UUID, captured: PortableProcessSupervisionPort.CapturedProcess, home: URL, processPort: PortableProcessSupervisionPort, supervisor: ProviderProcessSupervisor, resourceRepository: (any OwnedResourceRepository)?, ownedResources: [OwnedResourceRecord], disposableHome: Bool) {
        self.runID = runID
        self.captured = captured
        self.home = home
        self.processPort = processPort
        self.supervisor = supervisor
        self.resourceRepository = resourceRepository
        self.ownedResources = ownedResources
        self.disposableHome = disposableHome
    }

    static func launch(runID: UUID, executable: String, arguments: [String], environment: [String: String], workingDirectory: String, home: URL, processPort: PortableProcessSupervisionPort, supervisor: ProviderProcessSupervisor, outputDirectory: String, resourceRepository: (any OwnedResourceRepository)?, homeResources: [OwnedResourceRecord], disposableHome: Bool, launchValidation: @escaping @Sendable () throws -> Void) async throws -> NativeJSONLineProcess {
        let captureID = UUID()
        let outputRoot = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        let outputRecord = OwnedResourceRecord(
            kind: .providerOutput,
            runID: runID,
            externalID: captureID,
            internalPathIdentity: outputRoot.appendingPathComponent("\(captureID.uuidString).stdout").path,
            temporaryPathIdentity: outputRoot.appendingPathComponent("\(captureID.uuidString).stderr").path,
            lifecycleState: .preparing,
            metadata: ["transport": "stdio"],
            retentionDeadline: Date()
        )
        try await resourceRepository?.reserveOwnedResource(outputRecord)
        var capturedProcess: PortableProcessSupervisionPort.CapturedProcess?
        do {
            let captured = try await processPort.launchInteractiveCaptured(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                helperToken: runID.uuidString,
                outputDirectory: outputDirectory,
                captureID: captureID,
                launchValidation: launchValidation
            )
            capturedProcess = captured
            try await supervisor.register(runID: runID, leader: captured.identity)
            let activeOutput = try await resourceRepository?.transitionOwnedResource(resourceID: outputRecord.resourceID, expectedStates: [.preparing], to: .active, observedBytes: 0, contentDigest: nil, cleanupError: nil) ?? outputRecord.replacing(lifecycleState: .active, observedBytes: 0)
            return NativeJSONLineProcess(runID: runID, captured: captured, home: home, processPort: processPort, supervisor: supervisor, resourceRepository: resourceRepository, ownedResources: homeResources + [activeOutput], disposableHome: disposableHome)
        } catch {
            if let capturedProcess {
                try? await supervisor.cancel(runID: runID, graceScans: 5)
                await processPort.cleanupCapturedFiles(capturedProcess)
            } else {
                for path in [outputRecord.internalPathIdentity, outputRecord.temporaryPathIdentity].compactMap(\.self) {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            let remains = [outputRecord.internalPathIdentity, outputRecord.temporaryPathIdentity].compactMap(\.self).contains {
                FileManager.default.fileExists(atPath: $0)
            }
            _ = try? await resourceRepository?.transitionOwnedResource(
                resourceID: outputRecord.resourceID,
                expectedStates: [.preparing, .active],
                to: remains ? .quarantined : .deleted,
                observedBytes: nil,
                contentDigest: nil,
                cleanupError: remains ? "provider_output_launch_cleanup_incomplete" : nil
            )
            throw error
        }
    }

    func notify(method: String, params: [String: Any]? = nil) async throws {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { object["params"] = params }
        try await send(object)
    }

    func request(method: String, params: [String: Any]? = nil, timeout: Duration? = nil, onFrame: @escaping @Sendable (Data) async throws -> Void) async throws -> Data {
        let id = try await beginRequest(method: method, params: params)
        return try await awaitResponse(id: id, method: method, timeout: timeout, onFrame: onFrame)
    }

    /// Data is Sendable across the runtime/process actor boundary. Use this for
    /// request payloads assembled by a native runtime when more than one request
    /// path may execute (for example resume followed by missing-rollout start).
    func request(method: String, encodedParams: Data, timeout: Duration? = nil, onFrame: @escaping @Sendable (Data) async throws -> Void) async throws -> Data {
        guard let params = try JSONSerialization.jsonObject(with: encodedParams) as? [String: Any] else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider protocol request parameters are invalid")
        }
        let id = try await beginRequest(method: method, params: params)
        return try await awaitResponse(id: id, method: method, timeout: timeout, onFrame: onFrame)
    }

    private func awaitResponse(id: Int, method: String, timeout: Duration?, onFrame: @escaping @Sendable (Data) async throws -> Void) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now.advanced(by: $0) }
        while true {
            let line = try await nextLine(deadline: deadline)
            guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if (frame["id"] as? Int) == id {
                if let error = frame["error"] as? [String: Any] {
                    throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider protocol request \(method) failed: \(error["message"] as? String ?? "unknown error")")
                }
                return try JSONSerialization.data(withJSONObject: frame["result"] ?? [:])
            }
            try await onFrame(line)
        }
    }

    /// Starts a JSON-RPC request without creating another transport reader.
    /// Active-turn controllers use this for native steering; their one reader
    /// observes and fences the eventual response by request ID.
    func beginRequest(method: String, params: [String: Any]? = nil) async throws -> Int {
        let id = nextRequestID
        nextRequestID += 1
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { object["params"] = params }
        try await send(object)
        return id
    }

    func sendResponse(id: Any, result: Any) async throws {
        try await send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func sendRaw(_ data: Data) async throws {
        var line = data
        line.append(0x0A)
        try await processPort.write(line, to: captured)
    }

    func nextLine(deadline: ContinuousClock.Instant? = nil) async throws -> Data {
        let clock = ContinuousClock()
        while true {
            if let deadline, clock.now >= deadline {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider protocol request timed out")
            }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty { return line }
                continue
            }
            let chunk = try await processPort.capturedOutput(captured, after: offset, maximumBytes: 262_144)
            offset = chunk.nextOffset
            buffer.append(chunk.data)
            if chunk.data.isEmpty {
                if !chunk.running {
                    if !buffer.isEmpty { defer { buffer.removeAll() }
                        return buffer
                    }
                    let diagnostic = (try? String(contentsOfFile: captured.stderrPath, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = diagnostic.map { ": \($0.prefix(2048))" } ?? ""
                    throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider protocol transport closed\(suffix)")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func interrupt(protocolAction: @Sendable (NativeJSONLineProcess) async -> Void) async {
        guard !finished else { return }
        await protocolAction(self)
        // Give a native interrupt/cancel control frame a bounded opportunity
        // to reach the provider before enforcing process-family termination.
        try? await Task.sleep(for: .milliseconds(50))
        try? await supervisor.cancel(runID: runID, graceScans: 20)
        await cleanup()
    }

    func finish() async {
        guard !finished else { return }
        await processPort.closeInput(captured)
        for _ in 0 ..< 25 {
            if await (try? processPort.capturedOutput(captured, after: offset, maximumBytes: 1).running) != true { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if await (try? processPort.capturedOutput(captured, after: offset, maximumBytes: 1).running) == true {
            try? await supervisor.cancel(runID: runID, graceScans: 5)
        } else {
            _ = try? await processPort.waitForCapturedProcess(captured, maximumBytes: 1)
            await supervisor.forget(runID: runID)
        }
        await cleanup()
    }

    private func send(_ object: [String: Any]) async throws {
        try await sendRaw(JSONSerialization.data(withJSONObject: object))
    }

    private func cleanup() async {
        guard !finished else { return }
        finished = true
        for resource in ownedResources {
            _ = try? await resourceRepository?.transitionOwnedResource(
                resourceID: resource.resourceID,
                expectedStates: [.preparing, .prepared, .active, .quarantined],
                to: .cleanupPending,
                observedBytes: observedBytes(for: resource),
                contentDigest: nil,
                cleanupError: nil
            )
        }
        await processPort.cleanupCapturedFiles(captured)
        if disposableHome { try? FileManager.default.removeItem(at: home) }
        for resource in ownedResources {
            let remains = resourcePaths(resource).contains { FileManager.default.fileExists(atPath: $0) }
            _ = try? await resourceRepository?.transitionOwnedResource(
                resourceID: resource.resourceID,
                expectedStates: [.cleanupPending],
                to: remains ? .quarantined : .deleted,
                observedBytes: observedBytes(for: resource),
                contentDigest: nil,
                cleanupError: remains ? "provider_resource_cleanup_incomplete" : nil
            )
        }
    }

    private func resourcePaths(_ resource: OwnedResourceRecord) -> [String] {
        [resource.internalPathIdentity, resource.temporaryPathIdentity].compactMap(\.self)
    }

    private func observedBytes(for resource: OwnedResourceRecord) -> Int64? {
        let sizes = resourcePaths(resource).compactMap { path in
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

actor CodexAppServerProviderRuntime: AgentProviderRuntime {
    let kind = ProviderKind.codex
    nonisolated static let appServerArguments = [
        "--disable", "plugins",
        "--disable", "remote_plugin",
        "app-server",
    ]
    private let support: NativeProviderProcessSupport
    private var sessions: [UUID: NativeJSONLineProcess] = [:]
    private var threadIDs: [UUID: String] = [:]
    private var turnIDs: [UUID: String] = [:]

    fileprivate init(support: NativeProviderProcessSupport) {
        self.support = support
    }

    func capability() -> ProviderCapability {
        support.capability(supportsResume: true, supportsSteering: true)
    }

    func preflight() async -> ProviderCapability {
        let base = await support.preflight(supportsResume: true, supportsSteering: true, protocolName: "app-server-v2")
        guard base.enabled else { return base }
        let runID = UUID()
        var preflightProcess: NativeJSONLineProcess?
        do {
            let process = try await support.makeSession(runID: runID, arguments: Self.appServerArguments, workingDirectory: FileManager.default.currentDirectoryPath, includeCredentials: false)
            preflightProcess = process
            _ = try await process.request(method: "initialize", params: ["clientInfo": ["name": "repoprompt-server-preflight", "title": "RepoPrompt Server Preflight", "version": "1"], "capabilities": ["experimentalApi": true]], timeout: .seconds(2), onFrame: { _ in })
            try await process.notify(method: "initialized")
            await process.finish()
            return base
        } catch {
            await preflightProcess?.interrupt { _ in }
            return .init(kind: kind, enabled: false, executable: base.executable, supportsResume: true, supportsSteering: true, version: base.version, protocolVersion: base.protocolVersion, reasonUnavailable: "Codex app-server initialize handshake failed: \(error)")
        }
    }

    func recoverProcessFamilies() async throws {
        try await support.recover()
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        sessions[runID] != nil
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        let process = try await support.makeSession(runID: request.runID, arguments: Self.appServerArguments, workingDirectory: request.workingDirectory, policy: request.policy, launchValidation: { try request.validateLaunch() })
        sessions[request.runID] = process
        defer { sessions[request.runID] = nil
            threadIDs[request.runID] = nil
            turnIDs[request.runID] = nil
        }
        do {
            _ = try await process.request(method: "initialize", params: ["clientInfo": ["name": "repoprompt-server", "title": "RepoPrompt Server", "version": "1"], "capabilities": ["experimentalApi": true]], onFrame: { _ in })
            try await process.notify(method: "initialized")
            let policy = Self.codexPolicy(request.policy, workingDirectory: request.workingDirectory)
            let threadData: Data
            var turnPrompt = request.prompt
            var responseIdentityFallback = request.resumeProviderSessionID
            if let existing = request.resumeProviderSessionID {
                do {
                    threadData = try await process.request(
                        method: "thread/resume",
                        encodedParams: try Self.codexThreadParameters(request, policy: policy, threadID: existing),
                        onFrame: { line in try await Self.forward(line, output: onEvent) }
                    )
                } catch where Self.shouldStartFreshAfterMissingConversation(error) {
                    // This is the same bounded missing-rollout recovery Desktop
                    // applies. The server additionally owns a canonical transcript,
                    // so the one-time replacement thread can retain conversation
                    // context instead of silently becoming an unrelated chat.
                    threadData = try await process.request(
                        method: "thread/start",
                        encodedParams: try Self.codexThreadParameters(request, policy: policy, threadID: nil),
                        onFrame: { line in try await Self.forward(line, output: onEvent) }
                    )
                    turnPrompt = request.resumeFallbackPrompt ?? request.prompt
                    responseIdentityFallback = nil
                }
            } else {
                threadData = try await process.request(
                    method: "thread/start",
                    encodedParams: try Self.codexThreadParameters(request, policy: policy, threadID: nil),
                    onFrame: { line in try await Self.forward(line, output: onEvent) }
                )
            }
            let threadResult = try Self.object(threadData)
            guard let threadID = Self.string(in: threadResult, paths: [["thread", "id"], ["threadId"], ["id"]]) ?? responseIdentityFallback else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Codex app-server did not return a thread identity")
            }
            threadIDs[request.runID] = threadID
            await onEvent(.providerIdentity(threadID))
            var turnInput: [[String: Any]] = [["type": "text", "text": turnPrompt]]
            turnInput += request.structuredInput?.nativeImages.map { ["type": "localImage", "path": $0.filePath] } ?? []
            var turnParams: [String: Any] = [
                "threadId": threadID,
                "input": turnInput,
                "cwd": request.workingDirectory,
                "approvalPolicy": policy.approvalPolicy,
                "sandboxPolicy": policy.sandboxPolicy,
                "approvalsReviewer": policy.approvalsReviewer,
            ]
            if let model = request.model { turnParams["model"] = model }
            if let effort = request.policy.providerSettings["provider.reasoningEffort"] { turnParams["effort"] = effort }
            if let tier = request.policy.providerSettings["provider.serviceTier"] { turnParams["serviceTier"] = tier }
            let turnData = try await process.request(method: "turn/start", params: turnParams, onFrame: { line in try await Self.forward(line, output: onEvent) })
            let turnResult = try Self.object(turnData)
            turnIDs[request.runID] = Self.string(in: turnResult, paths: [["turn", "id"], ["turnId"], ["id"]])
            var output = ""
            while true {
                let line = try await process.nextLine()
                let normalized = try Self.normalize(line)
                for event in normalized.events {
                    switch event {
                    case let .assistantDelta(text): output += text
                    case let .assistantFinal(text): output = text
                    case let .assistantItemDelta(_, text): output += text
                    case let .assistantItemFinal(_, text): output = text
                    default: break
                    }
                    await onEvent(event)
                }
                if normalized.completed { break }
            }
            await onEvent(.completed(providerSessionID: threadID))
            await process.finish()
            return .init(output: output, providerSessionID: threadID)
        } catch {
            await process.interrupt { session in try? await session.notify(method: "turn/interrupt", params: [:]) }
            throw error
        }
    }

    func steer(runID: UUID, text: String, targetTurnEpoch _: Int64) async throws {
        for _ in 0 ..< 200 {
            if sessions[runID] != nil, threadIDs[runID] != nil, turnIDs[runID] != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let process = sessions[runID], let threadID = threadIDs[runID], let turnID = turnIDs[runID] else { throw ServiceAPIError(code: .notFound, message: "Codex turn is not active") }
        _ = try await process.beginRequest(method: "turn/steer", params: ["threadId": threadID, "expectedTurnId": turnID, "input": [["type": "text", "text": text]]])
    }

    func interrupt(runID: UUID) async throws {
        guard let process = sessions[runID] else { return }
        let threadID = threadIDs[runID]
        let turnID = turnIDs[runID]
        await process.interrupt { session in
            guard let threadID, let turnID else { return }
            _ = try? await session.beginRequest(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
        }
    }

    func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws {
        guard let process = sessions[runID] else { throw ServiceAPIError(code: .notFound, message: "Codex run is not active") }
        let id: Any = Int(providerRequestID) ?? providerRequestID
        let payload = (try? JSONSerialization.jsonObject(with: answer)) ?? ["decision": "decline"]
        try await process.sendResponse(id: id, result: payload)
    }

    nonisolated static func codexConfig(_ settings: [String: String]) -> [String: Any] {
        let bash = settings["codex.bashEnabled"] != "false"
        let search = settings["codex.searchEnabled"] != "false"
        let goals = settings["codex.goalsEnabled"] != "false"
        let summaries = settings["codex.reasoningSummariesEnabled"] == "true"
        let memories = settings["codex.memoriesEnabled"] == "true"
        var config: [String: Any] = [
            "features.apps": false,
            "features.shell_tool": bash,
            "features.goals": goals,
            "features.memories": memories,
            "features.computer_use": false,
            "features.plugins": false,
            "features.remote_plugin": false,
            "features.tool_call_mcp_elicitation": false,
            "features.tool_suggest": false,
            "memories.generate_memories": memories,
            "memories.use_memories": memories,
            "web_search": search ? "live" : "disabled",
            "model_reasoning_summary": summaries ? "auto" : "none",
            "features.code_mode.direct_only_tool_namespaces": ["mcp__RepoPromptCE"]
        ]
        if !bash { config["features.unified_exec"] = false }
        if CodexRepoPromptMCPConfig.isProvisioned(settings) {
            config["mcp_servers.RepoPromptCE.enabled"] = true
        }
        if let encoded = settings["codex.enabledMCPServers"],
           let data = encoded.data(using: .utf8),
           let names = try? JSONDecoder().decode([String].self, from: data)
        {
            for configuredName in names {
                // Enabling RepoPromptCE without a command/args block in the isolated
                // Codex home makes Codex reject thread/start. The server writes that
                // Desktop-shaped block only when `repoprompt.mcpProvisioned` is set.
                guard configuredName != "repoprompt", configuredName != "RepoPromptCE" else { continue }
                guard configuredName.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0) }) else { continue }
                config["mcp_servers.\(configuredName).enabled"] = true
            }
        }
        return config
    }

    nonisolated static func codexPolicy(_ policy: ProviderExecutionPolicy, workingDirectory: String) -> (approvalPolicy: String, sandbox: String, sandboxPolicy: [String: Any], approvalsReviewer: String) {
        let approvalsReviewer: String = {
            if let configured = policy.providerSettings["codex.approvalsReviewer"], ["user", "auto_review"].contains(configured) {
                return configured
            }
            return policy.providerSettings["provider.permissionId"] == "codex.autoReview" ? "auto_review" : "user"
        }()
        let typedSandbox = policy.providerSettings["codex.sandbox"].flatMap { raw -> String? in
            switch raw {
            case "read-only", "readOnly": "read-only"
            case "workspace-write", "workspaceWrite": "workspace-write"
            case "danger-full-access", "dangerFullAccess": "danger-full-access"
            default: nil
            }
        }
        let typedApproval = policy.providerSettings["codex.approvalPolicy"].flatMap { raw -> String? in
            switch raw {
            case "on-request", "onRequest": "on-request"
            case "untrusted", "unless-trusted", "unlessTrusted": "untrusted"
            case "never": "never"
            default: nil
            }
        }
        if let typedSandbox {
            switch typedSandbox {
            case "read-only":
                return (typedApproval ?? "on-request", "read-only", ["type": "readOnly"], approvalsReviewer)
            case "danger-full-access":
                return (typedApproval ?? "never", "danger-full-access", ["type": "dangerFullAccess"], approvalsReviewer)
            default:
                let roots = policy.writableRoots.isEmpty ? [workingDirectory] : policy.writableRoots
                return (typedApproval ?? "on-request", "workspace-write", ["type": "workspaceWrite", "writableRoots": roots], approvalsReviewer)
            }
        }
        switch policy.mode {
        case .readOnly:
            return (typedApproval ?? "on-request", "read-only", ["type": "readOnly"], approvalsReviewer)
        case .workspaceWrite:
            let roots = policy.writableRoots.isEmpty ? [workingDirectory] : policy.writableRoots
            return (typedApproval ?? "on-request", "workspace-write", ["type": "workspaceWrite", "writableRoots": roots], approvalsReviewer)
        case .fullAccess:
            return (typedApproval ?? "never", "danger-full-access", ["type": "dangerFullAccess"], approvalsReviewer)
        }
    }

    private nonisolated static func codexThreadParameters(
        _ request: ProviderExecutionRequest,
        policy: (approvalPolicy: String, sandbox: String, sandboxPolicy: [String: Any], approvalsReviewer: String),
        threadID: String?
    ) throws -> Data {
        var params: [String: Any] = [
            "cwd": request.workingDirectory,
            "approvalPolicy": policy.approvalPolicy,
            "sandbox": policy.sandbox,
            "approvalsReviewer": policy.approvalsReviewer,
        ]
        let config = codexConfig(request.policy.providerSettings)
        if !config.isEmpty { params["config"] = config }
        if let model = request.model { params["model"] = model }
        if let effort = request.policy.providerSettings["provider.reasoningEffort"] { params["effort"] = effort }
        if let tier = request.policy.providerSettings["provider.serviceTier"] { params["serviceTier"] = tier }
        if let threadID { params["threadId"] = threadID }
        return try JSONSerialization.data(withJSONObject: params)
    }

    private nonisolated static func forward(_ line: Data, output: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws {
        for event in try normalize(line).events {
            await output(event)
        }
    }

    nonisolated static func normalize(_ data: Data) throws -> (events: [ProviderRuntimeEvent], completed: Bool) {
        guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], false) }
        let method = frame["method"] as? String ?? ""
        let params = frame["params"] as? [String: Any] ?? [:]
        if frame["id"] != nil, !method.isEmpty {
            let id = String(describing: frame["id"]!)
            let prompt = string(in: params, paths: [["reason"], ["message"], ["question"], ["item", "command"], ["item", "path"]]) ?? method
            let kind: ProviderInteractionKind = method == "item/tool/requestUserInput" || method == "mcpServer/elicitation/request" ? .question : .approval
            return ([.interactionRequested(providerRequestID: id, kind: kind, prompt: prompt, choices: kind == .approval ? ["accept", "decline"] : [])], false)
        }
        switch method {
        case "item/agentMessage/delta", "codex/event/agent_message_delta":
            let text = string(in: params, paths: [["delta"], ["text"]]) ?? ""
            if let itemID = string(in: params, paths: [["itemId"], ["item_id"], ["item", "id"]]) {
                return ([.assistantItemDelta(providerItemID: itemID, text: text)], false)
            }
            return ([.assistantDelta(text)], false)
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            let text = string(in: params, paths: [["delta"], ["text"]]) ?? ""
            if let itemID = string(in: params, paths: [["itemId"], ["item_id"], ["item", "id"]]) {
                return ([.reasoningItemDelta(providerItemID: itemID, text: text)], false)
            }
            return ([.reasoning(text)], false)
        case "turn/started", "codex/event/turn_started":
            return ([.runStatusChanged(phase: .thinking, statusCode: HeadlessRunStatusCopy.thinkingCode, statusText: HeadlessRunStatusCopy.thinking)], false)
        case "item/started":
            let item = params["item"] as? [String: Any] ?? params
            let id = item["id"] as? String ?? UUID().uuidString
            let itemType = item["type"] as? String ?? "tool"
            let normalizedName = normalizedItemType(itemType)
            if normalizedName == "usermessage" { return ([], false) }
            if normalizedName == "agentmessage" {
                return ([.runStatusChanged(phase: .working, statusCode: HeadlessRunStatusCopy.thinkingCode, statusText: HeadlessRunStatusCopy.thinking)], false)
            }
            guard visibleToolItemTypes.contains(normalizedName) else { return ([], false) }
            let name = canonicalToolName(item: item, itemType: itemType)
            return ([.toolStarted(providerToolID: id, name: name, arguments: toolArguments(item: item, name: name))], false)
        case "item/commandExecution/outputDelta", "item/mcpToolCall/progress", "item/dynamicToolCall/outputDelta", "item/toolCall/outputDelta", "item/fileChange/outputDelta", "item/webSearch/outputDelta":
            let id = string(in: params, paths: [["itemId"], ["id"]]) ?? "tool"
            return ([.toolUpdated(providerToolID: id, output: string(in: params, paths: [["delta"], ["output"], ["message"]]) ?? "")], false)
        case "item/completed":
            let item = params["item"] as? [String: Any] ?? params
            let itemType = item["type"] as? String ?? "tool"
            let normalizedName = normalizedItemType(itemType)
            if normalizedName == "agentmessage" {
                let text = string(in: item, paths: [["text"], ["content"]]) ?? ""
                if let itemID = item["id"] as? String, !itemID.isEmpty {
                    return ([.assistantItemFinal(providerItemID: itemID, text: text)], false)
                }
                return ([.assistantFinal(text)], false)
            }
            guard visibleToolItemTypes.contains(normalizedName) else { return ([], false) }
            let name = canonicalToolName(item: item, itemType: itemType)
            let status = toolCompletionStatus(item: item, normalizedItemType: normalizedName)
            return ([.toolCompleted(
                providerToolID: item["id"] as? String ?? "tool",
                name: name,
                output: toolResult(item: item, name: name, status: status),
                status: status
            )], false)
        case "turn/completed", "codex/event/turn_completed":
            return ([], true)
        case "thread/status/changed":
            return ([], string(in: params, paths: [["status", "type"], ["status"]]) == "idle")
        case "thread/tokenUsage/updated", "thread/token_usage/updated", "codex/event/thread_tokenUsage_updated", "codex/event/thread_token_usage_updated":
            if let usage = parseTokenUsagePayload(from: params) {
                return ([.contextUsage(usage)], false)
            }
            return ([], false)
        default:
            return ([], false)
        }
    }

    fileprivate nonisolated static func object(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    fileprivate nonisolated static func string(in object: [String: Any], paths: [[String]]) -> String? {
        for path in paths {
            var value: Any = object
            for key in path {
                guard let dictionary = value as? [String: Any], let next = dictionary[key] else { value = NSNull()
                    break
                }
                value = next
            }
            if let string = value as? String, !string.isEmpty { return string }
        }
        return nil
    }

    /// Desktop `CodexNativeSessionController.parseTokenUsagePayload`.
    nonisolated static func parseTokenUsagePayload(from params: [String: Any]) -> ContextUsageWireSnapshot? {
        let tokenUsage = tokenUsageObject(from: params)
        guard let tokenUsage else { return nil }

        let last = usageBreakdown(in: tokenUsage, keys: ["last", "lastTokenUsage", "last_token_usage"])
        let total = usageBreakdown(in: tokenUsage, keys: ["total", "totalTokenUsage", "total_token_usage"])
        let lastTotal = usageTotalTokens(from: last)
        let totalTotal = usageTotalTokens(from: total)
        let contextWindow =
            intValue(tokenUsage["modelContextWindow"])
                ?? intValue(tokenUsage["model_context_window"])
                ?? intValue(tokenUsage["contextWindow"])
                ?? intValue(tokenUsage["context_window"])

        guard contextWindow != nil || lastTotal != nil || totalTotal != nil else {
            return nil
        }
        return ContextUsageWireSnapshot(
            modelContextWindow: contextWindow,
            lastTotalTokens: lastTotal,
            totalTotalTokens: totalTotal
        )
    }

    private nonisolated static func tokenUsageObject(from params: [String: Any]) -> [String: Any]? {
        if let tokenUsage = params["tokenUsage"] as? [String: Any] {
            return tokenUsage
        }
        if let tokenUsage = params["token_usage"] as? [String: Any] {
            return tokenUsage
        }
        let hasTokenUsageShape =
            params["last"] != nil
                || params["total"] != nil
                || params["lastTokenUsage"] != nil
                || params["last_token_usage"] != nil
                || params["totalTokenUsage"] != nil
                || params["total_token_usage"] != nil
                || params["modelContextWindow"] != nil
                || params["model_context_window"] != nil
        return hasTokenUsageShape ? params : nil
    }

    private nonisolated static func usageBreakdown(in tokenUsage: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = tokenUsage[key] as? [String: Any] {
                return value
            }
        }
        return nil
    }

    private nonisolated static func usageTotalTokens(from usage: [String: Any]?) -> Int? {
        guard let usage else { return nil }

        if let explicit =
            intValue(usage["totalTokens"])
                ?? intValue(usage["total_tokens"])
                ?? intValue(usage["tokenCount"])
                ?? intValue(usage["token_count"])
        {
            return explicit
        }

        let input = intValue(usage["inputTokens"]) ?? intValue(usage["input_tokens"])
        let cachedInput = intValue(usage["cachedInputTokens"]) ?? intValue(usage["cached_input_tokens"])
        let output = intValue(usage["outputTokens"]) ?? intValue(usage["output_tokens"])
        let reasoningOutput =
            intValue(usage["reasoningOutputTokens"])
                ?? intValue(usage["reasoning_output_tokens"])

        if input == nil, cachedInput == nil, output == nil, reasoningOutput == nil {
            return nil
        }
        return (input ?? 0) + (cachedInput ?? 0) + (output ?? 0) + (reasoningOutput ?? 0)
    }

    private nonisolated static let visibleToolItemTypes: Set<String> = [
        "commandexecution",
        "mcptoolcall",
        "dynamictoolcall",
        "filechange",
        "functioncall",
        "toolcall",
        "websearch",
    ]

    /// Keep the server projection on the same provider vocabulary as Desktop.
    /// The browser is a viewer of this canonical name, not a second Codex parser.
    private nonisolated static func canonicalToolName(item: [String: Any], itemType: String) -> String {
        let explicit = string(in: item, paths: [
            ["name"], ["toolName"], ["tool_name"], ["functionName"], ["function_name"], ["callName"], ["call_name"], ["tool"],
        ])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = explicit?.lowercased() ?? ""
        let suffix = raw.split(separator: ".").last.map(String.init) ?? raw
        if ["local_shell", "shell", "unified_exec", "exec_command", "run_shell_command"].contains(suffix) {
            return "bash"
        }
        if ["search", "web_search", "web_search_request", "google_web_search", "search_web", "websearch"].contains(suffix) {
            return "search"
        }
        if ["webfetch", "web_fetch", "web_read", "read_web", "browser.open", "browser_open", "open_url", "read_url", "fetch_url", "web_page", "webpage", "read_web_page"].contains(raw) {
            return "web_read"
        }
        if let explicit, !explicit.isEmpty { return explicit }

        let normalizedType = normalizedItemType(itemType)
        if normalizedType.contains("command") || normalizedType.contains("exec") || normalizedType.contains("shell") {
            return "bash"
        }
        if normalizedType.contains("filechange") { return "apply_patch" }
        if normalizedType.contains("search") { return "search" }
        if normalizedType.contains("mcp") { return "MCP tool" }
        return itemType
    }

    private nonisolated static func toolArguments(item: [String: Any], name: String) -> Data? {
        for key in ["arguments", "args", "input", "parameters", "params"] {
            if let value = item[key], let data = encodedJSON(value) { return data }
        }
        if name == "search" || name == "web_read" {
            let payload = compactWebPayload(item, includeResultMetadata: false)
            return payload.isEmpty ? nil : encodedJSON(payload)
        }

        var payload: [String: Any] = [:]
        copyString(item, from: ["command", "cmd"], to: "command", into: &payload)
        copyString(item, from: ["cwd"], to: "cwd", into: &payload)
        copyString(item, from: ["processId", "process_id"], to: "processId", into: &payload)
        return payload.isEmpty ? nil : encodedJSON(payload)
    }

    private nonisolated static func toolResult(
        item: [String: Any],
        name: String,
        status: AgentPresentationToolStatus
    ) -> String? {
        if name == "bash" {
            let wireStatus: String = switch status {
            case .failed: "failed"
            case .cancelled: "cancelled"
            case .warning, .unknown: "unknown"
            default: "completed"
            }
            var payload: [String: Any] = [
                "type": "commandExecution",
                "status": wireStatus,
            ]
            copyString(item, from: ["id"], to: "id", into: &payload)
            copyString(item, from: ["command", "cmd"], to: "command", into: &payload)
            copyString(item, from: ["cwd"], to: "cwd", into: &payload)
            copyString(item, from: ["processId", "process_id"], to: "processId", into: &payload)
            copyString(item, from: ["source"], to: "source", into: &payload)
            if let exitCode = intValue(item["exitCode"]) ?? intValue(item["exit_code"]) ?? intValue(item["code"]), exitCode >= 0 {
                payload["exitCode"] = exitCode
            }
            if let duration = intValue(item["durationMs"]) ?? intValue(item["duration_ms"]), duration >= 0 {
                payload["durationMs"] = duration
            }
            copyString(item, from: ["aggregatedOutput", "aggregated_output", "formattedOutput", "formatted_output", "output", "stdout", "stderr", "text", "message"], to: "aggregatedOutput", into: &payload)
            if let error = item["error"] { payload["error"] = error }
            return encodedJSONString(payload)
        }
        if name == "search" || name == "web_read" {
            let payload = compactWebPayload(item, includeResultMetadata: true)
            return payload.isEmpty ? nil : encodedJSONString(payload)
        }
        for key in ["result", "output", "response", "content"] {
            guard let value = item[key] else { continue }
            if let value = value as? String, !value.isEmpty { return value }
            if let encoded = encodedJSONString(value) { return encoded }
        }
        if let error = item["error"] { return encodedJSONString(error) }
        return encodedJSONString(item)
    }

    private nonisolated static func toolCompletionStatus(
        item: [String: Any],
        normalizedItemType: String
    ) -> AgentPresentationToolStatus {
        if let exitCode = intValue(item["exitCode"]) ?? intValue(item["exit_code"]) ?? intValue(item["code"]), exitCode >= 0 {
            return exitCode == 0 ? .success : .failed
        }
        if boolValue(item["isError"]) == true || boolValue(item["is_error"]) == true || hasNonEmptyErrorSignal(item) {
            return .failed
        }
        let rawStatus = string(in: item, paths: [["status"]])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch rawStatus {
        case "failed", "failure", "error", "declined": return .failed
        case "cancelled", "canceled": return .cancelled
        case "ok", "success", "succeeded", "complete", "completed": return .success
        default: break
        }

        if normalizedItemType == "commandexecution" {
            let source = string(in: item, paths: [["source"]])?.lowercased() ?? ""
            let output = string(in: item, paths: [["aggregatedOutput"], ["aggregated_output"], ["output"], ["stderr"], ["message"]]) ?? ""
            if source.contains("startup"), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failed
            }
            // A completed notification carrying a still-running payload has no
            // trustworthy terminal result. Preserve that uncertainty instead of
            // manufacturing the green success state the browser previously showed.
            return .warning
        }
        return .success
    }

    private nonisolated static func compactWebPayload(
        _ item: [String: Any],
        includeResultMetadata: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = [:]
        let action = item["action"] as? [String: Any]
        let sources = [item, action].compactMap { $0 }
        for source in sources {
            copyString(source, from: ["query", "q", "searchQuery", "search_query"], to: "query", into: &payload)
            copyString(source, from: ["url", "uri", "href", "link", "pageUrl", "page_url"], to: "url", into: &payload)
            copyString(source, from: ["refId", "ref_id", "ref"], to: "refId", into: &payload)
            copyString(source, from: ["pattern", "needle", "find", "findText", "find_text", "phrase"], to: "pattern", into: &payload)
            if payload["queries"] == nil, let queries = source["queries"] as? [String] {
                payload["queries"] = Array(queries.prefix(10)).map { compactWebText($0) }
            }
        }
        let actionType = string(in: action ?? [:], paths: [["type"], ["actionType"], ["action_type"]])
            ?? (item["action"] as? String)
        if let actionType {
            payload["action"] = canonicalWebAction(actionType)
        }
        if includeResultMetadata {
            for key in ["status", "title", "summary", "description", "resultCount", "result_count", "sourceCount", "source_count", "citationCount", "citation_count"] {
                if let value = item[key], value is String || value is NSNumber { payload[key] = value }
            }
            if let error = item["error"] { payload["error"] = error }
        }
        return payload
    }

    private nonisolated static func canonicalWebAction(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openpage", "open_page": "open_page"
        case "findinpage", "find_in_page": "find_in_page"
        case "search": "search"
        default: raw
        }
    }

    private nonisolated static func compactWebText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 500 ? trimmed : String(trimmed.prefix(499)) + "…"
    }

    private nonisolated static func copyString(
        _ source: [String: Any],
        from keys: [String],
        to target: String,
        into payload: inout [String: Any]
    ) {
        guard payload[target] == nil else { return }
        for key in keys {
            guard let value = source[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            payload[target] = target == "aggregatedOutput" ? value : compactWebText(value)
            return
        }
    }

    private nonisolated static func encodedJSON(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    private nonisolated static func encodedJSONString(_ value: Any) -> String? {
        encodedJSON(value).flatMap { String(data: $0, encoding: .utf8) }
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private nonisolated static func hasNonEmptyErrorSignal(_ item: [String: Any]) -> Bool {
        for key in ["error", "errors", "errorMessage", "error_message"] {
            guard let value = item[key] else { continue }
            if let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            if let value = value as? [Any], !value.isEmpty { return true }
            if let value = value as? [String: Any], !value.isEmpty { return true }
        }
        return false
    }

    private nonisolated static func normalizedItemType(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    /// Ported from Desktop's mature Codex resume recovery classifier. Only an
    /// explicitly missing rollout/conversation may create a replacement thread;
    /// transport, authentication, permission, and timeout failures still fail
    /// closed rather than duplicating a live conversation.
    private nonisolated static func shouldStartFreshAfterMissingConversation(_ error: Error) -> Bool {
        guard !(error is CancellationError) else { return false }
        let message = (error as? ServiceAPIError)?.message ?? error.localizedDescription
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let noRolloutFound = "no rollout found for thread id "
        if let range = normalized.range(of: noRolloutFound) {
            let threadID = normalized[range.upperBound...]
            if !threadID.isEmpty, !threadID.contains(where: \.isWhitespace) {
                return true
            }
        }
        guard normalized.contains("rollout") else { return false }
        let loadFailure = normalized.contains("failed to load rollout")
            || normalized.contains("failed loading rollout")
            || normalized.contains("failed to open rollout")
        let missingFile = normalized.contains("no such file")
            || normalized.contains("os error 2")
            || normalized.contains("enoent")
        return loadFailure && missingFile
    }
}

private actor ACPProviderRuntime: AgentProviderRuntime {
    let kind: ProviderKind
    private let arguments: [String]
    private let support: NativeProviderProcessSupport
    private var sessions: [UUID: NativeJSONLineProcess] = [:]
    private var providerSessionIDs: [UUID: String] = [:]
    private var promptRequestIDs: [UUID: Int] = [:]

    init(kind: ProviderKind, arguments: [String], support: NativeProviderProcessSupport) {
        self.kind = kind
        self.arguments = arguments
        self.support = support
    }

    func capability() -> ProviderCapability {
        support.capability(supportsResume: true, supportsSteering: true)
    }

    func preflight() async -> ProviderCapability {
        let base = await support.preflight(supportsResume: true, supportsSteering: true, protocolName: "acp-v1")
        guard base.enabled else { return base }
        var preflightProcess: NativeJSONLineProcess?
        do {
            let process = try await support.makeSession(runID: UUID(), arguments: arguments, workingDirectory: FileManager.default.currentDirectoryPath)
            preflightProcess = process
            let response = try await process.request(method: "initialize", params: ["protocolVersion": 1, "clientInfo": ["name": "RepoPrompt Preflight", "version": "1"], "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]], timeout: .seconds(2), onFrame: { _ in })
            let object = try CodexAppServerProviderRuntime.object(response)
            guard object["agentCapabilities"] is [String: Any] else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "ACP initialize omitted agent capabilities")
            }
            await process.finish()
            return base
        } catch {
            await preflightProcess?.interrupt { _ in }
            return .init(kind: kind, enabled: false, executable: base.executable, supportsResume: true, supportsSteering: true, version: base.version, protocolVersion: base.protocolVersion, reasonUnavailable: "ACP initialize handshake failed: \(error)")
        }
    }

    func recoverProcessFamilies() async throws {
        try await support.recover()
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        sessions[runID] != nil
    }

    private func launchArguments(for request: ProviderExecutionRequest) -> [String] {
        guard kind == .grokBuildACP, request.policy.mode == .fullAccess else {
            return arguments
        }
        var launched = arguments
        if let agentIndex = launched.firstIndex(of: "agent"), !launched.contains("--always-approve") {
            launched.insert("--always-approve", at: agentIndex + 1)
        }
        return launched
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        let process = try await support.makeSession(runID: request.runID, arguments: launchArguments(for: request), workingDirectory: request.workingDirectory, launchValidation: { try request.validateLaunch() })
        sessions[request.runID] = process
        defer { sessions[request.runID] = nil
            providerSessionIDs[request.runID] = nil
            promptRequestIDs[request.runID] = nil
        }
        do {
            let initialize = try await process.request(method: "initialize", params: ["protocolVersion": 1, "clientInfo": ["name": "RepoPrompt", "version": "1"], "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]], onFrame: { line in try await Self.forward(line, output: onEvent) })
            let capabilities = try CodexAppServerProviderRuntime.object(initialize)["agentCapabilities"] as? [String: Any] ?? [:]
            let sessionID: String
            let sessionOpenResult: [String: Any]
            if let resume = request.resumeProviderSessionID {
                guard capabilities["loadSession"] as? Bool == true else { throw ServiceAPIError(code: .resumeUnsupported, message: "ACP provider did not negotiate session/load") }
                let loaded = try await process.request(method: "session/load", params: ["sessionId": resume, "cwd": request.workingDirectory, "mcpServers": []], onFrame: { line in try await Self.forward(line, output: onEvent) })
                sessionOpenResult = try CodexAppServerProviderRuntime.object(loaded)
                sessionID = resume
            } else {
                let opened = try await process.request(method: "session/new", params: ["cwd": request.workingDirectory, "mcpServers": []], onFrame: { line in try await Self.forward(line, output: onEvent) })
                sessionOpenResult = try CodexAppServerProviderRuntime.object(opened)
                guard let id = CodexAppServerProviderRuntime.string(in: sessionOpenResult, paths: [["sessionId"]]) else { throw ServiceAPIError(code: .dependencyUnavailable, message: "ACP session/new omitted sessionId") }
                sessionID = id
            }
            try await Self.configureExecutionMode(request.policy, sessionID: sessionID, sessionOpenResult: sessionOpenResult, process: process, output: onEvent)
            try await Self.configureModel(
                request.model,
                kind: kind,
                policy: request.policy,
                sessionID: sessionID,
                sessionOpenResult: sessionOpenResult,
                process: process,
                output: onEvent
            )
            providerSessionIDs[request.runID] = sessionID
            await onEvent(.providerIdentity(sessionID))
            let output = ProviderOutputAccumulator()
            promptRequestIDs[request.runID] = try await process.beginRequest(method: "session/prompt", params: ["sessionId": sessionID, "prompt": [["type": "text", "text": request.prompt]]])
            while true {
                let line = try await process.nextLine()
                for event in try Self.normalize(line) {
                    await output.record(event)
                    await onEvent(event)
                }
                guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let responseID = frame["id"] as? Int,
                      responseID == promptRequestIDs[request.runID]
                else { continue }
                if let error = frame["error"] as? [String: Any] {
                    throw ServiceAPIError(code: .dependencyUnavailable, message: "ACP session/prompt failed: \(error["message"] as? String ?? "unknown error")")
                }
                if let result = frame["result"] as? [String: Any],
                   let usage = HeadlessACPSessionUpdateNormalizer.contextUsageFromPromptResult(result)
                {
                    await onEvent(.contextUsage(usage))
                }
                break
            }
            await onEvent(.completed(providerSessionID: sessionID))
            await process.finish()
            return await .init(output: output.value(), providerSessionID: sessionID)
        } catch {
            await process.interrupt { session in try? await session.notify(method: "session/cancel", params: [:]) }
            throw error
        }
    }

    func steer(runID: UUID, text: String, targetTurnEpoch _: Int64) async throws {
        guard let process = sessions[runID], let sessionID = providerSessionIDs[runID] else { throw ServiceAPIError(code: .notFound, message: "ACP run is not active") }
        try await process.notify(method: "session/cancel", params: ["sessionId": sessionID])
        promptRequestIDs[runID] = try await process.beginRequest(method: "session/prompt", params: ["sessionId": sessionID, "prompt": [["type": "text", "text": text]]])
    }

    func interrupt(runID: UUID) async throws {
        guard let process = sessions[runID] else { return }
        let sessionID = providerSessionIDs[runID]
        await process.interrupt { session in
            if let sessionID { try? await session.notify(method: "session/cancel", params: ["sessionId": sessionID]) }
        }
    }

    func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws {
        guard let process = sessions[runID] else { throw ServiceAPIError(code: .notFound, message: "ACP run is not active") }
        let answerObject = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
        let optionID = answerObject?["optionId"] as? String
        let outcome: [String: Any] = optionID.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        try await process.sendResponse(id: Int(providerRequestID) ?? providerRequestID, result: ["outcome": outcome])
    }

    private nonisolated static func configureExecutionMode(
        _ policy: ProviderExecutionPolicy,
        sessionID: String,
        sessionOpenResult: [String: Any],
        process: NativeJSONLineProcess,
        output: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws {
        let desired: String? = switch policy.mode {
        case .readOnly: policy.providerSettings["acp.readOnlyMode"] ?? "plan"
        case .workspaceWrite: policy.providerSettings["acp.mode"]
        case .fullAccess: policy.providerSettings["acp.fullAccessMode"]
        }
        guard let desired, !desired.isEmpty else { return }
        let options = sessionOpenResult["configOptions"] as? [[String: Any]] ?? []
        guard let mode = options.first(where: { ($0["category"] as? String)?.caseInsensitiveCompare("mode") == .orderedSame }),
              let configID = mode["id"] as? String
        else {
            if policy.mode == .readOnly {
                throw ServiceAPIError(code: .capabilityMissing, message: "ACP provider does not advertise an enforceable read-only mode")
            }
            return
        }
        let values = (mode["options"] as? [[String: Any]] ?? []).compactMap { ($0["value"] ?? $0["id"]) as? String }
        guard let canonical = values.first(where: { $0.caseInsensitiveCompare(desired) == .orderedSame }) else {
            throw ServiceAPIError(code: .capabilityMissing, message: "ACP provider does not advertise requested execution mode")
        }
        if (mode["currentValue"] as? String)?.caseInsensitiveCompare(canonical) == .orderedSame { return }
        let response = try await process.request(
            method: "session/set_config_option",
            params: ["sessionId": sessionID, "configId": configID, "value": canonical],
            onFrame: { line in try await forward(line, output: output) }
        )
        let updated = try CodexAppServerProviderRuntime.object(response)["configOptions"] as? [[String: Any]] ?? []
        guard updated.contains(where: { ($0["id"] as? String) == configID && (($0["currentValue"] as? String)?.caseInsensitiveCompare(canonical) == .orderedSame) }) else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "ACP provider did not acknowledge the execution mode")
        }
    }

    private nonisolated static func configureModel(
        _ requestedModel: String?,
        kind: ProviderKind,
        policy: ProviderExecutionPolicy,
        sessionID: String,
        sessionOpenResult: [String: Any],
        process: NativeJSONLineProcess,
        output: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws {
        guard let requestedModel = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedModel.isEmpty else { return }
        if kind == .grokBuildACP {
            try await configureGrokBuildModel(
                requestedModel,
                policy: policy,
                sessionID: sessionID,
                sessionOpenResult: sessionOpenResult,
                process: process,
                output: output
            )
            return
        }
        let options = sessionOpenResult["configOptions"] as? [[String: Any]] ?? []
        guard let model = options.first(where: { ($0["category"] as? String)?.caseInsensitiveCompare("model") == .orderedSame }),
              let configID = model["id"] as? String
        else { throw ServiceAPIError(code: .capabilityMissing, message: "ACP provider does not advertise model selection") }
        let choices = model["options"] as? [[String: Any]] ?? []
        let canonical = choices.compactMap { ($0["value"] ?? $0["id"]) as? String }
            .first { $0.caseInsensitiveCompare(requestedModel) == .orderedSame }
        guard let canonical else { throw ServiceAPIError(code: .providerUnavailable, message: "Requested ACP model is not advertised by the provider") }
        if (model["currentValue"] as? String)?.caseInsensitiveCompare(canonical) == .orderedSame { return }
        let response = try await process.request(
            method: "session/set_config_option",
            params: ["sessionId": sessionID, "configId": configID, "value": canonical],
            onFrame: { line in try await forward(line, output: output) }
        )
        let updated = try CodexAppServerProviderRuntime.object(response)["configOptions"] as? [[String: Any]] ?? []
        guard updated.contains(where: { ($0["id"] as? String) == configID && (($0["currentValue"] as? String)?.caseInsensitiveCompare(canonical) == .orderedSame) }) else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "ACP provider did not acknowledge the selected model")
        }
    }

    /// Desktop Grok Build advertises `SessionModelState` on `session/new`/`session/load`
    /// and selects with `session/set_model` `{sessionId, modelId, _meta.reasoningEffort?}`.
    /// Do not fall back to modern `configOptions`.
    private nonisolated static func configureGrokBuildModel(
        _ requestedModel: String,
        policy: ProviderExecutionPolicy,
        sessionID: String,
        sessionOpenResult: [String: Any],
        process: NativeJSONLineProcess,
        output: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws {
        guard let models = sessionOpenResult["models"] as? [String: Any],
              let available = models["availableModels"] as? [[String: Any]]
        else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Grok Build does not advertise SessionModelState model selection")
        }
        let advertised = available.compactMap { entry -> String? in
            guard let modelID = (entry["modelId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !modelID.isEmpty
            else { return nil }
            return modelID
        }
        guard let canonical = advertised.first(where: { $0.caseInsensitiveCompare(requestedModel) == .orderedSame }) else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Requested Grok Build model is not advertised by the provider")
        }
        let effort = policy.providerSettings["provider.reasoningEffort"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let current = (models["currentModelId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effortRequested = !(effort?.isEmpty ?? true)
        if current?.caseInsensitiveCompare(canonical) == .orderedSame, !effortRequested {
            return
        }
        var params: [String: Any] = ["sessionId": sessionID, "modelId": canonical]
        if let effort, !effort.isEmpty {
            params["_meta"] = ["reasoningEffort": effort]
        }
        let response = try await process.request(
            method: "session/set_model",
            params: params,
            onFrame: { line in try await forward(line, output: output) }
        )
        let result = try CodexAppServerProviderRuntime.object(response)
        let modelOutcome = (result["_meta"] as? [String: Any])?["model"] as? [String: Any]
        let hasOk = modelOutcome?.keys.contains("Ok") == true
        let hasErr = modelOutcome?.keys.contains("Err") == true
        if hasErr, !hasOk {
            let modelError = modelOutcome?["Err"] ?? "unknown"
            throw ServiceAPIError(code: .providerUnavailable, message: "Grok Build rejected model '\(canonical)': \(modelError)")
        }
        guard !hasErr,
              hasOk,
              let confirmedModel = modelOutcome?["Ok"] as? String,
              confirmedModel.trimmingCharacters(in: .whitespacesAndNewlines)
              .caseInsensitiveCompare(canonical) == .orderedSame
        else {
            throw ServiceAPIError(
                code: .dependencyUnavailable,
                message: "Grok Build did not confirm model '\(canonical)': unexpected session/set_model acknowledgement"
            )
        }
    }

    private nonisolated static func forward(_ line: Data, output: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws {
        for event in try normalize(line) {
            await output(event)
        }
    }

    nonisolated static func normalize(_ data: Data) throws -> [ProviderRuntimeEvent] {
        try HeadlessACPSessionUpdateNormalizer.normalize(data)
    }
}

actor ClaudeNativeProviderRuntime: AgentProviderRuntime {
    let kind = ProviderKind.claudeCompatible
    private let support: NativeProviderProcessSupport
    private var sessions: [UUID: NativeJSONLineProcess] = [:]

    fileprivate init(support: NativeProviderProcessSupport) {
        self.support = support
    }

    func capability() -> ProviderCapability {
        support.capability(supportsResume: true, supportsSteering: true)
    }

    func preflight() async -> ProviderCapability {
        await support.preflight(supportsResume: true, supportsSteering: true, protocolName: "bidirectional-stream-json")
    }

    func recoverProcessFamilies() async throws {
        try await support.recover()
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        sessions[runID] != nil
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        let launch = try Self.launchPackaging(request)
        let process = try await support.makeSession(runID: request.runID, arguments: launch.arguments, workingDirectory: request.workingDirectory, model: request.model, policy: request.policy, launchValidation: { try request.validateLaunch() })
        sessions[request.runID] = process
        defer { sessions[request.runID] = nil }
        do {
            var content: [[String: Any]] = [["type": "text", "text": launch.userMessage]]
            for image in request.structuredInput?.nativeImages ?? [] {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: image.filePath), options: [.mappedIfSafe])
                guard bytes.count == image.byteSize, CanonicalSigning.bodyDigest(bytes) == image.digest else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Accepted image changed before provider dispatch") }
                content.append(["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": bytes.base64EncodedString()]])
            }
            try await process.sendRaw(JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": NSNull()]))
            var output = ""
            var identity = request.resumeProviderSessionID
            while true {
                let line = try await process.nextLine()
                guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if frame["type"] as? String == "control_request", let requestID = frame["request_id"] as? String, let payload = frame["request"] as? [String: Any] {
                    await onEvent(.interactionRequested(providerRequestID: requestID, kind: .approval, prompt: payload["description"] as? String ?? payload["tool_name"] as? String ?? "Tool approval", choices: ["accept", "decline"]))
                    continue
                }
                identity = identity ?? frame["session_id"] as? String
                if let identity { await onEvent(.providerIdentity(identity)) }
                let type = frame["type"] as? String ?? ""
                if type == "assistant", let message = frame["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        if block["type"] as? String == "text", let text = block["text"] as? String { output += text
                            await onEvent(.assistantDelta(text))
                        }
                        if block["type"] as? String == "thinking", let text = block["thinking"] as? String { await onEvent(.reasoning(text)) }
                        if block["type"] as? String == "tool_use" {
                            await onEvent(.toolStarted(providerToolID: block["id"] as? String ?? UUID().uuidString, name: block["name"] as? String ?? "tool", arguments: try? JSONSerialization.data(withJSONObject: block["input"] ?? [:])))
                        }
                    }
                }
                if type == "result" {
                    if let final = frame["result"] as? String, !final.isEmpty { output = final
                        await onEvent(.assistantFinal(final))
                    }
                    await onEvent(.completed(providerSessionID: identity))
                    break
                }
            }
            await process.finish()
            return .init(output: output, providerSessionID: identity)
        } catch {
            await process.interrupt { session in try? await Self.sendInterrupt(to: session) }
            throw error
        }
    }

    func steer(runID: UUID, text: String, targetTurnEpoch _: Int64) async throws {
        guard let process = sessions[runID] else { throw ServiceAPIError(code: .notFound, message: "Claude run is not active") }
        try await Self.sendInterrupt(to: process)
        try await process.sendRaw(JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]], "parent_tool_use_id": NSNull()]))
    }

    func interrupt(runID: UUID) async throws {
        guard let process = sessions[runID] else { return }
        await process.interrupt { session in try? await Self.sendInterrupt(to: session) }
    }

    func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws {
        guard let process = sessions[runID] else { throw ServiceAPIError(code: .notFound, message: "Claude run is not active") }
        let answerObject = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] ?? [:]
        let accepted = answerObject["decision"] as? String == "accept" || answerObject["accepted"] as? Bool == true
        let response: [String: Any] = accepted ? ["behavior": "allow"] : ["behavior": "deny", "message": "Declined by controller"]
        try await process.sendRaw(JSONSerialization.data(withJSONObject: ["type": "control_response", "response": ["subtype": "success", "request_id": providerRequestID, "response": response]]))
    }

    private nonisolated static func sendInterrupt(to process: NativeJSONLineProcess) async throws {
        try await process.sendRaw(JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt", "reason": "authority control"]]))
    }

    /// Desktop `ClaudeAgentToolPreferences.agentModePromptDelivery` consume:
    /// `--system-prompt` replaces native, user-message XML keeps native, empty
    /// `--system-prompt` clears native. Store-backed `claude.promptDelivery` wins
    /// over composer toolValues.
    nonisolated static func launchPackaging(_ request: ProviderExecutionRequest) throws -> (arguments: [String], userMessage: String) {
        let delivery = ClaudeAgentModePromptDelivery.resolved(rawValue: request.policy.providerSettings["claude.promptDelivery"])
        let instructions = request.policy.providerSettings["claude.agentModeInstructions"] ?? ""
        var arguments = ["-p", "--verbose", "--output-format", "stream-json", "--input-format", "stream-json", "--permission-prompt-tool", "stdio"]
        switch request.policy.mode {
        case .readOnly:
            arguments += ["--permission-mode", "plan", "--disallowedTools", "Bash,Write,Edit,NotebookEdit"]
        case .workspaceWrite:
            let configured = request.policy.providerSettings["claude.permissionMode"] ?? "default"
            let mode = ["default", "acceptEdits", "auto"].contains(configured) ? configured : "default"
            arguments += ["--permission-mode", mode]
        case .fullAccess:
            arguments.append("--allow-dangerously-skip-permissions")
        }
        if request.policy.mode != .readOnly, request.policy.providerSettings["claude.bashEnabled"] == "false" {
            arguments += ["--disallowedTools", "Bash"]
        }
        if request.policy.providerSettings["claude.strictMCPEnabled"] == "true" {
            arguments.append("--strict-mcp-config")
        }
        if let resume = request.resumeProviderSessionID { arguments += ["--resume", resume] }
        let effectiveModel = try Self.effectiveModel(request.model, settings: request.policy.providerSettings)
        if let effectiveModel { arguments += ["--model", effectiveModel] }
        arguments = delivery.appendingSystemPrompt(to: arguments, instructions: instructions)
        return (arguments, delivery.packagedUserMessage(request.prompt, instructions: instructions))
    }

    private nonisolated static func effectiveModel(_ requested: String?, settings: [String: String]) throws -> String? {
        guard let backend = ClaudeCompatibleLaunchResolver.backendSettings(from: settings) else {
            return requested
        }
        return try ClaudeCompatibleLaunchResolver.resolveModel(settings: backend, requestedModel: requested)
    }
}

/// Portable normalized HeadlessAgentProvider wire. The helper emits the same
/// event vocabulary as AgentStreamEvent as NDJSON and accepts control NDJSON.
private actor NormalizedHeadlessProviderRuntime: AgentProviderRuntime {
    let kind: ProviderKind
    private let support: NativeProviderProcessSupport
    private var sessions: [UUID: NativeJSONLineProcess] = [:]
    init(kind: ProviderKind, support: NativeProviderProcessSupport) {
        self.kind = kind
        self.support = support
    }

    func capability() -> ProviderCapability {
        support.capability(supportsResume: true, supportsSteering: true)
    }

    func preflight() async -> ProviderCapability {
        await support.preflight(supportsResume: true, supportsSteering: true, protocolName: "repoprompt-headless-v1")
    }

    func recoverProcessFamilies() async throws {
        try await support.recover()
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        sessions[runID] != nil
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        let process = try await support.makeSession(runID: request.runID, arguments: ["--headless-provider-json"], workingDirectory: request.workingDirectory, launchValidation: { try request.validateLaunch() })
        sessions[request.runID] = process
        defer { sessions[request.runID] = nil }
        try await process.sendRaw(JSONSerialization.data(withJSONObject: [
            "operation": "start",
            "runID": request.runID.uuidString,
            "prompt": request.prompt,
            "model": request.model as Any,
            "resumeSessionID": request.resumeProviderSessionID as Any,
            "executionPolicy": [
                "mode": request.policy.mode.rawValue,
                "writableRoots": request.policy.writableRoots,
                "providerSettings": request.policy.providerSettings
            ]
        ]))
        var output = ""
        var identity = request.resumeProviderSessionID
        while true {
            let line = try await process.nextLine()
            guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch frame["type"] as? String {
            case "message": let text = frame["content"] as? String ?? ""
                output += text
                await onEvent(.assistantDelta(text))
            case "finalMessage": let text = frame["content"] as? String ?? ""
                output = text
                await onEvent(.assistantFinal(text))
            case "reasoning": await onEvent(.reasoning(frame["content"] as? String ?? ""))
            case "progress", "system": await onEvent(.progress(frame["message"] as? String ?? ""))
            case "toolCall": await onEvent(.toolStarted(providerToolID: frame["id"] as? String ?? UUID().uuidString, name: frame["name"] as? String ?? "tool", arguments: try? JSONSerialization.data(withJSONObject: frame["args"] ?? [:])))
            case "toolResult": await onEvent(.toolCompleted(providerToolID: frame["id"] as? String ?? "tool", name: frame["name"] as? String ?? "tool", output: frame["result"] as? String, status: frame["failed"] as? Bool == true ? .failed : .success))
            case "interaction": await onEvent(.interactionRequested(providerRequestID: frame["requestID"] as? String ?? UUID().uuidString, kind: (frame["kind"] as? String) == "question" ? .question : .approval, prompt: frame["prompt"] as? String ?? "Provider input required", choices: frame["choices"] as? [String] ?? []))
            case "completion": identity = frame["providerSessionID"] as? String ?? identity
                await onEvent(.completed(providerSessionID: identity))
                await process.finish()
                return .init(output: output, providerSessionID: identity)
            default: break
            }
        }
    }

    func steer(runID: UUID, text: String, targetTurnEpoch: Int64) async throws {
        guard let process = sessions[runID] else { throw ServiceAPIError(code: .notFound, message: "Headless run is not active") }
        try await process.sendRaw(JSONSerialization.data(withJSONObject: ["operation": "steer", "text": text, "targetTurnEpoch": targetTurnEpoch]))
    }

    func interrupt(runID: UUID) async throws {
        guard let process = sessions[runID] else { return }
        await process.interrupt { session in try? await session.sendRaw(try JSONSerialization.data(withJSONObject: ["operation": "interrupt"])) }
    }

    func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws {
        guard let process = sessions[runID] else { throw ServiceAPIError(code: .notFound, message: "Headless run is not active") }
        try await process.sendRaw(JSONSerialization.data(withJSONObject: ["operation": "respond", "requestID": providerRequestID, "answer": (try? JSONSerialization.jsonObject(with: answer)) ?? NSNull()]))
    }
}

private actor ProviderOutputAccumulator {
    private var output = ""
    func record(_ event: ProviderRuntimeEvent) {
        switch event {
        case let .assistantDelta(text): output += text
        case let .assistantFinal(text): output = text
        case let .assistantItemDelta(_, text): output += text
        case let .assistantItemFinal(_, text): output = text
        default: break
        }
    }

    func value() -> String {
        output
    }
}

/// Executable MCP compatibility path: initialize and tools/list are real stdio
/// JSON-RPC exchanges. It is intentionally not a second session authority.
private actor MCPStdioProviderRuntime: AgentProviderRuntime {
    let kind = ProviderKind.mcp
    private let arguments: [String]
    private let support: NativeProviderProcessSupport
    private var sessions: [UUID: NativeJSONLineProcess] = [:]
    init(arguments: [String], support: NativeProviderProcessSupport) {
        self.arguments = arguments
        self.support = support
    }

    func capability() -> ProviderCapability {
        support.capability(supportsResume: false, supportsSteering: false)
    }

    func preflight() async -> ProviderCapability {
        let base = await support.preflight(supportsResume: false, supportsSteering: false, protocolName: "mcp-stdio-2025-03-26")
        guard base.enabled else { return base }
        var preflightProcess: NativeJSONLineProcess?
        do {
            let process = try await support.makeSession(runID: UUID(), arguments: arguments, workingDirectory: FileManager.default.currentDirectoryPath)
            preflightProcess = process
            let initialized = try await process.request(method: "initialize", params: ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "RepoPromptServerPreflight", "version": "1"]], timeout: .seconds(2), onFrame: { _ in })
            let object = try CodexAppServerProviderRuntime.object(initialized)
            guard object["protocolVersion"] is String else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "MCP initialize omitted protocol version")
            }
            try await process.notify(method: "notifications/initialized")
            _ = try await process.request(method: "tools/list", params: [:], onFrame: { _ in })
            await process.finish()
            return base
        } catch {
            await preflightProcess?.interrupt { _ in }
            return .init(kind: kind, enabled: false, executable: base.executable, supportsResume: false, supportsSteering: false, version: base.version, protocolVersion: base.protocolVersion, reasonUnavailable: "MCP initialize/tools-list handshake failed: \(error)")
        }
    }

    func recoverProcessFamilies() async throws {
        try await support.recover()
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        sessions[runID] != nil
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        let process = try await support.makeSession(runID: request.runID, arguments: arguments, workingDirectory: request.workingDirectory, launchValidation: { try request.validateLaunch() })
        sessions[request.runID] = process
        defer { sessions[request.runID] = nil }
        _ = try await process.request(method: "initialize", params: ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "RepoPromptServer", "version": "1"]], onFrame: { _ in })
        try await process.notify(method: "notifications/initialized")
        let tools = try await process.request(method: "tools/list", params: [:], onFrame: { _ in })
        let object = try CodexAppServerProviderRuntime.object(tools)
        let names = (object["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.sorted()
        let output = names.joined(separator: "\n")
        await onEvent(.progress("MCP initialized with \(names.count) tools"))
        await onEvent(.assistantFinal(output))
        await onEvent(.completed(providerSessionID: nil))
        await process.finish()
        return .init(output: output, providerSessionID: nil)
    }

    func interrupt(runID: UUID) async throws {
        guard let process = sessions[runID] else { return }
        await process.interrupt { _ in }
    }
}
