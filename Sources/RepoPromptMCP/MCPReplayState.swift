import Foundation
import RepoPromptShared

struct MCPInitializeReplayPlan: Equatable {
    let initializeFrame: Data
    let initializeRequestID: JSONRPCBridgeID
    let initializeResultFingerprint: String
    let initializedFrame: Data
}

enum MCPInitializeReplayUnavailableReason: String, Swift.Error, Equatable {
    case missingInitializeFrame = "mcp_session_resume_unsupported_missing_initialize_frame"
    case initializeResponseNotDelivered = "mcp_session_resume_unsupported_initialize_response_not_delivered"
    case missingInitializedNotification = "mcp_session_resume_unsupported_missing_initialized_notification"

    var terminalReason: String {
        rawValue
    }
}

actor MCPInitializeReplayState {
    private var initializeFrame: Data?
    private var initializeRequestID: JSONRPCBridgeID?
    private var initializeResultFingerprint: String?
    private var initializedFrame: Data?
    private var initializeResponseDeliveredToHost = false

    func recordForwardedClientFrame(_ frame: Data) {
        guard let object = Self.jsonObject(from: frame),
              let method = object["method"] as? String
        else {
            return
        }

        if method == "initialize",
           initializeFrame == nil,
           let id = Self.jsonRPCID(from: object["id"]),
           id != .null
        {
            initializeFrame = frame
            initializeRequestID = id
            debugLog("MCPInitializeReplayState: cached initialize frame id=\(id)")
            return
        }

        if method == "notifications/initialized",
           object["id"] == nil
        {
            initializedFrame = frame
            debugLog("MCPInitializeReplayState: cached initialized notification")
        }
    }

    func recordDeliveredServerFrame(_ frame: Data) {
        guard !initializeResponseDeliveredToHost,
              let initializeRequestID,
              let object = Self.jsonObject(from: frame),
              let id = Self.jsonRPCID(from: object["id"]),
              id == initializeRequestID,
              let result = object["result"],
              let resultFingerprint = Self.initializeCompatibilityFingerprint(result),
              object["error"] == nil
        else {
            return
        }

        initializeResponseDeliveredToHost = true
        initializeResultFingerprint = resultFingerprint
        debugLog("MCPInitializeReplayState: initialize response delivered to host id=\(id)")
    }

    func replayPlan() -> Result<MCPInitializeReplayPlan, MCPInitializeReplayUnavailableReason> {
        guard let initializeFrame, let initializeRequestID else {
            return .failure(.missingInitializeFrame)
        }
        guard initializeResponseDeliveredToHost, let initializeResultFingerprint else {
            return .failure(.initializeResponseNotDelivered)
        }
        guard let initializedFrame else {
            return .failure(.missingInitializedNotification)
        }

        return .success(MCPInitializeReplayPlan(
            initializeFrame: initializeFrame,
            initializeRequestID: initializeRequestID,
            initializeResultFingerprint: initializeResultFingerprint,
            initializedFrame: initializedFrame
        ))
    }

    static func jsonObject(from frame: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any]
    }

    static func jsonRPCID(from value: Any?) -> JSONRPCBridgeID? {
        JSONRPCBridgeID.parseJSONValue(value)
    }

    static func canonicalJSONFingerprint(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              )
        else {
            return nil
        }
        return MCPResponseDeliveryTracer.sha256Hex(data)
    }

    static func initializeCompatibilityFingerprint(_ value: Any) -> String? {
        guard let result = value as? [String: Any] else { return nil }
        return canonicalJSONFingerprint([
            "capabilities": result["capabilities"] ?? [String: Any](),
            "protocolVersion": result["protocolVersion"] ?? NSNull()
        ])
    }
}

actor MCPOutstandingRequestReplayState {
    private struct EntryKey: Hashable {
        let id: JSONRPCBridgeID
        let ordinal: UInt64
    }

    private struct Entry {
        let id: JSONRPCBridgeID
        let ordinal: UInt64
        var frame: Data
    }

    private var nextFallbackOrdinal: UInt64 = 0
    private var entries: [EntryKey: Entry] = [:]

    func recordForwardedClientFrame(
        _ frame: Data,
        prepared: JSONRPCBridgePreparedFrame? = nil
    ) {
        recordReplayableClientRequests(frame, prepared: prepared)
        recordClientCancellations(frame)
    }

    @discardableResult
    func recordPreparedClientRequestFrame(
        _ frame: Data,
        prepared: JSONRPCBridgePreparedFrame
    ) -> Bool {
        recordReplayableClientRequests(frame, prepared: prepared)
    }

    func discardPreparedClientRequestFrame(
        _ frame: Data,
        prepared: JSONRPCBridgePreparedFrame
    ) {
        for descriptor in Self.replayableRequestDescriptors(from: frame) {
            guard let ordinal = Self.requestOrdinal(
                for: descriptor,
                in: prepared
            ) else {
                continue
            }
            let key = EntryKey(id: descriptor.id, ordinal: ordinal)
            if entries[key]?.frame == Self.lineFrame(frame) {
                entries.removeValue(forKey: key)
            }
        }
    }

    func recordDeliveredServerFrame(
        _ frame: Data,
        prepared: JSONRPCBridgePreparedFrame? = nil
    ) {
        let preparedResponses = prepared?.messages.filter { $0.kind == .response } ?? []
        if !preparedResponses.isEmpty {
            for message in preparedResponses {
                guard let id = message.id else { continue }
                removeDeliveredResponse(id: id, requestOrdinal: message.requestOrdinal)
            }
            return
        }

        for object in Self.jsonObjects(from: frame) where !object.keys.contains("method") {
            guard object["result"] != nil || object["error"] != nil,
                  let id = MCPInitializeReplayState.jsonRPCID(from: object["id"])
            else {
                continue
            }
            removeDeliveredResponse(id: id, requestOrdinal: nil)
        }
    }

    func replayFrames() -> [Data] {
        entries.values
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.frame)
    }

    @discardableResult
    private func recordReplayableClientRequests(
        _ frame: Data,
        prepared: JSONRPCBridgePreparedFrame?
    ) -> Bool {
        var didRecord = false
        let isBatch = Self.frameIsBatch(frame)
        for object in Self.jsonObjects(from: frame) {
            guard let method = object["method"] as? String else {
                continue
            }

            guard object["id"] != nil,
                  method != "initialize",
                  let id = MCPInitializeReplayState.jsonRPCID(from: object["id"]),
                  id != .null,
                  !isBatch,
                  JSONRPCBridgeReplayPolicy.isReplayableClientRequest(
                      method: method,
                      tool: Self.toolName(from: object, method: method),
                      toolArguments: Self.toolArguments(from: object, method: method)
                  )
            else {
                continue
            }

            let descriptor = RequestDescriptor(id: id, method: method, tool: Self.toolName(from: object, method: method))
            let ordinal = Self.requestOrdinal(for: descriptor, in: prepared)
                ?? fallbackOrdinal(for: id)
            let key = EntryKey(id: id, ordinal: ordinal)
            entries[key] = Entry(id: id, ordinal: ordinal, frame: Self.lineFrame(frame))
            didRecord = true
            debugLog("MCPOutstandingRequestReplayState: cached active client request id=\(id)")
        }
        return didRecord
    }

    private func recordClientCancellations(_ frame: Data) {
        for object in Self.jsonObjects(from: frame) {
            guard let method = object["method"] as? String,
                  method == "notifications/cancelled",
                  let params = object["params"] as? [String: Any],
                  let cancelledID = MCPInitializeReplayState.jsonRPCID(from: params["requestId"] ?? params["id"])
            else {
                continue
            }
            removeEntries(withID: cancelledID)
        }
    }

    private func fallbackOrdinal(for id: JSONRPCBridgeID) -> UInt64 {
        if let existing = entries.values.first(where: { $0.id == id }) {
            return existing.ordinal
        }
        nextFallbackOrdinal &+= 1
        return nextFallbackOrdinal
    }

    private func removeEntries(withID id: JSONRPCBridgeID) {
        entries = entries.filter { _, entry in entry.id != id }
    }

    private func removeDeliveredResponse(id: JSONRPCBridgeID, requestOrdinal: UInt64?) {
        if let requestOrdinal {
            entries.removeValue(forKey: EntryKey(id: id, ordinal: requestOrdinal))
        } else {
            removeEntries(withID: id)
        }
        debugLog("MCPOutstandingRequestReplayState: completed active client request id=\(id)")
    }

    private static func jsonObjects(from frame: Data) -> [[String: Any]] {
        guard let value = try? JSONSerialization.jsonObject(with: frame) else {
            return []
        }
        if let object = value as? [String: Any] {
            return [object]
        }
        if let batch = value as? [[String: Any]] {
            return batch
        }
        return []
    }

    private static func frameIsBatch(_ frame: Data) -> Bool {
        for byte in frame {
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                continue
            default:
                return byte == UInt8(ascii: "[")
            }
        }
        return false
    }

    private static func lineFrame(_ frame: Data) -> Data {
        guard frame.last != UInt8(ascii: "\n") else { return frame }
        var framed = frame
        framed.append(UInt8(ascii: "\n"))
        return framed
    }

    private static func toolName(from object: [String: Any], method: String) -> String? {
        guard method == "tools/call",
              let params = object["params"] as? [String: Any]
        else {
            return nil
        }
        return params["name"] as? String
    }

    private static func toolArguments(from object: [String: Any], method: String) -> [String: Any]? {
        guard method == "tools/call",
              let params = object["params"] as? [String: Any]
        else {
            return nil
        }
        return params["arguments"] as? [String: Any]
    }

    private struct RequestDescriptor {
        let id: JSONRPCBridgeID
        let method: String
        let tool: String?
    }

    private static func replayableRequestDescriptors(from frame: Data) -> [RequestDescriptor] {
        guard !frameIsBatch(frame) else { return [] }
        return jsonObjects(from: frame).compactMap { object in
            guard let method = object["method"] as? String,
                  object["id"] != nil,
                  method != "initialize",
                  let id = MCPInitializeReplayState.jsonRPCID(from: object["id"]),
                  id != .null,
                  JSONRPCBridgeReplayPolicy.isReplayableClientRequest(
                      method: method,
                      tool: toolName(from: object, method: method),
                      toolArguments: toolArguments(from: object, method: method)
                  )
            else {
                return nil
            }
            return RequestDescriptor(id: id, method: method, tool: toolName(from: object, method: method))
        }
    }

    private static func requestOrdinal(
        for descriptor: RequestDescriptor,
        in prepared: JSONRPCBridgePreparedFrame?
    ) -> UInt64? {
        prepared?.messages.first { message in
            message.kind == .request
                && message.id == descriptor.id
                && message.method == descriptor.method
                && message.tool == descriptor.tool
        }?.requestOrdinal
    }
}
