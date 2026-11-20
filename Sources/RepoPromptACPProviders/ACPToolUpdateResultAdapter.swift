import Foundation
import RepoPromptDomainRuntime

/// Provider-neutral adapter that rewrites terminal ACP `tool_call_update` payloads into the
/// canonical durable result object (`status` / `acp_status` / title / kind / rawOutput /
/// content / rawInput) consumed by the shared tool-result persistence policy. Extracted from
/// Cursor's normalizer; Grok Build feeds the same shapes through it. Provider-specific
/// suppression rules (e.g. Cursor's placeholder tools) stay in the provider normalizers.
package enum ACPToolUpdateResultAdapter {
    /// Generated-diff input limits shared by the persistence policy and provider enrichment.
    package static let generatedDiffInputBytesLimit = 16384
    package static let generatedDiffInputLineLimit = 800

    package static func adaptedTerminalToolUpdatePayload(_ payload: [String: Any], sessionUpdate: String) -> [String: Any] {
        guard sessionUpdate == "tool_call_update",
              let status = ACPRuntimeEventParsing.firstString(in: payload, keys: ["status"])?.lowercased(),
              status == "completed" || status == "failed"
        else { return payload }

        var adapted = payload
        let resultPayload = terminalResultPayload(from: payload, status: status)
        adapted["rawOutput"] = resultPayload
        if (resultPayload["status"] as? String)?.lowercased() == "failed" {
            adapted["status"] = "failed"
        }
        return adapted
    }

    private static func terminalResultPayload(from payload: [String: Any], status: String) -> [String: Any] {
        let failed = status == "failed" || rawOutputIndicatesFailure(payload["rawOutput"])
        var result: [String: Any] = [
            "status": failed ? "failed" : "success",
            "acp_status": status
        ]
        if let title = ACPRuntimeEventParsing.firstString(in: payload, keys: ["title"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        {
            result["title"] = title
        }
        if let kind = ACPRuntimeEventParsing.firstString(in: payload, keys: ["kind", "toolKind"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !kind.isEmpty
        {
            result["kind"] = kind
        }
        if let rawOutput = payload["rawOutput"] {
            result["rawOutput"] = rawOutput
            if let rawOutputObject = rawOutput as? [String: Any],
               let chatID = AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: rawOutputObject)
            {
                result["chat_id"] = chatID
            }
        }
        if let content = payload["content"] {
            result["content"] = content
        }
        if let rawInput = payload["rawInput"], valueIsMeaningful(rawInput) {
            result["rawInput"] = rawInput
        }
        return result
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
