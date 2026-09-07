import CoreFoundation
import Darwin
import Foundation

/// A deliberately narrow policy for newly created, explicitly paired backends.
/// Existing controllers and external runtime overrides cannot acquire this policy.
enum CodexManagedHTTPPolicy {
    static let providerID = "switchboard-managed-http"
    static let baseURL = "https://chatgpt.com/backend-api/codex"
    /// Upgrade only after repeating the outgoing HTTP identity and history probes.
    static let supportedRuntimeVersion = "0.149.0"

    static func verifyRuntimeVersion(_ version: String, bundledVersion: String) throws {
        guard version == supportedRuntimeVersion, version == bundledVersion else { throw Failure.unsupportedConfiguration }
    }

    /// Restore descriptor flags before callers handle failures/close transport.
    /// Capacity waits belong outside each chunk's revocable-consent lock.
    static func withNonblockingPipeWrite<T>(descriptor: Int32, _ body: () throws -> T) throws -> T {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure.unsupportedConfiguration
        }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        return try body()
    }

    /// Retain actor serialization for the whole frame, but never hold consent
    /// while waiting for pipe capacity. A revoked partial frame is terminal: its
    /// missing newline must never be completed by a later unrelated request.
    static func writeAuthorizedFrame(
        _ frame: Data, descriptor: Int32, authorization: CodexAccountAdoptionAuthorization,
        timeout: TimeInterval = 3,
        writeChunk: (Int32, Data) throws -> Void = { try writeAtomicChunk($1, descriptor: $0) },
        didPublishChunk: (Int) -> Void = { _ in }
    ) throws {
        let pipeLimit = fpathconf(descriptor, _PC_PIPE_BUF)
        guard pipeLimit > 0, timeout > 0, timeout <= 30 else { throw Failure.unsupportedConfiguration }
        let chunkLimit = min(Int(pipeLimit), 4096)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var offset = 0
        try withNonblockingPipeWrite(descriptor: descriptor) {
            do {
                while offset < frame.count {
                    guard DispatchTime.now().uptimeNanoseconds < deadline else { throw FDWriteError.system(errno: ETIMEDOUT) }
                    let end = min(offset + chunkLimit, frame.count)
                    let chunk = frame.subdata(in: offset ..< end)
                    do {
                        try authorization.withAuthorization { try writeChunk(descriptor, chunk) }
                    } catch let failure as FDWriteError where failure.errnoValue == EINTR {
                        continue
                    } catch let failure as FDWriteError where failure.errnoValue == EAGAIN || failure.errnoValue == EWOULDBLOCK {
                        // PIPE_BUF-sized nonblocking pipe writes are atomic:
                        // EAGAIN publishes none of this chunk. Poll outside the
                        // consent lock, then recheck authority before retrying.
                        var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                        let result = Darwin.poll(&event, 1, 10)
                        if result < 0, errno != EINTR { throw FDWriteError.system(errno: errno) }
                        continue
                    }
                    offset = end
                    didPublishChunk(offset)
                }
            } catch CodexAccountAdoptionReason.revoked {
                guard offset == 0 else { throw FDWriteError.system(errno: ECANCELED) }
                throw CodexAccountAdoptionReason.revoked
            }
        }
    }

    /// Exactly one syscall under consent; EINTR must return to the outer loop
    /// so its deadline and revocation checks are never hidden by writeAll.
    static func writeAtomicChunk(_ chunk: Data, descriptor: Int32) throws {
        let written = chunk.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == chunk.count else {
            let failure = written < 0 ? errno : (written == 0 ? EPIPE : EIO)
            switch failure {
            case EPIPE: throw FDWriteError.brokenPipe(errno: failure)
            case EBADF: throw FDWriteError.badDescriptor(errno: failure)
            default: throw FDWriteError.system(errno: failure)
            }
        }
    }

    enum Failure: Error, LocalizedError {
        case unsupportedConfiguration
        var errorDescription: String? {
            "Account switching requires a verified managed HTTP backend."
        }
    }

    /// Actor-owned admission returns the exact consent that must also protect
    /// frame publication: synchronous code can still race main-actor revocation.
    struct RequestGate {
        private static let providerWorkMethods: Set<String> = ["turn/start", "turn/steer", "review/start", "thread/compact/start", "thread/shellCommand"]
        private(set) var threadID: String?
        private var hasStarted = false
        private var lease: UUID?
        private var permitsTurns = false
        private var authorization: CodexAccountAdoptionAuthorization?
        private let expectedResumeThreadID: String?
        private var hasRequestedThread = false
        private var hasDispatchedProviderWork = false

        var permitsUnmaterializedThreadProof: Bool {
            threadID != nil && expectedResumeThreadID == nil && !hasDispatchedProviderWork
        }

        init(expectedResumeThreadID: String? = nil) {
            self.expectedResumeThreadID = expectedResumeThreadID
        }

        mutating func claimStartup() throws {
            guard !hasStarted else { throw Failure.unsupportedConfiguration }
            hasStarted = true
        }

        mutating func bindThread(_ id: String) throws {
            guard hasStarted, threadID == nil, !id.isEmpty,
                  expectedResumeThreadID == nil || expectedResumeThreadID == id else { throw Failure.unsupportedConfiguration }
            threadID = id
        }

        mutating func reserve() throws -> UUID {
            guard hasStarted, threadID != nil, lease == nil else { throw Failure.unsupportedConfiguration }
            let token = UUID()
            lease = token
            return token
        }

        mutating func finish(_ token: UUID, allowTurns: Bool) {
            guard lease == token else { return }
            lease = nil
            permitsTurns = allowTurns
        }

        mutating func bindAuthorization(_ authorization: CodexAccountAdoptionAuthorization) throws {
            guard lease != nil else { throw Failure.unsupportedConfiguration }
            try authorization.withAuthorization {}
            self.authorization = authorization
        }

        @discardableResult
        mutating func authorize(method: String, permitsAccountLogin: Bool = false, requestedThreadID: String? = nil) throws -> CodexAccountAdoptionAuthorization? {
            if method == "turn/interrupt" { return nil }
            if method == "account/login/start" {
                guard permitsAccountLogin, lease != nil else { throw Failure.unsupportedConfiguration }
                return nil
            }
            if ["account/logout", "thread/fork", "thread/goal/set", "thread/goal/clear"].contains(method) {
                throw Failure.unsupportedConfiguration
            }
            if method == "thread/start" || method == "thread/resume" {
                guard hasStarted, threadID == nil, lease == nil, !hasRequestedThread else { throw Failure.unsupportedConfiguration }
                if method == "thread/resume" {
                    guard let expectedResumeThreadID, requestedThreadID == expectedResumeThreadID else { throw Failure.unsupportedConfiguration }
                } else {
                    guard expectedResumeThreadID == nil else { throw Failure.unsupportedConfiguration }
                }
                hasRequestedThread = true
                return nil
            }
            if Self.providerWorkMethods.contains(method) {
                guard permitsTurns, lease == nil, let authorization else { throw Failure.unsupportedConfiguration }
                try authorization.withAuthorization {}
                return authorization
            }
            if lease != nil, method.hasPrefix("config/"), method != "config/read" {
                throw Failure.unsupportedConfiguration
            }
            if lease != nil, !["/read", "/list", "/get"].contains(where: method.hasSuffix) {
                throw Failure.unsupportedConfiguration
            }
            return nil
        }

        mutating func recordFramePublication(method: String) {
            if Self.providerWorkMethods.contains(method) { hasDispatchedProviderWork = true }
        }
    }

    static func threadProof(
        response: [String: Any], loaded: [String: Any], expectedThreadID: String,
        pendingMutation: Bool, persistedTools: [String]
    ) throws -> CodexAccountAdoptionRuntimeProof {
        guard !expectedThreadID.isEmpty,
              let ids = loaded["data"] as? [String], ids == [expectedThreadID],
              loaded["nextCursor"] == nil || loaded["nextCursor"] is NSNull,
              let thread = response["thread"] as? [String: Any],
              thread["id"] as? String == expectedThreadID,
              thread["modelProvider"] as? String == providerID,
              let status = thread["status"] as? [String: Any],
              let statusType = status["type"] as? String, ["idle", "active"].contains(statusType),
              let turns = thread["turns"] as? [[String: Any]] else { throw Failure.unsupportedConfiguration }
        var hasActiveTurn = statusType == "active"
        var hasTools = !persistedTools.isEmpty
        for turn in turns {
            guard let id = turn["id"] as? String, !id.isEmpty,
                  let turnStatus = turn["status"] as? String,
                  ["completed", "interrupted", "failed", "inProgress"].contains(turnStatus),
                  turn["itemsView"] == nil || turn["itemsView"] as? String == "full",
                  let items = turn["items"] as? [[String: Any]] else { throw Failure.unsupportedConfiguration }
            hasActiveTurn = hasActiveTurn || turnStatus == "inProgress"
            for item in items {
                let active = try CodexManagedThreadItemProof.hasActiveWork(item)
                hasTools = hasTools || active
            }
        }
        return .init(
            threadID: expectedThreadID,
            loadedThreadIDs: ids,
            isAuthoritativelyIdle: !hasActiveTurn && !pendingMutation,
            hasInProgressTools: hasTools,
            managedHTTP: true,
            pinnedRuntime: true
        )
    }

    static var launchArguments: [String] {
        launchArguments(baseURL: baseURL)
    }

    #if DEBUG
        static func integrationLaunchArguments(_ configuration: CodexManagedHTTPIntegrationConfiguration) -> [String] {
            launchArguments(baseURL: configuration.responsesURL)
        }

        static func verifyIntegrationConfiguration(_ response: [String: Any], configuration: CodexManagedHTTPIntegrationConfiguration) throws {
            try verifyEffectiveConfiguration(response, expectedBaseURL: configuration.responsesURL)
        }
    #endif

    private static func launchArguments(baseURL: String) -> [String] {
        let assignments = [
            "model_provider=\"\(providerID)\"",
            "model_providers.\(providerID).name=\"Switchboard managed HTTP\"",
            "model_providers.\(providerID).base_url=\"\(baseURL)\"",
            "model_providers.\(providerID).requires_openai_auth=true",
            "model_providers.\(providerID).wire_api=\"responses\"",
            "model_providers.\(providerID).supports_websockets=false",
            "cli_auth_credentials_store=\"ephemeral\"",
            "features.goals=false"
        ]
        return assignments.flatMap { ["-c", $0] }
    }

    static func environment(_ source: [String: String]) -> [String: String] {
        let removed: Set = [
            "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_AUTH",
            "OPENAI_BASE_URL", "ORCA_CODEX_HOME", "CODEX_REFRESH_TOKEN_URL_OVERRIDE",
            "CHATGPT_BASE_URL", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "SSLKEYLOGFILE", "LOG_LEVEL", "DEBUG", "TRACE"
        ]
        return source.filter {
            let key = $0.key
            if ["CODEX_HOME", "CODEX_SQLITE_HOME"].contains(key) { return true }
            return !removed.contains(key) && !["RUST_", "OTEL_", "OTLP_", "CODEX_"].contains(where: key.hasPrefix)
        }
    }

    static func verifyEffectiveConfiguration(_ response: [String: Any]) throws {
        try verifyEffectiveConfiguration(response, expectedBaseURL: baseURL)
    }

    private static func verifyEffectiveConfiguration(_ response: [String: Any], expectedBaseURL: String) throws {
        guard let config = response["config"] as? [String: Any],
              config["model_provider"] as? String == providerID,
              config["cli_auth_credentials_store"] as? String == "ephemeral",
              let features = config["features"] as? [String: Any],
              strictBoolean(features["goals"], equals: false),
              let providers = config["model_providers"] as? [String: Any],
              let provider = providers[providerID] as? [String: Any],
              provider["name"] as? String == "Switchboard managed HTTP",
              provider["base_url"] as? String == expectedBaseURL,
              provider["wire_api"] as? String == "responses",
              strictBoolean(provider["requires_openai_auth"], equals: true),
              strictBoolean(provider["supports_websockets"], equals: false)
        else { throw Failure.unsupportedConfiguration }

        let required: Set = ["name", "base_url", "wire_api", "requires_openai_auth", "supports_websockets"]
        let nullable: Set = ["env_key", "env_key_instructions", "experimental_bearer_token", "auth", "aws"]
        let dictionaries: Set = ["http_headers", "env_http_headers", "query_params"]
        let numbers: Set = ["request_max_retries", "stream_max_retries", "stream_idle_timeout_ms", "websocket_connect_timeout_ms"]
        for (key, value) in provider where !required.contains(key) {
            if nullable.contains(key), value is NSNull { continue }
            if dictionaries.contains(key), value is NSNull || (value as? [String: Any])?.isEmpty == true { continue }
            if numbers.contains(key) {
                if value is NSNull { continue }
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                   number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue { continue }
            }
            if key == "supports_standalone_web_search", strictBoolean(value, equals: false) { continue }
            throw Failure.unsupportedConfiguration
        }
        let rest = config.filter { !["model_provider", "model_providers", "cli_auth_credentials_store"].contains($0.key) }
        try validateConfiguration(rest, effective: true)
    }

    static func requestParameters(method: String, params: [String: Any]?, permitsAccountLogin: Bool = false) throws -> [String: Any]? {
        if method == "account/login/start" {
            guard permitsAccountLogin, params?["type"] as? String == "chatgptAuthTokens" else {
                throw Failure.unsupportedConfiguration
            }
            return params
        }
        guard method != "account/logout", method != "thread/goal/set", method != "thread/goal/clear" else {
            throw Failure.unsupportedConfiguration
        }
        var result = params ?? [:]
        for (key, value) in result {
            if key == "modelProvider" {
                guard value is NSNull || value as? String == providerID else { throw Failure.unsupportedConfiguration }
            } else if isBlocked(path: keyPath(key)) {
                throw Failure.unsupportedConfiguration
            }
        }
        if let config = result["config"], !(config is NSNull) {
            guard let dictionary = config as? [String: Any] else { throw Failure.unsupportedConfiguration }
            try validateConfiguration(dictionary)
        }
        if method == "config/value/write" {
            try validateWrite(result)
        } else if method == "config/batchWrite" {
            guard let edits = result["edits"] as? [[String: Any]] else { throw Failure.unsupportedConfiguration }
            for edit in edits {
                try validateWrite(edit)
            }
        }
        if ["thread/start", "thread/resume", "thread/fork"].contains(method) {
            result["modelProvider"] = providerID
        }
        return params == nil && result.isEmpty ? nil : result
    }

    private static let blockedKeys: Set<String> = [
        "modelprovider", "modelproviders", "provider", "providers", "ossprovider", "localprovider",
        "baseurl", "chatgptbaseurl", "openaibaseurl", "envkey", "apikey", "openaiapikey",
        "codexapikey", "codexaccesstoken", "codexauth", "codexhome", "orcacodexhome",
        "codexrefreshtokenurloverride", "experimentalbearertoken", "bearertoken", "authorization",
        "auth", "httpheaders", "envhttpheaders", "queryparams", "requiresopenaiauth", "wireapi",
        "supportswebsockets", "forcedloginmethod", "forcedchatgptworkspaceid", "cliauthcredentialsstore",
        "profile", "configfile", "configfilepath", "configprofile", "experimentalrealtimewsbaseurl",
        "experimentalrealtimewebrtccallbaseurl", "goals", "otel", "logdir"
    ]

    private static func keyPath(_ key: String) -> [String] {
        // These inputs are decoded JSON keys, not TOML source. Refuse escape
        // syntax rather than letting a later TOML parser reinterpret a route key.
        guard !key.contains("\\"), !key.contains("\""), !key.contains("'") else { return [""] }
        return key.lowercased().split(separator: ".", omittingEmptySubsequences: false).map {
            $0.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    private static func isBlocked(path: [String]) -> Bool {
        if path.first == "mcpservers" { return false }
        if path.count >= 3, path[0] == "profiles", path[2] == "mcpservers" {
            return path.prefix(2).contains { blockedKeys.contains($0) || $0.contains("websocket") }
        }
        return path.contains { blockedKeys.contains($0) || $0.contains("websocket") || $0.isEmpty }
    }

    private static func validateConfiguration(_ dictionary: [String: Any], prefix: [String] = [], effective: Bool = false) throws {
        for (key, value) in dictionary {
            let path = prefix + keyPath(key)
            if path == ["features", "goals"], strictBoolean(value, equals: false) { continue }
            if isBlocked(path: path) {
                if effective, path.count == 1 {
                    if ["forcedchatgptworkspaceid", "ossprovider", "profile", "openaibaseurl", "experimentalrealtimewsbaseurl", "experimentalrealtimewebrtccallbaseurl", "goals", "otel", "logdir"].contains(path[0]), value is NSNull { continue }
                    if path[0] == "forcedloginmethod", value is NSNull || value as? String == "chatgpt" { continue }
                    if path[0] == "chatgptbaseurl", value as? String == "https://chatgpt.com/backend-api/" { continue }
                }
                throw Failure.unsupportedConfiguration
            }
            try validateValue(value, path: path, effective: effective)
        }
    }

    private static func validateValue(_ value: Any, path: [String], effective: Bool) throws {
        if let dictionary = value as? [String: Any] {
            try validateConfiguration(dictionary, prefix: path, effective: effective)
        } else if let values = value as? [Any] {
            for item in values {
                try validateValue(item, path: path, effective: effective)
            }
        }
    }

    private static func validateWrite(_ edit: [String: Any]) throws {
        guard let key = edit["keyPath"] as? String, let value = edit["value"], !isBlocked(path: keyPath(key)) else {
            throw Failure.unsupportedConfiguration
        }
        try validateValue(value, path: keyPath(key), effective: false)
    }

    private static func strictBoolean(_ value: Any?, equals expected: Bool) -> Bool {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue == expected
    }
}
