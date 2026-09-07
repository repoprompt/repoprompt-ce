import Foundation

/// Only stable protocol codes cross this boundary; never retain a raw decoding,
/// socket, provider or filesystem error in a user-visible error value.
enum SwitchboardBridgeError: String, Error {
    case invalidRequest = "invalid_request"
    case unauthorized
    case expired
    case revoked
    case staleRevision = "stale_revision"
    case unavailable
    case grantUnavailable = "grant_unavailable"
    case identityMismatch = "identity_mismatch"
}

struct SwitchboardPairingEnvelope: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    struct ProcessStart: Equatable {
        let seconds: Int64
        let microseconds: Int64
    }

    let socketPath: String
    let peerPID: Int32
    let peerStart: ProcessStart
    let expiresAt: Date
    let capability: String

    var description: String {
        "SwitchboardPairingEnvelope(redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    private init(socketPath: String, peerPID: Int32, peerStart: ProcessStart, expiresAt: Date, capability: String) {
        self.socketPath = socketPath
        self.peerPID = peerPID
        self.peerStart = peerStart
        self.expiresAt = expiresAt
        self.capability = capability
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        let object = try SwitchboardBridgeWire.decodeObject(data)
        try object.requireKeys(["v", "socket_path", "peer_pid", "peer_start", "capability", "expires_at"])
        guard try object.integer("v") == 1 else { throw SwitchboardBridgeError.invalidRequest }
        let path = try object.text("socket_path", maxBytes: 103)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), components.count >= 3,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw SwitchboardBridgeError.invalidRequest }
        let pid = try object.integer("peer_pid", minimum: 1, maximum: Int64(Int32.max))
        let start = try object.object("peer_start")
        try start.requireKeys(["seconds", "microseconds"])
        let stamp = try ProcessStart(
            seconds: start.integer("seconds", minimum: 1),
            microseconds: start.integer("microseconds", maximum: 999_999)
        )
        let capability = try object.text("capability", maxBytes: 44)
        guard let decoded = Data(base64Encoded: capability), decoded.count == 32,
              decoded.base64EncodedString() == capability
        else { throw SwitchboardBridgeError.invalidRequest }
        let expires = try Date(timeIntervalSince1970: TimeInterval(object.integer("expires_at", minimum: 1)))
        guard now.timeIntervalSince1970.isFinite, expires > now, expires.timeIntervalSince(now) <= 300
        else { throw SwitchboardBridgeError.expired }
        return Self(socketPath: path, peerPID: Int32(pid), peerStart: stamp, expiresAt: expires, capability: capability)
    }
}

indirect enum SwitchboardJSONValue: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case object([String: SwitchboardJSONValue])
    case array([SwitchboardJSONValue])
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case null

    var description: String {
        "SwitchboardJSONValue(redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

extension [String: SwitchboardJSONValue] {
    func requireKeys(_ keys: Set<String>) throws {
        guard Set(self.keys) == keys else { throw SwitchboardBridgeError.invalidRequest }
    }

    func object(_ key: String) throws -> Self {
        guard case let .object(value) = self[key] else { throw SwitchboardBridgeError.invalidRequest }
        return value
    }

    func integer(_ key: String, minimum: Int64 = 0, maximum: Int64 = 9_007_199_254_740_991) throws -> Int64 {
        guard case let .integer(value) = self[key], value >= minimum, value <= maximum
        else { throw SwitchboardBridgeError.invalidRequest }
        return value
    }

    func text(_ key: String, maxBytes: Int = 512) throws -> String {
        guard case let .string(value) = self[key], !value.isEmpty, value.utf8.count <= maxBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw SwitchboardBridgeError.invalidRequest }
        return value
    }

    func optionalText(_ key: String, maxBytes: Int = 512) throws -> String? {
        if self[key] == .null { return nil }
        return try text(key, maxBytes: maxBytes)
    }

    func uuid(_ key: String) throws -> UUID {
        let value = try text(key, maxBytes: 36)
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value
        else { throw SwitchboardBridgeError.invalidRequest }
        return uuid
    }
}

enum SwitchboardBridgeWire {
    static let maximumFrameBytes = 65536

    static func validateFrame(_ data: Data, allowsArrays: Bool = false) throws {
        _ = try decodeFrame(data, allowsArrays: allowsArrays)
    }

    static func decodeFrame(_ data: Data, allowsArrays: Bool = false) throws -> [String: SwitchboardJSONValue] {
        guard !data.isEmpty, data.count <= maximumFrameBytes, data.last == 0x0A,
              !data.dropLast().contains(0x0A), !data.contains(0x0D)
        else { throw SwitchboardBridgeError.invalidRequest }
        return try decodeObject(Data(data.dropLast()), allowsArrays: allowsArrays)
    }

    static func decodeObject(_ data: Data, allowsArrays: Bool = false) throws -> [String: SwitchboardJSONValue] {
        guard !data.isEmpty, data.count < maximumFrameBytes, String(data: data, encoding: .utf8) != nil
        else { throw SwitchboardBridgeError.invalidRequest }
        var parser = Parser(bytes: Array(data), allowsArrays: allowsArrays)
        let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count, case let .object(object) = value
        else { throw SwitchboardBridgeError.invalidRequest }
        return object
    }

    static func encodeFrame(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { throw SwitchboardBridgeError.invalidRequest }
        data.append(0x0A)
        guard data.count <= maximumFrameBytes else { throw SwitchboardBridgeError.invalidRequest }
        return data
    }

    static func response(_ data: Data, requestID: UUID) throws -> [String: SwitchboardJSONValue] {
        let root = try decodeFrame(data)
        guard try root.integer("v") == 1, try root.uuid("id") == requestID else {
            throw SwitchboardBridgeError.invalidRequest
        }
        if root["error"] != nil {
            try root.requireKeys(["v", "id", "error"])
            let error = try root.object("error")
            try error.requireKeys(["code"])
            guard let code = try SwitchboardBridgeError(rawValue: error.text("code"))
            else { throw SwitchboardBridgeError.invalidRequest }
            throw code
        }
        try root.requireKeys(["v", "id", "result"])
        return try root.object("result")
    }

    static func selection(_ value: SwitchboardJSONValue?, now: Date) throws -> CodexAccountAdoptionGrant {
        guard case let .object(object) = value else { throw SwitchboardBridgeError.invalidRequest }
        try object.requireKeys([
            "selection_id", "adoption_id", "selection_revision", "expires_at",
            "account_id", "email", "plan", "access_token"
        ])
        let account = try object.text("account_id")
        let token = try object.text("access_token", maxBytes: 32768)
        guard !account.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !token.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
        else { throw SwitchboardBridgeError.identityMismatch }
        let expires = try Date(timeIntervalSince1970: TimeInterval(object.integer("expires_at", minimum: 1)))
        guard expires > now else { throw SwitchboardBridgeError.expired }
        return try CodexAccountAdoptionGrant(
            adoptionID: object.uuid("adoption_id"),
            selectionID: object.uuid("selection_id"),
            revision: object.integer("selection_revision", minimum: 1),
            expiresAt: expires,
            accountID: account,
            email: object.optionalText("email"),
            plan: object.optionalText("plan", maxBytes: 128),
            accessToken: token
        )
    }

    /// A small bounded parser preserves duplicate-key and integer lexical facts
    /// that JSONDecoder/JSONSerialization erase. Arrays are outside this protocol.
    private struct Parser {
        let bytes: [UInt8]
        let allowsArrays: Bool
        var index = 0

        mutating func whitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        mutating func value(depth: Int) throws -> SwitchboardJSONValue {
            whitespace()
            guard depth <= 8, index < bytes.count else { throw SwitchboardBridgeError.invalidRequest }
            switch bytes[index] {
            case 0x5B:
                guard allowsArrays else { throw SwitchboardBridgeError.invalidRequest }
                index += 1
                whitespace()
                var result: [SwitchboardJSONValue] = []
                if consume(0x5D) { return .array(result) }
                while true {
                    guard result.count < 64 else { throw SwitchboardBridgeError.invalidRequest }
                    try result.append(value(depth: depth + 1))
                    whitespace()
                    if consume(0x5D) { return .array(result) }
                    guard consume(0x2C) else { throw SwitchboardBridgeError.invalidRequest }
                }
            case 0x7B:
                index += 1
                whitespace()
                var result: [String: SwitchboardJSONValue] = [:]
                if consume(0x7D) { return .object(result) }
                while true {
                    whitespace()
                    let key = try string()
                    guard result[key] == nil else { throw SwitchboardBridgeError.invalidRequest }
                    whitespace()
                    guard consume(0x3A) else { throw SwitchboardBridgeError.invalidRequest }
                    result[key] = try value(depth: depth + 1)
                    whitespace()
                    if consume(0x7D) { return .object(result) }
                    guard consume(0x2C) else { throw SwitchboardBridgeError.invalidRequest }
                }
            case 0x22: return try .string(string())
            case 0x74: try literal("true")
                return .bool(true)
            case 0x66: try literal("false")
                return .bool(false)
            case 0x6E: try literal("null")
                return .null
            case 0x2D, 0x30 ... 0x39:
                let start = index
                _ = consume(0x2D)
                guard index < bytes.count else { throw SwitchboardBridgeError.invalidRequest }
                if !consume(0x30) {
                    guard (0x31 ... 0x39).contains(bytes[index]) else { throw SwitchboardBridgeError.invalidRequest }
                    while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
                        index += 1
                    }
                }
                guard let number = Int64(String(decoding: bytes[start ..< index], as: UTF8.self)),
                      (-9_007_199_254_740_991 ... 9_007_199_254_740_991).contains(number)
                else { throw SwitchboardBridgeError.invalidRequest }
                return .integer(number)
            default: throw SwitchboardBridgeError.invalidRequest
            }
        }

        mutating func string() throws -> String {
            let start = index
            guard consume(0x22) else { throw SwitchboardBridgeError.invalidRequest }
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 0x22 {
                    guard let decoded = try? JSONDecoder().decode(String.self, from: Data(bytes[start ..< index]))
                    else { throw SwitchboardBridgeError.invalidRequest }
                    return decoded
                }
                if byte == 0x5C {
                    guard index < bytes.count else { throw SwitchboardBridgeError.invalidRequest }
                    index += 1
                } else if byte < 0x20 {
                    throw SwitchboardBridgeError.invalidRequest
                }
            }
            throw SwitchboardBridgeError.invalidRequest
        }

        mutating func literal(_ value: String) throws {
            let expected = Array(value.utf8)
            guard bytes.count - index >= expected.count,
                  Array(bytes[index ..< index + expected.count]) == expected
            else { throw SwitchboardBridgeError.invalidRequest }
            index += expected.count
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}
