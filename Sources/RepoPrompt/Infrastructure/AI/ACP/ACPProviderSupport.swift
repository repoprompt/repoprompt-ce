import CryptoKit
import Foundation
import RepoPromptProcessSupport

enum ACPRuntimeEventParsing {
    static func extractContentText(from value: Any?) -> String? {
        guard let value else { return nil }
        if let dict = value as? [String: Any] {
            let type = (dict["type"] as? String)?.lowercased()
            if type == "text", let text = dict["text"] as? String {
                return text
            }
            if let nested = dict["content"] {
                return extractContentText(from: nested)
            }
            if let nested = dict["output"] {
                return extractContentText(from: nested)
            }
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { extractContentText(from: $0) }
            let joined = parts.joined()
            return joined.isEmpty ? nil : joined
        }
        if let text = value as? String {
            return text
        }
        return nil
    }

    static func normalizedToolName(from payload: [String: Any]) -> String {
        if let repoPromptToolName = repoPromptToolName(from: payload) {
            return repoPromptToolName
        }
        if let stableIdentifier = firstMachineIdentifier(
            in: payload,
            keys: ["toolName", "name", "tool"]
        ) {
            return explicitRepoPromptToolName(from: stableIdentifier) ?? stableIdentifier
        }
        if let title = firstString(in: payload, keys: ["title"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           isMachineIdentifier(title)
        {
            return explicitRepoPromptToolName(from: title) ?? title
        }
        if let stableKind = firstMachineIdentifier(in: payload, keys: ["toolKind", "kind"]) {
            return explicitRepoPromptToolName(from: stableKind) ?? stableKind
        }
        if let title = firstString(in: payload, keys: ["title"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty
        {
            return title
        }
        return "tool"
    }

    static func repoPromptToolName(from payload: [String: Any]) -> String? {
        guard let rawTitle = firstString(in: payload, keys: ["title"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTitle.isEmpty
        else {
            return nil
        }

        if let parenthesized = repoPromptToolNameFromParenthesizedServerTitle(rawTitle) {
            return parenthesized
        }
        if let prefixed = repoPromptToolNameFromPrefixedTitle(rawTitle) {
            return prefixed
        }
        return nil
    }

    private static func repoPromptToolNameFromParenthesizedServerTitle(_ rawTitle: String) -> String? {
        guard let match = rawTitle.wholeMatch(of: /^([A-Za-z0-9_.:\/-]+)\s+\((.+)\)$/) else {
            return nil
        }

        let toolName = String(match.1)
        let serverName = String(match.2)
        guard MCPIntegrationHelper.isRepoPromptServerIdentifier(serverName),
              let canonicalToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName)
        else {
            return nil
        }
        return explicitRepoPromptToolName(canonicalToolName)
    }

    private static func repoPromptToolNameFromPrefixedTitle(_ rawTitle: String) -> String? {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let prefix = "\(RepoPromptMCPServerConfiguration.defaultServerName.lowercased())-"
        guard lowered.hasPrefix(prefix) else { return nil }

        let body = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = body
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            + [body]
        for candidate in candidates {
            if let canonicalToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(candidate) {
                return explicitRepoPromptToolName(canonicalToolName)
            }
        }
        return nil
    }

    private static func explicitRepoPromptToolName(_ canonicalToolName: String) -> String {
        "mcp__\(RepoPromptMCPServerConfiguration.defaultServerName)__\(canonicalToolName)"
    }

    static func explicitRepoPromptToolName(from rawName: String) -> String? {
        guard MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(rawName),
              let canonicalToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(rawName)
        else {
            return nil
        }
        return "mcp__\(RepoPromptMCPServerConfiguration.defaultServerName)__\(canonicalToolName)"
    }

    static func firstString(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String {
                return value
            }
        }
        return nil
    }

    static func firstMachineIdentifier(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = payload[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isMachineIdentifier(trimmed) else { continue }
            return trimmed
        }
        return nil
    }

    static func serializeJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    static func stableInvocationUUID(namespace: String = "acp-tool", rawValue: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(namespace)|\(rawValue)".utf8)))
        let bytes: uuid_t = (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: bytes)
    }

    private static func isMachineIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        return value.range(of: #"^[A-Za-z0-9_.:\-/]+$"#, options: .regularExpression) != nil
    }
}

enum ACPDefaultSessionUpdateNormalizer {
    static func normalize(
        _ payload: [String: Any],
        providerID: ACPProviderID
    ) -> [NormalizedAgentRuntimeEvent] {
        guard let sessionUpdate = (payload["sessionUpdate"] as? String)?.lowercased() else {
            return []
        }

        switch sessionUpdate {
        case "agent_message_chunk":
            guard let text = ACPRuntimeEventParsing.extractContentText(from: payload["content"]), !text.isEmpty else { return [] }
            let messageID = ACPRuntimeEventParsing.firstString(in: payload, keys: ["messageId", "messageID"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return [.stream(AIStreamResult(type: "content", text: text, contentMessageID: messageID?.isEmpty == false ? messageID : nil))]
        case "agent_thought_chunk":
            guard let text = ACPRuntimeEventParsing.extractContentText(from: payload["content"]), !text.isEmpty else { return [] }
            return [.stream(AIStreamResult(type: "reasoning", text: nil, reasoning: text))]
        case "tool_call":
            return normalizeToolCall(payload)
        case "tool_call_update":
            return normalizeToolCallUpdate(payload)
        case "usage_update":
            return normalizeUsageUpdate(payload)
        case "session_info_update":
            if let title = ACPRuntimeEventParsing.firstString(in: payload, keys: ["title"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty
            {
                return [.stream(AIStreamResult(type: "status", text: title))]
            }
            return []
        case "available_commands_update", "plan", "user_message_chunk":
            return []
        default:
            return []
        }
    }

    private static func normalizeToolCall(_ payload: [String: Any]) -> [NormalizedAgentRuntimeEvent] {
        let toolCallID = ACPRuntimeEventParsing.firstString(in: payload, keys: ["toolCallId"]) ?? UUID().uuidString
        let toolName = ACPRuntimeEventParsing.normalizedToolName(from: payload)
        let argsJSON = ACPRuntimeEventParsing.serializeJSON(payload["rawInput"])
        return [
            .stream(
                AIStreamResult(
                    type: "tool_call",
                    text: nil,
                    toolName: toolName,
                    toolArgs: argsJSON,
                    toolInvocationID: ACPRuntimeEventParsing.stableInvocationUUID(rawValue: toolCallID),
                    toolArgsJSON: argsJSON
                )
            )
        ]
    }

    private static func normalizeToolCallUpdate(_ payload: [String: Any]) -> [NormalizedAgentRuntimeEvent] {
        let toolCallID = ACPRuntimeEventParsing.firstString(in: payload, keys: ["toolCallId"]) ?? UUID().uuidString
        let toolName = ACPRuntimeEventParsing.normalizedToolName(from: payload)
        let invocationID = ACPRuntimeEventParsing.stableInvocationUUID(rawValue: toolCallID)
        let status = ACPRuntimeEventParsing.firstString(in: payload, keys: ["status"])?.lowercased()
        let argsJSON = ACPRuntimeEventParsing.serializeJSON(payload["rawInput"])
        let outputJSON = ACPRuntimeEventParsing.serializeJSON(payload["rawOutput"])
            ?? ACPRuntimeEventParsing.serializeJSON(payload["content"])
            ?? ACPRuntimeEventParsing.extractContentText(from: payload["content"])
        let title = ACPRuntimeEventParsing.firstString(in: payload, keys: ["title"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let progressText = ACPRuntimeEventParsing.extractContentText(from: payload["content"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if status == "completed" || status == "failed" {
            return [
                .stream(
                    AIStreamResult(
                        type: "tool_result",
                        text: nil,
                        toolName: toolName,
                        toolArgs: argsJSON,
                        toolOutput: outputJSON,
                        toolInvocationID: invocationID,
                        toolResultJSON: outputJSON,
                        toolArgsJSON: argsJSON,
                        toolIsError: status == "failed"
                    )
                )
            ]
        }

        if let lifecycleStatus = durableLifecycleStatus(from: status) {
            let resultJSON = durableLifecycleResultJSON(
                status: lifecycleStatus,
                title: title,
                progressText: progressText,
                rawContent: payload["content"],
                rawInput: payload["rawInput"]
            )
            return [
                .stream(
                    AIStreamResult(
                        type: "tool_result",
                        text: nil,
                        toolName: toolName,
                        toolArgs: argsJSON,
                        toolOutput: resultJSON,
                        toolInvocationID: invocationID,
                        toolResultJSON: resultJSON,
                        toolArgsJSON: argsJSON,
                        toolIsError: false
                    )
                )
            ]
        }

        return []
    }

    private static func durableLifecycleStatus(from status: String?) -> String? {
        guard let status = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !status.isEmpty else { return nil }
        switch status {
        case "in_progress", "inprogress", "in-progress", "running":
            return "running"
        case "pending":
            return "pending"
        default:
            return nil
        }
    }

    private static func durableLifecycleResultJSON(
        status: String,
        title: String?,
        progressText: String?,
        rawContent: Any?,
        rawInput: Any?
    ) -> String {
        var payload: [String: Any] = ["status": status]
        if let title, !title.isEmpty {
            payload["title"] = title
        }
        if let progressText, !progressText.isEmpty {
            payload["progress"] = progressText
        }
        if let rawContent {
            payload["content"] = rawContent
        }
        if let rawInput {
            payload["rawInput"] = rawInput
        }
        return ACPRuntimeEventParsing.serializeJSON(payload) ?? "{\"status\":\"\(status)\"}"
    }

    private static func normalizeUsageUpdate(_ payload: [String: Any]) -> [NormalizedAgentRuntimeEvent] {
        let used = intValue(payload["used"])
        let size = intValue(payload["size"])
        let cost = costAmount(from: payload["cost"])
        guard used != nil || size != nil || cost != nil else { return [] }
        return [
            .stream(
                AIStreamResult(
                    type: "usage",
                    text: nil,
                    cost: cost,
                    modelContextWindow: size,
                    contextUsedTokens: used
                )
            )
        ]
    }

    private static func costAmount(from value: Any?) -> Double? {
        if let cost = value as? [String: Any] {
            return doubleValue(cost["amount"])
        }
        return doubleValue(value)
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let int64 as Int64:
            Int(int64)
        case let double as Double:
            Int(double)
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            double
        case let int as Int:
            Double(int)
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }
}

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
