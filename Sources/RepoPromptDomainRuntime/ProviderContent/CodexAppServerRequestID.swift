import Foundation

package enum CodexAppServerRequestID: Hashable {
    case int(Int)
    case string(String)

    package init?(raw: Any) {
        if let value = raw as? Int {
            self = .int(value)
            return
        }
        if let value = raw as? NSNumber {
            self = .int(value.intValue)
            return
        }
        if let value = raw as? String {
            self = .string(value)
            return
        }
        return nil
    }

    package var jsonValue: Any {
        switch self {
        case let .int(value): value
        case let .string(value): value
        }
    }

    package var identityComponent: String {
        switch self {
        case let .int(value): "int:\(value)"
        case let .string(value): "string:\(value.utf8.count):\(value)"
        }
    }

    package var displayValue: String {
        switch self {
        case let .int(value): String(value)
        case let .string(value): value
        }
    }
}

/// Origin of a server request, stamped by the client that read it. Never reconstruct this
/// from the current transport when answering a previously received request.
package struct CodexServerRequestReceipt: Hashable {
    package let clientInstanceID: UUID
    package let transportGeneration: UInt64
    package let requestID: CodexAppServerRequestID

    package init(clientInstanceID: UUID, transportGeneration: UInt64, requestID: CodexAppServerRequestID) {
        self.clientInstanceID = clientInstanceID
        self.transportGeneration = transportGeneration
        self.requestID = requestID
    }

    package var identitySeed: String {
        "codex|\(clientInstanceID.uuidString)|\(transportGeneration)|\(requestID.identityComponent)"
    }
}
