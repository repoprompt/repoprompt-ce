import Foundation

typealias HeadlessJSONObject = [String: Any]

enum HeadlessToolResponse {
    static func success(text: String, structured: Any? = nil) -> HeadlessJSONObject {
        var result: HeadlessJSONObject = [
            "content": [["type": "text", "text": text]],
            "isError": false
        ]
        if let structured {
            result["structuredContent"] = structured
        }
        return result
    }

    static func error(_ message: String, structured: Any? = nil) -> HeadlessJSONObject {
        var result: HeadlessJSONObject = [
            "content": [["type": "text", "text": message]],
            "isError": true
        ]
        if let structured {
            result["structuredContent"] = structured
        }
        return result
    }
}

enum HeadlessJSONValue {
    static func value(_ encodable: some Encodable) throws -> Any {
        let data = try HeadlessJSONFormatting.encoder(prettyPrinted: false).encode(encodable)
        return try JSONSerialization.jsonObject(with: data, options: [])
    }
}

enum HeadlessToolArguments {
    static func requiredString(_ arguments: HeadlessJSONObject, key: String) throws -> String {
        guard let value = string(arguments, key: key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HeadlessCommandError("Missing required argument '\(key)'.", exitCode: 2)
        }
        return value
    }

    static func string(_ arguments: HeadlessJSONObject, key: String) -> String? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        if let string = value as? String { return string }
        return nil
    }

    static func int(_ arguments: HeadlessJSONObject, key: String) -> Int? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func bool(_ arguments: HeadlessJSONObject, key: String) -> Bool? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1", "on": return true
            case "false", "no", "0", "off": return false
            default: return nil
            }
        }
        return nil
    }

    static func stringArray(_ arguments: HeadlessJSONObject, key: String) -> [String]? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        if let string = value as? String { return [string] }
        if let strings = value as? [String] { return strings }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return nil
    }

    static func objectArray(_ arguments: HeadlessJSONObject, key: String) -> [HeadlessJSONObject]? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        return value as? [HeadlessJSONObject]
    }
}

enum HeadlessToolSchemas {
    static func object(properties: HeadlessJSONObject = [:], required: [String] = []) -> HeadlessJSONObject {
        var schema: HeadlessJSONObject = [
            "type": "object",
            "properties": properties,
            "additionalProperties": true
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    static func string(enum values: [String]? = nil, description: String? = nil) -> HeadlessJSONObject {
        var schema: HeadlessJSONObject = ["type": "string"]
        if let values { schema["enum"] = values }
        if let description { schema["description"] = description }
        return schema
    }

    static func integer(description: String? = nil) -> HeadlessJSONObject {
        var schema: HeadlessJSONObject = ["type": "integer"]
        if let description { schema["description"] = description }
        return schema
    }

    static func boolean(description: String? = nil) -> HeadlessJSONObject {
        var schema: HeadlessJSONObject = ["type": "boolean"]
        if let description { schema["description"] = description }
        return schema
    }

    static func stringArray(description: String? = nil) -> HeadlessJSONObject {
        var schema: HeadlessJSONObject = ["type": "array", "items": ["type": "string"]]
        if let description { schema["description"] = description }
        return schema
    }
}

struct HeadlessToolDescriptor {
    let name: String
    let description: String
    let inputSchema: HeadlessJSONObject
    let readOnlyHint: Bool?

    init(name: String, description: String, inputSchema: HeadlessJSONObject, readOnlyHint: Bool? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.readOnlyHint = readOnlyHint
    }

    var json: HeadlessJSONObject {
        var payload: HeadlessJSONObject = [
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ]
        if let readOnlyHint {
            payload["annotations"] = ["readOnlyHint": readOnlyHint]
        }
        return payload
    }
}
