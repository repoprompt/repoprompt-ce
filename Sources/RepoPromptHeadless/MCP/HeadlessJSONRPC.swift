import Foundation

struct HeadlessRPCAction {
    let responseData: Data?
    /// True only after an `exit` notification is received following shutdown.
    let shouldExit: Bool
}

enum HeadlessRPCSubmission {
    case completed(HeadlessRPCAction)
    case pending(Task<HeadlessRPCAction, Never>)
}

enum HeadlessJSONRPCMessageKind {
    case request(id: Any)
    case notification
}

enum HeadlessJSONRPC {
    static func requestObject(from frame: Data) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: frame, options: [])
        guard let object = json as? [String: Any] else {
            throw HeadlessJSONRPCError.invalidRequest("JSON-RPC frame must be an object.")
        }
        return object
    }

    static func messageKind(for object: [String: Any]) -> HeadlessJSONRPCMessageKind {
        if object.keys.contains("id") {
            return .request(id: object["id"] ?? NSNull())
        }
        return .notification
    }

    static func response(id: Any, result: Any) -> Data {
        encode([
            "jsonrpc": "2.0",
            "id": normalizedID(id),
            "result": result
        ])
    }

    static func errorResponse(id: Any, code: Int, message: String, data: Any? = nil) -> Data {
        var error: [String: Any] = [
            "code": code,
            "message": message
        ]
        if let data {
            error["data"] = data
        }
        return encode([
            "jsonrpc": "2.0",
            "id": normalizedID(id),
            "error": error
        ])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [])
        } catch {
            let fallback: [String: Any] = [
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": [
                    "code": -32603,
                    "message": "Failed to encode JSON-RPC response: \(error.localizedDescription)"
                ]
            ]
            return (try? JSONSerialization.data(withJSONObject: fallback, options: [])) ?? Data()
        }
    }

    private static func normalizedID(_ id: Any) -> Any {
        switch id {
        case is String, is Int, is Int64, is Double, is NSNull:
            id
        default:
            NSNull()
        }
    }
}

enum HeadlessJSONRPCError: LocalizedError {
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(message): message
        }
    }
}
