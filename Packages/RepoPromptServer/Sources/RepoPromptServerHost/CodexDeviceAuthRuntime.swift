import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

/// Server projection of the desktop Codex runtime authority contract.
public enum CodexCLIContract {
    public static let pinnedVersion = "0.147.0"
    public static let deviceFlowType = "chatgptDeviceCode"
}

/// Matches RepoPrompt Desktop's dedicated Codex `CODEX_HOME` and
/// `CODEX_SQLITE_HOME`, rooted instead in protected server state. Neither the
/// server nor the portal decodes Codex credential files.
public struct CodexManagedAuthHome: Sendable {
    public let root: URL
    public let codexHome: URL
    public let sqliteHome: URL
    private let processHome: URL
    private let configHome: URL
    private let cacheHome: URL

    public init(rootPath: String) throws {
        guard rootPath.hasPrefix("/") else {
            throw ServiceAPIError(code: .invalidRequest, message: "Managed Codex authentication storage must use an absolute path")
        }
        root = URL(fileURLWithPath: rootPath, isDirectory: true)
        codexHome = root.appendingPathComponent("home", isDirectory: true)
        sqliteHome = root.appendingPathComponent("sqlite", isDirectory: true)
        processHome = root.appendingPathComponent("process-home", isDirectory: true)
        configHome = root.appendingPathComponent("config", isDirectory: true)
        cacheHome = root.appendingPathComponent("cache", isDirectory: true)
        try validateOrCreate()
    }

    public var credentialSourceDirectory: String { codexHome.path }

    public func validateOrCreate() throws {
        for directory in [root, codexHome, sqliteHome, processHome, configHome, cacheHome] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard isDirectory.boolValue, attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw ServiceAPIError(code: .dependencyUnavailable, message: "Managed Codex authentication storage is unsafe")
                }
            } else {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Managed Codex authentication storage is not private")
            }
        }
    }

    public func environment() throws -> [String: String] {
        try validateOrCreate()
        let source = ProcessInfo.processInfo.environment
        let inherited = ["PATH", "LANG", "LC_ALL", "TERM", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"]
        var value = Dictionary(uniqueKeysWithValues: inherited.compactMap { key in source[key].map { (key, $0) } })
        value["HOME"] = processHome.path
        value["CODEX_HOME"] = codexHome.path
        value["CODEX_SQLITE_HOME"] = sqliteHome.path
        value["XDG_CONFIG_HOME"] = configHome.path
        value["XDG_CACHE_HOME"] = cacheHome.path
        value["DISABLE_AUTOUPDATER"] = "1"
        return value
    }

    public var workingDirectory: String { processHome.path }
}

/// A bounded JSON-RPC transport for the same `codex app-server` account API
/// used by RepoPrompt Desktop's CodexManagedAuthRecoveryService.
private actor CodexManagedAuthRPCProcess {
    enum RPCError: Error {
        case server(String)
        case unavailable
    }

    struct Reply: @unchecked Sendable {
        let result: [String: Any]
        let notifications: [[String: Any]]
    }

    private let runID: UUID
    private let captured: PortableProcessSupervisionPort.CapturedProcess
    private let processPort: PortableProcessSupervisionPort
    private let supervisor: ProviderProcessSupervisor
    private var offset = 0
    private var buffer = Data()
    private var nextRequestID = 1
    private var stopped = false
    private let maximumBytes = 1_048_576

    private init(
        runID: UUID,
        captured: PortableProcessSupervisionPort.CapturedProcess,
        processPort: PortableProcessSupervisionPort,
        supervisor: ProviderProcessSupervisor
    ) {
        self.runID = runID
        self.captured = captured
        self.processPort = processPort
        self.supervisor = supervisor
    }

    static func launch(
        executable: String,
        expectedVersion: String,
        home: CodexManagedAuthHome,
        processPort: PortableProcessSupervisionPort,
        processStore: SQLiteServiceStore?,
        outputDirectory: String,
        timeout: Duration
    ) async throws -> CodexManagedAuthRPCProcess {
        let runID = UUID()
        let supervisor = ProviderProcessSupervisor(processPort: processPort, store: processStore)
        let captured = try await processPort.launchInteractiveCaptured(
            executable: executable,
            arguments: ["app-server"],
            environment: try home.environment(),
            workingDirectory: home.workingDirectory,
            helperToken: runID.uuidString,
            outputDirectory: outputDirectory
        )
        do {
            try await supervisor.register(runID: runID, leader: captured.identity)
            let process = CodexManagedAuthRPCProcess(runID: runID, captured: captured, processPort: processPort, supervisor: supervisor)
            let initialized = try await process.request(
                method: "initialize",
                params: ["clientInfo": ["name": "repoprompt-server", "title": "RepoPrompt Server", "version": "1"]],
                timeout: timeout
            )
            let expectedUserAgent = "repoprompt-server/\(expectedVersion)"
            guard let userAgent = initialized.result["userAgent"] as? String,
                  userAgent == expectedUserAgent || userAgent.hasPrefix("\(expectedUserAgent) ")
            else {
                throw ServiceAPIError(code: .capabilityMissing, message: "Pinned Codex CLI version is unavailable")
            }
            try await process.notify(method: "initialized")
            return process
        } catch {
            await processPort.cancelCapturedProcess(captured)
            throw error
        }
    }

    func request(method: String, params: [String: Any]?, timeout: Duration) async throws -> Reply {
        let requestID = nextRequestID
        nextRequestID += 1
        var object: [String: Any] = ["jsonrpc": "2.0", "id": requestID, "method": method]
        if let params { object["params"] = params }
        try await send(object)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var notifications: [[String: Any]] = []
        while ContinuousClock.now < deadline {
            let frame = try await nextFrame(deadline: deadline)
            if Self.integer(frame["id"]) == requestID {
                if let error = frame["error"] as? [String: Any] {
                    throw RPCError.server(error["message"] as? String ?? "")
                }
                return Reply(result: frame["result"] as? [String: Any] ?? [:], notifications: notifications)
            }
            if frame["method"] is String { notifications.append(frame) }
        }
        throw RPCError.unavailable
    }

    func notify(method: String, params: [String: Any]? = nil) async throws {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { object["params"] = params }
        try await send(object)
    }

    func modelList(cursor: String?, limit: Int, timeout: Duration) async throws -> Reply {
        var params: [String: Any] = ["limit": limit]
        if let cursor { params["cursor"] = cursor }
        return try await request(method: "model/list", params: params, timeout: timeout)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        #if os(Linux)
            try? await supervisor.cancel(runID: runID, graceScans: 10)
        #else
            await processPort.cancelCapturedProcess(captured)
            await supervisor.forget(runID: runID)
        #endif
        await processPort.cleanupCapturedFiles(captured)
    }

    private nonisolated static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func send(_ object: [String: Any]) async throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try await processPort.write(data, to: captured)
    }

    private func nextFrame(deadline: ContinuousClock.Instant) async throws -> [String: Any] {
        while ContinuousClock.now < deadline {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                return frame
            }
            let chunk = try await processPort.capturedOutput(captured, after: offset, maximumBytes: 65_536)
            offset = chunk.nextOffset
            guard offset <= maximumBytes else { throw RPCError.unavailable }
            buffer.append(chunk.data)
            if chunk.data.isEmpty {
                guard chunk.running else { throw RPCError.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw RPCError.unavailable
    }
}

/// Linux/server adapter for Desktop's managed Codex account lifecycle:
/// `account/login/start(type: chatgptDeviceCode)`, bounded account/read polling,
/// `account/login/cancel`, and `account/logout` on an owned app-server.
public actor CodexDeviceAuthDriver: ProviderAuthFlowDriving, ProviderManagedAuthenticationDriving {
    private struct Flow {
        let process: CodexManagedAuthRPCProcess
        let loginID: String
        let expiresAt: Date
        let pending: ProviderManagedAuthenticationTransaction
    }

    private let executable: String
    private let expectedVersion: String
    private let managedHome: CodexManagedAuthHome
    private let processPort: PortableProcessSupervisionPort
    private let processStore: SQLiteServiceStore?
    private let outputDirectory: String
    private let now: @Sendable () -> Date
    private let requestTimeout: Duration
    private let flowLifetime: Duration
    private var flows: [UUID: Flow] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var cachedAvailability: (Date, Bool)?
    private var cachedModelCatalog: (Date, [ProviderModelCatalogEntry])?
    private var managedAccountSummary: ProviderManagedAccountSummary?

    public init(
        executable: String,
        expectedVersion: String = CodexCLIContract.pinnedVersion,
        managedHome: CodexManagedAuthHome,
        processPort: PortableProcessSupervisionPort,
        processStore: SQLiteServiceStore? = nil,
        outputDirectory: String,
        now: @escaping @Sendable () -> Date = Date.init,
        requestTimeout: Duration = .seconds(30),
        flowLifetime: Duration = .seconds(900)
    ) {
        self.executable = executable
        self.expectedVersion = expectedVersion
        self.managedHome = managedHome
        self.processPort = processPort
        self.processStore = processStore
        self.outputDirectory = outputDirectory
        self.now = now
        self.requestTimeout = requestTimeout
        self.flowLifetime = flowLifetime
    }

    public func authFlowDescriptor(providerID: ProviderSettingsID, forceRefresh: Bool = false) async -> ProviderManagedAuthenticationFlowCapability? {
        guard providerID == .codex else { return nil }
        let available = await startable(forceRefresh: forceRefresh)
        return .init(
            kind: .deviceCodeBeta,
            displayName: "ChatGPT device authorization",
            startable: available,
            detail: available
                ? "Sign in to the server's separate Codex account with a code entered on another device"
                : "Device authorization is temporarily unavailable because RepoPrompt could not verify the Codex runtime. Existing settings are preserved; retry after runtime status recovers."
        )
    }

    public func authenticationState(providerID: ProviderSettingsID) async -> ProviderManagedAuthenticationState {
        guard providerID == .codex else { return .unavailable }
        do {
            let process = try await launchRPC()
            do {
                let reply = try await process.request(method: "account/read", params: ["refreshToken": true], timeout: requestTimeout)
                await process.stop()
                guard Self.isAuthenticatedAccountRead(reply.result) else {
                    managedAccountSummary = nil
                    return .notAuthenticated
                }
                managedAccountSummary = Self.accountSummary(reply.result)
                return .authenticated(accountLabel: Self.accountLabel(reply.result))
            } catch {
                await process.stop()
                throw error
            }
        } catch {
            return .unavailable
        }
    }

    public func accountSummary(providerID: ProviderSettingsID) async -> ProviderManagedAccountSummary? {
        providerID == .codex ? managedAccountSummary : nil
    }

    /// Uses the same managed Codex account and paginated app-server `model/list`
    /// contract as RepoPrompt Desktop. No built-in model names are supplied here.
    public func discoverModelCatalog(providerID: ProviderSettingsID, forceRefresh: Bool = false) async throws -> [ProviderModelCatalogEntry]? {
        guard providerID == .codex else { return nil }
        if !forceRefresh,
           let cachedModelCatalog,
           now().timeIntervalSince(cachedModelCatalog.0) < 60
        {
            return cachedModelCatalog.1
        }

        var launchedProcess: CodexManagedAuthRPCProcess?
        do {
            let process = try await launchRPC()
            launchedProcess = process
            let catalog = try await fetchModelCatalog(process: process)
            await process.stop()
            guard !catalog.isEmpty else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Codex returned an empty model catalog")
            }
            cachedModelCatalog = (now(), catalog)
            return catalog
        } catch let error as ServiceAPIError {
            await launchedProcess?.stop()
            throw error
        } catch {
            await launchedProcess?.stop()
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Codex model discovery is temporarily unavailable", retryable: true)
        }
    }

    public func start(providerID: ProviderSettingsID, kind: ProviderManagedAuthenticationFlowKind) async throws -> ProviderManagedAuthenticationTransaction {
        guard providerID == .codex, kind == .deviceCodeBeta else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Provider authentication flow is unavailable")
        }
        guard flows.isEmpty else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "A Codex authentication transaction is already active")
        }
        var launchedProcess: CodexManagedAuthRPCProcess?
        do {
            let process = try await launchRPC()
            launchedProcess = process
            let start: CodexManagedAuthRPCProcess.Reply
            do {
                start = try await process.request(
                    method: "account/login/start",
                    params: ["type": CodexCLIContract.deviceFlowType],
                    timeout: requestTimeout
                )
            } catch let CodexManagedAuthRPCProcess.RPCError.server(message)
                where message.localizedCaseInsensitiveContains("external auth is active")
            {
                _ = try? await process.request(method: "account/logout", params: nil, timeout: requestTimeout)
                start = try await process.request(
                    method: "account/login/start",
                    params: ["type": CodexCLIContract.deviceFlowType],
                    timeout: requestTimeout
                )
            }
            guard let parsed = Self.parseDeviceStart(start.result) else {
                await process.stop()
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Codex returned an invalid device authorization challenge")
            }
            let flowID = UUID()
            let expiresAt = now().addingTimeInterval(Self.seconds(flowLifetime))
            let pending = ProviderManagedAuthenticationTransaction(
                flowID: flowID,
                providerID: .codex,
                kind: .deviceCodeBeta,
                state: .pending,
                userCode: parsed.userCode,
                verificationURL: parsed.verificationURL,
                expiresAt: expiresAt,
                detail: "Waiting for ChatGPT device authorization"
            )
            flows[flowID] = Flow(process: process, loginID: parsed.loginID, expiresAt: expiresAt, pending: pending)
            let lifetime = flowLifetime
            expiryTasks[flowID] = Task { [weak self] in
                try? await Task.sleep(for: lifetime)
                await self?.expire(flowID: flowID)
            }
            return pending
        } catch let error as ServiceAPIError {
            await launchedProcess?.stop()
            throw error
        } catch {
            await launchedProcess?.stop()
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Codex device authorization could not be started")
        }
    }

    public func poll(flowID: UUID) async throws -> ProviderManagedAuthenticationTransaction {
        guard let flow = flows[flowID] else {
            throw ServiceAPIError(code: .notFound, message: "Provider authentication transaction was not found")
        }
        if flow.expiresAt <= now() {
            await expire(flowID: flowID)
            return terminal(flowID: flowID, state: .expired, expiresAt: flow.expiresAt, detail: "Authentication transaction expired")
        }
        do {
            let reply = try await flow.process.request(
                method: "account/read",
                params: ["refreshToken": true],
                timeout: requestTimeout
            )
            if Self.isAuthenticatedAccountRead(reply.result) {
                flows[flowID] = nil
                expiryTasks.removeValue(forKey: flowID)?.cancel()
                await flow.process.stop()
                return terminal(flowID: flowID, state: .completed, expiresAt: flow.expiresAt, detail: "ChatGPT authorization completed")
            }
            if Self.hasFailedCompletion(reply.notifications, loginID: flow.loginID) {
                flows[flowID] = nil
                expiryTasks.removeValue(forKey: flowID)?.cancel()
                await flow.process.stop()
                return terminal(flowID: flowID, state: .failed, expiresAt: flow.expiresAt, detail: "ChatGPT device authorization was not completed")
            }
            return flow.pending
        } catch {
            flows[flowID] = nil
            expiryTasks.removeValue(forKey: flowID)?.cancel()
            await cancelLogin(flow)
            return terminal(flowID: flowID, state: .failed, expiresAt: flow.expiresAt, detail: "Codex device authorization failed")
        }
    }

    public func cancel(flowID: UUID) async {
        guard let flow = flows.removeValue(forKey: flowID) else { return }
        expiryTasks.removeValue(forKey: flowID)?.cancel()
        await cancelLogin(flow)
    }

    public func logout(providerID: ProviderSettingsID) async throws {
        guard providerID == .codex else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Managed provider logout is unavailable")
        }
        for flowID in Array(flows.keys) { await cancel(flowID: flowID) }
        var launchedProcess: CodexManagedAuthRPCProcess?
        do {
            let process = try await launchRPC()
            launchedProcess = process
            _ = try await process.request(method: "account/logout", params: nil, timeout: requestTimeout)
            await process.stop()
        } catch {
            await launchedProcess?.stop()
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Codex could not complete sign out")
        }
    }

    private func launchRPC() async throws -> CodexManagedAuthRPCProcess {
        try await CodexManagedAuthRPCProcess.launch(
            executable: executable,
            expectedVersion: expectedVersion,
            home: managedHome,
            processPort: processPort,
            processStore: processStore,
            outputDirectory: outputDirectory,
            timeout: requestTimeout
        )
    }

    private func fetchModelCatalog(process: CodexManagedAuthRPCProcess) async throws -> [ProviderModelCatalogEntry] {
        var cursor: String?
        var seenCursors = Set<String>()
        var seenModelIDs = Set<String>()
        var catalog: [ProviderModelCatalogEntry] = []

        while catalog.count < 500 {
            let reply = try await process.modelList(cursor: cursor, limit: 100, timeout: requestTimeout)
            guard let data = reply.result["data"] as? [[String: Any]] else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Codex returned an invalid model catalog")
            }

            for item in data {
                guard let rawID = Self.string(item, keys: ["id"]),
                      let id = Self.safeModelText(rawID, maximumBytes: 256),
                      seenModelIDs.insert(id.lowercased()).inserted
                else { continue }
                let providerRawValue = Self.safeModelText(Self.string(item, keys: ["model"]) ?? id, maximumBytes: 256) ?? id
                let displayName = Self.safeModelText(Self.string(item, keys: ["displayName", "display_name"]) ?? providerRawValue, maximumBytes: 256) ?? providerRawValue
                let description = Self.safeModelText(Self.string(item, keys: ["description"]) ?? "", maximumBytes: 1024)
                let effortPayload = item["supportedReasoningEfforts"] as? [[String: Any]]
                    ?? item["supported_reasoning_efforts"] as? [[String: Any]]
                    ?? []
                let efforts = Self.normalizedEfforts(
                    effortPayload.compactMap { Self.string($0, keys: ["reasoningEffort", "reasoning_effort"]) },
                    advertisedDefault: Self.string(item, keys: ["defaultReasoningEffort", "default_reasoning_effort"])
                )
                let defaultEffort = Self.defaultEffort(
                    advertised: Self.string(item, keys: ["defaultReasoningEffort", "default_reasoning_effort"]),
                    supported: efforts
                )
                let isDefault = item["isDefault"] as? Bool ?? item["is_default"] as? Bool ?? false
                let base = ProviderModelCatalogEntry(
                    id: id,
                    providerRawValue: providerRawValue,
                    displayName: displayName,
                    description: description,
                    isProviderDefault: isDefault,
                    reasoningEfforts: efforts,
                    defaultReasoningEffort: defaultEffort,
                    supportsNativeImages: true,
                    supportsSteering: true
                )
                catalog.append(base)
                if CodexServiceTierAvailability.isFastEligible(baseModelID: id), catalog.count < 500 {
                    catalog.append(
                        ProviderModelCatalogEntry(
                            id: "\(id)-fast",
                            providerRawValue: providerRawValue,
                            displayName: "\(displayName) Fast",
                            description: Self.fastDescription(description),
                            reasoningEfforts: efforts,
                            defaultReasoningEffort: defaultEffort,
                            serviceTier: CodexServiceTierAvailability.fastServiceTier,
                            supportsNativeImages: true,
                            supportsSteering: true
                        )
                    )
                }
            }

            guard let next = Self.string(reply.result, keys: ["nextCursor", "next_cursor"]),
                  seenCursors.insert(next).inserted
            else { break }
            cursor = next
        }

        guard catalog.count <= 500 else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Codex returned an oversized model catalog")
        }
        return catalog
    }

    private nonisolated static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    private nonisolated static func normalizedEfforts(_ rawValues: [String], advertisedDefault: String?) -> [String] {
        var values = Set(rawValues.compactMap { safeModelText($0.lowercased(), maximumBytes: 128) })
        if let advertisedDefault = advertisedDefault.flatMap({ safeModelText($0.lowercased(), maximumBytes: 128) }) {
            values.insert(advertisedDefault)
        }
        return effortOrder.filter { values.remove($0) != nil } + values.sorted()
    }

    private nonisolated static func defaultEffort(advertised: String?, supported: [String]) -> String? {
        let advertised = advertised.flatMap { safeModelText($0.lowercased(), maximumBytes: 128) }
        if let advertised, supported.contains(advertised) { return advertised }
        return supported.first
    }

    private nonisolated static func safeModelText(_ value: String, maximumBytes: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumBytes,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(trimmed)
        else { return nil }
        return trimmed
    }

    private nonisolated static func fastDescription(_ description: String?) -> String {
        let warning = CodexServiceTierAvailability.fastCostWarningText
        guard let description, !description.isEmpty else { return warning }
        return "\(description) \(warning)"
    }

    private func startable(forceRefresh: Bool) async -> Bool {
        if !forceRefresh, let cachedAvailability, now().timeIntervalSince(cachedAvailability.0) < 30 {
            return cachedAvailability.1
        }
        let startable: Bool
        do {
            guard expectedVersion == CodexCLIContract.pinnedVersion,
                  FileManager.default.isExecutableFile(atPath: executable)
            else { throw ServiceAPIError(code: .capabilityMissing, message: "Pinned Codex CLI is unavailable") }
            let process = try await launchRPC()
            await process.stop()
            startable = true
        } catch {
            startable = false
        }
        cachedAvailability = (now(), startable)
        return startable
    }

    private func cancelLogin(_ flow: Flow) async {
        _ = try? await flow.process.request(
            method: "account/login/cancel",
            params: ["loginId": flow.loginID],
            timeout: requestTimeout
        )
        await flow.process.stop()
    }

    private func expire(flowID: UUID) async {
        guard let flow = flows.removeValue(forKey: flowID) else { return }
        expiryTasks.removeValue(forKey: flowID)?.cancel()
        await cancelLogin(flow)
    }

    private nonisolated static func parseDeviceStart(_ response: [String: Any]) -> (loginID: String, userCode: String, verificationURL: URL)? {
        guard string(response, keys: ["type"])?.lowercased() == "chatgptdevicecode",
              let loginID = string(response, keys: ["loginId", "login_id"]),
              let userCode = string(response, keys: ["userCode", "user_code"]),
              let rawURL = string(response, keys: ["verificationUrl", "verification_url"]),
              let verificationURL = URL(string: rawURL),
              verificationURL.scheme == "https",
              verificationURL.host?.lowercased() == "auth.openai.com",
              verificationURL.path == "/codex/device",
              userCode.utf8.count <= 64,
              userCode.range(of: "^[A-Za-z0-9 -]+$", options: .regularExpression) != nil
        else { return nil }
        return (loginID, userCode, verificationURL)
    }

    private nonisolated static func isAuthenticatedAccountRead(_ response: [String: Any]) -> Bool {
        guard (response["requiresOpenaiAuth"] as? Bool ?? response["requires_openai_auth"] as? Bool ?? true) != false else {
            return false
        }
        guard let account = response["account"], !(account is NSNull) else { return false }
        return true
    }

    private nonisolated static func accountLabel(_ response: [String: Any]) -> String? {
        guard let account = response["account"] as? [String: Any] else { return nil }
        return string(account, keys: ["email"])
    }

    private nonisolated static func accountSummary(_ response: [String: Any]) -> ProviderManagedAccountSummary? {
        guard let account = response["account"] as? [String: Any] else { return nil }
        let email = string(account, keys: ["email"])
        let plan = string(account, keys: ["planType", "plan_type", "plan"])
        let authentication = string(account, keys: ["authenticationMode", "authentication_mode", "authMode", "auth_mode"])
            ?? string(response, keys: ["authenticationMode", "authentication_mode", "authMode", "auth_mode"])
            ?? "managed_chatgpt"
        return .init(
            account: email ?? "Managed Codex account",
            plan: normalizedLabel(plan) ?? "Plan not provided",
            authentication: normalizedLabel(authentication) ?? "Managed Codex sign-in"
        )
    }

    private nonisolated static func normalizedLabel(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if trimmed.caseInsensitiveCompare("chatgpt") == .orderedSame { return "ChatGPT" }
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map { word in
                let lowered = word.lowercased()
                return switch lowered {
                case "api": "API"
                case "chatgpt": "ChatGPT"
                case "oauth": "OAuth"
                case "sso": "SSO"
                default: lowered.prefix(1).uppercased() + lowered.dropFirst()
                }
            }
            .joined(separator: " ")
    }

    private nonisolated static func hasFailedCompletion(_ notifications: [[String: Any]], loginID: String) -> Bool {
        notifications.contains { frame in
            guard frame["method"] as? String == "account/login/completed",
                  let params = frame["params"] as? [String: Any],
                  string(params, keys: ["loginId", "login_id"]) == loginID
            else { return false }
            return params["success"] as? Bool == false
        }
    }

    private nonisolated static func string(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private nonisolated func terminal(flowID: UUID, state: ProviderManagedAuthenticationTransactionState, expiresAt: Date, detail: String) -> ProviderManagedAuthenticationTransaction {
        .init(flowID: flowID, providerID: .codex, kind: .deviceCodeBeta, state: state, expiresAt: expiresAt, detail: detail)
    }

    private nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
