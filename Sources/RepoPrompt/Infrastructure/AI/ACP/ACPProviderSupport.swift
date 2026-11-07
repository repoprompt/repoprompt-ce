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
