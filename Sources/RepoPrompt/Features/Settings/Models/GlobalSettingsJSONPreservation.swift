import Foundation

/// Apply changes in the typed projection to the original JSON. Re-encoding a
/// Codable document alone drops fields introduced by other builds, even when
/// those fields were unrelated to the preference the user changed.
enum GlobalSettingsJSONPreservation {
    /// These maps are projected through UUID-keyed properties in
    /// GlobalSettingsStore, while the persisted document retains their raw
    /// string keys. Match records by UUID identity so a casing-only rewrite is
    /// not mistaken for a deletion followed by a new record.
    private static let uuidKeyedMapKeys: Set<String> = [
        "copySettingsByWorkspaceID",
        "chatSettingsByWorkspaceID",
        "agentModelsSettingsByWorkspaceID"
    ]

    private struct CanonicalizedUUIDMap {
        var known: [String: Any] = [:]
        var unknown: [String: Any] = [:]
    }

    private struct RawUUIDMap {
        var winners: [String: (key: String, value: Any)] = [:]
        var unknown: [String: Any] = [:]
    }

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
            if uuidKeyedMapKeys.contains(key) {
                result[key] = removingUUIDKeyedEntries(known: oldObject[key], from: result[key])
            } else {
                result[key] = UUID(uuidString: key) == nil
                    ? removingKnownFields(oldObject[key], from: result[key])
                    : nil
            }
        }
        for key in newObject.keys.sorted() {
            guard let value = newObject[key] else { continue }
            if uuidKeyedMapKeys.contains(key) {
                result[key] = mergingUUIDKeyedMap(before: oldObject[key], after: value, raw: result[key])
            } else {
                result[key] = merge(before: oldObject[key], after: value, raw: result[key])
            }
        }
        return result
    }

    /// Merge UUID-keyed workspace records by canonical UUID identity. The typed
    /// projection always emits uppercase UUID strings, but the raw document may
    /// contain lowercase or mixed-case aliases. For duplicate raw aliases use
    /// the same deterministic winner as GlobalSettingsDocument: an exact
    /// canonical key wins; otherwise the lexicographically first raw key wins.
    private static func mergingUUIDKeyedMap(before: Any?, after: Any, raw: Any?) -> Any {
        let oldMap = canonicalizedUUIDMap(before)
        let newMap = canonicalizedUUIDMap(after)
        let rawMap = canonicalizedRawUUIDMap(raw)
        var result = rawMap.unknown

        let identities = Set(oldMap.known.keys).union(newMap.known.keys)
        for canonicalKey in identities.sorted() {
            if let afterValue = newMap.known[canonicalKey] {
                result[canonicalKey] = merge(
                    before: oldMap.known[canonicalKey],
                    after: afterValue,
                    raw: rawMap.winners[canonicalKey]?.value
                )
            } else if oldMap.known[canonicalKey] == nil,
                      let rawValue = rawMap.winners[canonicalKey]
            {
                // A valid raw record that was never in the typed projection is
                // unknown to this build; retain it under its deterministic key.
                result[rawValue.key] = rawValue.value
            }
            // A UUID present in before but absent from after was explicitly
            // removed. Do not retain any raw casing aliases for it.
        }

        // Preserve valid raw records that are unknown to both typed snapshots.
        for canonicalKey in rawMap.winners.keys.sorted()
            where oldMap.known[canonicalKey] == nil && newMap.known[canonicalKey] == nil
        {
            if let rawValue = rawMap.winners[canonicalKey] {
                result[rawValue.key] = rawValue.value
            }
        }

        // Invalid workspace IDs are not part of the typed projection. Keep
        // them as opaque raw entries so an ordinary save cannot discard data
        // merely because this build cannot interpret the key.
        for key in newMap.unknown.keys.sorted() {
            guard let value = newMap.unknown[key] else { continue }
            result[key] = merge(before: oldMap.unknown[key], after: value, raw: rawMap.unknown[key])
        }
        return result
    }

    /// Remove typed UUID records while retaining unrelated opaque entries in a
    /// map that is being removed from the replacement document. Returning nil
    /// lets the enclosing object omit an empty optional Agent Models map.
    private static func removingUUIDKeyedEntries(known: Any?, from raw: Any?) -> Any? {
        let knownMap = canonicalizedUUIDMap(known)
        let rawMap = canonicalizedRawUUIDMap(raw)
        var result = rawMap.unknown
        for canonicalKey in rawMap.winners.keys.sorted()
            where knownMap.known[canonicalKey] == nil
        {
            if let rawValue = rawMap.winners[canonicalKey] {
                result[rawValue.key] = rawValue.value
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func canonicalizedUUIDMap(_ value: Any?) -> CanonicalizedUUIDMap {
        guard let object = value as? [String: Any] else { return CanonicalizedUUIDMap() }
        var map = CanonicalizedUUIDMap()
        for key in object.keys.sorted() {
            guard let value = object[key] else { continue }
            guard let uuid = UUID(uuidString: key) else {
                map.unknown[key] = value
                continue
            }
            let canonicalKey = uuid.uuidString
            if map.known[canonicalKey] == nil || key == canonicalKey {
                map.known[canonicalKey] = value
            }
        }
        return map
    }

    private static func canonicalizedRawUUIDMap(_ value: Any?) -> RawUUIDMap {
        guard let object = value as? [String: Any] else { return RawUUIDMap() }
        var map = RawUUIDMap()
        for key in object.keys.sorted() {
            guard let value = object[key] else { continue }
            guard let uuid = UUID(uuidString: key) else {
                map.unknown[key] = value
                continue
            }
            let canonicalKey = uuid.uuidString
            if map.winners[canonicalKey] == nil || key == canonicalKey {
                map.winners[canonicalKey] = (key: key, value: value)
            }
        }
        return map
    }

    private static func removingKnownFields(_ known: Any?, from raw: Any?) -> Any? {
        guard let known = known as? [String: Any], var remaining = raw as? [String: Any] else { return nil }
        for (key, value) in known {
            remaining[key] = UUID(uuidString: key) == nil ? removingKnownFields(value, from: remaining[key]) : nil
        }
        return remaining.isEmpty ? nil : remaining
    }
}
