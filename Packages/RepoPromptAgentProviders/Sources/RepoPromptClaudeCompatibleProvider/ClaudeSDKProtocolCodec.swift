import Foundation

public enum ClaudeSDKProtocolCodec {
    public enum InboundMessage: Sendable, Equatable {
        case streamPayload([String: ClaudeProviderJSONValue])
        case controlRequest(ControlRequest)
        case controlResponse(ControlResponse)
        case controlCancelRequest(requestID: String)
        case keepAlive
    }

    public struct ControlRequest: Sendable, Equatable {
        public let requestID: String
        public let request: [String: ClaudeProviderJSONValue]
        public let subtype: String
    }

    public struct ControlResponse: Sendable, Equatable {
        public let requestID: String
        public let subtype: String
        public let response: [String: ClaudeProviderJSONValue]?
        public let error: String?
        public let pendingPermissionRequests: [[String: ClaudeProviderJSONValue]]
    }

    public enum CodecError: Error, Equatable {
        case invalidJSON
        case unsupportedPayload
    }

    public static func decodeLine(_ lineData: Data) throws -> InboundMessage? {
        guard let trimmed = trimmedASCIIWhitespace(lineData), !trimmed.isEmpty else {
            return nil
        }
        let object = try parseJSONObject(from: trimmed)

        let type = object["type"]?.stringValue ?? ""
        switch type {
        case "control_request":
            guard let requestID = object["request_id"]?.stringValue,
                  let request = object["request"]?.objectValue
            else {
                throw CodecError.unsupportedPayload
            }
            let subtype = request["subtype"]?.stringValue ?? ""
            return .controlRequest(
                ControlRequest(
                    requestID: requestID,
                    request: request,
                    subtype: subtype
                )
            )
        case "control_response":
            guard let envelope = object["response"]?.objectValue,
                  let requestID = envelope["request_id"]?.stringValue,
                  let subtype = envelope["subtype"]?.stringValue
            else {
                throw CodecError.unsupportedPayload
            }
            let responseObject = envelope["response"]?.objectValue
            let error = envelope["error"]?.stringValue
            let pendingPermissionRequests = envelope["pending_permission_requests"]?.arrayValue?
                .compactMap(\.objectValue) ?? []
            return .controlResponse(
                ControlResponse(
                    requestID: requestID,
                    subtype: subtype,
                    response: responseObject,
                    error: error,
                    pendingPermissionRequests: pendingPermissionRequests
                )
            )
        case "control_cancel_request":
            guard let requestID = object["request_id"]?.stringValue else {
                throw CodecError.unsupportedPayload
            }
            return .controlCancelRequest(requestID: requestID)
        case "keep_alive":
            return .keepAlive
        default:
            return .streamPayload(object)
        }
    }

    private static func parseJSONObject(from data: Data) throws -> [String: ClaudeProviderJSONValue] {
        func decodeObject(from data: Data) throws -> [String: ClaudeProviderJSONValue] {
            let rawObject = try JSONSerialization.jsonObject(with: data)
            guard let object = rawObject as? [String: Any] else {
                throw CodecError.invalidJSON
            }
            return try object.mapValues { try ClaudeProviderJSONValue(any: $0) }
        }

        do {
            return try decodeObject(from: data)
        } catch {
            guard let text = String(data: data, encoding: .utf8),
                  let sanitized = sanitizeJSONControlCharactersInStrings(in: text),
                  let sanitizedData = sanitized.data(using: .utf8)
            else {
                throw CodecError.invalidJSON
            }
            do {
                return try decodeObject(from: sanitizedData)
            } catch {
                throw CodecError.invalidJSON
            }
        }
    }

    private static func sanitizeJSONControlCharactersInStrings(in raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        var output = String()
        output.reserveCapacity(raw.count + 8)
        var inString = false
        var isEscaping = false
        var didSanitize = false

        for scalar in raw.unicodeScalars {
            if inString {
                if isEscaping {
                    output.unicodeScalars.append(scalar)
                    isEscaping = false
                    continue
                }
                switch scalar {
                case "\\":
                    output.unicodeScalars.append(scalar)
                    isEscaping = true
                case "\"":
                    output.unicodeScalars.append(scalar)
                    inString = false
                default:
                    if scalar.value < 0x20 {
                        output.append(String(format: "\\u%04X", scalar.value))
                        didSanitize = true
                    } else {
                        output.unicodeScalars.append(scalar)
                    }
                }
            } else {
                output.unicodeScalars.append(scalar)
                if scalar == "\"" {
                    inString = true
                }
            }
        }

        guard didSanitize else { return nil }
        return output
    }

    public static func encodeControlRequest(requestID: String, request: [String: ClaudeProviderJSONValue]) throws -> Data {
        let payload: [String: Any] = [
            "type": "control_request",
            "request_id": requestID,
            "request": request.mapValues { $0.foundationObject() }
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    public static func encodeControlResponseSuccess(requestID: String, response: [String: ClaudeProviderJSONValue]? = nil) throws -> Data {
        var envelope: [String: Any] = [
            "subtype": "success",
            "request_id": requestID
        ]
        if let response, !response.isEmpty {
            envelope["response"] = response.mapValues { $0.foundationObject() }
        }
        let payload: [String: Any] = [
            "type": "control_response",
            "response": envelope
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    public static func encodeControlResponseError(requestID: String, error: String) throws -> Data {
        let payload: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "error",
                "request_id": requestID,
                "error": error
            ]
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    public static func encodeUserMessage(text: String, sessionID: String?, uuid: UUID? = nil) throws -> Data {
        var payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ],
            "parent_tool_use_id": NSNull()
        ]
        if let uuid {
            payload["uuid"] = uuid.uuidString
        }
        if let sessionID, !sessionID.isEmpty {
            payload["session_id"] = sessionID
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }
}
