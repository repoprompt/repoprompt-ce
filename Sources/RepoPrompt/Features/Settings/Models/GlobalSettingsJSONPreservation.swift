import Foundation

/// Apply changes in the typed projection to the original JSON. Re-encoding a
/// Codable document alone drops fields introduced by other builds, even when
/// those fields were unrelated to the preference the user changed.
enum GlobalSettingsJSONPreservation {
    static func applyingChanges(from baseline: Data, to replacement: Data, preserving original: Data) throws -> Data {
        let before = try JSONSerialization.jsonObject(with: baseline)
        let after = try JSONSerialization.jsonObject(with: replacement)
        let raw = try JSONSerialization.jsonObject(with: original)
        var result = merge(before: before, after: after, raw: raw) as? [String: Any] ?? [:]
        // Header fields describe the supported output format, regardless of the
        // projection baseline's original stamp.
        if let header = after as? [String: Any] {
            for key in ["schemaVersion", "schemaLineage", "updatedAt"] {
                result[key] = header[key]
            }
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    private static func merge(before: Any?, after: Any, raw: Any?) -> Any? {
        if let before = before as? NSObject, before.isEqual(after) { return raw }
        guard let newObject = after as? [String: Any] else { return after }
        let oldObject = before as? [String: Any] ?? [:]
        var result = raw as? [String: Any] ?? [:]
        for key in oldObject.keys where newObject[key] == nil {
            // Remove workspace records explicitly, but retain unknown fields in
            // optional preference groups when their last known setting is cleared.
            result[key] = UUID(uuidString: key) == nil
                ? removingKnownFields(oldObject[key], from: result[key])
                : nil
        }
        for (key, value) in newObject {
            result[key] = merge(before: oldObject[key], after: value, raw: result[key])
        }
        return result
    }

    private static func removingKnownFields(_ known: Any?, from raw: Any?) -> Any? {
        guard let known = known as? [String: Any], var remaining = raw as? [String: Any] else { return nil }
        for (key, value) in known {
            remaining[key] = UUID(uuidString: key) == nil ? removingKnownFields(value, from: remaining[key]) : nil
        }
        return remaining.isEmpty ? nil : remaining
    }
}
