import Foundation

enum CursorACPEventNormalizer {
    static func normalize(_ payload: [String: Any]) -> [NormalizedAgentRuntimeEvent] {
        guard let sessionUpdate = (payload["sessionUpdate"] as? String)?.lowercased() else {
            return ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .cursor)
        }

        switch sessionUpdate {
        case "tool_call", "tool_call_update":
            guard !shouldSuppressPlaceholderToolEvent(payload) else { return [] }
            return ACPDefaultSessionUpdateNormalizer.normalize(
                ACPToolUpdateResultAdapter.adaptedTerminalToolUpdatePayload(payload, sessionUpdate: sessionUpdate),
                providerID: .cursor
            )
        default:
            return ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .cursor)
        }
    }

    private static func shouldSuppressPlaceholderToolEvent(_ payload: [String: Any]) -> Bool {
        let toolName = ACPRuntimeEventParsing.normalizedToolName(from: payload)
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized == "other" || normalized == "tool" else { return false }
        return !hasMeaningfulPlaceholderPayload(payload)
    }

    private static func hasMeaningfulPlaceholderPayload(_ payload: [String: Any]) -> Bool {
        if let rawInput = payload["rawInput"], valueIsMeaningful(rawInput) { return true }
        if let rawOutput = payload["rawOutput"], rawOutputIsMeaningful(rawOutput) { return true }
        if let content = payload["content"], valueIsMeaningful(content) { return true }
        return false
    }

    private static func rawOutputIsMeaningful(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if rawOutputIndicatesFailure(object) { return true }
            let meaningfulKeys = object.keys.filter { key in
                let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized != "success" && normalized != "status"
            }
            guard !meaningfulKeys.isEmpty else { return false }
            return meaningfulKeys.contains { key in
                guard let nested = object[key] else { return false }
                return valueIsMeaningful(nested)
            }
        }
        return valueIsMeaningful(value)
    }

    private static func rawOutputIndicatesFailure(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        if let success = object["success"] as? Bool, success == false {
            return true
        }
        if let status = ACPRuntimeEventParsing.firstString(in: object, keys: ["status", "result", "outcome", "state"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           ["failed", "failure", "error", "cancelled", "canceled"].contains(status)
        {
            return true
        }
        for key in ["exitCode", "exit_code", "code"] {
            if let code = intValue(object[key]), code != 0 {
                return true
            }
        }
        for key in ["error", "errorMessage", "error_message"] {
            if let message = object[key] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return true
            }
        }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func valueIsMeaningful(_ value: Any) -> Bool {
        if let string = value as? String {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let array = value as? [Any] {
            return array.contains { valueIsMeaningful($0) }
        }
        if let object = value as? [String: Any] {
            return object.contains { _, nested in valueIsMeaningful(nested) }
        }
        return true
    }
}
