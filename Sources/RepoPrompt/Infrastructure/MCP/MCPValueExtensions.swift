//
//  MCPValueExtensions.swift
//  RepoPrompt
//
//  Utility extensions for working with MCP Value types
//

import Foundation
import MCP

public extension Value {
    // Note: stringValue, boolValue, intValue, doubleValue, arrayValue, objectValue
    // are already provided by MCP.Value. We only add static helper methods here.

    /// Attempt to decode any JSON string into a `Value`. Returns nil if decoding fails.
    static func fromJSONString(_ json: String) -> Value? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(Value.self, from: data)
        } catch {
            return nil
        }
    }

    /// Attempt to decode a JSON object string into `[String: Value]`.
    /// Returns nil if the string isn't valid JSON or isn't an object.
    static func objectFromJSONString(_ json: String) -> [String: Value]? {
        guard let val = fromJSONString(json) else { return nil }
        if case let .object(obj) = val {
            return obj
        }
        return nil
    }
}
