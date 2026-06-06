import Foundation
import Logging
import MCP

struct MCPStreamableHTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    var remoteAddress: String

    init(method: String, path: String, headers: [String: String] = [:], body: Data = Data(), remoteAddress: String = "127.0.0.1") {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
    }

    func header(_ name: String) -> String? {
        let lowercased = name.lowercased()
        return headers.first { $0.key.lowercased() == lowercased }?.value
    }
}

struct MCPStreamableHTTPResponse: Equatable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data?

    init(statusCode: Int, headers: [String: String] = [:], body: Data? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    static func accepted(headers: [String: String] = [:]) -> MCPStreamableHTTPResponse {
        MCPStreamableHTTPResponse(statusCode: 202, headers: headers)
    }

    static func ok(headers: [String: String] = [:], body: Data? = nil) -> MCPStreamableHTTPResponse {
        MCPStreamableHTTPResponse(statusCode: 200, headers: headers, body: body)
    }

    static func json(_ data: Data, headers: [String: String] = [:]) -> MCPStreamableHTTPResponse {
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json"
        return MCPStreamableHTTPResponse(statusCode: 200, headers: responseHeaders, body: data)
    }

    static func error(statusCode: Int, message: String, code: Int = -32600, sessionID: String? = nil, extraHeaders: [String: String] = [:]) -> MCPStreamableHTTPResponse {
        var headers = extraHeaders
        headers["Content-Type"] = "application/json"
        if let sessionID {
            headers[MCPStreamableHTTPHeader.sessionID] = sessionID
        }
        let bodyObject: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
            "id": NSNull()
        ]
        let body = try? JSONSerialization.data(withJSONObject: bodyObject, options: [])
        return MCPStreamableHTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }
}

enum MCPStreamableHTTPHeader {
    static let sessionID = "MCP-Session-Id"
    static let authorization = "Authorization"
    static let contentType = "Content-Type"
    static let allow = "Allow"
}

enum MCPStreamableHTTPTransportError: Error, Equatable, LocalizedError {
    case invalidPath
    case invalidMethod
    case emptyBody
    case invalidJSONRPC
    case batchInitializeUnsupported
    case missingSessionID
    case invalidSessionID
    case sessionTerminated
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidPath: "Not Found"
        case .invalidMethod: "Method Not Allowed"
        case .emptyBody: "Empty request body"
        case .invalidJSONRPC: "Invalid JSON-RPC message"
        case .batchInitializeUnsupported: "Initialize must be a single JSON-RPC request in this Streamable HTTP slice"
        case .missingSessionID: "Missing MCP-Session-Id header"
        case .invalidSessionID: "Invalid or expired MCP-Session-Id"
        case .sessionTerminated: "Session has been terminated"
        case .requestTimedOut: "Timed out waiting for JSON-RPC response"
        }
    }
}

actor MCPStreamableHTTPTransport: Transport {
    nonisolated let logger: Logger
    nonisolated let sessionID: String

    private struct PendingHTTPResponse {
        var expectedIDs: [String]
        var isBatch: Bool
        var responsesByID: [String: Data] = [:]
        var continuation: CheckedContinuation<Data, Error>
    }

    private let responseTimeout: TimeInterval
    private var started = false
    private var terminated = false
    private var lastActivityAt: Date?

    private nonisolated let incomingStream: AsyncThrowingStream<Data, Error>
    private var incomingContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private nonisolated let closeStream: AsyncStream<Void>
    private var closeContinuation: AsyncStream<Void>.Continuation
    private var closeSignaled = false

    private var pendingByKey: [UUID: PendingHTTPResponse] = [:]
    private var pendingKeyByID: [String: UUID] = [:]

    init(sessionID: String = UUID().uuidString, responseTimeout: TimeInterval = 30.0, logger: Logger? = nil) {
        self.sessionID = sessionID
        self.responseTimeout = responseTimeout
        self.logger = logger ?? Logger(label: "com.repoprompt.mcp.http.transport") { _ in SwiftLogNoOpLogHandler() }

        var messageContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        incomingStream = AsyncThrowingStream(Data.self, bufferingPolicy: .bufferingOldest(1024)) { continuation in
            messageContinuation = continuation
        }
        incomingContinuation = messageContinuation

        var closedContinuation: AsyncStream<Void>.Continuation!
        closeStream = AsyncStream(Void.self) { continuation in
            closedContinuation = continuation
        }
        closeContinuation = closedContinuation
    }

    func connect() async throws {
        guard !started else { throw MCPError.internalError("HTTP transport already started") }
        guard !terminated else { throw MCPError.connectionClosed }
        started = true
    }

    func disconnect() async {
        terminate(error: MCPError.connectionClosed)
    }

    func send(_ data: Data) async throws {
        guard !terminated else { throw MCPError.connectionClosed }
        lastActivityAt = Date()
        guard let responses = Self.extractResponses(from: data), !responses.isEmpty else {
            logger.debug("Dropping server-initiated HTTP MCP message without matching POST response channel")
            return
        }

        for response in responses {
            guard let id = response.id,
                  let pendingKey = pendingKeyByID[id],
                  var pending = pendingByKey[pendingKey]
            else {
                logger.debug("No pending HTTP response waiter for JSON-RPC response")
                continue
            }

            pending.responsesByID[id] = response.data
            pendingByKey[pendingKey] = pending
            if pending.expectedIDs.allSatisfy({ pending.responsesByID[$0] != nil }) {
                completePendingResponse(key: pendingKey)
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        incomingStream
    }

    func closed() -> AsyncStream<Void> {
        closeStream
    }

    func secondsSinceLastActivity() -> TimeInterval? {
        guard let lastActivityAt else { return nil }
        return Date().timeIntervalSince(lastActivityAt)
    }

    func handle(_ request: MCPStreamableHTTPRequest) async -> MCPStreamableHTTPResponse {
        guard request.path == "/mcp" else {
            return .error(statusCode: 404, message: MCPStreamableHTTPTransportError.invalidPath.localizedDescription, code: -32600)
        }
        guard !terminated else {
            return .error(statusCode: 404, message: MCPStreamableHTTPTransportError.sessionTerminated.localizedDescription, code: -32000, sessionID: sessionID)
        }

        switch request.method.uppercased() {
        case "GET":
            return .error(
                statusCode: 405,
                message: "GET SSE is not supported by this first-slice Streamable HTTP MCP endpoint",
                code: -32600,
                sessionID: sessionID,
                extraHeaders: [MCPStreamableHTTPHeader.allow: "POST, DELETE"]
            )
        case "DELETE":
            guard validateSessionHeader(request) else {
                return sessionValidationError(for: request)
            }
            terminate(error: nil)
            return .ok(headers: sessionHeaders())
        case "POST":
            return await handlePost(request)
        default:
            return .error(
                statusCode: 405,
                message: MCPStreamableHTTPTransportError.invalidMethod.localizedDescription,
                code: -32600,
                sessionID: sessionID,
                extraHeaders: [MCPStreamableHTTPHeader.allow: "GET, POST, DELETE"]
            )
        }
    }

    private func handlePost(_ request: MCPStreamableHTTPRequest) async -> MCPStreamableHTTPResponse {
        guard !request.body.isEmpty else {
            return .error(statusCode: 400, message: MCPStreamableHTTPTransportError.emptyBody.localizedDescription, code: -32700, sessionID: sessionID)
        }
        guard let classification = Self.classifyClientMessage(request.body) else {
            return .error(statusCode: 400, message: MCPStreamableHTTPTransportError.invalidJSONRPC.localizedDescription, code: -32700, sessionID: sessionID)
        }
        if classification.containsInitialize, classification.isBatch {
            return .error(statusCode: 400, message: MCPStreamableHTTPTransportError.batchInitializeUnsupported.localizedDescription, code: -32600, sessionID: sessionID)
        }
        if classification.containsInitialize == false, validateSessionHeader(request) == false {
            return sessionValidationError(for: request)
        }
        if classification.containsInitialize, request.header(MCPStreamableHTTPHeader.sessionID) != nil, validateSessionHeader(request) == false {
            return sessionValidationError(for: request)
        }

        lastActivityAt = Date()
        if classification.requestIDs.isEmpty {
            incomingContinuation.yield(request.body)
            return .accepted(headers: sessionHeaders())
        }

        let pendingKey = UUID()
        do {
            let responseData = try await waitForResponse(
                key: pendingKey,
                expectedIDs: classification.requestIDs,
                isBatch: classification.isBatch,
                body: request.body
            )
            return .json(responseData, headers: sessionHeaders())
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .error(statusCode: 504, message: message, code: -32002, sessionID: sessionID)
        }
    }

    private func waitForResponse(key: UUID, expectedIDs: [String], isBatch: Bool, body: Data) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [self] in
                try await registerPendingAndWait(
                    key: key,
                    expectedIDs: expectedIDs,
                    isBatch: isBatch,
                    body: body
                )
            }
            group.addTask { [self, responseTimeout] in
                try await Task.sleep(for: .seconds(responseTimeout))
                await cancelPendingIfPresent(key: key, error: MCPStreamableHTTPTransportError.requestTimedOut)
                throw MCPStreamableHTTPTransportError.requestTimedOut
            }

            do {
                let result = try await group.next() ?? Data()
                group.cancelAll()
                cancelPendingIfPresent(key: key, error: CancellationError())
                return result
            } catch {
                group.cancelAll()
                cancelPendingIfPresent(key: key, error: error)
                throw error
            }
        }
    }

    private func registerPendingAndWait(key: UUID, expectedIDs: [String], isBatch: Bool, body: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingHTTPResponse(
                expectedIDs: expectedIDs,
                isBatch: isBatch,
                continuation: continuation
            )
            pendingByKey[key] = pending
            for id in expectedIDs {
                pendingKeyByID[id] = key
            }
            incomingContinuation.yield(body)
        }
    }

    private func completePendingResponse(key: UUID) {
        guard let pending = pendingByKey.removeValue(forKey: key) else { return }
        for id in pending.expectedIDs {
            pendingKeyByID.removeValue(forKey: id)
        }
        let responseData: Data
        if pending.isBatch {
            let objects = pending.expectedIDs.compactMap { id -> Any? in
                guard let data = pending.responsesByID[id] else { return nil }
                return try? JSONSerialization.jsonObject(with: data, options: [])
            }
            responseData = (try? JSONSerialization.data(withJSONObject: objects, options: [])) ?? Data("[]".utf8)
        } else {
            responseData = pending.responsesByID[pending.expectedIDs[0]] ?? Data()
        }
        pending.continuation.resume(returning: responseData)
    }

    private func cancelPendingIfPresent(key: UUID, error: Error) {
        guard let pending = pendingByKey.removeValue(forKey: key) else { return }
        for id in pending.expectedIDs {
            pendingKeyByID.removeValue(forKey: id)
        }
        pending.continuation.resume(throwing: error)
    }

    private func validateSessionHeader(_ request: MCPStreamableHTTPRequest) -> Bool {
        request.header(MCPStreamableHTTPHeader.sessionID) == sessionID
    }

    private func sessionValidationError(for request: MCPStreamableHTTPRequest) -> MCPStreamableHTTPResponse {
        if request.header(MCPStreamableHTTPHeader.sessionID) == nil {
            return .error(statusCode: 400, message: MCPStreamableHTTPTransportError.missingSessionID.localizedDescription, code: -32600, sessionID: sessionID)
        }
        return .error(statusCode: 404, message: MCPStreamableHTTPTransportError.invalidSessionID.localizedDescription, code: -32600, sessionID: sessionID)
    }

    private func sessionHeaders() -> [String: String] {
        [MCPStreamableHTTPHeader.sessionID: sessionID]
    }

    private func terminate(error: Error?) {
        guard !terminated else { return }
        terminated = true
        for key in Array(pendingByKey.keys) {
            if let pending = pendingByKey.removeValue(forKey: key) {
                pending.continuation.resume(throwing: error ?? MCPError.connectionClosed)
            }
        }
        pendingKeyByID.removeAll()
        if let error {
            incomingContinuation.finish(throwing: error)
        } else {
            incomingContinuation.finish()
        }
        signalClosedOnce()
    }

    private func signalClosedOnce() {
        guard !closeSignaled else { return }
        closeSignaled = true
        closeContinuation.yield()
        closeContinuation.finish()
    }

    static func isSingleInitializeRequest(_ body: Data) -> Bool {
        guard let classification = classifyClientMessage(body) else { return false }
        return classification.containsInitialize && !classification.isBatch
    }

    private struct ClientMessageClassification {
        var requestIDs: [String]
        var containsInitialize: Bool
        var isBatch: Bool
    }

    private struct ResponseFragment {
        var id: String?
        var data: Data
    }

    private static func classifyClientMessage(_ data: Data) -> ClientMessageClassification? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        if let array = json as? [Any] {
            guard !array.isEmpty else { return nil }
            var requestIDs: [String] = []
            var containsInitialize = false
            for element in array {
                guard let object = element as? [String: Any] else { return nil }
                let item = classifyClientObject(object)
                guard item.isValid else { return nil }
                if let id = item.requestID { requestIDs.append(id) }
                containsInitialize = containsInitialize || item.isInitialize
            }
            return ClientMessageClassification(requestIDs: requestIDs, containsInitialize: containsInitialize, isBatch: true)
        }
        guard let object = json as? [String: Any] else { return nil }
        let item = classifyClientObject(object)
        guard item.isValid else { return nil }
        return ClientMessageClassification(
            requestIDs: item.requestID.map { [$0] } ?? [],
            containsInitialize: item.isInitialize,
            isBatch: false
        )
    }

    private static func classifyClientObject(_ object: [String: Any]) -> (isValid: Bool, requestID: String?, isInitialize: Bool) {
        guard let method = object["method"] as? String else {
            // Client responses are accepted and yielded as notification-like messages.
            return (object["result"] != nil || object["error"] != nil, nil, false)
        }
        let id = normalizedJSONRPCID(object["id"])
        return (true, id, method == "initialize")
    }

    private static func extractResponses(from data: Data) -> [ResponseFragment]? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        if let array = json as? [Any] {
            return array.compactMap { element in
                guard let object = element as? [String: Any], object["result"] != nil || object["error"] != nil else { return nil }
                return responseFragment(from: object)
            }
        }
        guard let object = json as? [String: Any], object["result"] != nil || object["error"] != nil else { return nil }
        return responseFragment(from: object).map { [$0] }
    }

    private static func responseFragment(from object: [String: Any]) -> ResponseFragment? {
        guard let id = normalizedJSONRPCID(object["id"]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else { return nil }
        return ResponseFragment(id: id, data: data)
    }

    private static func normalizedJSONRPCID(_ rawID: Any?) -> String? {
        switch rawID {
        case let value as String:
            value
        case let value as Int:
            String(value)
        case let value as Int64:
            String(value)
        case let value as UInt64:
            String(value)
        case let value as Double where value.rounded() == value:
            String(Int64(value))
        default:
            nil
        }
    }
}
