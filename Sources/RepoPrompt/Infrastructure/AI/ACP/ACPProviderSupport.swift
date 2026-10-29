import CryptoKit
import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptProcess
import RepoPromptSettingsCore

struct ACPActiveRequestEntry {
    let controller: ACPAgentSessionController
    let task: Task<Void, Never>
}

actor ACPActiveRequestRegistry {
    private var entries: [UUID: ACPActiveRequestEntry] = [:]
    private var isDisposed = false

    func register(
        controller: ACPAgentSessionController,
        task: Task<Void, Never>,
        id: UUID
    ) -> Bool {
        guard !isDisposed else { return false }
        entries[id] = ACPActiveRequestEntry(controller: controller, task: task)
        return true
    }

    func controller(for id: UUID) -> ACPAgentSessionController? {
        entries[id]?.controller
    }

    func remove(id: UUID) {
        entries.removeValue(forKey: id)
    }

    func snapshotAndDispose() -> [ACPActiveRequestEntry] {
        isDisposed = true
        let snapshot = Array(entries.values)
        entries.removeAll()
        return snapshot
    }
}

actor ACPDiagnosticsBuffer {
    private let logPrefix: String
    private let enableDebugLogging: Bool
    private let logCollector: CLIProcessLogCollector?
    private let maxLines: Int
    private var lines: [String] = []

    init(
        logPrefix: String,
        enableDebugLogging: Bool,
        logCollector: CLIProcessLogCollector?,
        maxLines: Int = 80
    ) {
        self.logPrefix = logPrefix
        self.enableDebugLogging = enableDebugLogging
        self.logCollector = logCollector
        self.maxLines = maxLines
    }

    func record(_ event: ACPAgentSessionController.DiagnosticEvent) {
        if enableDebugLogging {
            print("\(logPrefix) \(describe(event))")
        }
        guard let text = text(for: event) else { return }
        append(text)
    }

    func recordText(_ text: String?) {
        guard let text = normalized(text) else { return }
        append(text)
    }

    func snapshot() -> String {
        lines.joined(separator: "\n")
    }

    private func append(_ text: String) {
        lines.append(text)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        logCollector?.append(text)
    }

    private func text(for event: ACPAgentSessionController.DiagnosticEvent) -> String? {
        switch event {
        case let .stderrLine(line):
            normalized(line)
        case let .info(info):
            normalized(info)
        case let .invalidJSON(line):
            normalized(line)
        case let .unmatchedResponse(_, line):
            normalized(line)
        case .phaseStarted, .phaseCompleted, .outboundJSON, .inboundJSON:
            nil
        }
    }

    private func normalized(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private func describe(_ event: ACPAgentSessionController.DiagnosticEvent) -> String {
        switch event {
        case let .phaseStarted(phase):
            "phase started: \(phase)"
        case let .phaseCompleted(phase):
            "phase completed: \(phase)"
        case let .outboundJSON(line):
            "→ \(line)"
        case let .inboundJSON(line):
            "← \(line)"
        case let .stderrLine(line):
            "stderr: \(line)"
        case let .info(info):
            "info: \(info)"
        case let .invalidJSON(line):
            "invalid json: \(line)"
        case let .unmatchedResponse(id, line):
            "unmatched response \(id): \(line)"
        }
    }
}

actor ACPTimeoutState {
    private var didTimeout = false

    func markTimedOut() {
        didTimeout = true
    }

    func isTimedOut() -> Bool {
        didTimeout
    }
}

/// Provider-neutral adapter that rewrites terminal ACP `tool_call_update` payloads into the
/// canonical durable result object (`status` / `acp_status` / title / kind / rawOutput /
/// content / rawInput) consumed by the shared tool-result persistence policy. Extracted from
/// Cursor's normalizer; Grok Build feeds the same shapes through it. Provider-specific
/// suppression rules (e.g. Cursor's placeholder tools) stay in the provider normalizers.
enum ACPToolUpdateResultAdapter {
    /// Generated-diff input limits shared by the persistence policy and provider enrichment.
    static let generatedDiffInputBytesLimit = 16384
    static let generatedDiffInputLineLimit = 800

    static func adaptedTerminalToolUpdatePayload(_ payload: [String: Any], sessionUpdate: String) -> [String: Any] {
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

/// Provider permission-option policy for ACP approval flows. Pure and testable: the
/// controller's selection paths filter and preference-match through these helpers.
enum ACPPermissionOptionPolicy {
    static func normalizedOptionValue(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    /// Option IDs that must never be selected by an automatic or fallback path.
    /// Grok's `enable-always-approve` is typed AllowOnce for backward compatibility, so a
    /// bare kind match would otherwise select it and broaden approval beyond the request.
    static func denylistedAutoSelectOptionIDs(for providerID: ACPProviderID) -> Set<String> {
        switch providerID {
        case .openCode, .cursor, .antigravity:
            []
        case .devin:
            ["allow_always", "allow_always_global", "allow_server_session", "allow_server_always"]
        case .grokBuild:
            ["enable-always-approve"]
        }
    }

    static func isAutoSelectable(optionID: String?, for providerID: ACPProviderID) -> Bool {
        guard let normalized = normalizedOptionValue(optionID) else { return false }
        return !denylistedAutoSelectOptionIDs(for: providerID).contains(normalized)
    }

    /// Overseer approval is strictly per request. ACP's `allow_once` kind is authoritative
    /// only when the option ID does not advertise a wider scope (some providers mislabel it).
    static func overseerOneTimeAllowOptionID(
        options: [(optionID: String, kind: String)],
        providerID: ACPProviderID
    ) -> String? {
        options.first { option in
            guard let id = normalizedOptionValue(option.optionID),
                  normalizedOptionValue(option.kind) == "allow_once",
                  isAutoSelectable(optionID: id, for: providerID)
            else { return false }
            return !id.contains("always") && !id.contains("session") && !id.contains("persist") && !id.contains("global")
        }?.optionID
    }

    /// An observer's explicit decline is strictly per request, like its approval. Only a genuine
    /// one-time reject is selected; without one the caller reports `cancelled` rather than falling
    /// back to a persistent `reject_always`.
    static func overseerOneTimeRejectOptionID(
        options: [(optionID: String, kind: String)]
    ) -> String? {
        let oneTimeRejectIDs: Set = [
            "reject_once", "reject-once", "reject", "deny_once", "deny-once", "deny"
        ]
        return options.first { option in
            guard let id = normalizedOptionValue(option.optionID),
                  !id.contains("always"), !id.contains("session"), !id.contains("persist")
            else { return false }
            switch normalizedOptionValue(option.kind) {
            case "reject_once":
                return true
            case nil, "reject":
                return oneTimeRejectIDs.contains(id)
            default:
                return false
            }
        }?.optionID
    }
}
