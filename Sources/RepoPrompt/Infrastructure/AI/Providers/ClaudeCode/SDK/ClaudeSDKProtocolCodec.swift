import Foundation

/// Core compatibility facade for the Claude SDK protocol codec.
///
/// The parsing/encoding implementation lives in the Claude-compatible provider
/// package. This facade preserves the core controller's existing `[String: Any]`
/// shape while routing protocol rules through the package-owned DTO codec.
enum ClaudeSDKProtocolCodec {
    enum InboundMessage {
        case streamPayload([String: Any])
        case controlRequest(ControlRequest)
        case controlResponse(ControlResponse)
        case controlCancelRequest(requestID: String)
        case keepAlive
    }

    struct ControlRequest {
        let requestID: String
        let request: [String: Any]
        let subtype: String
    }

    struct ControlResponse {
        let requestID: String
        let subtype: String
        let response: [String: Any]?
        let error: String?
        let pendingPermissionRequests: [[String: Any]]
    }

    enum CodecError: Error {
        case invalidJSON
        case unsupportedPayload
    }

    static func decodeLine(_ lineData: Data) throws -> InboundMessage? {
        do {
            guard let inbound = try ClaudeCompatiblePluginProtocolCodec.decodeLine(lineData) else {
                return nil
            }
            return mapInboundMessage(inbound)
        } catch let error as ClaudeCompatiblePluginProtocolCodec.CodecError {
            throw mapCodecError(error)
        }
    }

    static func encodeControlRequest(requestID: String, request: [String: Any]) throws -> Data {
        try ClaudeCompatiblePluginProtocolCodec.encodeControlRequest(
            requestID: requestID,
            request: pluginJSONObject(from: request)
        )
    }

    static func encodeControlResponseSuccess(requestID: String, response: [String: Any]? = nil) throws -> Data {
        try ClaudeCompatiblePluginProtocolCodec.encodeControlResponseSuccess(
            requestID: requestID,
            response: response.map(pluginJSONObject(from:))
        )
    }

    static func encodeControlResponseError(requestID: String, error: String) throws -> Data {
        try ClaudeCompatiblePluginProtocolCodec.encodeControlResponseError(requestID: requestID, error: error)
    }

    static func encodeUserMessage(text: String, sessionID: String?, uuid: UUID? = nil) throws -> Data {
        try ClaudeCompatiblePluginProtocolCodec.encodeUserMessage(text: text, sessionID: sessionID, uuid: uuid)
    }

    private static func mapInboundMessage(_ inbound: ClaudeCompatiblePluginProtocolCodec.InboundMessage) -> InboundMessage {
        switch inbound {
        case let .streamPayload(payload):
            .streamPayload(coreJSONObject(from: payload))
        case let .controlRequest(request):
            .controlRequest(
                ControlRequest(
                    requestID: request.requestID,
                    request: coreJSONObject(from: request.request),
                    subtype: request.subtype
                )
            )
        case let .controlResponse(response):
            .controlResponse(
                ControlResponse(
                    requestID: response.requestID,
                    subtype: response.subtype,
                    response: response.response.map(coreJSONObject(from:)),
                    error: response.error,
                    pendingPermissionRequests: response.pendingPermissionRequests.map(coreJSONObject(from:))
                )
            )
        case let .controlCancelRequest(requestID):
            .controlCancelRequest(requestID: requestID)
        case .keepAlive:
            .keepAlive
        }
    }

    private static func mapCodecError(_ error: ClaudeCompatiblePluginProtocolCodec.CodecError) -> CodecError {
        switch error {
        case .invalidJSON:
            .invalidJSON
        case .unsupportedPayload:
            .unsupportedPayload
        }
    }

    private static func pluginJSONObject(from object: [String: Any]) throws -> [String: ClaudeCompatiblePluginJSONValue] {
        do {
            return try object.mapValues { try ClaudeCompatiblePluginJSONValue(any: $0) }
        } catch {
            throw CodecError.unsupportedPayload
        }
    }

    private static func coreJSONObject(from object: [String: ClaudeCompatiblePluginJSONValue]) -> [String: Any] {
        object.mapValues { $0.foundationObject() }
    }
}
