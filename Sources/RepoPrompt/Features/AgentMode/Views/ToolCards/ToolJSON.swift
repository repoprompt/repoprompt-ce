import Foundation

enum ToolJSON {
    private static let strictEnvelopeKeys = [
        "Ok",
        "ok",
        "Err",
        "err",
        "structuredContent",
        "structured_content",
        "structuredResult",
        "structured_result",
        "toolResult",
        "tool_result"
    ]

    private static let singleKeyEnvelopeKeys = [
        "result",
        "output",
        "response",
        "payload",
        "data",
        "value"
    ]

    private static let contentEnvelopeKeys = [
        "json",
        "structuredContent",
        "structured_content",
        "text"
    ]

    static func data(from json: String?) -> Data? {
        guard let raw = json?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw.data(using: .utf8)
    }

    /// Decode args DTOs (uses convertFromSnakeCase for DTOs without explicit CodingKeys).
    /// Memoized per unique payload via `ToolCardProjectionCache` so repeated
    /// SwiftUI body evaluations reuse the derived DTO.
    static func decodeArgs<T: Decodable>(
        _ type: T.Type,
        from json: String?,
        cache: ToolCardProjectionCache = .shared
    ) -> T? {
        cache.projection(T.self, variant: "args", primary: json) {
            guard let data = data(from: json) else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(type, from: data)
        }
    }

    /// Decode result DTOs (no key conversion - result DTOs have explicit CodingKeys).
    /// Memoized per unique payload via `ToolCardProjectionCache`.
    static func decodeResult<T: Decodable>(
        _ type: T.Type,
        from json: String?,
        cache: ToolCardProjectionCache = .shared
    ) -> T? {
        cache.projection(T.self, variant: "result", primary: json) {
            guard let directData = data(from: json) else { return nil }
            let decoder = JSONDecoder()
            if let nestedJSON = preferredStructuredResultJSON(from: json, requireEnvelope: true, cache: cache),
               let nestedData = data(from: nestedJSON),
               let nested = try? decoder.decode(type, from: nestedData)
            {
                return nested
            }
            return try? decoder.decode(type, from: directData)
        }
    }

    /// Legacy decode - prefer decodeArgs or decodeResult
    static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        decodeResult(type, from: json)
    }

    /// Memoized `ToolRawJSON.object(from:)` for presentation-layer reads.
    /// Tool cards should use this instead of calling `ToolRawJSON.object`
    /// directly inside `body` evaluation.
    static func rawObject(
        from json: String?,
        cache: ToolCardProjectionCache = .shared
    ) -> [String: Any]? {
        cache.projection([String: Any].self, variant: "rawObject", primary: json) {
            ToolRawJSON.object(from: json)
        }
    }

    static func preferredStructuredResultJSON(
        from json: String?,
        requireEnvelope: Bool = false,
        cache: ToolCardProjectionCache = .shared
    ) -> String? {
        cache.projection(String.self, variant: "preferredJSON|env:\(requireEnvelope)", primary: json) {
            guard let data = data(from: json),
                  let root = try? JSONSerialization.jsonObject(with: data)
            else {
                return requireEnvelope ? nil : json?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let preferred = preferredStructuredValue(in: root) else {
                return requireEnvelope ? nil : json?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return canonicalJSONString(from: preferred)
        }
    }

    static func structuredResultObject(
        from json: String?,
        cache: ToolCardProjectionCache = .shared
    ) -> [String: Any]? {
        cache.projection([String: Any].self, variant: "structuredResultObject", primary: json) {
            if let preferred = preferredStructuredResultJSON(from: json, cache: cache),
               let data = preferred.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                return object
            }
            guard let data = data(from: json),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            return object
        }
    }

    static func prettyPrinted(_ json: String) -> String {
        guard let data = data(from: json),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let prettyString = String(data: pretty, encoding: .utf8)
        else {
            return json
        }
        return prettyString
    }

    static func looksLikeJSON(_ s: String?) -> Bool {
        guard let raw = s?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        if (raw.hasPrefix("{") && raw.hasSuffix("}")) || (raw.hasPrefix("[") && raw.hasSuffix("]")) {
            return true
        }
        return false
    }

    static func displayArgsJSON(from argsJSON: String?) -> String? {
        guard let data = data(from: argsJSON),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        if var dict = obj as? [String: Any] {
            dict.removeValue(forKey: "_windowID")
            dict.removeValue(forKey: "_rawJSON")
            dict.removeValue(forKey: "_tabID")
            guard !dict.isEmpty else { return nil }
            guard let pretty = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
                  let prettyString = String(data: pretty, encoding: .utf8)
            else { return argsJSON }
            return prettyString
        }

        return prettyPrinted(String(data: data, encoding: .utf8) ?? "")
    }

    private static func preferredStructuredValue(in value: Any, depth: Int = 0) -> Any? {
        guard depth < 4 else { return nil }

        if let object = value as? [String: Any] {
            for key in strictEnvelopeKeys {
                if let nested = object[key] {
                    if let preferred = preferredStructuredValue(in: nested, depth: depth + 1) {
                        return preferred
                    }
                    return nested
                }
            }

            if object.count == 1,
               let singleKey = object.keys.first,
               singleKeyEnvelopeKeys.contains(singleKey),
               let nested = object[singleKey]
            {
                if let preferred = preferredStructuredValue(in: nested, depth: depth + 1) {
                    return preferred
                }
                return nested
            }

            if let content = object["content"] as? [Any] {
                for element in content {
                    if let preferred = preferredStructuredValue(in: element, depth: depth + 1) {
                        return preferred
                    }
                    guard let contentObject = element as? [String: Any] else { continue }
                    for key in contentEnvelopeKeys {
                        guard let nested = contentObject[key] else { continue }
                        if let preferred = preferredStructuredValue(in: nested, depth: depth + 1) {
                            return preferred
                        }
                        return nested
                    }
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let preferred = preferredStructuredValue(in: element, depth: depth + 1) {
                    return preferred
                }
            }
        }

        return nil
    }

    private static func canonicalJSONString(from value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
