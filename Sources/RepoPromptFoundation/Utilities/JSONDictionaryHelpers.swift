import Foundation

package enum JSONDictionaryHelpers {
    package static func prettyJSONString(from object: Any, sortedKeys: Bool = true) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        if sortedKeys {
            options.insert(.sortedKeys)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    package static func object(from raw: String?) -> [String: Any]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any]
        else {
            return nil
        }
        return object
    }

    package static func string(_ object: [String: Any], key: String) -> String? {
        if let value = object[key] as? String {
            return value
        }
        if let value = object[key] as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    package static func bool(_ object: [String: Any], key: String) -> Bool? {
        if let value = object[key] as? Bool {
            return value
        }
        if let value = object[key] as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    package static func int(_ object: [String: Any], key: String) -> Int? {
        if let value = object[key] as? Int {
            return value
        }
        if let value = object[key] as? NSNumber {
            return value.intValue
        }
        if let value = object[key] as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
