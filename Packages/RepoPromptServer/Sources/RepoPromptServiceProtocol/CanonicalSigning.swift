import CoreFoundation
import Crypto
import Foundation

public enum CanonicalSigning {
    public static func bodyDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func requestString(
        method: String,
        pathAndQuery: String,
        timestamp: String,
        nonce: String,
        bodyDigest: String,
        authorizationDecisionDigest: String,
        keyID: String
    ) -> String {
        [method.uppercased(), pathAndQuery, timestamp, nonce, bodyDigest, authorizationDecisionDigest, keyID]
            .joined(separator: "\n")
    }

    public static func hmacSHA256(message: String, key: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }

    public static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: value) { return value }
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return ordinary.date(from: value)
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URLDecode(_ value: String) -> Data? {
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        var standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }

    public static func randomNonce(byteCount: Int = 24) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URLEncode(Data((0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    public static func canonicalJSON(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func canonicalJSONObject(_ data: Data, removingTopLevelKeys: Set<String> = []) throws -> String {
        var value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if var object = value as? [String: Any] {
            for key in removingTopLevelKeys { object[key] = nil }
            value = object
        }
        return try renderCanonicalJSON(value)
    }

    private static func renderCanonicalJSON(_ value: Any) throws -> String {
        switch value {
        case is NSNull:
            return "null"
        case let value as String:
            return String(decoding: try JSONSerialization.data(withJSONObject: [value]), as: UTF8.self).dropFirst().dropLast().description
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "true" : "false" }
            return value.stringValue
        case let value as [Any]:
            return "[" + (try value.map(renderCanonicalJSON)).joined(separator: ",") + "]"
        case let value as [String: Any]:
            let entries = try value.keys.sorted().map { key in
                let encodedKey = String(decoding: try JSONSerialization.data(withJSONObject: [key]), as: UTF8.self).dropFirst().dropLast()
                return "\(encodedKey):\(try renderCanonicalJSON(value[key] as Any))"
            }
            return "{" + entries.joined(separator: ",") + "}"
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }

    public static func secureEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
