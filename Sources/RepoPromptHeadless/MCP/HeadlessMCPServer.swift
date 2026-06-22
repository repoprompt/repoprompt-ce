import Foundation

actor HeadlessMCPServer {
    typealias ToolCallOverride = (String, HeadlessJSONObject) async throws -> HeadlessJSONObject

    private enum LifecycleState {
        case uninitialized
        case awaitingInitializedNotification
        case ready
        case shutdown
    }

    private enum RequestKey: Hashable {
        case string(String)
        case number(Double)
        case null

        init?(id: Any) {
            switch id {
            case is NSNull:
                self = .null
            case let value as String:
                self = .string(value)
            case let value as NSNumber:
                guard String(cString: value.objCType) != "c" else { return nil }
                let number = value.doubleValue
                guard number.isFinite else { return nil }
                self = .number(number)
            case is Bool:
                return nil
            default:
                return nil
            }
        }
    }

    private let configurationStore: HeadlessConfigurationStore
    private let host: HeadlessHost
    private let registry: HeadlessToolRegistry
    private let toolCallOverride: ToolCallOverride?
    private var lifecycleState: LifecycleState = .uninitialized
    private var activeRequests: [RequestKey: Task<HeadlessRPCAction, Never>] = [:]
    private var serializedToolTail: Task<Void, Never>?

    init(
        configurationStore: HeadlessConfigurationStore,
        toolCallOverride: ToolCallOverride? = nil
    ) {
        self.configurationStore = configurationStore
        host = HeadlessHost(configurationStore: configurationStore)
        registry = HeadlessToolRegistry(host: host, configurationStore: configurationStore)
        self.toolCallOverride = toolCallOverride
    }

    func handle(frame: Data) async -> HeadlessRPCAction {
        switch submit(frame: frame) {
        case let .completed(action):
            action
        case let .pending(task):
            await task.value
        }
    }

    func submit(frame: Data) -> HeadlessRPCSubmission {
        do {
            let object = try HeadlessJSONRPC.requestObject(from: frame)
            return submit(object: object)
        } catch let error as HeadlessJSONRPCError {
            return .completed(HeadlessRPCAction(
                responseData: HeadlessJSONRPC.errorResponse(id: NSNull(), code: -32600, message: error.localizedDescription),
                shouldExit: false
            ))
        } catch {
            return .completed(HeadlessRPCAction(
                responseData: HeadlessJSONRPC.errorResponse(id: NSNull(), code: -32700, message: "Parse error: \(error.localizedDescription)"),
                shouldExit: false
            ))
        }
    }

    func cancelActiveRequests() {
        for task in activeRequests.values {
            task.cancel()
        }
    }

    func activeRequestCountForTesting() -> Int {
        activeRequests.count
    }

    private func submit(object: [String: Any]) -> HeadlessRPCSubmission {
        let hasID = object.keys.contains("id")
        let id = object["id"] ?? NSNull()
        guard object["jsonrpc"] as? String == "2.0" else {
            return .completed(invalidRequest(id: hasID ? id : NSNull(), message: "Only JSON-RPC 2.0 requests are supported."))
        }
        guard let method = object["method"] as? String, !method.isEmpty else {
            return .completed(invalidRequest(id: hasID ? id : NSNull(), message: "JSON-RPC request is missing a method."))
        }

        switch HeadlessJSONRPC.messageKind(for: object) {
        case .notification:
            return .completed(handleNotification(method: method, object: object))
        case let .request(requestID):
            return handleRequest(method: method, id: requestID, object: object)
        }
    }

    private func handleNotification(method: String, object: [String: Any]) -> HeadlessRPCAction {
        switch method {
        case "notifications/initialized":
            if lifecycleState == .awaitingInitializedNotification {
                lifecycleState = .ready
            }
            return HeadlessRPCAction(responseData: nil, shouldExit: false)
        case "notifications/cancelled":
            cancelRequest(from: object["params"])
            return HeadlessRPCAction(responseData: nil, shouldExit: false)
        case "exit":
            let shouldExit = lifecycleState == .shutdown
            if shouldExit {
                cancelActiveRequests()
            }
            return HeadlessRPCAction(responseData: nil, shouldExit: shouldExit)
        default:
            // MCP methods other than notifications/initialized, notifications/cancelled,
            // and exit are request-only. Unknown notifications are ignored per JSON-RPC.
            return HeadlessRPCAction(responseData: nil, shouldExit: false)
        }
    }

    private func handleRequest(method: String, id: Any, object: [String: Any]) -> HeadlessRPCSubmission {
        guard let requestKey = RequestKey(id: id) else {
            return .completed(requestError(
                hasID: true,
                id: NSNull(),
                code: -32600,
                message: "JSON-RPC request id must be a string, number, or null."
            ))
        }
        guard activeRequests[requestKey] == nil else {
            return .completed(requestError(
                hasID: true,
                id: id,
                code: -32600,
                message: "A request with the same JSON-RPC id is already active."
            ))
        }
        if lifecycleState == .shutdown {
            return .completed(requestError(
                hasID: true,
                id: id,
                code: -32600,
                message: "Server has shut down and no longer accepts requests."
            ))
        }

        switch method {
        case "notifications/initialized", "notifications/cancelled":
            return .completed(requestError(
                hasID: true,
                id: id,
                code: -32600,
                message: "\(method) must be sent as a notification without an id."
            ))
        case "exit":
            return .completed(requestError(
                hasID: true,
                id: id,
                code: -32600,
                message: "exit must be sent as a notification without an id."
            ))
        case "initialize":
            guard lifecycleState == .uninitialized else {
                return .completed(requestError(
                    hasID: true,
                    id: id,
                    code: -32600,
                    message: "initialize may only be sent once."
                ))
            }
            guard validInitializeParams(object["params"]) else {
                return .completed(requestError(
                    hasID: true,
                    id: id,
                    code: -32602,
                    message: "initialize requires params.protocolVersion, params.capabilities, and params.clientInfo with non-empty name and version."
                ))
            }
            lifecycleState = .awaitingInitializedNotification
            return .completed(requestResult(hasID: true, id: id, result: initializeResult()))
        default:
            guard lifecycleState == .ready else {
                return .completed(requestError(
                    hasID: true,
                    id: id,
                    code: -32002,
                    message: "Server not initialized. Send initialize, then notifications/initialized."
                ))
            }
            return executeReadyRequest(method: method, id: id, requestKey: requestKey, object: object)
        }
    }

    private func executeReadyRequest(
        method: String,
        id: Any,
        requestKey: RequestKey,
        object: [String: Any]
    ) -> HeadlessRPCSubmission {
        switch method {
        case "ping":
            return .completed(requestResult(hasID: true, id: id, result: [:]))
        case "tools/list":
            return .completed(requestResult(hasID: true, id: id, result: ["tools": registry.listDescriptors()]))
        case "tools/call":
            guard let params = object["params"] as? [String: Any] else {
                return .completed(requestError(hasID: true, id: id, code: -32602, message: "tools/call requires params."))
            }
            guard let name = params["name"] as? String, !name.isEmpty else {
                return .completed(requestError(hasID: true, id: id, code: -32602, message: "tools/call requires params.name."))
            }
            let arguments: [String: Any]
            if let rawArguments = params["arguments"] {
                if rawArguments is NSNull {
                    arguments = [:]
                } else if let objectArguments = rawArguments as? [String: Any] {
                    arguments = objectArguments
                } else {
                    return .completed(requestError(hasID: true, id: id, code: -32602, message: "tools/call params.arguments must be an object when provided."))
                }
            } else {
                arguments = [:]
            }
            return startToolRequest(id: id, requestKey: requestKey, name: name, arguments: arguments)
        case "shutdown":
            lifecycleState = .shutdown
            return .completed(requestResult(hasID: true, id: id, result: NSNull()))
        default:
            return .completed(requestError(hasID: true, id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func startToolRequest(
        id: Any,
        requestKey: RequestKey,
        name: String,
        arguments: HeadlessJSONObject
    ) -> HeadlessRPCSubmission {
        let previousSerializedTask = Self.runsConcurrently(toolName: name) ? nil : serializedToolTail
        let task = Task { [weak self, registry, toolCallOverride] in
            if let previousSerializedTask {
                await previousSerializedTask.value
            }
            let action: HeadlessRPCAction
            do {
                try Task.checkCancellation()
                let result: HeadlessJSONObject = if let toolCallOverride {
                    try await toolCallOverride(name, arguments)
                } else {
                    try await registry.call(name: name, arguments: arguments)
                }
                // A completed mutating tool call is already committed. Cancellation
                // observed after that boundary must not rewrite success as rollback.
                action = HeadlessRPCAction(
                    responseData: HeadlessJSONRPC.response(id: id, result: result),
                    shouldExit: false
                )
            } catch is CancellationError {
                action = HeadlessRPCAction(
                    responseData: HeadlessJSONRPC.errorResponse(id: id, code: -32800, message: "Request cancelled."),
                    shouldExit: false
                )
            } catch {
                action = HeadlessRPCAction(
                    responseData: HeadlessJSONRPC.errorResponse(id: id, code: -32603, message: "Tool request failed: \(error.localizedDescription)"),
                    shouldExit: false
                )
            }
            await self?.requestCompleted(requestKey)
            return action
        }
        activeRequests[requestKey] = task
        if previousSerializedTask != nil || !Self.runsConcurrently(toolName: name) {
            serializedToolTail = Task {
                _ = await task.value
            }
        }
        return .pending(task)
    }

    private func requestCompleted(_ key: RequestKey) {
        activeRequests.removeValue(forKey: key)
    }

    private func cancelRequest(from rawParams: Any?) {
        guard let params = rawParams as? [String: Any],
              let requestID = params["requestId"],
              let key = RequestKey(id: requestID)
        else {
            return
        }
        activeRequests[key]?.cancel()
    }

    private static func runsConcurrently(toolName: String) -> Bool {
        switch toolName {
        case "get_file_tree", "get_code_structure", "read_file", "file_search":
            true
        default:
            false
        }
    }

    private func initializeResult() -> [String: Any] {
        let configuredRootCount = (try? configurationStore.loadOrCreate().allowedRoots.count) ?? 0
        return [
            "protocolVersion": HeadlessVersion.mcpProtocolVersion,
            "capabilities": [
                "tools": [:]
            ],
            "serverInfo": [
                "name": HeadlessVersion.displayName,
                "version": HeadlessVersion.versionString
            ],
            "instructions": "RepoPrompt Headless is running the standalone read-oriented safe profile over direct stdio. Configure allowed roots with `repoprompt-headless config roots add /absolute/path --name NAME`. Only bind_context, constrained manage_workspaces, manage_selection, workspace_context, get_file_tree, get_code_structure, read_file, file_search, and prompt are enabled.",
            "headless": [
                "configuredRootCount": configuredRootCount,
                "stateDirectory": configurationStore.paths.rootDirectory.path,
                "safeToolsEnabled": true
            ]
        ]
    }

    private func requestResult(hasID: Bool, id: Any, result: Any, shouldExit: Bool = false) -> HeadlessRPCAction {
        guard hasID else {
            return HeadlessRPCAction(responseData: nil, shouldExit: shouldExit)
        }
        return HeadlessRPCAction(responseData: HeadlessJSONRPC.response(id: id, result: result), shouldExit: shouldExit)
    }

    private func requestError(hasID: Bool, id: Any, code: Int, message: String) -> HeadlessRPCAction {
        guard hasID else {
            return HeadlessRPCAction(responseData: nil, shouldExit: false)
        }
        return HeadlessRPCAction(responseData: HeadlessJSONRPC.errorResponse(id: id, code: code, message: message), shouldExit: false)
    }

    private func invalidRequest(id: Any, message: String) -> HeadlessRPCAction {
        HeadlessRPCAction(
            responseData: HeadlessJSONRPC.errorResponse(id: id, code: -32600, message: message),
            shouldExit: false
        )
    }

    private func validInitializeParams(_ rawParams: Any?) -> Bool {
        guard let params = rawParams as? [String: Any],
              let protocolVersion = params["protocolVersion"] as? String,
              !protocolVersion.isEmpty,
              params["capabilities"] is [String: Any],
              let clientInfo = params["clientInfo"] as? [String: Any],
              let clientName = clientInfo["name"] as? String,
              !clientName.isEmpty,
              let clientVersion = clientInfo["version"] as? String,
              !clientVersion.isEmpty
        else {
            return false
        }
        return true
    }
}
