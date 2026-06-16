import CryptoKit
import Foundation

enum AgentConversationReplayMode: String, Equatable {
    case equivalent
    case bounded
}

struct AgentConversationReplayBudget: Equatable {
    let maxOutputUTF8Bytes: Int
    let maxToolArgumentCharacters: Int

    init(maxOutputUTF8Bytes: Int, maxToolArgumentCharacters: Int) {
        self.maxOutputUTF8Bytes = max(0, maxOutputUTF8Bytes)
        self.maxToolArgumentCharacters = max(0, maxToolArgumentCharacters)
    }
}

enum AgentConversationReplayPolicy: Equatable {
    case equivalent
    case bounded(AgentConversationReplayBudget)
}

enum AgentConversationReplayCategory: String, CaseIterable, Hashable {
    case user
    case assistant
    case toolCall
    case toolResult
    case system
    case error
}

struct AgentConversationReplayCategoryMetrics: Equatable {
    var examinedCount: Int = 0
    var emittedCount: Int = 0
    var omittedCount: Int = 0
    var unboundedUTF8Bytes: Int = 0
    var emittedUTF8Bytes: Int = 0
}

struct AgentConversationReplayMetrics: Equatable {
    let mode: AgentConversationReplayMode
    let turnCount: Int
    let examinedRowCount: Int
    let unboundedOutputUTF8Bytes: Int
    let outputUTF8Bytes: Int
    let userAuthoredUTF8Bytes: Int
    let originalToolArgumentCharacters: Int
    let emittedToolArgumentCharacters: Int
    let truncatedToolCallCount: Int
    let omittedRowCount: Int
    let essentialOverflowUTF8Bytes: Int
    let finalOverBudgetUTF8Bytes: Int
    let categories: [AgentConversationReplayCategory: AgentConversationReplayCategoryMetrics]
}

struct AgentConversationReplaySerialization: Equatable {
    let text: String
    let metrics: AgentConversationReplayMetrics
}

#if DEBUG
    struct AgentTranscriptProtectedTailScanMetrics: Equatable {
        let transcriptTurnCount: Int
        let limit: Int
        let turnsVisited: Int
        let spansInspected: Int
        let activitiesInspected: Int
        let alreadyOrderedSpanCount: Int
        let sortedSpanCount: Int
        let summarizedToolSignalUseCount: Int
        let summarizedToolSignalCount: Int
        let countedToolExecutionCount: Int
        let protectedTurnCount: Int
        let durationMS: Double
    }

    struct AgentTranscriptCompactionMetrics: Equatable {
        let mode: AgentTranscriptCompactionMode
        let initialWorkingUnitCount: Int
        let finalWorkingUnitCount: Int
        let softGuardSkippedScan: Bool
        let downshiftIterationCount: Int
        /// Number of archive loop passes. A pass may archive more than one summary turn.
        let archiveIterationCount: Int
        let archivedTurnCount: Int
        let protectedToolTailTurnCount: Int
        let durationMS: Double
    }

    struct AgentTranscriptWorkingSourceItemsMetrics: Equatable {
        let transcriptTurnCount: Int
        let fullTurnCount: Int
        let itemCount: Int
        let durationMS: Double
    }

    struct AgentTranscriptRebuildMetrics: Equatable {
        let existingTurnCount: Int
        let workingItemsCount: Int
        let existingWorkingItemCount: Int
        let appendedRowDelta: Int
        let usedIncrementalFinalTurnUpdate: Bool
        let reusableFrozenPrefixTurnCount: Int?
        let requestedCompactionMode: AgentTranscriptCompactionMode
        let tierWorseningCount: Int
        let legacyNonFullTierWorseningCount: Int
        let rebuiltTurnCount: Int
        let durationMS: Double
    }

    struct AgentTranscriptProjectionBuildMetrics: Equatable {
        let turnCount: Int
        let reusedPrefixTurnCount: Int
        let cacheHitCount: Int
        let workingBlockCount: Int
        let archivedBlockCount: Int
        let workingRowCount: Int
        let archivedRowCount: Int
        let workingUnitCount: Int
        let durationMS: Double
    }

    struct AgentTranscriptRefreshAttemptMetrics: Equatable {
        let reason: String
        let sourceItemsRevision: Int
        let itemCount: Int
        let nextSequenceIndex: Int
        let runState: String
        let selectedAgent: String
        let projectionProtection: String
        let pendingMutationSummary: String
        let incrementalPath: String
        let inputSignature: String
        let previousInputSignature: String?
        let isConsecutiveDuplicateInput: Bool
    }

    struct AgentTranscriptPresentationPublishMetrics: Equatable {
        let visibleRowCount: Int
        let workingRowCount: Int
        let visibleBlockCount: Int
        let workingBlockCount: Int
        let contentChanged: Bool
        let performanceChanged: Bool
        let forceRevision: Bool
        let willAssignSnapshot: Bool
        let willIncrementRevision: Bool
        let semanticDigest: String
        let previousSemanticDigest: String
        let identityDigest: String
        let previousIdentityDigest: String
        let rowSemanticDigest: String
        let previousRowSemanticDigest: String
        let rowIdentityDigest: String
        let previousRowIdentityDigest: String
        let blockSemanticDigest: String
        let previousBlockSemanticDigest: String
        let blockIdentityDigest: String
        let previousBlockIdentityDigest: String
        let semanticNoOpPublishOpportunity: Bool
        let rowIdentityDrift: Bool
        let blockIdentityDrift: Bool
    }

    struct AgentTranscriptSessionItemsReplacementMetrics: Equatable {
        let reason: String
        let previousItemCount: Int
        let newItemCount: Int
        let isEqual: Bool
        let previousSignature: String
        let newSignature: String
    }

    struct AgentTranscriptProjectionIdentityMetrics: Equatable {
        let previousRowCount: Int
        let newRowCount: Int
        let previousBlockCount: Int
        let newBlockCount: Int
        let rowSemanticDigest: String
        let previousRowSemanticDigest: String
        let rowIdentityDigest: String
        let previousRowIdentityDigest: String
        let blockSemanticDigest: String
        let previousBlockSemanticDigest: String
        let blockIdentityDigest: String
        let previousBlockIdentityDigest: String
        let rowIdentityDrift: Bool
        let blockIdentityDrift: Bool
    }

    enum AgentTranscriptDebugInstrumentation {
        nonisolated(unsafe) static var isEnabled = false
        nonisolated(unsafe) static var protectedTailScanHandler: ((AgentTranscriptProtectedTailScanMetrics) -> Void)?
        nonisolated(unsafe) static var compactionHandler: ((AgentTranscriptCompactionMetrics) -> Void)?
        nonisolated(unsafe) static var workingSourceItemsHandler: ((AgentTranscriptWorkingSourceItemsMetrics) -> Void)?
        nonisolated(unsafe) static var rebuildHandler: ((AgentTranscriptRebuildMetrics) -> Void)?
        nonisolated(unsafe) static var projectionBuildHandler: ((AgentTranscriptProjectionBuildMetrics) -> Void)?
        nonisolated(unsafe) static var refreshAttemptHandler: ((AgentTranscriptRefreshAttemptMetrics) -> Void)?
        nonisolated(unsafe) static var presentationPublishHandler: ((AgentTranscriptPresentationPublishMetrics) -> Void)?
        nonisolated(unsafe) static var sessionItemsReplacementHandler: ((AgentTranscriptSessionItemsReplacementMetrics) -> Void)?
        nonisolated(unsafe) static var projectionIdentityHandler: ((AgentTranscriptProjectionIdentityMetrics) -> Void)?
        private static let refreshSignatureLock = NSLock()
        private nonisolated(unsafe) static var lastRefreshInputSignatureByTabID: [UUID: String] = [:]

        static func reset() {
            isEnabled = false
            protectedTailScanHandler = nil
            compactionHandler = nil
            workingSourceItemsHandler = nil
            rebuildHandler = nil
            projectionBuildHandler = nil
            refreshAttemptHandler = nil
            presentationPublishHandler = nil
            sessionItemsReplacementHandler = nil
            projectionIdentityHandler = nil
            refreshSignatureLock.lock()
            lastRefreshInputSignatureByTabID = [:]
            refreshSignatureLock.unlock()
        }

        static func durationMS(since start: TimeInterval) -> Double {
            max(0, (Date.timeIntervalSinceReferenceDate - start) * 1000)
        }

        static func emitRefreshAttempt(
            tabID: UUID,
            reason: String,
            sourceItemsRevision: Int,
            itemCount: Int,
            nextSequenceIndex: Int,
            runState: String,
            selectedAgent: String,
            projectionProtection: String,
            pendingMutationSummary: String,
            incrementalPath: String,
            inputSignature: String
        ) {
            guard isEnabled else { return }
            refreshSignatureLock.lock()
            let previous = lastRefreshInputSignatureByTabID[tabID]
            lastRefreshInputSignatureByTabID[tabID] = inputSignature
            refreshSignatureLock.unlock()
            refreshAttemptHandler?(.init(
                reason: reason,
                sourceItemsRevision: sourceItemsRevision,
                itemCount: itemCount,
                nextSequenceIndex: nextSequenceIndex,
                runState: runState,
                selectedAgent: selectedAgent,
                projectionProtection: projectionProtection,
                pendingMutationSummary: pendingMutationSummary,
                incrementalPath: incrementalPath,
                inputSignature: inputSignature,
                previousInputSignature: previous,
                isConsecutiveDuplicateInput: previous == inputSignature
            ))
        }

        static func stableDigest(_ values: [String]) -> String {
            var hasher = SHA256()
            for value in values {
                hasher.update(data: Data(value.utf8))
                hasher.update(data: Data([0]))
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        static func hashedText(_ value: String?) -> String {
            guard let value else { return "nil" }
            return stableDigest(["text", String(value.count), value])
        }

        static func itemIdentitySignature(_ items: [AgentChatItem]) -> String {
            stableDigest(items.map(itemIdentityComponent))
        }

        static func itemSemanticSignature(_ items: [AgentChatItem]) -> String {
            stableDigest(items.map(itemSemanticComponent))
        }

        static func blockIdentitySignature(_ blocks: [AgentTranscriptRenderBlock]) -> String {
            stableDigest(blocks.map(blockIdentityComponent))
        }

        static func blockSemanticSignature(_ blocks: [AgentTranscriptRenderBlock]) -> String {
            stableDigest(blocks.map(blockSemanticComponent))
        }

        private static func itemIdentityComponent(_ item: AgentChatItem) -> String {
            [
                "id=\(item.id.uuidString)",
                itemSemanticComponent(item)
            ].joined(separator: "|")
        }

        private static func itemSemanticComponent(_ item: AgentChatItem) -> String {
            [
                "seq=\(item.sequenceIndex)",
                "kind=\(item.kind.rawValue)",
                "stream=\(item.isStreaming)",
                "tool=\(item.toolName ?? "nil")",
                "invocation=\(item.toolInvocationID?.uuidString ?? "nil")",
                "isError=\(item.toolIsError.map(String.init) ?? "nil")",
                "textHash=\(hashedText(item.text))",
                "argsHash=\(hashedText(item.toolArgsJSON))",
                "resultHash=\(hashedText(item.toolResultJSON))",
                "reasoningHash=\(hashedText(item.reasoning))",
                "attachments=\(item.attachments.count)",
                "tagged=\(item.taggedFileAttachments.count)",
                "workflow=\(item.workflow?.id ?? "nil")"
            ].joined(separator: "|")
        }

        private static func blockIdentityComponent(_ block: AgentTranscriptRenderBlock) -> String {
            [
                "id=\(block.id)",
                blockSemanticComponent(block)
            ].joined(separator: "|")
        }

        private static func blockSemanticComponent(_ block: AgentTranscriptRenderBlock) -> String {
            [
                "kind=\(block.kind.rawValue)",
                "turn=\(block.turnID.uuidString)",
                "span=\(block.spanID?.uuidString ?? "nil")",
                "tier=\(block.retentionTier.rawValue)",
                "archived=\(block.isArchived)",
                "primaryAnchor=\(block.primaryAnchor.map { String(describing: $0) } ?? "nil")",
                "anchorActivity=\(block.anchorActivityID?.uuidString ?? "nil")",
                "activityIDs=\(block.activityIDs.map(\.uuidString).joined(separator: ","))",
                "presentation=\(block.defaultPresentation.rawValue)",
                "rowSemantic=\(itemSemanticSignature(block.rows))",
                "cluster=\(block.clusterSummary == nil ? "nil" : "present")",
                "grouped=\(block.groupedHistory.map(groupedHistorySemanticComponent) ?? "nil")"
            ].joined(separator: "|")
        }

        private static func groupedHistorySemanticComponent(_ groupedHistory: AgentTranscriptGroupedHistory) -> String {
            [
                "summary=\(String(describing: groupedHistory.summary))",
                "sections=\(groupedHistory.sections.map(groupedSectionSemanticComponent).joined(separator: ";"))"
            ].joined(separator: "|")
        }

        private static func groupedSectionSemanticComponent(_ section: AgentTranscriptGroupedSection) -> String {
            [
                "kind=\(section.kind.rawValue)",
                "titleHash=\(hashedText(section.title))",
                "icon=\(section.icon ?? "nil")",
                "children=\(blockSemanticSignature(section.childBlocks))",
                "cluster=\(section.clusterSummary == nil ? "nil" : "present")"
            ].joined(separator: "|")
        }
    }
#endif

enum ToolRawJSON {
    private static let explicitEnvelopeKeys = [
        "Ok",
        "ok",
        "Err",
        "err",
        "structuredContent",
        "structured_content",
        "structuredResult",
        "structured_result",
        "toolResult",
        "tool_result"
    ]

    private static let explicitContentEnvelopeKeys = [
        "json",
        "structuredContent",
        "structured_content"
    ]

    static func object(from raw: String?) -> [String: Any]? {
        guard let data = ToolJSON.data(from: raw),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        if let unwrapped = explicitlyUnwrappedObject(from: json) {
            return unwrapped
        }
        return json as? [String: Any]
    }

    private static func explicitlyUnwrappedObject(from value: Any, depth: Int = 0) -> [String: Any]? {
        guard depth < 4 else { return nil }
        if let object = value as? [String: Any] {
            for key in explicitEnvelopeKeys {
                guard let nested = object[key] else { continue }
                if let unwrapped = explicitlyUnwrappedObject(from: nested, depth: depth + 1) {
                    return unwrapped
                }
                if let nestedObject = nested as? [String: Any] {
                    return nestedObject
                }
            }
            if let content = object["content"] as? [Any] {
                for element in content {
                    guard let block = element as? [String: Any] else { continue }
                    for key in explicitContentEnvelopeKeys {
                        guard let nested = block[key] else { continue }
                        if let unwrapped = explicitlyUnwrappedObject(from: nested, depth: depth + 1) {
                            return unwrapped
                        }
                        if let nestedObject = nested as? [String: Any] {
                            return nestedObject
                        }
                    }
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let unwrapped = explicitlyUnwrappedObject(from: element, depth: depth + 1) {
                    return unwrapped
                }
            }
        }
        return nil
    }

    static func string(_ object: [String: Any], key: String) -> String? {
        if let value = object[key] as? String { return value }
        if let number = object[key] as? NSNumber { return number.stringValue }
        return nil
    }

    static func bool(_ object: [String: Any], key: String) -> Bool? {
        if let value = object[key] as? Bool { return value }
        if let number = object[key] as? NSNumber { return number.boolValue }
        return nil
    }

    static func int(_ object: [String: Any], key: String) -> Int? {
        if let value = object[key] as? Int { return value }
        if let number = object[key] as? NSNumber { return number.intValue }
        if let string = object[key] as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}

enum AgentTranscriptToolStatusSemantics {
    private static let runningStatusWords: Set<String> = ["running", "in_progress", "inprogress", "in-progress", "pending"]
    private static let terminalStatusWords: Set<String> = [
        "completed", "complete", "success", "succeeded", "ok", "failed", "failure", "error",
        "cancelled", "canceled", "terminated", "stopped", "done", "exited", "finished",
        "timeout", "timed_out", "killed", "interrupted"
    ]

    static func normalizedStatusWord(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else {
            return nil
        }
        switch raw {
        case "ok", "success", "succeeded", "complete", "completed", "done", "exited", "finished":
            return "success"
        case "partial", "warning", "warn", "limited":
            return "warning"
        case "error", "failed", "failure", "rejected", "denied", "timeout", "timed_out", "killed":
            return "failed"
        case "cancelled", "canceled", "terminated", "stopped", "interrupted":
            return "cancelled"
        case "pending":
            return "pending"
        case "running", "in_progress", "inprogress", "in-progress":
            return "running"
        default:
            return raw
        }
    }

    static func transcriptStatus(fromNormalizedStatusWord word: String?) -> AgentTranscriptToolStatus {
        switch word {
        case "pending":
            .pending
        case "running":
            .running
        case "success":
            .success
        case "warning":
            .warning
        case "failed":
            .failed
        case "cancelled":
            .cancelled
        default:
            .unknown
        }
    }

    static func persistedStatusWord(from status: AgentTranscriptToolStatus) -> String {
        switch status {
        case .pending:
            "pending"
        case .running:
            "running"
        case .success:
            "success"
        case .warning:
            "warning"
        case .failed:
            "failed"
        case .cancelled:
            "cancelled"
        case .unknown:
            "unknown"
        }
    }

    static func isRunningStatusWord(_ raw: String?) -> Bool {
        guard let normalized = normalizedStatusWord(raw) else { return false }
        return runningStatusWords.contains(normalized)
    }

    static func isTerminalStatusWord(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return false
        }
        return terminalStatusWords.contains(raw) || terminalStatusWords.contains(normalizedStatusWord(raw) ?? "")
    }

    static func normalizedCommandExecutionStatusOverride(from object: [String: Any]?) -> String? {
        guard let object else { return nil }
        let typeWord = ToolRawJSON.string(object, key: "type")?.lowercased() ?? ""
        let processID = ToolRawJSON.string(object, key: "processId")
            ?? ToolRawJSON.string(object, key: "process_id")
        let hasCommandHints = typeWord.contains("command")
            || processID != nil
            || ToolRawJSON.string(object, key: "command") != nil
            || ToolRawJSON.string(object, key: "cmd") != nil
        guard hasCommandHints else { return nil }

        let hasCompletionTimingHint = BashToolResultParser.hasCommandCompletionTimingHint(object)
        let exitCode = ToolRawJSON.int(object, key: "exitCode")
            ?? ToolRawJSON.int(object, key: "exit_code")
            ?? ToolRawJSON.int(object, key: "code")
        let statusWord = normalizedStatusWord(ToolRawJSON.string(object, key: "status"))

        if statusWord == "running" {
            return "running"
        }
        if let statusWord, isTerminalStatusWord(statusWord), hasCompletionTimingHint {
            return statusWord
        }
        if let exitCode, exitCode < 0, processID?.isEmpty == false {
            if hasCompletionTimingHint {
                if let statusWord, isTerminalStatusWord(statusWord) {
                    return statusWord
                }
                return "failed"
            }
            return "running"
        }
        if statusWord == nil, exitCode == nil, processID?.isEmpty == false {
            return "running"
        }
        if let statusWord, isTerminalStatusWord(statusWord) {
            return statusWord
        }
        return nil
    }

    static func normalizedBashStatusWord(
        metadata: BashToolResultParser.Metadata,
        rawObject: [String: Any]?
    ) -> String? {
        if metadata.isRunning {
            return "running"
        }
        if let statusWord = normalizedStatusWord(metadata.statusWord) {
            return statusWord
        }
        if let override = normalizedCommandExecutionStatusOverride(from: rawObject) {
            return override
        }
        return nil
    }
}

enum BashToolResultParser {
    struct Metadata: Equatable {
        let isRunning: Bool
        let statusWord: String?
        let exitCode: Int?
        let processID: String?
        let isSummaryOnly: Bool
    }

    struct ParsedResult: Equatable {
        let isRunning: Bool
        let command: String?
        let statusWord: String?
        let exitCode: Int?
        let output: String?
        let processID: String?
        let isSummaryOnly: Bool
    }

    private struct Analysis {
        let object: [String: Any]?
        let metadata: Metadata
        let rawFallbackOutput: String?
    }

    private struct ParsedCacheKey: Hashable {
        let raw: String
        let argsJSON: String
    }

    private enum CacheEntry<Value> {
        case value(Value)
        case missing
    }

    private final class Cache {
        private let lock = NSLock()
        private var metadataByRaw: [String: CacheEntry<Metadata>] = [:]
        private var parsedByKey: [ParsedCacheKey: CacheEntry<ParsedResult>] = [:]

        func metadata(raw: String, compute: () -> Metadata) -> Metadata {
            lock.lock()
            if let cached = metadataByRaw[raw] {
                lock.unlock()
                switch cached {
                case let .value(value):
                    return value
                case .missing:
                    return compute()
                }
            }
            lock.unlock()

            let value = compute()

            lock.lock()
            if metadataByRaw.count > 255 {
                metadataByRaw.removeAll(keepingCapacity: true)
            }
            metadataByRaw[raw] = .value(value)
            lock.unlock()
            return value
        }

        func parsed(raw: String, argsJSON: String, compute: () -> ParsedResult) -> ParsedResult {
            let key = ParsedCacheKey(raw: raw, argsJSON: argsJSON)
            lock.lock()
            if let cached = parsedByKey[key] {
                lock.unlock()
                switch cached {
                case let .value(value):
                    return value
                case .missing:
                    return compute()
                }
            }
            lock.unlock()

            let value = compute()

            lock.lock()
            if parsedByKey.count > 255 {
                parsedByKey.removeAll(keepingCapacity: true)
            }
            parsedByKey[key] = .value(value)
            lock.unlock()
            return value
        }
    }

    private static let cache = Cache()
    private static let commandKeys: [String] = [
        "command", "cmd", "input", "text", "value", "argv", "args",
        "commandLine", "command_line", "cmdline", "cmd_line", "parsedCommand", "parsed_command",
        "parsedCmd", "parsed_cmd"
    ]
    private static let shellCommandWrapperRegex = try! NSRegularExpression(
        pattern: #"^(?:\/\S+\/)?(?:bash|zsh|sh|fish)(?:\.exe)?\s+-lc\s+(?:(['"])([\s\S]+)\1|([\s\S]+))$"#
    )
    private static let leadingDirectoryCommandRegex = try! NSRegularExpression(
        pattern: #"^\s*cd\s+[^&;]+(?:\s*&&\s*|\s*;\s*)([\s\S]+)$"#,
        options: [.caseInsensitive]
    )
    private static let plainTextRunningSessionIDRegex = try! NSRegularExpression(
        pattern: #"process\s+running\s+with\s+session\s+id\s+([0-9]+)"#,
        options: [.caseInsensitive]
    )
    private static let plainTextExitCodeRegex = try! NSRegularExpression(
        pattern: #"process\s+completed\s+with\s+exit\s+code\s+(-?[0-9]+)"#,
        options: [.caseInsensitive]
    )
    private static let jsonStatusRegex = try! NSRegularExpression(
        pattern: #"[\"']status[\"']\s*:\s*[\"']([^\"']+)[\"']"#,
        options: [.caseInsensitive]
    )
    private static let jsonProcessIDRegex = try! NSRegularExpression(
        pattern: #"[\"']process_?id[\"']\s*:\s*[\"']?([^\"',}\s]+)"#,
        options: [.caseInsensitive]
    )
    private static let jsonExitCodeRegex = try! NSRegularExpression(
        pattern: #"[\"'](?:exitCode|exit_code|code)[\"']\s*:\s*(-?[0-9]+)"#,
        options: [.caseInsensitive]
    )
    private static let jsonDurationRegex = try! NSRegularExpression(
        pattern: #"[\"'](?:durationMs|duration_ms|duration)[\"']\s*:"#,
        options: [.caseInsensitive]
    )
    private static let jsonSuccessFlagRegex = try! NSRegularExpression(
        pattern: #"[\"'](?:success|ok)[\"']\s*:\s*true"#,
        options: [.caseInsensitive]
    )
    private static let jsonErrorTextRegex = try! NSRegularExpression(
        pattern: #"[\"']error[\"']\s*:\s*[\"'][^\"']+[\"']"#,
        options: [.caseInsensitive]
    )
    private static let livenessScanCharacterLimit = 32768

    static func parseMetadata(raw: String?) -> Metadata {
        parseMetadata(raw: raw, context: nil)
    }

    static func parseMetadata(raw: String?, context: AgentToolResultProcessingContext?) -> Metadata {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return Metadata(isRunning: false, statusWord: nil, exitCode: nil, processID: nil, isSummaryOnly: false)
        }
        if let context {
            return context.bashMetadata(raw: trimmed) {
                cache.metadata(raw: trimmed) {
                    parseLivenessMetadata(raw: trimmed)
                }
            }
        }
        return cache.metadata(raw: trimmed) {
            parseLivenessMetadata(raw: trimmed)
        }
    }

    static func parseLivenessMetadata(raw: String?) -> Metadata {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return Metadata(isRunning: false, statusWord: nil, exitCode: nil, processID: nil, isSummaryOnly: false)
        }
        let scanText = livenessScanText(from: trimmed)
        let plainTextHint = plainTextCommandExecutionHint(raw: scanText)
        let capturedStatusWord = captureFirstGroup(in: scanText, regex: jsonStatusRegex, group: 1)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let statusWord = capturedStatusWord ?? plainTextHint.statusWord
        let capturedExitCode = captureFirstGroup(in: scanText, regex: jsonExitCodeRegex, group: 1).flatMap(Int.init)
        let exitCode = capturedExitCode ?? plainTextHint.exitCode
        let processID = captureFirstGroup(in: scanText, regex: jsonProcessIDRegex, group: 1) ?? plainTextHint.processID
        let scanRange = NSRange(scanText.startIndex ..< scanText.endIndex, in: scanText)
        let hasDurationHint = jsonDurationRegex.firstMatch(
            in: scanText,
            options: [],
            range: scanRange
        ) != nil
        let hasSuccessFlag = jsonSuccessFlagRegex.firstMatch(in: scanText, options: [], range: scanRange) != nil
        let hasErrorText = jsonErrorTextRegex.firstMatch(in: scanText, options: [], range: scanRange) != nil
        let isSummaryOnly = scanText.range(of: #""summary_only"\s*:\s*true"#, options: [.regularExpression, .caseInsensitive]) != nil
            || scanText.range(of: #""summaryOnly"\s*:\s*true"#, options: [.regularExpression, .caseInsensitive]) != nil
        let isRunning: Bool = {
            if plainTextHint.isRunning { return true }
            if AgentTranscriptToolStatusSemantics.isRunningStatusWord(statusWord) { return true }
            if hasSuccessFlag || hasErrorText { return false }
            if let exitCode, exitCode >= 0 { return false }
            if let statusWord, AgentTranscriptToolStatusSemantics.isTerminalStatusWord(statusWord) {
                if exitCode != nil, exitCode ?? 0 < 0, processID?.isEmpty == false, !hasDurationHint {
                    return true
                }
                return false
            }
            if exitCode != nil { return false }
            return processID?.isEmpty == false
        }()
        return Metadata(
            isRunning: isRunning,
            statusWord: statusWord,
            exitCode: exitCode,
            processID: processID,
            isSummaryOnly: isSummaryOnly
        )
    }

    private static func livenessScanText(from raw: String) -> String {
        let limit = livenessScanCharacterLimit
        guard raw.count > limit * 2 else { return raw }
        return String(raw.prefix(limit)) + "\n" + String(raw.suffix(limit))
    }

    static func parse(raw: String?, argsJSON: String?) -> ParsedResult {
        parse(raw: raw, argsJSON: argsJSON, context: nil)
    }

    static func parse(raw: String?, argsJSON: String?, context: AgentToolResultProcessingContext?) -> ParsedResult {
        let rawValue = raw ?? ""
        let normalizedRaw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArgs = argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedRaw.isEmpty {
            return ParsedResult(
                isRunning: false,
                command: command(from: trimmedArgs).map(cleanCommandText),
                statusWord: nil,
                exitCode: nil,
                output: nil,
                processID: nil,
                isSummaryOnly: false
            )
        }
        return cache.parsed(raw: rawValue, argsJSON: trimmedArgs) {
            let analysis = analyze(raw: rawValue)
            let metadata = analysis.metadata
            if let object = analysis.object {
                let commandText = command(from: object) ?? command(from: trimmedArgs)
                return ParsedResult(
                    isRunning: metadata.isRunning,
                    command: commandText.map(cleanCommandText),
                    statusWord: metadata.statusWord,
                    exitCode: metadata.exitCode,
                    output: outputText(from: object),
                    processID: metadata.processID,
                    isSummaryOnly: metadata.isSummaryOnly
                )
            }

            return ParsedResult(
                isRunning: metadata.isRunning,
                command: command(from: trimmedArgs).map(cleanCommandText),
                statusWord: metadata.statusWord,
                exitCode: metadata.exitCode,
                output: analysis.rawFallbackOutput,
                processID: metadata.processID,
                isSummaryOnly: metadata.isSummaryOnly
            )
        }
    }

    static func command(from rawJSON: String?) -> String? {
        guard let rawJSON else { return nil }
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [])
        {
            return command(fromAny: json)
        }
        return trimmed
    }

    static func resultJSON(
        statusWord: String,
        command: String?,
        processID: String?,
        output: String?,
        exitCode: Int?,
        summaryOnly: Bool = false
    ) -> String {
        var object: [String: Any] = [
            "type": "commandExecution",
            "status": statusWord
        ]
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object["command"] = command
        }
        if let processID, !processID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object["processId"] = processID
        }
        if let output, !output.isEmpty {
            object["aggregatedOutput"] = output
        }
        if let exitCode {
            object["exitCode"] = exitCode
        }
        if summaryOnly {
            object["summary_only"] = true
        }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: []),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return #"{\"type\":\"commandExecution\",\"status\":\"\#(statusWord)\"}"#
    }

    static func hasCommandCompletionTimingHint(_ object: [String: Any]) -> Bool {
        if ToolRawJSON.int(object, key: "durationMs") != nil
            || ToolRawJSON.int(object, key: "duration_ms") != nil
        {
            return true
        }
        if object["duration"] != nil {
            return true
        }
        return false
    }

    private static func analyze(raw: String) -> Analysis {
        if let object = ToolRawJSON.object(from: raw) {
            let statusWord = ToolRawJSON.string(object, key: "status")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let exitCode = commandExitCode(from: object)
            let hasNegativeExitCode = (exitCode != nil && (exitCode ?? 0) < 0)
            let hasTerminalExitCode = (exitCode != nil && (exitCode ?? 0) >= 0)
            let isCommandLike = isCommandType(object) || hasAnyCommandValue(object)
            let processID = commandProcessID(from: object)
            let hasCompletionTimingHint = hasCommandCompletionTimingHint(object)
            let hasSuccessFlag = ToolRawJSON.bool(object, key: "success") == true
                || ToolRawJSON.bool(object, key: "ok") == true
            let hasErrorText = ToolRawJSON.string(object, key: "error")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false

            let isRunning = if AgentTranscriptToolStatusSemantics.isRunningStatusWord(statusWord) {
                true
            } else if hasTerminalExitCode {
                false
            } else if hasSuccessFlag || hasErrorText {
                false
            } else if AgentTranscriptToolStatusSemantics.isTerminalStatusWord(statusWord) {
                if hasNegativeExitCode,
                   isCommandLike,
                   processID != nil,
                   !hasCompletionTimingHint
                {
                    true
                } else {
                    false
                }
            } else if isCommandLike, processID != nil {
                true
            } else if isCommandLike {
                false
            } else {
                false
            }

            let isSummaryOnly = ToolRawJSON.bool(object, key: "summary_only") == true
                || ToolRawJSON.bool(object, key: "summaryOnly") == true
            return Analysis(
                object: object,
                metadata: Metadata(
                    isRunning: isRunning,
                    statusWord: statusWord,
                    exitCode: exitCode,
                    processID: processID,
                    isSummaryOnly: isSummaryOnly
                ),
                rawFallbackOutput: nil
            )
        }

        let outputFallback = raw.isEmpty ? nil : raw
        let plainTextHint = plainTextCommandExecutionHint(raw: raw)

        return Analysis(
            object: nil,
            metadata: Metadata(
                isRunning: plainTextHint.isRunning,
                statusWord: plainTextHint.statusWord,
                exitCode: plainTextHint.exitCode,
                processID: plainTextHint.processID,
                isSummaryOnly: false
            ),
            rawFallbackOutput: outputFallback
        )
    }

    private static func isCommandType(_ object: [String: Any]) -> Bool {
        let type = ToolRawJSON.string(object, key: "type")?.lowercased() ?? ""
        return type.contains("command")
    }

    private static func hasAnyCommandValue(_ object: [String: Any]) -> Bool {
        for key in commandKeys {
            if let value = stringValue(object, key: key),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return true
            }
        }
        return false
    }

    private static func commandExitCode(from object: [String: Any]) -> Int? {
        ToolRawJSON.int(object, key: "exitCode")
            ?? ToolRawJSON.int(object, key: "exit_code")
            ?? ToolRawJSON.int(object, key: "code")
    }

    private static func commandProcessID(from object: [String: Any]) -> String? {
        stringValue(object, key: "processId")
            ?? stringValue(object, key: "process_id")
    }

    private static func command(from object: [String: Any]) -> String? {
        for key in commandKeys {
            if let command = stringValue(object, key: key),
               !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return command
            }
        }
        if let invocation = object["invocation"] as? [String: Any],
           let nested = command(from: invocation)
        {
            return nested
        }
        if let arguments = object["arguments"],
           let nested = command(fromAny: arguments)
        {
            return nested
        }
        if let payload = object["payload"] as? [String: Any],
           let nested = command(from: payload)
        {
            return nested
        }
        return nil
    }

    private static func command(fromAny value: Any) -> String? {
        if let object = value as? [String: Any] {
            return command(from: object)
        }
        if let array = value as? [Any] {
            let parts = array
                .compactMap { element -> String? in
                    if let string = element as? String { return string }
                    if let number = element as? NSNumber { return number.stringValue }
                    return nil
                }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("\""),
               let data = trimmed.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: data, options: []),
               let nestedCommand = command(fromAny: nested)
            {
                return nestedCommand
            }
            if let unquoted = unquotedCommandText(trimmed) {
                return unquoted
            }
            return trimmed
        }
        if let number = value as? NSNumber {
            let text = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func outputText(from object: [String: Any]) -> String? {
        for key in [
            "delta",
            "outputDelta",
            "output_delta",
            "aggregatedOutput",
            "aggregated_output",
            "formattedOutput",
            "formatted_output",
            "recentOutput",
            "recent_output",
            "combinedOutput",
            "combined_output",
            "output",
            "stdout",
            "stderr",
            "text",
            "message",
            "content",
            "result",
            "log",
            "logs"
        ] {
            if let value = stringValue(object, key: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return value }
            }
        }
        return nil
    }

    private static func stringValue(_ object: [String: Any], key: String) -> String? {
        if let value = object[key] as? String { return value }
        if let number = object[key] as? NSNumber { return number.stringValue }
        if let array = object[key] as? [Any] {
            let parts = array
                .compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        return nil
    }

    private static func cleanCommandText(_ raw: String) -> String {
        var command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return command }

        if let unwrapped = captureFirstGroup(in: command, regex: shellCommandWrapperRegex, group: 2)
            ?? captureFirstGroup(in: command, regex: shellCommandWrapperRegex, group: 3)
        {
            command = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let stripped = captureFirstGroup(
            in: command,
            regex: leadingDirectoryCommandRegex,
            group: 1
        ) {
            command = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return command
    }

    private static func unquotedCommandText(_ raw: String) -> String? {
        guard raw.count >= 2 else { return nil }
        guard let first = raw.first, let last = raw.last, first == last, first == "\"" || first == "'" else {
            return nil
        }
        let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    private static func plainTextCommandExecutionHint(
        raw: String?
    ) -> (isRunning: Bool, statusWord: String?, exitCode: Int?, processID: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return (false, nil, nil, nil)
        }
        let lowered = raw.lowercased()

        if let sessionID = captureFirstGroup(
            in: raw,
            regex: plainTextRunningSessionIDRegex,
            group: 1
        ) {
            return (true, "running", nil, "session:\(sessionID)")
        }
        if lowered.contains("process running with session id")
            || lowered.contains(#""status":"running""#)
            || lowered.contains(#""status": "running""#)
        {
            return (true, "running", nil, nil)
        }
        if let exitCodeText = captureFirstGroup(
            in: raw,
            regex: plainTextExitCodeRegex,
            group: 1
        ),
            let exitCode = Int(exitCodeText)
        {
            return (false, exitCode == 0 ? "completed" : "failed", exitCode, nil)
        }
        if lowered.contains("stdin is closed for this session") {
            return (false, "failed", nil, nil)
        }
        return (false, nil, nil, nil)
    }

    private static func captureFirstGroup(
        in text: String,
        regex: NSRegularExpression,
        group: Int
    ) -> String? {
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard match.numberOfRanges > group else { return nil }
        let groupRange = match.range(at: group)
        guard groupRange.location != NSNotFound,
              let swiftRange = Range(groupRange, in: text)
        else { return nil }
        let captured = String(text[swiftRange])
        return captured.isEmpty ? nil : captured
    }
}

final class AgentToolResultProcessingContext: @unchecked Sendable {
    static let maxCachedJSONEntryCount = 128
    static let maxCachedJSONBytes = 16384

    enum JSONCacheValue {
        case parsed([String: Any])
        case missing
    }

    enum ToolExecutionLookup {
        case hit(AgentTranscriptToolExecution?)
        case miss
    }

    private let lock = NSLock()
    private var jsonObjectByRaw: [String: JSONCacheValue] = [:]
    private var toolExecutionByItemID: [UUID: AgentTranscriptToolExecution] = [:]
    private var missingToolExecutionItemIDs: Set<UUID> = []
    private var bashMetadataByRaw: [String: BashToolResultParser.Metadata] = [:]
    #if DEBUG || EDIT_FLOW_PERF
        private var metrics: AgentToolResultProcessingMetrics = .zero
    #endif

    func jsonObject(from raw: String?) -> [String: Any]? {
        guard let normalizedRaw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedRaw.isEmpty
        else {
            return nil
        }
        let byteCount = normalizedRaw.utf8.count
        lock.lock()
        #if DEBUG || EDIT_FLOW_PERF
            metrics.jsonParseAttemptCount += 1
            metrics.jsonParseByteCount += byteCount
        #endif
        if let cached = jsonObjectByRaw[normalizedRaw] {
            #if DEBUG || EDIT_FLOW_PERF
                metrics.jsonParseCacheHitCount += 1
            #endif
            lock.unlock()
            switch cached {
            case let .parsed(object):
                return object
            case .missing:
                return nil
            }
        }
        #if DEBUG || EDIT_FLOW_PERF
            metrics.jsonParseCacheMissCount += 1
        #endif
        let shouldCache = byteCount <= Self.maxCachedJSONBytes
            && jsonObjectByRaw.count < Self.maxCachedJSONEntryCount
        lock.unlock()

        guard let data = normalizedRaw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            lock.lock()
            #if DEBUG || EDIT_FLOW_PERF
                metrics.jsonParseFailureCount += 1
            #endif
            if shouldCache {
                jsonObjectByRaw[normalizedRaw] = .missing
            }
            lock.unlock()
            return nil
        }

        lock.lock()
        #if DEBUG || EDIT_FLOW_PERF
            metrics.jsonParseSuccessCount += 1
        #endif
        if shouldCache {
            jsonObjectByRaw[normalizedRaw] = .parsed(json)
        }
        lock.unlock()
        return json
    }

    func lookupToolExecution(for itemID: UUID) -> ToolExecutionLookup {
        lock.lock()
        if let cached = toolExecutionByItemID[itemID] {
            #if DEBUG || EDIT_FLOW_PERF
                metrics.toolExecutionCacheHitCount += 1
            #endif
            lock.unlock()
            return .hit(cached)
        }
        if missingToolExecutionItemIDs.contains(itemID) {
            #if DEBUG || EDIT_FLOW_PERF
                metrics.toolExecutionCacheHitCount += 1
            #endif
            lock.unlock()
            return .hit(nil)
        }
        #if DEBUG || EDIT_FLOW_PERF
            metrics.toolExecutionCacheMissCount += 1
        #endif
        lock.unlock()
        return .miss
    }

    func storeToolExecution(_ execution: AgentTranscriptToolExecution, for itemID: UUID) {
        lock.lock()
        toolExecutionByItemID[itemID] = execution
        missingToolExecutionItemIDs.remove(itemID)
        lock.unlock()
    }

    func markMissingToolExecution(for itemID: UUID) {
        lock.lock()
        missingToolExecutionItemIDs.insert(itemID)
        toolExecutionByItemID.removeValue(forKey: itemID)
        lock.unlock()
    }

    func bashMetadata(raw: String?, compute: () -> BashToolResultParser.Metadata) -> BashToolResultParser.Metadata {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return compute() }
        lock.lock()
        if let cached = bashMetadataByRaw[trimmed] {
            #if DEBUG || EDIT_FLOW_PERF
                metrics.bashMetadataCacheHitCount += 1
            #endif
            lock.unlock()
            return cached
        }
        #if DEBUG || EDIT_FLOW_PERF
            metrics.bashMetadataCacheMissCount += 1
        #endif
        lock.unlock()

        let value = compute()
        lock.lock()
        if bashMetadataByRaw.count > 255 {
            bashMetadataByRaw.removeAll(keepingCapacity: true)
        }
        bashMetadataByRaw[trimmed] = value
        lock.unlock()
        return value
    }

    func recordRegexCapture() {
        #if DEBUG || EDIT_FLOW_PERF
            lock.lock()
            metrics.regexCaptureCallCount += 1
            lock.unlock()
        #endif
    }

    func snapshotMetrics() -> AgentToolResultProcessingMetrics {
        #if DEBUG || EDIT_FLOW_PERF
            lock.lock()
            let snapshot = metrics
            lock.unlock()
            return snapshot
        #else
            return .zero
        #endif
    }
}

private struct ClusterSummaryCacheKey: Hashable {
    let rowIDs: [UUID]
}

private final class AgentTranscriptProjectionBuildContext {
    let processingContext: AgentToolResultProcessingContext
    var clusterSummaryByRowIDs: [ClusterSummaryCacheKey: AgentTranscriptClusterSummary] = [:]

    init(processingContext: AgentToolResultProcessingContext = AgentToolResultProcessingContext()) {
        self.processingContext = processingContext
    }
}

private struct CollapsibleLeafDescriptor {
    let kind: AgentTranscriptRenderBlockKind
    let rowCount: Int
    let containsProgressNote: Bool

    init(
        kind: AgentTranscriptRenderBlockKind,
        rowCount: Int,
        containsProgressNote: Bool = false
    ) {
        self.kind = kind
        self.rowCount = rowCount
        self.containsProgressNote = containsProgressNote
    }
}

enum AgentTranscriptToolNormalizer {
    static func stableExecutionID(for item: AgentChatItem) -> String {
        if let invocationID = item.toolInvocationID {
            return invocationID.uuidString.lowercased()
        }
        let toolName = normalizedToolName(item.toolName) ?? ""
        let signature = [toolName, item.toolArgsJSON ?? item.toolResultJSON ?? "", String(item.sequenceIndex)].joined(separator: "|")
        let digest = SHA256.hash(data: Data(signature.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedToolName(_ raw: String?) -> String? {
        AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(raw)
    }

    static func toolExecution(for item: AgentChatItem) -> AgentTranscriptToolExecution? {
        toolExecution(for: item, context: nil)
    }

    static func toolExecution(
        for item: AgentChatItem,
        context: AgentToolResultProcessingContext?
    ) -> AgentTranscriptToolExecution? {
        if let context {
            switch context.lookupToolExecution(for: item.id) {
            case let .hit(execution):
                return execution
            case .miss:
                break
            }
        }
        guard item.kind == .toolCall || item.kind == .toolResult else {
            context?.markMissingToolExecution(for: item.id)
            return nil
        }
        let normalizedToolName = AgentTranscriptToolNormalizer.normalizedToolName(item.toolName) ?? ""
        let argsObject = jsonObject(from: item.toolArgsJSON, context: context)
        let resultObject = item.kind == .toolResult && normalizedToolName != "bash"
            ? jsonObject(from: item.toolResultJSON, context: context)
            : nil
        let status = status(for: item, resultObject: resultObject, context: context)
        let bashMetadata = normalizedToolName == "bash"
            ? BashToolResultParser.parseMetadata(raw: item.toolResultJSON, context: context)
            : nil
        let summaryOnly = bashMetadata?.isSummaryOnly ?? isSummaryOnly(resultObject: resultObject)
        let processID = bashMetadata?.processID ?? stringValue(resultObject, keys: ["processId", "process_id"])
        let exitCode = bashMetadata?.exitCode ?? intValue(resultObject, keys: ["exitCode", "exit_code", "code"])
        var keyPaths = extractKeyPaths(argsObject: argsObject, resultObject: resultObject)
        if let pathSignal = AgentTranscriptToolVisibilityPolicy.pathSignal(fromPathLikeToolName: item.toolName),
           !keyPaths.contains(pathSignal)
        {
            keyPaths.insert(pathSignal, at: 0)
        }
        let execution = AgentTranscriptToolExecution(
            stableExecutionID: stableExecutionID(for: item),
            toolName: normalizedToolName.isEmpty ? item.toolName : normalizedToolName,
            invocationID: item.toolInvocationID,
            argsJSON: item.toolArgsJSON,
            resultJSON: item.toolResultJSON,
            toolIsError: item.toolIsError,
            status: status,
            summaryOnly: summaryOnly,
            processID: processID,
            exitCode: exitCode,
            summaryText: summaryText(for: item, keyPaths: keyPaths, status: status),
            keyPaths: keyPaths
        )
        context?.storeToolExecution(execution, for: item.id)
        return execution
    }

    static func status(for item: AgentChatItem) -> AgentTranscriptToolStatus {
        status(for: item, context: nil)
    }

    static func status(
        for item: AgentChatItem,
        context: AgentToolResultProcessingContext?
    ) -> AgentTranscriptToolStatus {
        let normalizedToolName = normalizedToolName(item.toolName) ?? ""
        let resultObject = normalizedToolName == "bash"
            ? nil
            : jsonObject(from: item.toolResultJSON, context: context)
        return status(for: item, resultObject: resultObject, context: context)
    }

    private static func status(
        for item: AgentChatItem,
        resultObject: [String: Any]?,
        context: AgentToolResultProcessingContext? = nil
    ) -> AgentTranscriptToolStatus {
        guard item.kind == .toolCall || item.kind == .toolResult else { return .unknown }
        if item.kind == .toolCall {
            return .pending
        }
        let normalizedToolName = normalizedToolName(item.toolName) ?? ""
        if normalizedToolName == "agent_run" || normalizedToolName == "agent_explore" {
            if let status = transcriptStatusForAgentRunStatusWord(
                stringValue(resultObject, keys: ["status"])
            ) {
                return status
            }
            if let toolIsError = item.toolIsError {
                return toolIsError ? .failed : .success
            }
            if let isError = boolValue(resultObject, keys: ["is_error", "isError"]) {
                return isError ? .failed : .success
            }
            return .unknown
        }
        if normalizedToolName == "bash" {
            let metadata = BashToolResultParser.parseMetadata(raw: item.toolResultJSON, context: context)
            let statusWord = AgentTranscriptToolStatusSemantics.normalizedBashStatusWord(
                metadata: metadata,
                rawObject: resultObject
            )
            let status = AgentTranscriptToolStatusSemantics.transcriptStatus(fromNormalizedStatusWord: statusWord)
            if status != .unknown {
                return status
            }
            if let exitCode = metadata.exitCode {
                return exitCode == 0 ? .success : .failed
            }
        }
        if let object = resultObject {
            if let rawStatus = AgentTranscriptToolStatusSemantics.normalizedStatusWord(
                stringValue(object, keys: ["status", "result", "outcome", "state"])
            ) {
                let status = AgentTranscriptToolStatusSemantics.transcriptStatus(fromNormalizedStatusWord: rawStatus)
                if status != .unknown {
                    return status
                }
            }
            if let isError = boolValue(object, keys: ["is_error", "isError"]) {
                return isError ? .failed : .success
            }
            if let exitCode = intValue(object, keys: ["exitCode", "exit_code", "code"]) {
                return exitCode == 0 ? .success : .failed
            }
        }
        if let toolIsError = item.toolIsError {
            return toolIsError ? .failed : .success
        }
        return .unknown
    }

    static func isSummaryOnly(raw: String?) -> Bool {
        isSummaryOnly(raw: raw, context: nil)
    }

    static func isSummaryOnly(raw: String?, context: AgentToolResultProcessingContext?) -> Bool {
        BashToolResultParser.parseMetadata(raw: raw, context: context).isSummaryOnly || isSummaryOnly(resultObject: jsonObject(from: raw, context: context))
    }

    private static func isSummaryOnly(resultObject: [String: Any]?) -> Bool {
        boolValue(resultObject, keys: ["summary_only", "summaryOnly"]) ?? false
    }

    private static func summaryText(for item: AgentChatItem, keyPaths: [String], status: AgentTranscriptToolStatus) -> String? {
        if !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           item.kind != .toolResult
        {
            return item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let toolName = normalizedToolName(item.toolName) ?? item.toolName ?? "tool"
        let pathSummary = keyPaths.prefix(3).joined(separator: ", ")
        if !pathSummary.isEmpty {
            return "\(toolName) • \(status.rawValue) • \(pathSummary)"
        }
        return "\(toolName) • \(status.rawValue)"
    }

    private static func extractKeyPaths(
        argsObject: [String: Any]?,
        resultObject: [String: Any]?
    ) -> [String] {
        let object = argsObject ?? resultObject
        guard let object else { return [] }
        var collected: [String] = []
        for key in ["path", "file_path", "filePath", "new_path", "newPath"] {
            if let value = stringValue(object, keys: [key]), !value.isEmpty {
                collected.append(value)
            }
        }
        if let paths = object["paths"] as? [String] {
            collected.append(contentsOf: paths.filter { !$0.isEmpty })
        }
        return Array(NSOrderedSet(array: collected)) as? [String] ?? collected
    }

    static func jsonObject(
        from raw: String?,
        context: AgentToolResultProcessingContext? = nil
    ) -> [String: Any]? {
        if let context {
            return context.jsonObject(from: raw)
        }
        guard let normalizedRaw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedRaw.isEmpty,
              let data = normalizedRaw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    private static func stringValue(_ object: [String: Any]?, keys: [String]) -> String? {
        guard let object else { return nil }
        for key in keys {
            if let string = object[key] as? String {
                return string
            }
            if let number = object[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func boolValue(_ object: [String: Any]?, keys: [String]) -> Bool? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? Bool {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.boolValue
            }
        }
        return nil
    }

    private static func transcriptStatusForAgentRunStatusWord(_ raw: String?) -> AgentTranscriptToolStatus? {
        guard let normalized = AgentTranscriptToolStatusSemantics.normalizedStatusWord(raw) else {
            return nil
        }
        switch normalized {
        case "running":
            return .running
        case "waiting_for_input":
            return .warning
        case "completed":
            return .success
        case "failed":
            return .failed
        case "cancelled":
            return .cancelled
        case "expired":
            return .warning
        default:
            return nil
        }
    }

    private static func intValue(_ object: [String: Any]?, keys: [String]) -> Int? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? Int {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.intValue
            }
            if let value = object[key] as? String,
               let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return intValue
            }
        }
        return nil
    }
}

private func mergedToolExecutionMetadata(
    _ preferred: AgentTranscriptToolExecution,
    with fallback: AgentTranscriptToolExecution
) -> AgentTranscriptToolExecution {
    var merged = preferred
    if merged.toolName == nil {
        merged.toolName = fallback.toolName
    }
    if merged.invocationID == nil {
        merged.invocationID = fallback.invocationID
    }
    if merged.argsJSON == nil {
        merged.argsJSON = fallback.argsJSON
    }
    if merged.resultJSON == nil {
        merged.resultJSON = fallback.resultJSON
    }
    if merged.toolIsError == nil {
        merged.toolIsError = fallback.toolIsError
    }
    if merged.processID == nil {
        merged.processID = fallback.processID
    }
    if merged.exitCode == nil {
        merged.exitCode = fallback.exitCode
    }
    if merged.summaryText?.isEmpty ?? true {
        merged.summaryText = fallback.summaryText
    }
    let mergedKeyPaths = Array(NSOrderedSet(array: fallback.keyPaths + merged.keyPaths)) as? [String]
        ?? (fallback.keyPaths + merged.keyPaths)
    merged.keyPaths = mergedKeyPaths
    merged.summaryOnly = merged.summaryOnly || fallback.summaryOnly
    return merged
}

struct AgentTranscriptImportPolicy: Equatable {
    var hideAlwaysHiddenTools: Bool
    var hidePendingQuestionToolCall: Bool

    init(
        hideAlwaysHiddenTools: Bool = true,
        hidePendingQuestionToolCall: Bool = false
    ) {
        self.hideAlwaysHiddenTools = hideAlwaysHiddenTools
        self.hidePendingQuestionToolCall = hidePendingQuestionToolCall
    }

    static let canonical = AgentTranscriptImportPolicy()

    static func liveSession(hidePendingQuestionToolCall: Bool) -> AgentTranscriptImportPolicy {
        AgentTranscriptImportPolicy(
            hideAlwaysHiddenTools: true,
            hidePendingQuestionToolCall: hidePendingQuestionToolCall
        )
    }
}

enum AgentTranscriptSummaryTextFormatter {
    static func summaryTitle(for summary: AgentTranscriptClusterSummary?, fallbackCount: Int) -> String {
        guard let summary else {
            return fallbackCount == 1 ? "Update" : "Updates"
        }
        switch ClusterToolCategory.summaryTitleSemantic(
            toolNames: summary.toolNames,
            toolNameCounts: summary.toolNameCounts,
            containsRunningWork: summary.containsRunningWork
        ) {
        case .running:
            return "Running"
        case .exploredAndEdited:
            return "Explored & edited"
        case .madeChanges:
            return "Made changes"
        case .ranCommands:
            return "Ran commands"
        case .agentActivity:
            return "Agent activity"
        case .exploredCodebase:
            return "Explored codebase"
        case .toolActivity:
            return "Tool activity"
        case .none:
            return fallbackCount == 1 ? "Update" : "Updates"
        }
    }

    static func groupedSummarySubtitle(summary: AgentTranscriptGroupedHistorySummary) -> String {
        var parts: [String] = []
        if summary.hiddenAssistantCount > 0 {
            parts.append("\(summary.hiddenAssistantCount) assistant")
        }
        if summary.hiddenProgressCount > 0 {
            parts.append("\(summary.hiddenProgressCount) progress")
        }
        if summary.hiddenNoteCount > 0 {
            parts.append("\(summary.hiddenNoteCount) notes")
        }
        return parts.joined(separator: " • ")
    }

    static func collapsedDisplay(
        for summary: AgentTranscriptClusterSummary?,
        fallbackCount: Int,
        fallbackText: String? = nil
    ) -> AgentTranscriptCollapsedSummaryDisplay {
        let narration = summary?.shortNarration?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolGroupText = collapsedToolGroupText(summary?.toolGroups ?? [])
        return AgentTranscriptCollapsedSummaryDisplay(
            title: summaryTitle(for: summary, fallbackCount: fallbackCount),
            count: fallbackCount > 0 ? fallbackCount : nil,
            detailText: collapsedDetailText(
                narration: summary?.shortNarration,
                toolGroups: summary?.toolGroups ?? [],
                fallbackText: fallbackText
            ),
            narrationText: (narration?.isEmpty == false) ? narration : nil,
            toolGroupText: (toolGroupText?.isEmpty == false) ? toolGroupText : nil,
            status: collapsedStatus(for: summary)
        )
    }

    static func collapsedDisplay(summary: AgentTranscriptGroupedHistorySummary) -> AgentTranscriptCollapsedSummaryDisplay {
        collapsedDisplay(
            for: summary.toolSummary,
            fallbackCount: summary.hiddenToolCardCount,
            fallbackText: groupedSummarySubtitle(summary: summary)
        )
    }

    static func groupedHistorySystemText(summary: AgentTranscriptGroupedHistorySummary) -> String {
        var parts: [String] = []
        parts.append(summaryTitle(for: summary.toolSummary, fallbackCount: summary.hiddenToolCardCount))
        if summary.hiddenToolCardCount > 0 {
            let noun = summary.hiddenToolCardCount == 1 ? "tool call" : "tool calls"
            parts.append("\(summary.hiddenToolCardCount) hidden \(noun)")
        }
        let subtitle = groupedSummarySubtitle(summary: summary)
        if !subtitle.isEmpty {
            parts.append(subtitle)
        }
        if let narration = summary.toolSummary?.shortNarration?.trimmingCharacters(in: .whitespacesAndNewlines),
           !narration.isEmpty
        {
            parts.append(narration)
        }
        let chipSummary = toolChipSummaryText(summary: summary.toolSummary)
        if !chipSummary.isEmpty {
            parts.append(chipSummary)
        }
        return parts.joined(separator: " • ")
    }

    /// Handoff-optimized version: title + narration + tool names only (no counts, no folder paths).
    static func groupedHistoryHandoffText(summary: AgentTranscriptGroupedHistorySummary) -> String {
        var parts: [String] = []
        parts.append(summaryTitle(for: summary.toolSummary, fallbackCount: summary.hiddenToolCardCount))
        if let narration = summary.toolSummary?.shortNarration?.trimmingCharacters(in: .whitespacesAndNewlines),
           !narration.isEmpty
        {
            parts.append(wordBoundaryTruncate(narration, maxLength: 150))
        }
        let toolNames = handoffToolChipText(summary: summary.toolSummary)
        if !toolNames.isEmpty {
            parts.append(toolNames)
        }
        return parts.joined(separator: " • ")
    }

    /// Truncates at a word boundary instead of mid-word.
    fileprivate static func wordBoundaryTruncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let trimmed = text.prefix(maxLength)
        if let lastSpace = trimmed.lastIndex(of: " ") {
            return String(trimmed[..<lastSpace]) + "…"
        }
        return String(trimmed) + "…"
    }

    /// Tool names only — excludes keyPaths (folder/file names) that leak into the UI chip list.
    private static func handoffToolChipText(summary: AgentTranscriptClusterSummary?) -> String {
        guard let summary else { return "" }
        var tokens: [String] = []
        var seenTools = Set<String>()
        let uniqueTools = summary.toolNames.filter { toolName in
            let key = toolName.lowercased()
            if seenTools.contains(key) { return false }
            seenTools.insert(key)
            return true
        }
        for toolName in uniqueTools.prefix(4) {
            let count = summary.toolNameCounts[toolName] ?? summary.toolNameCounts[toolName.lowercased()] ?? 1
            tokens.append(count > 1 ? "\(toolName) ×\(count)" : toolName)
        }
        return tokens.joined(separator: ", ")
    }

    private static func toolChipSummaryText(summary: AgentTranscriptClusterSummary?) -> String {
        guard let summary else { return "" }
        var tokens: [String] = []
        var seenTools = Set<String>()
        let uniqueTools = summary.toolNames.filter { toolName in
            let key = toolName.lowercased()
            if seenTools.contains(key) {
                return false
            }
            seenTools.insert(key)
            return true
        }
        for toolName in uniqueTools.prefix(4) {
            let count = summary.toolNameCounts[toolName] ?? summary.toolNameCounts[toolName.lowercased()] ?? 1
            tokens.append(count > 1 ? "\(toolName) ×\(count)" : toolName)
        }
        for path in summary.keyPaths.prefix(3) {
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            tokens.append(fileName.isEmpty ? path : fileName)
        }
        if tokens.count < summary.toolNames.count {
            tokens.append("+\(summary.toolNames.count - tokens.count)")
        }
        return tokens.joined(separator: ", ")
    }

    private static func collapsedStatus(for summary: AgentTranscriptClusterSummary?) -> AgentTranscriptCollapsedSummaryStatus {
        guard let summary else { return .neutral }
        if summary.containsFailure { return .failure }
        if summary.containsWarning { return .warning }
        if summary.containsRunningWork { return .running }
        return .neutral
    }

    private static func collapsedDetailText(
        narration: String?,
        toolGroups: [ClusterToolGroup],
        fallbackText: String?
    ) -> String? {
        let parts = [
            narration?.trimmingCharacters(in: .whitespacesAndNewlines),
            collapsedToolGroupText(toolGroups),
            fallbackText?.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .compactMap(\.self)
        .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return Array(parts.prefix(2)).joined(separator: " • ")
    }

    private static func collapsedToolGroupText(_ toolGroups: [ClusterToolGroup]) -> String? {
        let labels = toolGroups.map(\.label).filter { !$0.isEmpty }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ", ")
    }
}

enum AgentTranscriptIO {
    private static let hiddenTranscriptToolNames: Set<String> = [
        "wait_for_next_user_instruction",
        "share_thoughts",
        "set_status"
    ]

    private static func logHandoffDebug(_ message: @autoclosure () -> String) {
        #if DEBUG
            print("[HandoffExport] \(message())")
        #endif
    }

    static func shouldHideToolFromTranscript(_ name: String?) -> Bool {
        guard let name else { return false }
        return hiddenTranscriptToolNames.contains(AgentTranscriptToolNormalizer.normalizedToolName(name) ?? "")
    }

    static func shouldIncludeLegacyItem(
        _ item: AgentChatItem,
        policy: AgentTranscriptImportPolicy = .canonical
    ) -> Bool {
        if policy.hideAlwaysHiddenTools,
           item.kind == .toolCall || item.kind == .toolResult,
           shouldHideToolFromTranscript(item.toolName)
        {
            return false
        }
        if policy.hidePendingQuestionToolCall,
           item.kind == .toolCall,
           MCPIntegrationHelper.isRepoPromptAskUserToolName(item.toolName)
        {
            return false
        }
        return true
    }

    static func filteredLegacyItems(
        _ items: [AgentChatItem],
        policy: AgentTranscriptImportPolicy = .canonical
    ) -> [AgentChatItem] {
        items.filter { shouldIncludeLegacyItem($0, policy: policy) }
    }

    static func containsExcludedLegacyItems(
        _ items: [AgentChatItem],
        policy: AgentTranscriptImportPolicy = .canonical
    ) -> Bool {
        items.contains { !shouldIncludeLegacyItem($0, policy: policy) }
    }

    static func containsRowsExcludedByPolicy(
        in transcript: AgentTranscript,
        policy: AgentTranscriptImportPolicy = .canonical
    ) -> Bool {
        flattenFullTranscript(transcript).contains { !shouldIncludeLegacyItem($0, policy: policy) }
    }

    static func buildTranscript(
        from items: [AgentChatItem],
        terminalState: AgentSessionRunState? = nil,
        nextSequenceIndex: Int? = nil,
        policy: AgentTranscriptImportPolicy = .canonical,
        compact: Bool = true,
        protection: AgentTranscriptProjectionProtection = .none
    ) -> AgentTranscript {
        let transcript = importLegacyItems(
            filteredLegacyItems(items, policy: policy),
            terminalState: terminalState,
            nextSequenceIndex: nextSequenceIndex
        )
        return compact ? AgentTranscriptCompactor.compact(transcript, protection: protection) : transcript
    }

    static func runtimeNormalizedTranscript(
        _ transcript: AgentTranscript,
        protection: AgentTranscriptProjectionProtection = .none
    ) -> AgentTranscript {
        AgentTranscriptCompactor.compact(transcript, protection: protection)
    }

    static func persistedTranscript(
        _ transcript: AgentTranscript,
        protection: AgentTranscriptProjectionProtection = .none
    ) -> AgentTranscript {
        AgentTranscriptPolicyPipeline.persistedTranscript(
            from: transcript,
            protection: protection
        ).transcript
    }

    static func normalizedTranscript(_ transcript: AgentTranscript) -> AgentTranscript {
        AgentTranscriptDurableFrontierSupport.normalizedTranscript(transcript)
    }

    static func workingSourceItems(from transcript: AgentTranscript) -> [AgentChatItem] {
        #if DEBUG
            let startedAt = Date.timeIntervalSinceReferenceDate
        #endif
        let rows = transcript.turns
            .filter { $0.retentionTier == .full }
            .flatMap { turn in
                var rows: [AgentChatItem] = []
                if let request = turn.request {
                    rows.append(request.toItem())
                }
                rows.append(contentsOf: turn.allActivities.map { $0.toItem() })
                return rows
            }
            .sorted { lhs, rhs in
                if lhs.sequenceIndex == rhs.sequenceIndex {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.sequenceIndex < rhs.sequenceIndex
            }
        #if DEBUG
            if AgentTranscriptDebugInstrumentation.isEnabled {
                AgentTranscriptDebugInstrumentation.workingSourceItemsHandler?(.init(
                    transcriptTurnCount: transcript.turns.count,
                    fullTurnCount: transcript.turns.count(where: { $0.retentionTier == .full }),
                    itemCount: rows.count,
                    durationMS: AgentTranscriptDebugInstrumentation.durationMS(since: startedAt)
                ))
            }
        #endif
        return rows
    }

    #if DEBUG
        private static func workingSourceItemCountWithoutProjection(from transcript: AgentTranscript) -> Int {
            transcript.turns.reduce(into: 0) { partial, turn in
                guard turn.retentionTier == .full else { return }
                if turn.request != nil {
                    partial += 1
                }
                partial += turn.allActivities.count
            }
        }

        private static func retentionTierWorseningCounts(
            from oldTranscript: AgentTranscript,
            to newTranscript: AgentTranscript
        ) -> (all: Int, legacyNonFull: Int) {
            let newTierByTurnID = Dictionary(uniqueKeysWithValues: newTranscript.turns.map { ($0.id, $0.retentionTier) })
            var all = 0
            var legacyNonFull = 0
            for turn in oldTranscript.turns {
                guard let newTier = newTierByTurnID[turn.id],
                      retentionWorseningRank(newTier) > retentionWorseningRank(turn.retentionTier)
                else {
                    continue
                }
                all += 1
                if turn.retentionTier != .full {
                    legacyNonFull += 1
                }
            }
            return (all, legacyNonFull)
        }

        private static func retentionWorseningRank(_ tier: AgentTranscriptRetentionTier) -> Int {
            switch tier {
            case .full:
                0
            case .condensed:
                1
            case .summary:
                2
            case .archived:
                3
            }
        }
    #endif

    static func fullDetailTurnEnvelopeChanged(
        from oldTranscript: AgentTranscript,
        to newTranscript: AgentTranscript
    ) -> Bool {
        let oldFullTurnIDs = oldTranscript.turns.lazy
            .filter { $0.retentionTier == .full }
            .map(\.id)
        let newFullTurnIDs = newTranscript.turns.lazy
            .filter { $0.retentionTier == .full }
            .map(\.id)
        return !oldFullTurnIDs.elementsEqual(newFullTurnIDs)
    }

    private static func compactedPrefixTurns(in transcript: AgentTranscript) -> [AgentTranscriptTurn] {
        Array(transcript.turns.prefix { $0.retentionTier != .full })
    }

    private static func workingDetailTranscript(from transcript: AgentTranscript) -> AgentTranscript {
        AgentTranscript(
            version: transcript.version,
            turns: transcript.turns.filter { $0.retentionTier == .full },
            nextSequenceIndex: transcript.nextSequenceIndex,
            compactionFrontier: nil
        )
    }

    private static func transcriptByReplacingWorkingTurns(
        in transcript: AgentTranscript,
        with workingTranscript: AgentTranscript,
        nextSequenceIndex: Int? = nil
    ) -> AgentTranscript {
        var remainingWorkingTurns = workingTranscript.turns
        var mergedTurns: [AgentTranscriptTurn] = []
        mergedTurns.reserveCapacity(max(transcript.turns.count, workingTranscript.turns.count))

        for turn in transcript.turns {
            guard turn.retentionTier == .full else {
                mergedTurns.append(turn)
                continue
            }
            if let matchedIndex = remainingWorkingTurns.firstIndex(where: { $0.id == turn.id }) {
                mergedTurns.append(remainingWorkingTurns.remove(at: matchedIndex))
            } else if !remainingWorkingTurns.isEmpty {
                mergedTurns.append(remainingWorkingTurns.removeFirst())
            } else {
                mergedTurns.append(turn)
            }
        }
        mergedTurns.append(contentsOf: remainingWorkingTurns)
        return AgentTranscript(
            version: max(transcript.version, workingTranscript.version),
            turns: mergedTurns,
            nextSequenceIndex: nextSequenceIndex ?? workingTranscript.nextSequenceIndex,
            compactionFrontier: nil
        )
    }

    static func rebuiltTranscriptPreservingCompactedPrefix(
        existingTranscript: AgentTranscript,
        workingItems: [AgentChatItem],
        earliestChangedIndex: Int? = nil,
        terminalState: AgentSessionRunState? = nil,
        nextSequenceIndex: Int? = nil,
        policy: AgentTranscriptImportPolicy = .canonical,
        protection: AgentTranscriptProjectionProtection = .none
    ) -> AgentTranscript {
        #if DEBUG
            let startedAt = Date.timeIntervalSinceReferenceDate
            let existingWorkingItemCount = workingSourceItemCountWithoutProjection(from: existingTranscript)
            var usedIncrementalFinalTurnUpdate = false
        #endif
        let existingWorkingTranscript = workingDetailTranscript(from: existingTranscript)
        let rebuiltWorkingTranscript: AgentTranscript
        if let earliestChangedIndex,
           !workingItems.isEmpty,
           let incrementallyUpdatedTranscript = incrementallyUpdatedTranscriptForFinalTurn(
               existingTranscript: existingWorkingTranscript,
               items: workingItems,
               earliestChangedIndex: earliestChangedIndex,
               terminalState: terminalState,
               nextSequenceIndex: nextSequenceIndex,
               policy: policy,
               protection: protection
           )
        {
            #if DEBUG
                usedIncrementalFinalTurnUpdate = true
            #endif
            rebuiltWorkingTranscript = incrementallyUpdatedTranscript
        } else {
            rebuiltWorkingTranscript = buildTranscript(
                from: workingItems,
                terminalState: terminalState,
                nextSequenceIndex: nextSequenceIndex,
                policy: policy,
                compact: false,
                protection: protection
            )
        }
        var mergedTranscript = transcriptByReplacingWorkingTurns(
            in: existingTranscript,
            with: rebuiltWorkingTranscript,
            nextSequenceIndex: nextSequenceIndex ?? rebuiltWorkingTranscript.nextSequenceIndex
        )
        let reusableFrozenPrefixTurnCount = AgentTranscriptDurableFrontierSupport.validatedFrozenPrefixTurnCountForIncrementalReuse(
            in: existingTranscript
        )
        if reusableFrozenPrefixTurnCount != nil {
            mergedTranscript.compactionFrontier = existingTranscript.compactionFrontier
        }
        let requestedCompactionMode: AgentTranscriptCompactionMode = reusableFrozenPrefixTurnCount != nil ? .preserveDurableFrontier : .recomputeAll
        let compacted = AgentTranscriptCompactor.compact(
            mergedTranscript,
            mode: requestedCompactionMode,
            protection: protection
        )
        #if DEBUG
            if AgentTranscriptDebugInstrumentation.isEnabled {
                let worsening = retentionTierWorseningCounts(from: existingTranscript, to: compacted)
                AgentTranscriptDebugInstrumentation.rebuildHandler?(.init(
                    existingTurnCount: existingTranscript.turns.count,
                    workingItemsCount: workingItems.count,
                    existingWorkingItemCount: existingWorkingItemCount,
                    appendedRowDelta: workingItems.count - existingWorkingItemCount,
                    usedIncrementalFinalTurnUpdate: usedIncrementalFinalTurnUpdate,
                    reusableFrozenPrefixTurnCount: reusableFrozenPrefixTurnCount,
                    requestedCompactionMode: requestedCompactionMode,
                    tierWorseningCount: worsening.all,
                    legacyNonFullTierWorseningCount: worsening.legacyNonFull,
                    rebuiltTurnCount: compacted.turns.count,
                    durationMS: AgentTranscriptDebugInstrumentation.durationMS(since: startedAt)
                ))
            }
        #endif
        return compacted
    }

    static func validatedReusableFrozenPrefixTurnCount(in transcript: AgentTranscript) -> Int? {
        AgentTranscriptDurableFrontierSupport.validatedFrozenPrefixTurnCountForIncrementalReuse(in: transcript)
    }

    static func incrementallyUpdatedTranscriptForFinalTurn(
        existingTranscript: AgentTranscript,
        items: [AgentChatItem],
        earliestChangedIndex: Int,
        terminalState: AgentSessionRunState? = nil,
        nextSequenceIndex: Int? = nil,
        policy: AgentTranscriptImportPolicy = .canonical,
        protection: AgentTranscriptProjectionProtection = .none
    ) -> AgentTranscript? {
        guard !items.isEmpty,
              !existingTranscript.turns.isEmpty,
              let frozenPrefixTurnCount = AgentTranscriptDurableFrontierSupport.validatedFrozenPrefixTurnCountForIncrementalReuse(
                  in: existingTranscript
              ),
              let finalTurnStartIndex = finalTurnStartIndex(in: items),
              earliestChangedIndex >= finalTurnStartIndex
        else {
            return nil
        }
        let suffixItems = Array(items[finalTurnStartIndex...])
        let rebuiltSuffixTranscript = buildTranscript(
            from: suffixItems,
            terminalState: terminalState,
            nextSequenceIndex: nextSequenceIndex,
            policy: policy,
            compact: false,
            protection: protection
        )
        guard rebuiltSuffixTranscript.turns.count == 1,
              let rebuiltFinalTurn = rebuiltSuffixTranscript.turns.first,
              let existingFinalTurn = existingTranscript.turns.last,
              existingFinalTurn.request?.id == rebuiltFinalTurn.request?.id
        else {
            return nil
        }
        var updatedTranscript = existingTranscript
        updatedTranscript.turns[updatedTranscript.turns.count - 1] = rebuiltFinalTurn
        updatedTranscript.nextSequenceIndex = nextSequenceIndex ?? updatedTranscript.nextSequenceIndex
        return AgentTranscriptCompactor.compact(
            updatedTranscript,
            mode: frozenPrefixTurnCount > 0 ? .preserveDurableFrontier : .recomputeAll,
            protection: protection
        )
    }

    static func lastUserInteractionDate(in items: [AgentChatItem]) -> Date? {
        let userInteraction = items.last(where: isUserInteractionItem(_:))
        return userInteraction?.timestamp
    }

    static func lastUserInteractionDate(in transcript: AgentTranscript) -> Date? {
        for turn in transcript.turns.reversed() {
            if let interactionDate = lastUserInteractionDate(in: turn) {
                return interactionDate
            }
        }
        return nil
    }

    private static func isUserInteractionItem(_ item: AgentChatItem) -> Bool {
        if item.kind == .user {
            return true
        }
        guard item.kind == .toolResult,
              MCPIntegrationHelper.isRepoPromptAskUserToolName(item.toolName),
              let result = item.toolResultJSON,
              let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return json["response"] != nil
            || json["skipped"] as? Bool == true
            || json["timed_out"] as? Bool == true
    }

    private static func lastUserInteractionDate(in turn: AgentTranscriptTurn) -> Date? {
        var latest = turn.summary?.lastUserInteractionAt
        if let requestTimestamp = turn.request?.timestamp {
            latest = max(latest ?? requestTimestamp, requestTimestamp)
        }
        for activity in turn.allActivities {
            guard isUserInteractionItem(activity.toItem()) else { continue }
            let timestamp = activity.timestamp
            latest = max(latest ?? timestamp, timestamp)
        }
        return latest
    }

    @discardableResult
    static func finalizePendingToolCalls(
        in items: inout [AgentChatItem],
        terminalState: AgentSessionRunState,
        includeExplicitRepoPromptToolCalls: Bool,
        maxSequenceIndexExclusive: Int? = nil,
        nonToolBoundary: Int
    ) -> Int {
        guard !items.isEmpty else { return 0 }
        var finalizedCount = 0
        var consecutiveNonToolItems = 0
        for index in items.indices.reversed() {
            if let maxSequenceIndexExclusive,
               items[index].sequenceIndex >= maxSequenceIndexExclusive
            {
                continue
            }
            switch items[index].kind {
            case .toolCall:
                if let toolName = items[index].toolName,
                   MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName),
                   !includeExplicitRepoPromptToolCalls
                {
                    consecutiveNonToolItems = 0
                    continue
                }
                let fallback = terminalFallbackToolResult(for: terminalState, item: items[index])
                var updated = items[index]
                updated.kind = .toolResult
                updated.toolResultJSON = fallback.json
                updated.text = fallback.json
                updated.toolIsError = fallback.isError
                items[index] = updated
                finalizedCount += 1
                consecutiveNonToolItems = 0
            case .toolResult:
                guard runningToolResultStatusWord(from: items[index].toolResultJSON) != nil else {
                    consecutiveNonToolItems = 0
                    continue
                }
                // Skip running/pending RepoPrompt tool results the same way as pending tool calls —
                // they should not be force-finalized when the tool name has already been normalized.
                if let toolName = items[index].toolName,
                   MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName),
                   !includeExplicitRepoPromptToolCalls
                {
                    consecutiveNonToolItems = 0
                    continue
                }
                let fallback = terminalFallbackToolResult(for: terminalState, item: items[index])
                var updated = items[index]
                updated.toolResultJSON = fallback.json
                updated.text = fallback.json
                updated.toolIsError = fallback.isError
                items[index] = updated
                finalizedCount += 1
                consecutiveNonToolItems = 0
            default:
                consecutiveNonToolItems += 1
                if consecutiveNonToolItems >= nonToolBoundary {
                    return finalizedCount
                }
            }
        }
        return finalizedCount
    }

    static func isAgentControlToolName(_ raw: String?) -> Bool {
        let normalized = MCPIntegrationHelper.normalizedRepoPromptToolName(raw ?? "")
        return normalized == "agent_run" || normalized == "agent_explore"
    }

    static func terminalFallbackToolResult(
        for terminalState: AgentSessionRunState,
        item: AgentChatItem
    ) -> (json: String, isError: Bool) {
        guard isAgentControlToolName(item.toolName) else {
            return (fallbackToolResultJSON(for: terminalState), true)
        }

        let op = agentControlOperation(from: item.toolArgsJSON)
        let status: String
        let reason: String
        let note: String
        let isError: Bool
        switch terminalState {
        case .completed:
            if op == "wait" {
                status = "cancelled"
                reason = "wait_interrupted"
                note = "The agent-run wait was interrupted before a tool result payload was received. If the child run is still active, call agent_run.wait again."
                isError = false
            } else {
                status = "completed"
                reason = "result_missing_after_turn_completed"
                note = "No tool result payload was received before the agent turn completed."
                isError = false
            }
        case .cancelled:
            status = "cancelled"
            reason = op == "wait" ? "wait_interrupted" : "run_cancelled"
            note = "The agent-run control call was interrupted before a tool result payload was received."
            isError = false
        case .failed:
            status = "failed"
            reason = "run_failed"
            note = "No tool result payload was received before the agent run failed."
            isError = true
        default:
            status = "cancelled"
            reason = "run_ended"
            note = "No tool result payload was received before the agent run ended."
            isError = false
        }
        var payload: [String: Any] = [
            "status": status,
            "reason": reason,
            "note": note
        ]
        if let op {
            payload["op"] = op
        }
        if let toolName = item.toolName?.trimmingCharacters(in: .whitespacesAndNewlines), !toolName.isEmpty {
            payload["tool"] = MCPIntegrationHelper.normalizedRepoPromptToolName(toolName)
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let json = String(data: data, encoding: .utf8)
        {
            return (json, isError)
        }
        return ("{\"status\":\"\(status)\",\"reason\":\"\(reason)\"}", isError)
    }

    private static func agentControlOperation(from argsJSON: String?) -> String? {
        guard let raw = argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["op"] as? String
        else {
            return nil
        }
        let trimmed = op.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func runningToolResultStatusWord(from raw: String?) -> String? {
        guard let object = toolResultObject(from: raw),
              let rawStatus = toolResultString(object: object, key: "status")?
              .trimmingCharacters(in: .whitespacesAndNewlines)
              .lowercased()
        else {
            return nil
        }
        switch rawStatus {
        case "running", "in_progress", "pending":
            return rawStatus
        default:
            return nil
        }
    }

    private static func toolResultObject(from raw: String?) -> [String: Any]? {
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

    private static func toolResultString(object: [String: Any], key: String) -> String? {
        if let string = object[key] as? String {
            return string
        }
        if let number = object[key] as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func fallbackToolResultJSON(for terminalState: AgentSessionRunState) -> String {
        let status: String
        let reason: String
        switch terminalState {
        case .cancelled:
            status = "failed"
            reason = "run_cancelled"
        case .failed:
            status = "failed"
            reason = "run_failed"
        case .completed:
            status = "failed"
            reason = "result_missing"
        default:
            status = "failed"
            reason = "run_ended"
        }
        let payload: [String: Any] = [
            "status": status,
            "reason": reason,
            "note": "No tool result payload was received before the run ended."
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return "{\"status\":\"\(status)\",\"reason\":\"\(reason)\"}"
    }

    private static func finalTurnStartIndex(in items: [AgentChatItem]) -> Int? {
        items.lastIndex(where: { $0.kind == .user })
    }

    static func importLegacyItems(
        _ items: [AgentChatItem],
        terminalState: AgentSessionRunState? = nil,
        nextSequenceIndex: Int? = nil
    ) -> AgentTranscript {
        guard !items.isEmpty else {
            return AgentTranscript(version: 3, turns: [], nextSequenceIndex: nextSequenceIndex ?? 0)
        }
        let orderedItems = items.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        var turns: [AgentTranscriptTurn] = []
        var currentTurn: AgentTranscriptTurn?
        var currentSpan: AgentTranscriptProviderResponseSpan?
        var pendingStableExecutionIDsByToolName: [String: [String]] = [:]
        let processingContext = AgentToolResultProcessingContext()

        func finalizeSpan(
            _ span: inout AgentTranscriptProviderResponseSpan,
            isCompleted: Bool
        ) {
            if isCompleted {
                span.lifecycle = .completed
                span.completedAt = span.completedAt ?? span.lastActivityAt ?? span.startedAt
            } else {
                span.lifecycle = .open
                span.completedAt = nil
            }
        }

        func flushCurrentTurn(isCompleted: Bool, terminalState: AgentSessionRunState?) {
            guard var turn = currentTurn else { return }
            if var span = currentSpan {
                finalizeSpan(&span, isCompleted: isCompleted)
                turn.responseSpans.append(span)
            }
            finalizeTurn(
                &turn,
                priorTurns: turns,
                terminalState: terminalState,
                isCompleted: isCompleted
            )
            if turn.request != nil || !turn.responseSpans.isEmpty {
                turns.append(turn)
            }
            currentTurn = nil
            currentSpan = nil
            pendingStableExecutionIDsByToolName.removeAll(keepingCapacity: false)
        }

        func ensureCurrentTurn(for item: AgentChatItem) {
            if currentTurn == nil {
                currentTurn = AgentTranscriptTurn(
                    id: item.id,
                    request: nil,
                    startedAt: item.timestamp,
                    lastActivityAt: item.timestamp,
                    completedAt: nil
                )
            }
            if currentSpan == nil, let turnID = currentTurn?.id {
                currentSpan = AgentTranscriptProviderResponseSpan(
                    id: deterministicSpanID(turnID: turnID, ordinal: currentTurn?.responseSpans.count ?? 0),
                    startedAt: item.timestamp,
                    lastActivityAt: item.timestamp
                )
            }
        }

        for item in orderedItems {
            if item.kind == .user {
                flushCurrentTurn(isCompleted: true, terminalState: nil)
                currentTurn = AgentTranscriptTurn(
                    id: item.id,
                    request: AgentTranscriptRequestAnchor(from: item),
                    startedAt: item.timestamp,
                    lastActivityAt: nil,
                    completedAt: nil
                )
                currentSpan = AgentTranscriptProviderResponseSpan(
                    id: deterministicSpanID(turnID: item.id, ordinal: 0),
                    startedAt: item.timestamp
                )
                continue
            }
            ensureCurrentTurn(for: item)
            guard var span = currentSpan else { continue }
            var toolExecution = AgentTranscriptToolNormalizer.toolExecution(for: item, context: processingContext)
            if var resolvedToolExecution = toolExecution {
                let normalizedToolName = AgentTranscriptToolNormalizer.normalizedToolName(item.toolName) ?? ""
                if item.toolInvocationID == nil, !normalizedToolName.isEmpty {
                    switch item.kind {
                    case .toolCall:
                        pendingStableExecutionIDsByToolName[normalizedToolName, default: []].append(resolvedToolExecution.stableExecutionID)
                    case .toolResult:
                        if var pendingIDs = pendingStableExecutionIDsByToolName[normalizedToolName], let matchedStableID = pendingIDs.popLast() {
                            resolvedToolExecution.stableExecutionID = matchedStableID
                            pendingStableExecutionIDsByToolName[normalizedToolName] = pendingIDs
                        }
                    default:
                        break
                    }
                }
                toolExecution = resolvedToolExecution
            }
            let activity = AgentTranscriptActivity(
                from: item,
                toolExecution: toolExecution,
                role: role(for: item),
                sealsAssistantBoundary: sealsAssistantBoundary(for: item, toolExecution: toolExecution)
            )
            span.activities.append(activity)
            span.lastActivityAt = item.timestamp
            currentSpan = span
            currentTurn?.lastActivityAt = item.timestamp
        }
        let shouldCloseTrailingTurn = !(terminalState?.isActive ?? false)
        flushCurrentTurn(
            isCompleted: shouldCloseTrailingTurn,
            terminalState: terminalState
        )

        let maxSequence = orderedItems.map(\.sequenceIndex).max() ?? -1
        return AgentTranscript(
            version: 3,
            turns: turns,
            nextSequenceIndex: nextSequenceIndex ?? (maxSequence + 1)
        )
    }

    static func flattenFullTranscript(_ transcript: AgentTranscript) -> [AgentChatItem] {
        var rows: [AgentChatItem] = []
        for turn in transcript.turns {
            if let request = turn.request {
                rows.append(request.toItem())
            }
            rows.append(contentsOf: turn.allActivities.map { $0.toItem() })
        }
        return rows.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
    }

    static func latestAssistantPreviewText(from transcript: AgentTranscript) -> String? {
        for turn in transcript.turns.reversed() {
            if let text = latestAssistantPreviewText(in: turn) {
                return text
            }
        }
        return nil
    }

    /// Extract assistant preview text from a single turn.
    static func latestAssistantPreviewText(in turn: AgentTranscriptTurn) -> String? {
        if let activity = conclusionActivity(in: turn),
           AgentDisplayableText.hasDisplayableBody(activity.text)
        {
            return activity.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for activity in turn.allActivities.reversed() where (activity.itemKind == .assistant || activity.itemKind == .assistantInline) && AgentDisplayableText.hasDisplayableBody(activity.text) {
            return activity.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Extract the latest error text from the transcript.
    static func latestErrorText(from transcript: AgentTranscript, latestTurnOnly: Bool) -> String? {
        let turns = latestTurnOnly ? transcript.turns.suffix(1) : transcript.turns[...]
        for turn in turns.reversed() {
            for activity in turn.allActivities.reversed() where activity.itemKind == .error {
                let trimmed = activity.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private struct ConversationReplayWriter {
        private(set) var text = ""
        private(set) var utf8ByteCount = 0
        private var hasLine = false

        mutating func appendLine(_ line: String) {
            if hasLine {
                text.append("\n")
                utf8ByteCount += 1
            }
            text.append(line)
            utf8ByteCount += line.utf8.count
            hasLine = true
        }
    }

    private enum BoundedReplayOmissionPriority: Int {
        case conclusionAssistant = 1
        case context = 2
        case intermediateAssistant = 3
        case toolCall = 4
        case toolResult = 5
    }

    private struct BoundedReplayItem {
        let category: AgentConversationReplayCategory
        let line: String
        let unboundedLineUTF8Bytes: Int
        let omissionPriority: BoundedReplayOmissionPriority?
        let emittedToolArgumentCharacters: Int
        let toolArgumentsWereTruncated: Bool
    }

    static func buildConversationHistory(
        from transcript: AgentTranscript,
        renderUserMessage: ((AgentTranscriptRequestAnchor) -> String)? = nil
    ) -> String {
        #if DEBUG
            let startMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let serialization = serializeConversationHistory(
            from: transcript,
            renderUserMessage: renderUserMessage,
            policy: .equivalent
        )
        #if DEBUG
            AgentModePerfDiagnostics.recordConversationReplay(
                serialization.metrics,
                startMS: startMS
            )
        #endif
        return serialization.text
    }

    static func serializeConversationHistory(
        from transcript: AgentTranscript,
        renderUserMessage: ((AgentTranscriptRequestAnchor) -> String)? = nil,
        policy: AgentConversationReplayPolicy = .equivalent
    ) -> AgentConversationReplaySerialization {
        switch policy {
        case .equivalent:
            serializeEquivalentConversationHistory(
                from: transcript,
                renderUserMessage: renderUserMessage
            )
        case let .bounded(budget):
            serializeBoundedConversationHistory(
                from: transcript,
                renderUserMessage: renderUserMessage,
                budget: budget
            )
        }
    }

    private static func serializeEquivalentConversationHistory(
        from transcript: AgentTranscript,
        renderUserMessage: ((AgentTranscriptRequestAnchor) -> String)?
    ) -> AgentConversationReplaySerialization {
        var writer = ConversationReplayWriter()
        var categories = emptyConversationReplayCategoryMetrics()
        var examinedRowCount = 0
        var userAuthoredUTF8Bytes = 0
        var toolArgumentCharacters = 0

        func recordLine(
            _ line: String,
            category: AgentConversationReplayCategory,
            writer: inout ConversationReplayWriter,
            categories: inout [AgentConversationReplayCategory: AgentConversationReplayCategoryMetrics]
        ) {
            writer.appendLine(line)
            var metrics = categories[category] ?? .init()
            metrics.emittedCount += 1
            metrics.unboundedUTF8Bytes += line.utf8.count
            metrics.emittedUTF8Bytes += line.utf8.count
            categories[category] = metrics
        }

        for turn in transcript.turns {
            if let request = turn.request {
                examinedRowCount += 1
                var metrics = categories[.user] ?? .init()
                metrics.examinedCount += 1
                categories[.user] = metrics
                let rendered = renderUserMessage?(request) ?? request.text
                userAuthoredUTF8Bytes += rendered.utf8.count
                recordLine(
                    "<user>\(rendered)</user>",
                    category: .user,
                    writer: &writer,
                    categories: &categories
                )
            }
            for activity in renderableRows(for: turn, includeArchivedPresentation: true) {
                guard activity.kind != .user else { continue }
                examinedRowCount += 1
                guard let category = conversationReplayCategory(for: activity.kind) else { continue }
                var metrics = categories[category] ?? .init()
                metrics.examinedCount += 1
                categories[category] = metrics
                if AgentTranscriptToolVisibilityPolicy.shouldSuppressRow(activity) {
                    continue
                }
                switch activity.kind {
                case .assistant, .assistantInline:
                    if AgentDisplayableText.hasDisplayableBody(activity.text) {
                        let trimmed = activity.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        recordLine(
                            "<assistant>\(trimmed)</assistant>",
                            category: .assistant,
                            writer: &writer,
                            categories: &categories
                        )
                    }
                case .toolCall:
                    if let toolName = AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(activity.toolName) {
                        let args = activity.toolArgsJSON ?? ""
                        toolArgumentCharacters += args.count
                        let line = args.isEmpty
                            ? "<tool_call name=\"\(toolName)\"/>"
                            : "<tool_call name=\"\(toolName)\">\(args)</tool_call>"
                        recordLine(
                            line,
                            category: .toolCall,
                            writer: &writer,
                            categories: &categories
                        )
                    }
                case .toolResult:
                    if let toolName = AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(activity.toolName) {
                        recordLine(
                            "<tool_result name=\"\(toolName)\"/>",
                            category: .toolResult,
                            writer: &writer,
                            categories: &categories
                        )
                    }
                case .system:
                    recordLine(
                        "<system>\(activity.text)</system>",
                        category: .system,
                        writer: &writer,
                        categories: &categories
                    )
                case .error:
                    recordLine(
                        "<error>\(activity.text)</error>",
                        category: .error,
                        writer: &writer,
                        categories: &categories
                    )
                case .user, .thinking:
                    break
                }
            }
        }

        return AgentConversationReplaySerialization(
            text: writer.text,
            metrics: AgentConversationReplayMetrics(
                mode: .equivalent,
                turnCount: transcript.turns.count,
                examinedRowCount: examinedRowCount,
                unboundedOutputUTF8Bytes: writer.utf8ByteCount,
                outputUTF8Bytes: writer.utf8ByteCount,
                userAuthoredUTF8Bytes: userAuthoredUTF8Bytes,
                originalToolArgumentCharacters: toolArgumentCharacters,
                emittedToolArgumentCharacters: toolArgumentCharacters,
                truncatedToolCallCount: 0,
                omittedRowCount: 0,
                essentialOverflowUTF8Bytes: 0,
                finalOverBudgetUTF8Bytes: 0,
                categories: categories
            )
        )
    }

    private static func serializeBoundedConversationHistory(
        from transcript: AgentTranscript,
        renderUserMessage: ((AgentTranscriptRequestAnchor) -> String)?,
        budget: AgentConversationReplayBudget
    ) -> AgentConversationReplaySerialization {
        var items: [BoundedReplayItem] = []
        var categories = emptyConversationReplayCategoryMetrics()
        var examinedRowCount = 0
        var userAuthoredUTF8Bytes = 0
        var originalToolArgumentCharacters = 0
        var truncatedToolCallCount = 0

        func appendItem(_ item: BoundedReplayItem) {
            items.append(item)
            var metrics = categories[item.category] ?? .init()
            metrics.emittedCount += 1
            metrics.unboundedUTF8Bytes += item.unboundedLineUTF8Bytes
            categories[item.category] = metrics
        }

        for turn in transcript.turns {
            if let request = turn.request {
                examinedRowCount += 1
                var metrics = categories[.user] ?? .init()
                metrics.examinedCount += 1
                categories[.user] = metrics
                let rendered = renderUserMessage?(request) ?? request.text
                userAuthoredUTF8Bytes += rendered.utf8.count
                let line = "<user>\(rendered)</user>"
                appendItem(BoundedReplayItem(
                    category: .user,
                    line: line,
                    unboundedLineUTF8Bytes: line.utf8.count,
                    omissionPriority: nil,
                    emittedToolArgumentCharacters: 0,
                    toolArgumentsWereTruncated: false
                ))
            }

            let rows = renderableRows(for: turn, includeArchivedPresentation: true)
            let conclusionAssistantID = rows.last(where: { activity in
                !AgentTranscriptToolVisibilityPolicy.shouldSuppressRow(activity) &&
                    (activity.kind == .assistant || activity.kind == .assistantInline) &&
                    AgentDisplayableText.hasDisplayableBody(activity.text)
            })?.id

            for activity in rows {
                guard activity.kind != .user else { continue }
                examinedRowCount += 1
                guard let category = conversationReplayCategory(for: activity.kind) else { continue }
                var metrics = categories[category] ?? .init()
                metrics.examinedCount += 1
                categories[category] = metrics
                if AgentTranscriptToolVisibilityPolicy.shouldSuppressRow(activity) {
                    continue
                }

                switch activity.kind {
                case .assistant, .assistantInline:
                    guard AgentDisplayableText.hasDisplayableBody(activity.text) else { continue }
                    let trimmed = activity.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let line = "<assistant>\(trimmed)</assistant>"
                    appendItem(BoundedReplayItem(
                        category: .assistant,
                        line: line,
                        unboundedLineUTF8Bytes: line.utf8.count,
                        omissionPriority: activity.id == conclusionAssistantID ? .conclusionAssistant : .intermediateAssistant,
                        emittedToolArgumentCharacters: 0,
                        toolArgumentsWereTruncated: false
                    ))
                case .toolCall:
                    guard let toolName = AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(activity.toolName) else { continue }
                    let args = activity.toolArgsJSON ?? ""
                    let originalCharacterCount = args.count
                    originalToolArgumentCharacters += originalCharacterCount
                    let emittedPrefix = String(args.prefix(budget.maxToolArgumentCharacters))
                    let omittedCharacterCount = max(0, originalCharacterCount - emittedPrefix.count)
                    let emittedArgs: String = if omittedCharacterCount > 0 {
                        emittedPrefix + conversationReplayToolArgumentTruncationMarker(
                            omittedCharacterCount: omittedCharacterCount
                        )
                    } else {
                        args
                    }
                    let line = emittedArgs.isEmpty
                        ? "<tool_call name=\"\(toolName)\"/>"
                        : "<tool_call name=\"\(toolName)\">\(emittedArgs)</tool_call>"
                    let unboundedLine = args.isEmpty
                        ? "<tool_call name=\"\(toolName)\"/>"
                        : "<tool_call name=\"\(toolName)\">\(args)</tool_call>"
                    appendItem(BoundedReplayItem(
                        category: .toolCall,
                        line: line,
                        unboundedLineUTF8Bytes: unboundedLine.utf8.count,
                        omissionPriority: .toolCall,
                        emittedToolArgumentCharacters: emittedPrefix.count,
                        toolArgumentsWereTruncated: omittedCharacterCount > 0
                    ))
                case .toolResult:
                    guard let toolName = AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(activity.toolName) else { continue }
                    let line = "<tool_result name=\"\(toolName)\"/>"
                    appendItem(BoundedReplayItem(
                        category: .toolResult,
                        line: line,
                        unboundedLineUTF8Bytes: line.utf8.count,
                        omissionPriority: .toolResult,
                        emittedToolArgumentCharacters: 0,
                        toolArgumentsWereTruncated: false
                    ))
                case .system:
                    let line = "<system>\(activity.text)</system>"
                    appendItem(BoundedReplayItem(
                        category: .system,
                        line: line,
                        unboundedLineUTF8Bytes: line.utf8.count,
                        omissionPriority: .context,
                        emittedToolArgumentCharacters: 0,
                        toolArgumentsWereTruncated: false
                    ))
                case .error:
                    let line = "<error>\(activity.text)</error>"
                    appendItem(BoundedReplayItem(
                        category: .error,
                        line: line,
                        unboundedLineUTF8Bytes: line.utf8.count,
                        omissionPriority: .context,
                        emittedToolArgumentCharacters: 0,
                        toolArgumentsWereTruncated: false
                    ))
                case .user, .thinking:
                    break
                }
            }
        }

        let unboundedOutputUTF8Bytes = conversationReplayOutputUTF8Bytes(
            lineUTF8Bytes: items.map(\.unboundedLineUTF8Bytes)
        )
        let userLineUTF8Bytes = items
            .filter { $0.category == .user }
            .map(\.line.utf8.count)
        let essentialUserOutputUTF8Bytes = conversationReplayOutputUTF8Bytes(
            lineUTF8Bytes: userLineUTF8Bytes
        )
        let essentialOverflowUTF8Bytes = max(
            0,
            essentialUserOutputUTF8Bytes - budget.maxOutputUTF8Bytes
        )

        let omissionCandidates = items.indices
            .filter { items[$0].omissionPriority != nil }
            .sorted { lhs, rhs in
                let lhsPriority = items[lhs].omissionPriority?.rawValue ?? 0
                let rhsPriority = items[rhs].omissionPriority?.rawValue ?? 0
                if lhsPriority == rhsPriority {
                    return lhs < rhs
                }
                return lhsPriority > rhsPriority
            }

        var droppedIndices = Set<Int>()
        var retainedLineUTF8Bytes = items.reduce(0) { $0 + $1.line.utf8.count }
        var retainedLineCount = items.count

        func projectedOutputUTF8Bytes() -> Int {
            let omissionMarkerBytes = droppedIndices.isEmpty
                ? nil
                : conversationReplayOmissionMarker(omittedRowCount: droppedIndices.count).utf8.count
            let essentialMarkerBytes = essentialOverflowUTF8Bytes > 0
                ? conversationReplayEssentialOverflowMarker.utf8.count
                : nil
            let markerBytes = [omissionMarkerBytes, essentialMarkerBytes].compactMap(\.self)
            return conversationReplayOutputUTF8Bytes(
                totalLineUTF8Bytes: retainedLineUTF8Bytes + markerBytes.reduce(0, +),
                lineCount: retainedLineCount + markerBytes.count
            )
        }

        for index in omissionCandidates where projectedOutputUTF8Bytes() > budget.maxOutputUTF8Bytes {
            droppedIndices.insert(index)
            retainedLineUTF8Bytes -= items[index].line.utf8.count
            retainedLineCount -= 1
        }

        var writer = ConversationReplayWriter()
        var emittedToolArgumentCharacters = 0
        for (index, item) in items.enumerated() {
            var metrics = categories[item.category] ?? .init()
            if droppedIndices.contains(index) {
                metrics.emittedCount -= 1
                metrics.omittedCount += 1
            } else {
                writer.appendLine(item.line)
                metrics.emittedUTF8Bytes += item.line.utf8.count
                emittedToolArgumentCharacters += item.emittedToolArgumentCharacters
                if item.toolArgumentsWereTruncated {
                    truncatedToolCallCount += 1
                }
            }
            categories[item.category] = metrics
        }
        if !droppedIndices.isEmpty {
            writer.appendLine(conversationReplayOmissionMarker(omittedRowCount: droppedIndices.count))
        }
        if essentialOverflowUTF8Bytes > 0 {
            writer.appendLine(conversationReplayEssentialOverflowMarker)
        }

        return AgentConversationReplaySerialization(
            text: writer.text,
            metrics: AgentConversationReplayMetrics(
                mode: .bounded,
                turnCount: transcript.turns.count,
                examinedRowCount: examinedRowCount,
                unboundedOutputUTF8Bytes: unboundedOutputUTF8Bytes,
                outputUTF8Bytes: writer.utf8ByteCount,
                userAuthoredUTF8Bytes: userAuthoredUTF8Bytes,
                originalToolArgumentCharacters: originalToolArgumentCharacters,
                emittedToolArgumentCharacters: emittedToolArgumentCharacters,
                truncatedToolCallCount: truncatedToolCallCount,
                omittedRowCount: droppedIndices.count,
                essentialOverflowUTF8Bytes: essentialOverflowUTF8Bytes,
                finalOverBudgetUTF8Bytes: max(0, writer.utf8ByteCount - budget.maxOutputUTF8Bytes),
                categories: categories
            )
        )
    }

    private static func emptyConversationReplayCategoryMetrics() -> [AgentConversationReplayCategory: AgentConversationReplayCategoryMetrics] {
        Dictionary(uniqueKeysWithValues: AgentConversationReplayCategory.allCases.map { ($0, .init()) })
    }

    private static func conversationReplayCategory(
        for kind: AgentChatItemKind
    ) -> AgentConversationReplayCategory? {
        switch kind {
        case .user: .user
        case .assistant, .assistantInline: .assistant
        case .toolCall: .toolCall
        case .toolResult: .toolResult
        case .system: .system
        case .error: .error
        case .thinking: nil
        }
    }

    private static func conversationReplayOutputUTF8Bytes(lineUTF8Bytes: [Int]) -> Int {
        conversationReplayOutputUTF8Bytes(
            totalLineUTF8Bytes: lineUTF8Bytes.reduce(0, +),
            lineCount: lineUTF8Bytes.count
        )
    }

    private static func conversationReplayOutputUTF8Bytes(
        totalLineUTF8Bytes: Int,
        lineCount: Int
    ) -> Int {
        totalLineUTF8Bytes + max(0, lineCount - 1)
    }

    private static func conversationReplayToolArgumentTruncationMarker(
        omittedCharacterCount: Int
    ) -> String {
        "[replay_tool_arguments_truncated omitted_characters=\(omittedCharacterCount)]"
    }

    private static func conversationReplayOmissionMarker(omittedRowCount: Int) -> String {
        "<system>[replay_rows_omitted count=\(omittedRowCount)]</system>"
    }

    private static let conversationReplayEssentialOverflowMarker =
        "<system>[replay_budget_exceeded_by_user_text user_text_preserved=true]</system>"

    // MARK: - Fork Transcript XML (priority-based budget)

    /// Drop-priority tiers for fork transcript items (higher number = dropped first).
    private enum ForkItemDropPriority: Int, Comparable {
        /// User messages and conclusion assistant messages (last assistant per turn).
        case essential = 0
        /// System summaries and error messages.
        case context = 1
        /// Non-conclusion assistant messages (intermediate narration that survived earlier filtering).
        case supplemental = 2
        /// Tool call previews — lowest priority, dropped first.
        case toolCall = 3

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct ForkItem {
        enum Payload {
            case tagged(tag: String, text: String)
            case rawXML(String)
        }

        let pos: Int
        let payload: Payload
        let dropPriority: ForkItemDropPriority
        let turnID: UUID?
    }

    static func buildForkTranscriptXML(
        from transcript: AgentTranscript,
        upToRowID: UUID? = nil,
        maxTranscriptItems: Int = 200,
        maxToolArgsCharacters: Int = 2000,
        preserveIntermediateAssistantNarration: Bool = false
    ) -> String {
        let entries = handoffExportEntries(
            from: transcript,
            upToRowID: upToRowID,
            preserveIntermediateAssistantNarration: preserveIntermediateAssistantNarration
        )
        logHandoffDebug("buildForkTranscriptXML entries=\(entries.count) transcriptTurns=\(transcript.turns.count) upToRowID=\(upToRowID?.uuidString ?? "nil") preserveIntermediateAssistantNarration=\(preserveIntermediateAssistantNarration)")

        // --- Phase 1: Flatten entries into prioritized fork items ---

        // First pass: identify conclusion assistant entries (last assistant per turn).
        var lastAssistantIndexByTurn: [UUID: Int] = [:]
        var flatIndex = 0
        for entry in entries {
            for row in entry.xmlItems {
                if row.hasDisplayableAssistantBody,
                   let turnID = entry.turnID
                {
                    lastAssistantIndexByTurn[turnID] = flatIndex
                }
                flatIndex += 1
            }
        }
        let conclusionIndices = Set(lastAssistantIndexByTurn.values)

        // Second pass: build fork items with priorities.
        var forkItems: [ForkItem] = []
        flatIndex = 0
        var pos = 0
        for entry in entries {
            let tid = entry.turnID
            for row in entry.xmlItems {
                defer { flatIndex += 1 }
                switch row.kind {
                case .user:
                    forkItems.append(ForkItem(pos: pos, payload: .tagged(tag: "user", text: row.text), dropPriority: .essential, turnID: tid))
                    pos += 1
                case .assistant, .assistantInline:
                    guard row.hasDisplayableAssistantBody else { continue }
                    let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isConclusion = conclusionIndices.contains(flatIndex)
                    forkItems.append(ForkItem(pos: pos, payload: .tagged(tag: "assistant", text: trimmed), dropPriority: isConclusion ? .essential : .supplemental, turnID: tid))
                    pos += 1
                case .system:
                    let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    forkItems.append(ForkItem(pos: pos, payload: .tagged(tag: "system", text: trimmed), dropPriority: .context, turnID: tid))
                    pos += 1
                case .error:
                    let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    forkItems.append(ForkItem(pos: pos, payload: .tagged(tag: "error", text: trimmed), dropPriority: .context, turnID: tid))
                    pos += 1
                case .toolCall:
                    guard !AgentTranscriptToolVisibilityPolicy.shouldSuppressRow(row),
                          let toolName = AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(row.toolName) else { continue }
                    let args = truncateArgs(row.toolArgsJSON, max: maxToolArgsCharacters)
                    let xml = args.isEmpty
                        ? "<tool_call name=\"\(toolName)\"/>"
                        : "<tool_call name=\"\(toolName)\">\(args)</tool_call>"
                    forkItems.append(ForkItem(pos: pos, payload: .rawXML(xml), dropPriority: .toolCall, turnID: tid))
                    pos += 1
                case .toolResult, .thinking:
                    break
                }
            }
        }

        /// --- Phase 2: Fit within budget by dropping lowest-importance items first ---
        ///
        /// Non-essential tiers (toolCall, supplemental, context) are dropped individually,
        /// oldest first. Essential items are dropped in turn-groups so a user prompt is
        /// never orphaned from its conclusion assistant (or vice versa).
        func renderedOutputCount(excluding dropIndices: Set<Int>) -> Int {
            var count = 0
            var lastWasSystem = false
            for (index, item) in forkItems.enumerated() where !dropIndices.contains(index) {
                switch item.payload {
                case let .tagged(tag, _):
                    if tag == "system", lastWasSystem {
                        continue
                    }
                    count += 1
                    lastWasSystem = (tag == "system")
                case .rawXML:
                    count += 1
                    lastWasSystem = false
                }
            }
            return count
        }

        var surviving = forkItems
        var droppedCount = 0
        let initialRenderedCount = renderedOutputCount(excluding: [])
        var survivingRenderedCount = initialRenderedCount
        if initialRenderedCount > maxTranscriptItems {
            // Step 1: Drop non-essential items oldest-first by tier.
            let nonEssentialSorted = forkItems.indices
                .filter { forkItems[$0].dropPriority != .essential }
                .sorted { a, b in
                    if forkItems[a].dropPriority != forkItems[b].dropPriority {
                        return forkItems[a].dropPriority > forkItems[b].dropPriority
                    }
                    return a < b
                }
            var dropIndices = Set<Int>()
            var currentRendered = initialRenderedCount
            for idx in nonEssentialSorted {
                dropIndices.insert(idx)
                currentRendered = renderedOutputCount(excluding: dropIndices)
                if currentRendered <= maxTranscriptItems { break }
            }

            // Step 2: If still over budget, drop essential items in whole-turn groups
            // (oldest turns first) so user+conclusion pairs stay together.
            if currentRendered > maxTranscriptItems {
                // Group essential indices by turnID, ordered by first appearance.
                var turnOrder: [UUID] = []
                var essentialByTurn: [UUID: [Int]] = [:]
                for idx in forkItems.indices where forkItems[idx].dropPriority == .essential {
                    guard let turnID = forkItems[idx].turnID else { continue }
                    if essentialByTurn[turnID] == nil { turnOrder.append(turnID) }
                    essentialByTurn[turnID, default: []].append(idx)
                }
                for turnID in turnOrder {
                    guard currentRendered > maxTranscriptItems else { break }
                    for idx in essentialByTurn[turnID, default: []] {
                        dropIndices.insert(idx)
                    }
                    currentRendered = renderedOutputCount(excluding: dropIndices)
                }
            }

            droppedCount = dropIndices.count
            survivingRenderedCount = currentRendered
            surviving = forkItems.enumerated().compactMap { i, item in
                dropIndices.contains(i) ? nil : item
            }
        }

        logHandoffDebug("buildForkTranscriptXML items=\(forkItems.count) rendered=\(initialRenderedCount) surviving=\(surviving.count) survivingRendered=\(survivingRenderedCount) dropped=\(droppedCount)")

        // --- Phase 3: Render survivors in chronological order ---
        enum ForkTranscriptOutput {
            case tagged(tag: String, text: String)
            case rawXML(String)
        }
        var outputs: [ForkTranscriptOutput] = []
        func appendOutput(_ output: ForkTranscriptOutput) {
            switch output {
            case let .tagged(tag, text):
                if tag == "system",
                   case let .tagged(lastTag, lastText)? = outputs.last,
                   lastTag == "system"
                {
                    outputs[outputs.count - 1] = .tagged(tag: "system", text: lastText + "\n" + text)
                } else {
                    outputs.append(.tagged(tag: tag, text: text))
                }
            case .rawXML:
                outputs.append(output)
            }
        }

        for item in surviving {
            switch item.payload {
            case let .tagged(tag, text):
                appendOutput(.tagged(tag: tag, text: text))
            case let .rawXML(xml):
                appendOutput(.rawXML(xml))
            }
        }

        var lines = ["<transcript>"]
        for output in outputs {
            switch output {
            case let .tagged(tag, text):
                lines.append("<\(tag)>\(text)</\(tag)>")
            case let .rawXML(xml):
                lines.append(xml)
            }
        }
        if droppedCount > 0 {
            lines.append("<note>\(droppedCount) item\(droppedCount == 1 ? "" : "s") omitted to fit \(maxTranscriptItems) item budget.</note>")
        }
        lines.append("</transcript>")
        return lines.joined(separator: "\n")
    }

    /// Builds a spartan XML transcript for MCP log monitoring.
    ///
    /// This reuses the handoff export/projection pipeline for consistency and bounded
    /// output, but preserves intermediate assistant narration so `get_log` remains a
    /// faithful chronological monitor unless entries are explicitly dropped by budget.
    static func buildSpartanLogXML(
        from transcript: AgentTranscript,
        maxTranscriptItems: Int = 200,
        maxToolArgsCharacters: Int = 2000
    ) -> String {
        buildForkTranscriptXML(
            from: transcript,
            maxTranscriptItems: maxTranscriptItems,
            maxToolArgsCharacters: maxToolArgsCharacters,
            preserveIntermediateAssistantNarration: true
        )
    }

    static func buildHandoffTranscriptItems(from transcript: AgentTranscript, upToRowID: UUID) -> [AgentChatItem] {
        handoffExportEntries(from: transcript, upToRowID: upToRowID).compactMap(\.migratedItem).enumerated().map { index, item in
            var copy = item
            copy.isStreaming = false
            copy.sequenceIndex = index
            return copy
        }
    }

    /// Returns true when `rowID` belongs to the same projected row universe accepted
    /// by handoff export cutoff handling. This intentionally checks the materialized
    /// handoff projection (including hidden grouped-history activity IDs), rather
    /// than the raw/full transcript rows.
    static func isValidHandoffExportCutoffRowID(_ rowID: UUID, in transcript: AgentTranscript) -> Bool {
        handoffExportCutoffRowIDs(from: transcript).contains(rowID)
    }

    private static func handoffExportCutoffRowIDs(from transcript: AgentTranscript) -> Set<UUID> {
        let materialized = AgentTranscriptPolicyPipeline.handoffTranscript(
            from: transcript,
            upToRowID: nil
        )
        let projection = materialized.projection
        let blocks = projection.archivedBlocks + projection.workingBlocks
        var rowIDs = Set<UUID>()
        for block in blocks {
            if block.kind == .groupedHistory {
                rowIDs.formUnion(block.activityIDs)
            } else if block.kind == .standaloneTool {
                rowIDs.formUnion(block.rows.map(\.id))
            } else {
                rowIDs.formUnion(block.rows.lazy.filter { $0.kind != .thinking }.map(\.id))
            }
        }
        return rowIDs
    }

    private struct HandoffExportEntry {
        let migratedItem: AgentChatItem?
        let sourceRowID: UUID?
        let xmlItems: [AgentChatItem]
        let turnID: UUID?
        /// True when this entry represents tool activity (raw tool call or grouped history summary).
        /// Used by the intermediate-assistant filter to detect tool boundaries.
        let isToolBoundary: Bool
    }

    /// Returns the turns included in a handoff export, sliced at the turn containing `upToRowID`.
    /// If `upToRowID` is nil, all turns are included.
    static func turnsForExport(
        from transcript: AgentTranscript,
        upToRowID: UUID?
    ) -> [AgentTranscriptTurn] {
        guard let upToRowID else { return transcript.turns }
        // Find the turn that contains the target row and include it and all prior turns.
        // Check activity IDs, request IDs, and compacted summary IDs so we don't miss
        // synthetic rows from already-compacted turns.
        for (index, turn) in transcript.turns.enumerated() {
            var rowIDs = turn.allActivities.map(\.id)
            if let requestID = turn.request?.id {
                rowIDs.append(requestID)
            }
            if let summaryItemID = turn.summary?.middleSummaryItemID {
                rowIDs.append(summaryItemID)
            }
            if turn.conclusionActivityID == nil, turn.summary != nil {
                rowIDs.append(deterministicConclusionItemID(for: turn.id))
            }
            if rowIDs.contains(upToRowID) {
                return Array(transcript.turns.prefix(through: index))
            }
        }
        // Row not found — fall back to full transcript.
        return transcript.turns
    }

    private static func handoffExportEntries(
        from transcript: AgentTranscript,
        upToRowID: UUID?,
        preserveIntermediateAssistantNarration: Bool = false
    ) -> [HandoffExportEntry] {
        let materialized = AgentTranscriptPolicyPipeline.handoffTranscript(
            from: transcript,
            upToRowID: upToRowID
        )
        let projection = materialized.projection
        let blocks = projection.archivedBlocks + projection.workingBlocks
        // Build turn lookup for rewriting baked summary text in handoff
        let turnsByID = Dictionary(uniqueKeysWithValues: materialized.transcript.turns.map { ($0.id, $0) })
        // Collect collapsedSummary structs by turnID so we can reformat baked system rows
        var collapsedSummaryByTurnID: [UUID: AgentTranscriptGroupedHistorySummary] = [:]
        for turn in materialized.transcript.turns {
            for span in turn.responseSpans {
                if let cs = span.collapsedSummary {
                    collapsedSummaryByTurnID[turn.id] = cs
                    break
                }
            }
        }
        logHandoffDebug("handoffExportEntries blocks=\(blocks.count) archived=\(projection.archivedBlocks.count) working=\(projection.workingBlocks.count)")
        var entries: [HandoffExportEntry] = []
        for block in blocks {
            logHandoffDebug("block kind=\(block.kind) rows=\(block.rows.count) groupedSections=\(block.groupedHistory?.sections.count ?? 0) activityIDs=\(block.activityIDs.count)")
            if block.kind == .groupedHistory {
                if let summary = block.groupedHistory?.summary,
                   let summaryItem = groupedHistorySummaryItem(for: block, summary: summary)
                {
                    logHandoffDebug("groupedHistory summary hiddenTools=\(summary.hiddenToolCardCount) hiddenAssistant=\(summary.hiddenAssistantCount) hiddenProgress=\(summary.hiddenProgressCount) hiddenNotes=\(summary.hiddenNoteCount)")
                    entries.append(HandoffExportEntry(
                        migratedItem: summaryItem,
                        sourceRowID: nil,
                        xmlItems: [summaryItem],
                        turnID: block.turnID,
                        isToolBoundary: true
                    ))
                }

                if let upToRowID,
                   block.activityIDs.contains(upToRowID)
                {
                    logHandoffDebug("cutoff matched hidden groupedHistory activity currentEntries=\(entries.count)")
                    return filterHandoffEntries(
                        entries,
                        preserveIntermediateAssistantNarration: preserveIntermediateAssistantNarration
                    )
                }
            }
            // Standalone tool blocks only have .toolResult rows (no .toolCall rows).
            // For XML export, synthesize a <tool_call> preview from the result metadata.
            // For transcript migration, preserve the completion/result state, but use the
            // same sanitized tool-result shape we persist rather than the full live payload.
            if block.kind == .standaloneTool {
                let migratedToolRow = handoffMigratedStandaloneToolItem(for: block)
                let toolPreviewItem = groupedHistoryToolPreviewItem(for: block)
                if let toolPreviewItem {
                    logHandoffDebug("standaloneTool synthesized toolCall tool=\(toolPreviewItem.toolName ?? "nil")")
                }
                if migratedToolRow != nil || toolPreviewItem != nil {
                    entries.append(HandoffExportEntry(
                        migratedItem: migratedToolRow,
                        sourceRowID: migratedToolRow?.id ?? block.rows.first?.id,
                        xmlItems: toolPreviewItem.map { [$0] } ?? [],
                        turnID: block.turnID,
                        isToolBoundary: true
                    ))
                }
                if let upToRowID, block.rows.contains(where: { $0.id == upToRowID }) {
                    logHandoffDebug("cutoff matched standaloneTool block currentEntries=\(entries.count)")
                    return filterHandoffEntries(
                        entries,
                        preserveIntermediateAssistantNarration: preserveIntermediateAssistantNarration
                    )
                }
                continue
            }
            for row in block.rows.sorted(by: { exportRowOrder(lhs: $0, rhs: $1) }) {
                if AgentTranscriptToolVisibilityPolicy.shouldSuppressRow(row) {
                    continue
                }
                if row.kind == .thinking {
                    continue
                }
                // Rewrite baked system summary rows with handoff-friendly text
                let emittedRow: AgentChatItem
                let isSummaryRow: Bool
                if row.kind == .system {
                    let handoffText: String? = {
                        // Prefer collapsedSummary with toolSummary (has tool names, narration)
                        if let cs = collapsedSummaryByTurnID[block.turnID],
                           cs.toolSummary != nil
                        {
                            return AgentTranscriptSummaryTextFormatter.groupedHistoryHandoffText(summary: cs)
                        }
                        // Fall back to turn summary if it has tool data
                        if let turn = turnsByID[block.turnID],
                           let summary = turn.summary,
                           !summary.notableToolNames.isEmpty
                        {
                            return handoffMiddleSummaryText(from: summary)
                        }
                        // No quality data — keep original text as-is
                        return nil
                    }()
                    if let handoffText {
                        var rewritten = row
                        rewritten.text = handoffText
                        emittedRow = rewritten
                        isSummaryRow = true
                    } else {
                        emittedRow = row
                        isSummaryRow = false
                    }
                } else {
                    emittedRow = row
                    isSummaryRow = false
                }
                entries.append(HandoffExportEntry(
                    migratedItem: emittedRow,
                    sourceRowID: row.id,
                    xmlItems: [emittedRow],
                    turnID: block.turnID,
                    isToolBoundary: row.kind == .toolCall || isSummaryRow
                ))
                if let upToRowID, row.id == upToRowID {
                    logHandoffDebug("cutoff matched row kind=\(row.kind) seq=\(row.sequenceIndex) currentEntries=\(entries.count)")
                    return filterHandoffEntries(
                        entries,
                        preserveIntermediateAssistantNarration: preserveIntermediateAssistantNarration
                    )
                }
            }
        }
        return filterHandoffEntries(
            entries,
            preserveIntermediateAssistantNarration: preserveIntermediateAssistantNarration
        )
    }

    // MARK: - Handoff Entry Filtering

    /// Post-processes handoff entries to reduce noise in the exported transcript.
    /// 1. Drops summary-only tool results (no actionable content)
    /// 2. Drops internal diagnostic error items ([ede_diagnostic] prefix)
    /// 3. Filters intermediate assistant narration within each turn unless log export requests faithful narration
    private static func filterHandoffEntries(
        _ entries: [HandoffExportEntry],
        preserveIntermediateAssistantNarration: Bool = false
    ) -> [HandoffExportEntry] {
        // Pass 1: Drop summary-only tool results and diagnostic errors
        let itemFiltered = entries.filter { entry in
            guard let item = entry.xmlItems.first else { return true }
            // Drop [ede_diagnostic] error items
            if item.kind == .error,
               item.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[ede_diagnostic]")
            {
                return false
            }
            // Drop summary-only tool results
            if item.kind == .toolResult, isSummaryOnlyToolResult(item) {
                return false
            }
            return true
        }
        // Pass 2: Filter intermediate assistant narration per turn for compact handoff.
        guard !preserveIntermediateAssistantNarration else { return itemFiltered }
        return filterIntermediateAssistantNarration(itemFiltered)
    }

    private static func isSummaryOnlyToolResult(_ item: AgentChatItem) -> Bool {
        guard item.kind == .toolResult else { return false }
        guard let json = item.toolResultJSON ?? (item.text.isEmpty ? nil : item.text) else { return false }
        return json.contains("\"summary_only\":true") || json.contains("\"summary_only\": true")
    }

    /// Filters intermediate assistant narration within each turn.
    ///
    /// Within a turn's sequence, assistant messages are classified by position relative
    /// to tool call boundaries:
    /// - First assistant (before any tools): kept (sets intent)
    /// - Intermediate (tools before, not the last assistant): dropped
    /// - Last intermediate: truncated (~1 line)
    /// - Last assistant in turn: kept in full (conclusion)
    private static func filterIntermediateAssistantNarration(_ entries: [HandoffExportEntry]) -> [HandoffExportEntry] {
        // Group entry indices by turnID
        var turnSegments: [[Int]] = []
        var currentTurnID: UUID?
        var currentSegment: [Int] = []
        for (index, entry) in entries.enumerated() {
            if entry.turnID != currentTurnID {
                if !currentSegment.isEmpty {
                    turnSegments.append(currentSegment)
                }
                currentTurnID = entry.turnID
                currentSegment = [index]
            } else {
                currentSegment.append(index)
            }
        }
        if !currentSegment.isEmpty {
            turnSegments.append(currentSegment)
        }

        var dropIndices = Set<Int>()
        var truncateIndices = Set<Int>()

        for segment in turnSegments {
            // Identify assistant and tool-call positions within this turn
            var assistantIndices: [Int] = []
            var toolBeforeSeen = false
            var hasToolBefore = Set<Int>()

            for i in segment {
                let entry = entries[i]
                if isDisplayableAssistantEntry(entry) {
                    assistantIndices.append(i)
                    if toolBeforeSeen { hasToolBefore.insert(i) }
                } else if entry.isToolBoundary {
                    toolBeforeSeen = true
                }
            }

            // Scan backwards to find which assistants have tools after them
            var toolAfterSeen = false
            var hasToolAfter = Set<Int>()
            for i in segment.reversed() {
                let entry = entries[i]
                if isDisplayableAssistantEntry(entry) {
                    if toolAfterSeen { hasToolAfter.insert(i) }
                } else if entry.isToolBoundary {
                    toolAfterSeen = true
                }
            }

            // Intermediate = has tool before AND is not the last assistant in the turn.
            // The last assistant is always the conclusion (kept in full).
            guard let lastAssistant = assistantIndices.last else { continue }
            let intermediates = assistantIndices.filter {
                hasToolBefore.contains($0) && $0 != lastAssistant
            }
            guard !intermediates.isEmpty else { continue }

            // Last intermediate gets truncated; all others are dropped
            for (offset, idx) in intermediates.enumerated() {
                if offset == intermediates.count - 1 {
                    truncateIndices.insert(idx)
                } else {
                    dropIndices.insert(idx)
                }
            }
        }

        guard !dropIndices.isEmpty || !truncateIndices.isEmpty else { return entries }

        logHandoffDebug("filterIntermediateAssistant dropped=\(dropIndices.count) truncated=\(truncateIndices.count)")
        return entries.enumerated().compactMap { index, entry in
            if dropIndices.contains(index) { return nil }
            if truncateIndices.contains(index) {
                return truncateAssistantEntry(entry)
            }
            return entry
        }
    }

    #if DEBUG
        static func debugFilterIntermediateAssistantNarrationForTesting(_ rows: [AgentChatItem], turnID: UUID = UUID()) -> [AgentChatItem] {
            let entries = rows.map { row in
                HandoffExportEntry(
                    migratedItem: row,
                    sourceRowID: row.id,
                    xmlItems: [row],
                    turnID: turnID,
                    isToolBoundary: row.kind == .toolCall
                )
            }
            return filterIntermediateAssistantNarration(entries).flatMap(\.xmlItems)
        }
    #endif

    private static func isDisplayableAssistantEntry(_ entry: HandoffExportEntry) -> Bool {
        guard let item = entry.xmlItems.first else { return false }
        return item.hasDisplayableAssistantBody
    }

    private static func truncateAssistantEntry(_ entry: HandoffExportEntry) -> HandoffExportEntry {
        let truncatedItems = entry.xmlItems.map { item -> AgentChatItem in
            guard item.kind == .assistant || item.kind == .assistantInline else { return item }
            var copy = item
            copy.text = compactConclusionText(from: item.text) ?? ""
            return copy
        }
        var truncatedMigrated = entry.migratedItem
        if let mi = entry.migratedItem,
           mi.kind == .assistant || mi.kind == .assistantInline
        {
            truncatedMigrated = mi
            truncatedMigrated?.text = compactConclusionText(from: mi.text) ?? ""
        }
        return HandoffExportEntry(
            migratedItem: truncatedMigrated,
            sourceRowID: entry.sourceRowID,
            xmlItems: truncatedItems,
            turnID: entry.turnID,
            isToolBoundary: entry.isToolBoundary
        )
    }

    private static func groupedHistorySummaryItem(
        for block: AgentTranscriptRenderBlock,
        summary: AgentTranscriptGroupedHistorySummary
    ) -> AgentChatItem? {
        let text = AgentTranscriptSummaryTextFormatter.groupedHistoryHandoffText(summary: summary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let childRows = block.groupedHistory?.sections
            .flatMap(\.childBlocks)
            .flatMap(\.rows) ?? []
        let timestamp = childRows.map(\.timestamp).min() ?? Date()
        let sequenceIndex = childRows.map(\.sequenceIndex).min() ?? Int.max
        return AgentChatItem(
            timestamp: timestamp,
            kind: .system,
            text: text,
            sequenceIndex: sequenceIndex,
            isStreaming: false
        )
    }

    /// Builds handoff-friendly text from a compacted turn summary (for middleSummary blocks).
    /// Mirrors the format of `groupedHistoryHandoffText`: title + narration + tool names.
    private static func handoffMiddleSummaryText(from summary: AgentTranscriptTurnSummary) -> String {
        var parts: [String] = []
        // Title from tool semantic classification
        let semantic = ClusterToolCategory.summaryTitleSemantic(
            toolNames: summary.notableToolNames,
            toolNameCounts: [:],
            containsRunningWork: false
        )
        switch semantic {
        case .running: parts.append("Running")
        case .exploredAndEdited: parts.append("Explored & edited")
        case .madeChanges: parts.append("Made changes")
        case .ranCommands: parts.append("Ran commands")
        case .agentActivity: parts.append("Agent activity")
        case .exploredCodebase: parts.append("Explored codebase")
        case .toolActivity: parts.append("Tool activity")
        case .none: parts.append(summary.toolCount == 1 ? "Update" : "Updates")
        }
        // Narration from conclusion
        if let narration = summary.compactConclusionText ?? summary.conclusionText {
            let trimmed = narration.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(AgentTranscriptSummaryTextFormatter.wordBoundaryTruncate(trimmed, maxLength: 150))
            }
        }
        // Tool names only (no counts, no paths)
        if !summary.notableToolNames.isEmpty {
            parts.append(summary.notableToolNames.prefix(4).joined(separator: ", "))
        }
        return parts.joined(separator: " • ")
    }

    private static func exportRowOrder(lhs: AgentChatItem, rhs: AgentChatItem) -> Bool {
        if lhs.sequenceIndex == rhs.sequenceIndex {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.sequenceIndex < rhs.sequenceIndex
    }

    private static func groupedHistoryLocalizedExportEntries(
        for block: AgentTranscriptRenderBlock
    ) -> [HandoffExportEntry] {
        let childBlocks = block.groupedHistory?.sections
            .flatMap(\.childBlocks) ?? []
        logHandoffDebug("groupedHistoryLocalizedExportEntries childBlocks=\(childBlocks.count) childKinds=\(childBlocks.map(\.kind.rawValue).joined(separator: ","))")
        var entries: [HandoffExportEntry] = []
        for childBlock in childBlocks {
            logHandoffDebug("localized child kind=\(childBlock.kind) rows=\(childBlock.rows.count) rowKinds=\(childBlock.rows.map(\.kind.rawValue).joined(separator: ","))")
            switch childBlock.kind {
            case .standaloneAssistant:
                for row in childBlock.rows where row.kind == .assistant || row.kind == .assistantInline {
                    entries.append(HandoffExportEntry(
                        migratedItem: nil,
                        sourceRowID: nil,
                        xmlItems: [row],
                        turnID: block.turnID,
                        isToolBoundary: false
                    ))
                }
            case .standaloneTool:
                guard !childBlock.rows.allSatisfy({ AgentTranscriptToolVisibilityPolicy.shouldSuppressRow($0) }) else { break }
                if let toolPreviewItem = groupedHistoryToolPreviewItem(for: childBlock) {
                    entries.append(HandoffExportEntry(
                        migratedItem: nil,
                        sourceRowID: nil,
                        xmlItems: [toolPreviewItem],
                        turnID: block.turnID,
                        isToolBoundary: true
                    ))
                }
            case .standaloneNote:
                for localizedNote in groupedHistoryLocalizedNoteItems(from: childBlock.rows) {
                    entries.append(HandoffExportEntry(
                        migratedItem: nil,
                        sourceRowID: nil,
                        xmlItems: [localizedNote],
                        turnID: block.turnID,
                        isToolBoundary: false
                    ))
                }
            case .request, .activityCluster, .groupedHistory, .middleSummary, .conclusion:
                break
            }
        }
        return entries
    }

    private static func handoffMigratedStandaloneToolItem(
        for block: AgentTranscriptRenderBlock
    ) -> AgentChatItem? {
        let visibleRows = block.rows.filter { !AgentTranscriptToolVisibilityPolicy.shouldSuppressRow($0) }
        if let toolResultRow = visibleRows.last(where: { $0.kind == .toolResult }) {
            return AgentToolResultPersistencePolicy.sanitizeItem(toolResultRow)
        }
        return visibleRows.first(where: { $0.kind == .toolCall })
    }

    private static func groupedHistoryToolPreviewItem(
        for childBlock: AgentTranscriptRenderBlock
    ) -> AgentChatItem? {
        let visibleRows = childBlock.rows.filter { !AgentTranscriptToolVisibilityPolicy.shouldSuppressRow($0) }
        let toolCallRow = visibleRows.first(where: { $0.kind == .toolCall })
        let toolResultRow = visibleRows.last(where: { $0.kind == .toolResult })
        guard let sourceRow = toolCallRow ?? toolResultRow,
              let toolName = AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(sourceRow.toolName)
        else {
            logHandoffDebug("tool preview skipped: no toolCall/toolResult row")
            return nil
        }
        let toolExecution = childBlock.rows
            .compactMap { AgentTranscriptToolNormalizer.toolExecution(for: $0) }
            .last
        if let toolExecution,
           toolExecution.status == .failed || toolExecution.status == .cancelled
        {
            logHandoffDebug("tool preview pruned tool=\(toolName) status=\(toolExecution.status.rawValue)")
            return nil
        }
        let argsJSON = localizedGroupedHistoryPreviewArgsJSON(
            from: sourceRow,
            execution: toolExecution
        )
        logHandoffDebug("tool preview emit tool=\(toolName) args=\(argsJSON ?? "nil")")
        return AgentChatItem(
            timestamp: sourceRow.timestamp,
            kind: .toolCall,
            text: "",
            toolName: toolName,
            toolArgsJSON: argsJSON,
            sequenceIndex: sourceRow.sequenceIndex,
            isStreaming: false
        )
    }

    private static func groupedHistoryLocalizedNoteItems(from rows: [AgentChatItem]) -> [AgentChatItem] {
        rows.compactMap { row in
            switch row.kind {
            case .system, .error:
                return row
            case .thinking:
                let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return AgentChatItem(
                    timestamp: row.timestamp,
                    kind: .system,
                    text: "Progress • \(trimmed)",
                    sequenceIndex: row.sequenceIndex,
                    isStreaming: false
                )
            default:
                return nil
            }
        }
    }

    private static func localizedGroupedHistoryPreviewArgsJSON(
        from sourceRow: AgentChatItem,
        execution: AgentTranscriptToolExecution?
    ) -> String? {
        var object = AgentTranscriptToolNormalizer.jsonObject(from: sourceRow.toolArgsJSON)
            ?? AgentTranscriptToolNormalizer.jsonObject(from: sourceRow.toolResultJSON)
            ?? [:]
        if let execution {
            if !execution.keyPaths.isEmpty, object["key_paths"] == nil {
                object["key_paths"] = Array(execution.keyPaths.prefix(4))
            }
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return sourceRow.toolArgsJSON ?? sourceRow.toolResultJSON
        }
        return String(data: data, encoding: .utf8) ?? sourceRow.toolArgsJSON ?? sourceRow.toolResultJSON
    }

    private static func renderableRows(for turn: AgentTranscriptTurn, includeArchivedPresentation: Bool) -> [AgentChatItem] {
        switch turn.retentionTier {
        case .full:
            var rows: [AgentChatItem] = []
            if let request = turn.request {
                rows.append(request.toItem())
            }
            rows.append(contentsOf: turn.allActivities.map { $0.toItem() })
            return rows
        case .condensed, .summary, .archived:
            return AgentTranscriptProjectionBuilder.rows(for: turn, archived: turn.retentionTier == .archived)
        }
    }

    private static func role(for item: AgentChatItem) -> AgentTranscriptActivityRole {
        switch item.kind {
        case .assistant, .assistantInline:
            .assistant
        case .toolCall, .toolResult:
            .toolExecution
        case .system:
            .system
        case .error:
            .error
        case .thinking:
            .thinking
        case .user:
            .note
        }
    }

    private static func sealsAssistantBoundary(
        for item: AgentChatItem,
        toolExecution: AgentTranscriptToolExecution? = nil
    ) -> Bool {
        guard item.kind == .toolCall || item.kind == .toolResult else { return false }
        let normalizedToolName = AgentTranscriptToolNormalizer.normalizedToolName(item.toolName) ?? ""
        switch normalizedToolName {
        case "set_status", "share_thoughts", "ask_user", "request_user_input", "apply_edits", "apply_patch":
            return true
        case "bash":
            let status = toolExecution?.status ?? AgentTranscriptToolNormalizer.status(for: item)
            switch status {
            case .pending, .running, .warning, .failed, .cancelled:
                return true
            case .success, .unknown:
                return false
            }
        default:
            return false
        }
    }

    private static func finalizeTurn(
        _ turn: inout AgentTranscriptTurn,
        priorTurns: [AgentTranscriptTurn],
        terminalState: AgentSessionRunState?,
        isCompleted: Bool
    ) {
        let activities = turn.allActivities
        turn.terminalState = terminalState ?? turn.terminalState
        turn.lastActivityAt = turn.lastActivityAt ?? activities.last?.timestamp
        if isCompleted {
            turn.completedAt = turn.completedAt ?? turn.lastActivityAt ?? turn.request?.timestamp ?? turn.startedAt
        } else {
            turn.completedAt = nil
        }
        let assistantActivities = activities.filter {
            ($0.itemKind == .assistant || $0.itemKind == .assistantInline)
                && AgentDisplayableText.hasDisplayableBody($0.text)
        }
        let lastMiddleSequenceIndex = activities.last(where: {
            $0.itemKind != .assistant && $0.itemKind != .assistantInline
        })?.sequenceIndex ?? Int.min
        let trailingAssistantActivities = assistantActivities.filter { $0.sequenceIndex > lastMiddleSequenceIndex }
        turn.conclusionActivityID = trailingAssistantActivities.reversed().first(where: \.isSubstantiveAssistant)?.id
            ?? trailingAssistantActivities.last?.id
        for index in turn.responseSpans.indices {
            turn.responseSpans[index].collapsedSummary = buildCollapsedSummary(
                for: turn.responseSpans[index],
                in: turn
            )
        }
        if isCompleted, turn.retentionTier == .full {
            let toolCount = AgentTranscriptProjectionBuilder.standaloneToolBlockCount(for: turn)
            let transcriptForAllocation = AgentTranscript(
                turns: priorTurns + [turn],
                nextSequenceIndex: (turn.request?.sequenceIndex ?? turn.allActivities.last?.sequenceIndex ?? 0) + 1
            )
            let allocatedLimit =
                AgentTranscriptProjectionBuilder.detailedToolTailLimits(for: transcriptForAllocation)[turn.id]
                    ?? min(
                        toolCount,
                        AgentTranscriptProjectionBuilder.globalDetailedToolTailLimit
                    )
            turn.frozenDetailedToolTailLimit = AgentTranscriptProjectionBuilder.groupedHistoryWouldCollapse(
                in: turn,
                detailedToolTailLimit: allocatedLimit
            ) ? allocatedLimit : nil
        } else {
            turn.frozenDetailedToolTailLimit = nil
        }
        turn.summary = buildSummary(for: turn)
    }

    fileprivate static func buildSummary(for turn: AgentTranscriptTurn) -> AgentTranscriptTurnSummary? {
        let activities = turn.allActivities
        guard turn.request != nil || !activities.isEmpty else { return nil }
        let conclusion = conclusionActivity(in: turn)
        let toolActivities = activities.filter {
            ($0.itemKind == .toolCall || $0.itemKind == .toolResult)
                && !AgentTranscriptToolVisibilityPolicy.shouldSuppressActivity($0)
        }
        let toolExecutions = latestToolExecutions(from: toolActivities)
        let notableTools = Array(NSOrderedSet(array: toolExecutions.compactMap { summarizedToolName($0.toolName) })) as? [String] ?? toolExecutions.compactMap { summarizedToolName($0.toolName) }
        let keyPaths = Array(NSOrderedSet(array: toolExecutions.flatMap(\.keyPaths))) as? [String] ?? []
        let hadWarning = toolExecutions.contains { $0.status == .warning }
        let hadError = activities.contains { $0.itemKind == .error } || toolExecutions.contains { execution in
            execution.status == .failed || execution.status == .cancelled
        }
        let middleActivities = activities.filter {
            $0.id != turn.conclusionActivityID && !AgentTranscriptToolVisibilityPolicy.shouldSuppressActivity($0)
        }
        let middleSummaryText = middleSummaryText(
            for: turn.request,
            activities: middleActivities,
            toolCount: toolExecutions.count,
            notableTools: notableTools,
            keyPaths: keyPaths,
            hadWarning: hadWarning,
            hadError: hadError
        )
        let conclusionText = conclusion?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lastUserInteractionAt = turn.request?.timestamp
        for activity in activities where isUserInteractionItem(activity.toItem()) {
            let timestamp = activity.timestamp
            lastUserInteractionAt = max(lastUserInteractionAt ?? timestamp, timestamp)
        }
        return AgentTranscriptTurnSummary(
            middleSummaryItemID: deterministicSummaryItemID(for: turn.id),
            requestText: turn.request?.text,
            conclusionText: conclusionText,
            compactConclusionText: compactConclusionText(from: conclusionText),
            middleSummaryText: middleSummaryText,
            toolCount: toolExecutions.count,
            notableToolNames: Array(notableTools.prefix(6)),
            keyPaths: Array(keyPaths.prefix(8)),
            compactedActivityCount: max(0, middleActivities.count),
            hadWarning: hadWarning,
            hadError: hadError,
            lastUserInteractionAt: lastUserInteractionAt
        )
    }

    private static func latestToolExecutions(from activities: [AgentTranscriptActivity]) -> [AgentTranscriptToolExecution] {
        var orderedExecutionIDs: [String] = []
        var latestByExecutionID: [String: AgentTranscriptToolExecution] = [:]
        for activity in activities {
            guard let execution = activity.toolExecution else { continue }
            if latestByExecutionID[execution.stableExecutionID] == nil {
                orderedExecutionIDs.append(execution.stableExecutionID)
                latestByExecutionID[execution.stableExecutionID] = execution
                continue
            }
            if let existing = latestByExecutionID[execution.stableExecutionID],
               toolStatusRank(existing.status) <= toolStatusRank(execution.status)
            {
                latestByExecutionID[execution.stableExecutionID] = mergedToolExecutionMetadata(execution, with: existing)
            } else if let existing = latestByExecutionID[execution.stableExecutionID] {
                latestByExecutionID[execution.stableExecutionID] = mergedToolExecutionMetadata(existing, with: execution)
            }
        }
        return orderedExecutionIDs.compactMap { latestByExecutionID[$0] }
    }

    private static func toolStatusRank(_ status: AgentTranscriptToolStatus) -> Int {
        switch status {
        case .pending:
            0
        case .running:
            1
        case .unknown:
            2
        case .success:
            3
        case .warning:
            4
        case .failed:
            5
        case .cancelled:
            6
        }
    }

    private static func summarizedToolName(_ rawToolName: String?) -> String? {
        guard let rawToolName else { return nil }
        let normalized = AgentTranscriptToolNormalizer.normalizedToolName(rawToolName) ?? ""
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    fileprivate static func buildCollapsedSummary(
        for span: AgentTranscriptProviderResponseSpan,
        in turn: AgentTranscriptTurn
    ) -> AgentTranscriptGroupedHistorySummary? {
        let visibleActivities = span.activities.filter {
            $0.id != turn.conclusionActivityID && !AgentTranscriptToolVisibilityPolicy.shouldSuppressActivity($0)
        }
        guard !visibleActivities.isEmpty else { return nil }
        let hiddenAssistantCount = visibleActivities.count(where: {
            ($0.itemKind == .assistant || $0.itemKind == .assistantInline)
                && AgentDisplayableText.hasDisplayableBody($0.text)
        })
        let hiddenProgressCount = visibleActivities.count(where: { $0.itemKind == .thinking })
        let hiddenNoteCount = visibleActivities.count(where: {
            $0.itemKind == .system || $0.itemKind == .error
        })
        let hiddenToolCardCount = latestToolExecutions(from: visibleActivities.filter {
            $0.itemKind == .toolCall || $0.itemKind == .toolResult
        }).count
        return AgentTranscriptGroupedHistorySummary(
            hiddenToolCardCount: hiddenToolCardCount,
            hiddenAssistantCount: hiddenAssistantCount,
            hiddenProgressCount: hiddenProgressCount,
            hiddenNoteCount: hiddenNoteCount,
            toolSummary: collapsedToolSummary(from: visibleActivities)
        )
    }

    private static func collapsedToolSummary(from activities: [AgentTranscriptActivity]) -> AgentTranscriptClusterSummary? {
        let toolExecutions = latestToolExecutions(from: activities.filter {
            ($0.itemKind == .toolCall || $0.itemKind == .toolResult)
                && !AgentTranscriptToolVisibilityPolicy.shouldSuppressActivity($0)
        })
        guard !toolExecutions.isEmpty else { return nil }
        let toolNames = Array(NSOrderedSet(array: toolExecutions.compactMap {
            summarizedToolName($0.toolName)
        })) as? [String] ?? toolExecutions.compactMap { summarizedToolName($0.toolName) }
        var toolNameCounts: [String: Int] = [:]
        for execution in toolExecutions {
            guard let toolName = summarizedToolName(execution.toolName) else { continue }
            toolNameCounts[toolName, default: 0] += 1
        }
        let keyPaths = Array(NSOrderedSet(array: toolExecutions.flatMap(\.keyPaths))) as? [String] ?? []
        let allToolNames = toolNameCounts.isEmpty ? toolNames : Array(toolNameCounts.keys.sorted())
        let narration = latestCollapsedNarrationText(from: activities)
        let shortNarration = narration.map {
            $0.count > 120 ? String($0.prefix(120)) + "…" : $0
        }
        let toolGroups = ClusterToolCategory.buildGroups(toolNames: allToolNames, counts: toolNameCounts)
        let summary = AgentTranscriptClusterSummary(
            toolCount: toolExecutions.count,
            toolNames: Array(toolNames.prefix(6)),
            toolNameCounts: toolNameCounts,
            toolGroups: toolGroups,
            keyPaths: Array(keyPaths.prefix(6)),
            containsRunningWork: toolExecutions.contains { $0.status == .running || $0.status == .pending },
            containsFailure: toolExecutions.contains { $0.status == .failed || $0.status == .cancelled },
            containsWarning: toolExecutions.contains { $0.status == .warning },
            shortNarration: shortNarration
        )
        return AgentTranscriptClusterSummary(
            toolCount: summary.toolCount,
            toolNames: summary.toolNames,
            toolNameCounts: summary.toolNameCounts,
            toolGroups: summary.toolGroups,
            keyPaths: summary.keyPaths,
            containsRunningWork: summary.containsRunningWork,
            containsFailure: summary.containsFailure,
            containsWarning: summary.containsWarning,
            shortNarration: summary.shortNarration,
            collapsedDisplay: AgentTranscriptSummaryTextFormatter.collapsedDisplay(
                for: summary,
                fallbackCount: summary.toolCount
            )
        )
    }

    private static func latestCollapsedNarrationText(from activities: [AgentTranscriptActivity]) -> String? {
        let latestAssistantText = activities.reversed().first(where: {
            ($0.itemKind == .assistant || $0.itemKind == .assistantInline)
                && AgentDisplayableText.hasDisplayableBody($0.text)
        })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let latestAssistantText {
            return latestAssistantText
        }

        let latestThinkingText = activities.reversed().first(where: {
            $0.itemKind == .thinking
        })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let latestThinkingText, !latestThinkingText.isEmpty {
            return latestThinkingText
        }
        return nil
    }

    private static func middleSummaryText(
        for request: AgentTranscriptRequestAnchor?,
        activities: [AgentTranscriptActivity],
        toolCount: Int,
        notableTools: [String],
        keyPaths: [String],
        hadWarning: Bool,
        hadError: Bool
    ) -> String? {
        guard !activities.isEmpty else { return nil }
        let assistantMessageCount = activities.count(where: {
            ($0.itemKind == .assistant || $0.itemKind == .assistantInline)
                && AgentDisplayableText.hasDisplayableBody($0.text)
        })
        var parts: [String] = []
        if toolCount > 0 {
            parts.append("\(toolCount) tool\(toolCount == 1 ? "" : "s") called")
        }
        if assistantMessageCount > 0 {
            parts.append("\(assistantMessageCount) assistant message\(assistantMessageCount == 1 ? "" : "s")")
        }
        if !keyPaths.isEmpty {
            parts.append("\(keyPaths.count) file\(keyPaths.count == 1 ? "" : "s")")
        }
        if !notableTools.isEmpty {
            parts.append(notableTools.prefix(4).joined(separator: ", "))
        }
        if hadError {
            parts.append("error")
        } else if hadWarning {
            parts.append("warning")
        }
        if parts.isEmpty, let requestText = request?.text.trimmingCharacters(in: .whitespacesAndNewlines), !requestText.isEmpty {
            parts.append("Work completed for \(requestText.prefix(80))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func deterministicSummaryItemID(for turnID: UUID) -> UUID {
        deterministicUUID(seed: turnID.uuidString + ":middle-summary")
    }

    fileprivate static func deterministicConclusionItemID(for turnID: UUID) -> UUID {
        deterministicUUID(seed: turnID.uuidString + ":compact-conclusion")
    }

    private static func deterministicSpanID(turnID: UUID, ordinal: Int) -> UUID {
        deterministicUUID(seed: turnID.uuidString + ":response-span:\(ordinal)")
    }

    private static func deterministicUUID(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    fileprivate static func compactConclusionText(from text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.count <= 220 {
            return text
        }
        let endIndex = text.index(text.startIndex, offsetBy: 220)
        return String(text[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func conclusionActivity(in turn: AgentTranscriptTurn) -> AgentTranscriptActivity? {
        guard let conclusionActivityID = turn.conclusionActivityID else { return nil }
        return turn.allActivities.first(where: { $0.id == conclusionActivityID })
    }

    private static func truncateArgs(_ rawArgs: String?, max limit: Int) -> String {
        guard let rawArgs, !rawArgs.isEmpty else { return "" }
        return rawArgs.count > limit ? String(rawArgs.prefix(limit)) + "…" : rawArgs
    }
}

private enum AgentTranscriptDurableFrontierSupport {
    static let supportedVersion = 1

    static func establishedFrontier(for transcript: AgentTranscript) -> AgentTranscriptCompactionFrontier? {
        let frozenPrefix = transcript.turns.prefix { $0.retentionTier != .full }
        guard let lastFrozenTurn = frozenPrefix.last else { return nil }
        return AgentTranscriptCompactionFrontier(
            version: supportedVersion,
            frozenPrefixTurnCount: frozenPrefix.count,
            lastFrozenTurnID: lastFrozenTurn.id
        )
    }

    static func normalizedTranscript(_ transcript: AgentTranscript) -> AgentTranscript {
        var normalized = transcript
        normalized.compactionFrontier = establishedFrontier(for: transcript)
        return normalized
    }

    static func validatedFrozenPrefixTurnCountForIncrementalReuse(in transcript: AgentTranscript) -> Int? {
        guard !transcript.turns.isEmpty else { return nil }
        guard let frontier = transcript.compactionFrontier else {
            return transcript.turns.dropLast().allSatisfy { $0.retentionTier == .full } ? 0 : nil
        }
        let frozenPrefixTurnCount = frontier.frozenPrefixTurnCount
        guard frontier.version == supportedVersion,
              frozenPrefixTurnCount > 0,
              frozenPrefixTurnCount < transcript.turns.count,
              transcript.turns.indices.contains(frozenPrefixTurnCount - 1),
              transcript.turns[frozenPrefixTurnCount - 1].id == frontier.lastFrozenTurnID,
              transcript.turns.prefix(frozenPrefixTurnCount).allSatisfy({ $0.retentionTier != .full }),
              transcript.turns.dropFirst(frozenPrefixTurnCount).dropLast().allSatisfy({ $0.retentionTier == .full })
        else {
            return nil
        }
        return frozenPrefixTurnCount
    }
}

enum AgentTranscriptCompactionMode: Equatable {
    case recomputeAll
    case preserveDurableFrontier
}

enum AgentTranscriptCompactor {
    static let targetWorkingUnitCount = 55
    static let softMaxWorkingUnitCount = 65
    static let hardMaxWorkingUnitCount = 70
    /// Storage-retention invariant: preserve full detail for the transcript suffix anchored
    /// at the earliest of the last visible tool executions. This is intentionally separate
    /// from projection's visual detailed-tool budget even though both are currently 8.
    static let protectedDetailedToolExecutionTailCount = 8

    private struct ProtectedToolTailRegion {
        let protectedTurnIDs: Set<UUID>
    }

    private struct CompactionPressure {
        let workingUnitCount: Int

        var exceedsSoftLimit: Bool {
            workingUnitCount > AgentTranscriptCompactor.softMaxWorkingUnitCount
        }

        var exceedsTargetLimit: Bool {
            workingUnitCount > AgentTranscriptCompactor.targetWorkingUnitCount
        }

        var exceedsHardLimit: Bool {
            workingUnitCount > AgentTranscriptCompactor.hardMaxWorkingUnitCount
        }

        init(transcript: AgentTranscript) {
            workingUnitCount = AgentTranscriptCompactor.estimatedWorkingUnitCount(for: transcript)
        }

        private init(workingUnitCount: Int) {
            self.workingUnitCount = workingUnitCount
        }

        func removingWorkingUnits(_ count: Int) -> CompactionPressure {
            CompactionPressure(workingUnitCount: max(0, workingUnitCount - max(0, count)))
        }
    }

    static func compact(
        _ transcript: AgentTranscript,
        mode: AgentTranscriptCompactionMode = .recomputeAll,
        protection: AgentTranscriptProjectionProtection = .none,
        enforceActualByteBackstop: Bool = true
    ) -> AgentTranscript {
        switch mode {
        case .recomputeAll:
            return AgentTranscriptDurableFrontierSupport.normalizedTranscript(
                recomputedCompaction(
                    transcript,
                    mode: mode,
                    protection: protection
                )
            )
        case .preserveDurableFrontier:
            guard let frozenPrefixTurnCount = AgentTranscriptDurableFrontierSupport.validatedFrozenPrefixTurnCountForIncrementalReuse(
                in: transcript
            ),
                frozenPrefixTurnCount > 0
            else {
                return compact(
                    transcript,
                    mode: .recomputeAll,
                    protection: protection
                )
            }
            let frozenPrefix = Array(transcript.turns.prefix(frozenPrefixTurnCount))
            // This prevention fix does not promote legacy non-full prefix turns back to `.full`.
            // When the protected tool-tail region overlaps an already-frozen prefix, reusing the
            // full frozen prefix is therefore the least destructive no-worsening behavior: it
            // preserves whatever summary/archived/recoverable legacy detail remains, while new
            // full-detail suffix turns are still protected by the recomputed compaction pass.
            let safeReusablePrefixCount = frozenPrefixTurnCount
            var compacted = recomputedCompaction(
                transcript,
                mode: mode,
                protection: protection
            )
            guard compacted.turns.count >= frozenPrefixTurnCount else {
                return AgentTranscriptDurableFrontierSupport.normalizedTranscript(compacted)
            }
            if safeReusablePrefixCount > 0 {
                compacted.turns.replaceSubrange(0 ..< safeReusablePrefixCount, with: frozenPrefix.prefix(safeReusablePrefixCount))
            }
            return AgentTranscriptDurableFrontierSupport.normalizedTranscript(compacted)
        }
    }

    private static func recomputedCompaction(
        _ transcript: AgentTranscript,
        mode: AgentTranscriptCompactionMode,
        protection: AgentTranscriptProjectionProtection
    ) -> AgentTranscript {
        #if DEBUG
            let startedAt = Date.timeIntervalSinceReferenceDate
            var downshiftIterationCount = 0
            var archiveIterationCount = 0
            var archivedTurnCount = 0
        #endif
        var copy = transcript
        var pressure = CompactionPressure(transcript: copy)
        #if DEBUG
            let initialWorkingUnitCount = pressure.workingUnitCount
        #endif
        let protectedTurnID = protection.protectedTurnID
        guard pressure.exceedsSoftLimit else {
            let trimmed = structurallyTrimmedTranscript(copy)
            #if DEBUG
                if AgentTranscriptDebugInstrumentation.isEnabled {
                    AgentTranscriptDebugInstrumentation.compactionHandler?(.init(
                        mode: mode,
                        initialWorkingUnitCount: initialWorkingUnitCount,
                        finalWorkingUnitCount: CompactionPressure(transcript: trimmed).workingUnitCount,
                        softGuardSkippedScan: true,
                        downshiftIterationCount: 0,
                        archiveIterationCount: 0,
                        archivedTurnCount: 0,
                        protectedToolTailTurnCount: 0,
                        durationMS: AgentTranscriptDebugInstrumentation.durationMS(since: startedAt)
                    ))
                }
            #endif
            return trimmed
        }
        let protectedToolTailTurnIDs = protectedToolTailRegion(in: copy).protectedTurnIDs
        while pressure.exceedsTargetLimit {
            if applyOldestTierDownshiftIfPossible(
                to: &copy,
                protectedTurnID: protectedTurnID,
                protectedToolTailTurnIDs: protectedToolTailTurnIDs
            ) {
                #if DEBUG
                    downshiftIterationCount += 1
                #endif
                pressure = CompactionPressure(transcript: copy)
                continue
            }
            guard pressure.exceedsHardLimit else {
                break
            }
            let archivedThisPass = archiveOldestEligibleSummariesIfNeeded(
                in: &copy,
                pressure: &pressure,
                protectedTurnID: protectedTurnID,
                protectedToolTailTurnIDs: protectedToolTailTurnIDs
            )
            guard archivedThisPass > 0 else {
                break
            }
            #if DEBUG
                archiveIterationCount += 1
                archivedTurnCount += archivedThisPass
            #endif
        }
        let trimmed = structurallyTrimmedTranscript(copy)
        #if DEBUG
            if AgentTranscriptDebugInstrumentation.isEnabled {
                AgentTranscriptDebugInstrumentation.compactionHandler?(.init(
                    mode: mode,
                    initialWorkingUnitCount: initialWorkingUnitCount,
                    finalWorkingUnitCount: CompactionPressure(transcript: trimmed).workingUnitCount,
                    softGuardSkippedScan: false,
                    downshiftIterationCount: downshiftIterationCount,
                    archiveIterationCount: archiveIterationCount,
                    archivedTurnCount: archivedTurnCount,
                    protectedToolTailTurnCount: protectedToolTailTurnIDs.count,
                    durationMS: AgentTranscriptDebugInstrumentation.durationMS(since: startedAt)
                ))
            }
        #endif
        return trimmed
    }

    static func estimatedWorkingUnitCount(for transcript: AgentTranscript) -> Int {
        AgentTranscriptProjectionBuilder.estimatedWorkingUnitCount(for: transcript)
    }

    private static func applyOldestTierDownshiftIfPossible(
        to transcript: inout AgentTranscript,
        protectedTurnID: UUID?,
        protectedToolTailTurnIDs: Set<UUID>
    ) -> Bool {
        guard let index = oldestTierDownshiftableTurnIndex(
            in: transcript.turns,
            protectedTurnID: protectedTurnID,
            protectedToolTailTurnIDs: protectedToolTailTurnIDs
        ) else {
            return false
        }
        switch transcript.turns[index].retentionTier {
        case .full:
            transcript.turns[index].retentionTier = .condensed
        case .condensed:
            transcript.turns[index].retentionTier = .summary
        case .summary, .archived:
            return false
        }
        return true
    }

    private static func archiveOldestEligibleSummariesIfNeeded(
        in transcript: inout AgentTranscript,
        pressure: inout CompactionPressure,
        protectedTurnID: UUID?,
        protectedToolTailTurnIDs: Set<UUID>
    ) -> Int {
        guard pressure.exceedsHardLimit, !transcript.turns.isEmpty else { return 0 }
        let lastTurnIndex = transcript.turns.count - 1
        var indicesToArchive: [Int] = []
        var releasedWorkingUnits = 0

        for index in transcript.turns.indices {
            let turn = transcript.turns[index]
            guard isArchivableSummaryTurn(
                turn,
                at: index,
                lastTurnIndex: lastTurnIndex,
                protectedTurnID: protectedTurnID,
                protectedToolTailTurnIDs: protectedToolTailTurnIDs
            ) else {
                continue
            }
            indicesToArchive.append(index)
            releasedWorkingUnits += AgentTranscriptProjectionBuilder.estimatedSummaryWorkingUnitContribution(for: turn)
            if pressure.workingUnitCount - releasedWorkingUnits <= hardMaxWorkingUnitCount {
                break
            }
        }

        guard !indicesToArchive.isEmpty else { return 0 }
        for index in indicesToArchive {
            transcript.turns[index].retentionTier = .archived
        }
        pressure = pressure.removingWorkingUnits(releasedWorkingUnits)
        return indicesToArchive.count
    }

    static func retainedFullDetailBytes(for transcript: AgentTranscript) -> Int {
        transcript.turns.reduce(into: 0) { partial, turn in
            guard turn.retentionTier == .full else { return }
            partial += retainedDetailBytes(for: turn)
        }
    }

    private static func retainedDetailBytes(for turn: AgentTranscriptTurn) -> Int {
        turn.allActivities.reduce(into: 0) { partial, activity in
            partial += activity.text.lengthOfBytes(using: .utf8)
            partial += (activity.reasoning ?? "").lengthOfBytes(using: .utf8)
            guard let execution = activity.toolExecution else { return }
            partial += (execution.argsJSON ?? "").lengthOfBytes(using: .utf8)
            let resultJSON = execution.resultJSON ?? ""
            let resultBytes = resultJSON.lengthOfBytes(using: .utf8)
            if resultJSON != activity.text {
                partial += resultBytes
            }
            partial += (execution.summaryText ?? "").lengthOfBytes(using: .utf8)
        }
    }

    /// Returns the index of the oldest turn eligible for tier downshifting.
    /// The newest turn is always excluded — its inline activities must survive compaction.
    /// While the newest turn is active/pending, keep the latest full-detail continuation suffix
    /// intact so a restored response turn and subsequent steering/user rows do not collapse
    /// before the agent has a chance to answer.
    private static func oldestTierDownshiftableTurnIndex(
        in turns: [AgentTranscriptTurn],
        protectedTurnID: UUID?,
        protectedToolTailTurnIDs: Set<UUID>
    ) -> Int? {
        let lastTurnIndex = turns.count - 1
        let activeContinuationProtectedTurnIDs = activeContinuationProtectedTurnIDs(in: turns)
        return turns.enumerated().first(where: { index, turn in
            index != lastTurnIndex
                && turn.isCompleted
                && (turn.retentionTier == .full || turn.retentionTier == .condensed)
                && turn.id != protectedTurnID
                && !activeContinuationProtectedTurnIDs.contains(turn.id)
                && !protectedToolTailTurnIDs.contains(turn.id)
        })?.offset
    }

    private static func activeContinuationProtectedTurnIDs(in turns: [AgentTranscriptTurn]) -> Set<UUID> {
        guard turns.count >= 2 else { return [] }
        let newestIndex = turns.count - 1
        let newest = turns[newestIndex]
        guard shouldProtectActiveContinuationSuffix(for: newest) else { return [] }

        let precedingRange = turns.indices[..<newestIndex]
        let preferredAnchorIndex = precedingRange.reversed().first { index in
            let turn = turns[index]
            return turn.retentionTier == .full
                && turn.isCompleted
                && turn.hasStoredActivities
        }
        let fallbackAnchorIndex = preferredAnchorIndex ?? precedingRange.reversed().first { index in
            let turn = turns[index]
            return turn.retentionTier == .full
                && turn.isCompleted
        }
        guard let anchorIndex = fallbackAnchorIndex else { return [] }

        return Set(turns[anchorIndex ..< newestIndex].compactMap { turn in
            turn.retentionTier == .full ? turn.id : nil
        })
    }

    private static func shouldProtectActiveContinuationSuffix(for newest: AgentTranscriptTurn) -> Bool {
        guard newest.completedAt == nil else {
            return false
        }
        if let terminalState = newest.terminalState {
            return terminalState.isActive
        }
        if newest.responseSpans.contains(where: { $0.lifecycle == .open }) {
            return true
        }
        if newest.request != nil, newest.responseSpans.isEmpty {
            return true
        }
        return !newest.isCompleted
    }

    private static func isArchivableSummaryTurn(
        _ turn: AgentTranscriptTurn,
        at index: Int,
        lastTurnIndex: Int,
        protectedTurnID: UUID?,
        protectedToolTailTurnIDs: Set<UUID>
    ) -> Bool {
        index != lastTurnIndex
            && turn.isCompleted
            && turn.retentionTier == .summary
            && turn.id != protectedTurnID
            && !protectedToolTailTurnIDs.contains(turn.id)
    }

    private static func protectedToolTailRegion(
        in transcript: AgentTranscript,
        limit: Int = protectedDetailedToolExecutionTailCount
    ) -> ProtectedToolTailRegion {
        #if DEBUG
            let startedAt = Date.timeIntervalSinceReferenceDate
            var turnsVisited = 0
            var spansInspected = 0
            var activitiesInspected = 0
            var alreadyOrderedSpanCount = 0
            var sortedSpanCount = 0
            var summarizedToolSignalUseCount = 0
            var summarizedToolSignalCount = 0

            func emit(countedToolExecutionCount: Int, protectedTurnCount: Int) {
                guard AgentTranscriptDebugInstrumentation.isEnabled else { return }
                AgentTranscriptDebugInstrumentation.protectedTailScanHandler?(.init(
                    transcriptTurnCount: transcript.turns.count,
                    limit: limit,
                    turnsVisited: turnsVisited,
                    spansInspected: spansInspected,
                    activitiesInspected: activitiesInspected,
                    alreadyOrderedSpanCount: alreadyOrderedSpanCount,
                    sortedSpanCount: sortedSpanCount,
                    summarizedToolSignalUseCount: summarizedToolSignalUseCount,
                    summarizedToolSignalCount: summarizedToolSignalCount,
                    countedToolExecutionCount: countedToolExecutionCount,
                    protectedTurnCount: protectedTurnCount,
                    durationMS: AgentTranscriptDebugInstrumentation.durationMS(since: startedAt)
                ))
            }
        #endif
        guard limit > 0, !transcript.turns.isEmpty else {
            #if DEBUG
                emit(countedToolExecutionCount: 0, protectedTurnCount: 0)
            #endif
            return ProtectedToolTailRegion(protectedTurnIDs: [])
        }

        var countedToolExecutionCount = 0
        var earliestProtectedTurnIndex: Int?

        for turnIndex in transcript.turns.indices.reversed() {
            #if DEBUG
                turnsVisited += 1
            #endif
            let turn = transcript.turns[turnIndex]
            let remaining = limit - countedToolExecutionCount
            guard remaining > 0 else { break }

            #if DEBUG
                let visibleToolSignalCount = AgentTranscriptDebugInstrumentation.isEnabled
                    ? debugVisibleToolSignalCount(
                        in: turn,
                        limit: remaining,
                        spansInspected: &spansInspected,
                        activitiesInspected: &activitiesInspected,
                        alreadyOrderedSpanCount: &alreadyOrderedSpanCount,
                        sortedSpanCount: &sortedSpanCount
                    )
                    : Self.visibleToolSignalCount(in: turn, limit: remaining)
            #else
                let visibleToolSignalCount = Self.visibleToolSignalCount(in: turn, limit: remaining)
            #endif
            if visibleToolSignalCount > 0 {
                countedToolExecutionCount += visibleToolSignalCount
                earliestProtectedTurnIndex = turnIndex
            } else {
                let summaryToolSignalCount = Self.summarizedToolSignalCount(in: turn)
                if summaryToolSignalCount > 0 {
                    #if DEBUG
                        summarizedToolSignalUseCount += 1
                        summarizedToolSignalCount += min(summaryToolSignalCount, remaining)
                    #endif
                    countedToolExecutionCount += min(summaryToolSignalCount, remaining)
                    earliestProtectedTurnIndex = turnIndex
                }
            }

            if countedToolExecutionCount >= limit {
                break
            }
        }

        guard let earliestProtectedTurnIndex else {
            #if DEBUG
                emit(countedToolExecutionCount: countedToolExecutionCount, protectedTurnCount: 0)
            #endif
            return ProtectedToolTailRegion(protectedTurnIDs: [])
        }

        let protectedTurnIDs = Set(transcript.turns[earliestProtectedTurnIndex...].map(\.id))
        #if DEBUG
            emit(countedToolExecutionCount: countedToolExecutionCount, protectedTurnCount: protectedTurnIDs.count)
        #endif
        return ProtectedToolTailRegion(protectedTurnIDs: protectedTurnIDs)
    }

    #if DEBUG
        private static func debugVisibleToolSignalCount(
            in turn: AgentTranscriptTurn,
            limit: Int,
            spansInspected: inout Int,
            activitiesInspected: inout Int,
            alreadyOrderedSpanCount: inout Int,
            sortedSpanCount: inout Int
        ) -> Int {
            guard limit > 0 else { return 0 }
            var countedToolExecutionCount = 0
            var seenExecutionIDs: Set<String> = []
            for span in turn.responseSpans {
                spansInspected += 1
                let activities: [AgentTranscriptActivity]
                if activitiesAreInTranscriptOrder(span.activities) {
                    alreadyOrderedSpanCount += 1
                    activities = span.activities
                } else {
                    sortedSpanCount += 1
                    activities = span.activities.sorted(by: transcriptActivityPrecedes)
                }
                for activity in activities {
                    activitiesInspected += 1
                    guard activity.itemKind == .toolCall || activity.itemKind == .toolResult else { continue }
                    guard !AgentTranscriptToolVisibilityPolicy.shouldSuppressActivity(activity) else { continue }
                    let stableExecutionID = activity.toolExecution?.stableExecutionID ?? activity.id.uuidString
                    guard seenExecutionIDs.insert(stableExecutionID).inserted else { continue }
                    countedToolExecutionCount += 1
                    if countedToolExecutionCount >= limit {
                        return countedToolExecutionCount
                    }
                }
            }
            return countedToolExecutionCount
        }
    #endif

    private static func visibleToolSignalCount(in turn: AgentTranscriptTurn, limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        var countedToolExecutionCount = 0
        var seenExecutionIDs: Set<String> = []
        for span in turn.responseSpans {
            for activity in transcriptOrderedActivities(in: span) {
                guard activity.itemKind == .toolCall || activity.itemKind == .toolResult else { continue }
                guard !AgentTranscriptToolVisibilityPolicy.shouldSuppressActivity(activity) else { continue }
                let stableExecutionID = activity.toolExecution?.stableExecutionID ?? activity.id.uuidString
                guard seenExecutionIDs.insert(stableExecutionID).inserted else { continue }
                countedToolExecutionCount += 1
                if countedToolExecutionCount >= limit {
                    return countedToolExecutionCount
                }
            }
        }
        return countedToolExecutionCount
    }

    private static func transcriptOrderedActivities(in span: AgentTranscriptProviderResponseSpan) -> [AgentTranscriptActivity] {
        guard !activitiesAreInTranscriptOrder(span.activities) else {
            return span.activities
        }
        return span.activities.sorted(by: transcriptActivityPrecedes)
    }

    private static func activitiesAreInTranscriptOrder(_ activities: [AgentTranscriptActivity]) -> Bool {
        guard activities.count > 1 else { return true }
        for index in activities.indices.dropFirst() {
            let previousIndex = activities.index(before: index)
            if transcriptActivityPrecedes(activities[index], activities[previousIndex]) {
                return false
            }
        }
        return true
    }

    private static func transcriptActivityPrecedes(_ lhs: AgentTranscriptActivity, _ rhs: AgentTranscriptActivity) -> Bool {
        if lhs.sequenceIndex == rhs.sequenceIndex {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.sequenceIndex < rhs.sequenceIndex
    }

    private static func summarizedToolSignalCount(in turn: AgentTranscriptTurn) -> Int {
        let summaryToolCount = turn.summary?.toolCount ?? 0
        let collapsedToolCount = turn.responseSpans.reduce(0) { partial, span in
            partial + (span.collapsedSummary?.hiddenToolCardCount ?? 0)
        }
        return max(summaryToolCount, collapsedToolCount)
    }

    private static func structurallyTrimmedTranscript(_ transcript: AgentTranscript) -> AgentTranscript {
        var copy = transcript
        for index in copy.turns.indices {
            trimTurnForRetention(&copy.turns[index])
        }
        return copy
    }

    private static func trimTurnForRetention(_ turn: inout AgentTranscriptTurn) {
        switch turn.retentionTier {
        case .full:
            turn.summary = nil
            for index in turn.responseSpans.indices {
                turn.responseSpans[index].collapsedSummary = nil
            }
        case .condensed, .summary, .archived:
            let snapshot = turn
            if turn.summary == nil {
                turn.summary = AgentTranscriptIO.buildSummary(for: snapshot)
            }
            for index in turn.responseSpans.indices {
                trimSpanForRetention(&turn.responseSpans[index], in: snapshot, tier: turn.retentionTier)
            }
            if let summary = turn.summary {
                turn.summary = normalizeSummaryForRetention(summary, tier: turn.retentionTier)
            }
        }
    }

    private static func trimSpanForRetention(
        _ span: inout AgentTranscriptProviderResponseSpan,
        in turn: AgentTranscriptTurn,
        tier: AgentTranscriptRetentionTier
    ) {
        if span.lastActivityAt == nil {
            span.lastActivityAt = span.activities.last?.timestamp
        }
        if span.completedAt == nil, span.lifecycle != .open {
            span.completedAt = span.lastActivityAt ?? span.startedAt
        }
        switch tier {
        case .full:
            span.collapsedSummary = nil
            if !turn.isCompleted || span.lifecycle == .open {
                span.fullRenderGroupedHistoryCache = nil
            }
        case .condensed, .summary:
            span.fullRenderGroupedHistoryCache = nil
            if span.collapsedSummary == nil {
                span.collapsedSummary = AgentTranscriptIO.buildCollapsedSummary(for: span, in: turn)
            }
            let conclusionID = turn.conclusionActivityID
            span.activities = span.activities.filter { $0.id == conclusionID }
        case .archived:
            span.fullRenderGroupedHistoryCache = nil
            span.collapsedSummary = nil
            let conclusionID = turn.conclusionActivityID
            span.activities = span.activities.filter { $0.id == conclusionID }
        }
    }

    private static func normalizeSummaryForRetention(
        _ summary: AgentTranscriptTurnSummary,
        tier: AgentTranscriptRetentionTier
    ) -> AgentTranscriptTurnSummary {
        var normalized = summary
        normalized.requestText = nil
        if normalized.compactConclusionText == nil {
            normalized.compactConclusionText = AgentTranscriptIO.compactConclusionText(from: normalized.conclusionText)
        }
        switch tier {
        case .full:
            break
        case .condensed:
            break
        case .summary, .archived:
            normalized.conclusionText = nil
        }
        return normalized
    }
}

struct AgentTranscriptTurnProjectionCache: Equatable {
    struct ValidationToken: Equatable {
        let turnID: UUID
        let retentionTier: AgentTranscriptRetentionTier
        let isCompleted: Bool
        let responseSpanCount: Int
        let activityCount: Int
        let conclusionActivityID: UUID?
        let frozenDetailedToolTailLimit: Int?
    }

    let token: ValidationToken
    let workingBlocks: [AgentTranscriptRenderBlock]
    let archivedBlocks: [AgentTranscriptRenderBlock]
    let workingRows: [AgentChatItem]
    let archivedRows: [AgentChatItem]
    let rowAnchorIndex: [UUID: AgentTranscriptAnchor]
    let anchorBlockIndex: [AgentTranscriptAnchor: String]
}

struct AgentTranscriptProjectionBuildResult: Equatable {
    let projection: AgentTranscriptProjection
    let updatedTurnCaches: [UUID: AgentTranscriptTurnProjectionCache]
}

enum AgentTranscriptProjectionBuilder {
    private static func debugRowSummary(_ item: AgentChatItem) -> String {
        let label = item.toolName ?? item.kind.rawValue
        return "\(item.sequenceIndex):\(item.kind.rawValue):\(label):stream=\(item.isStreaming)"
    }

    private static func debugBlockSummary(_ block: AgentTranscriptRenderBlock) -> String {
        let rowSummary = block.rows.map { "\($0.sequenceIndex):\($0.kind.rawValue)" }.joined(separator: ",")
        return "\(block.kind.rawValue){\(rowSummary)}"
    }

    private struct ReusableProjectionPrefix {
        let turnCount: Int
        let workingBlocks: [AgentTranscriptRenderBlock]
        let archivedBlocks: [AgentTranscriptRenderBlock]
        let workingRows: [AgentChatItem]
        let archivedRows: [AgentChatItem]
        let rowAnchorIndex: [UUID: AgentTranscriptAnchor]
        let anchorBlockIndex: [AgentTranscriptAnchor: String]
    }

    private struct GroupedHistoryCollapsePlan {
        let contentBlocks: [AgentTranscriptRenderBlock]
        let conclusionBlocks: [AgentTranscriptRenderBlock]
        let collapsedPrefix: [AgentTranscriptRenderBlock]
        let groupedPrefix: [AgentTranscriptRenderBlock]
        let detailedSuffix: [AgentTranscriptRenderBlock]
        let bufferedLeadingAssistant: AgentTranscriptRenderBlock?
        let collapseDigest: String
    }

    /// Refreshes completed full-turn grouped-history summary caches.
    /// Also intentionally tightens `frozenDetailedToolTailLimit` when an eligible completed
    /// full turn emits grouped history under the current newest-first allocation. Callers
    /// must use the returned transcript; this method is not cache-only.
    static func refreshCompletedFullTurnGroupedHistoryCaches(
        in transcript: AgentTranscript,
        reusablePrefixTurnCount: Int? = nil
    ) -> AgentTranscript {
        var updatedTranscript = transcript
        let context = AgentTranscriptProjectionBuildContext()
        let firstTurnIndex = min(max(0, reusablePrefixTurnCount ?? 0), updatedTranscript.turns.count)
        let detailedToolTailLimits = detailedToolTailLimits(for: updatedTranscript)
        for turnIndex in updatedTranscript.turns.indices {
            let turn = updatedTranscript.turns[turnIndex]
            let detailedToolTailLimit = detailedToolTailLimits[turn.id] ?? 0
            if turnIndex < firstTurnIndex,
               canReuseGroupedHistoryState(
                   for: turn,
                   detailedToolTailLimit: detailedToolTailLimit
               )
            {
                continue
            }
            let isEligible = turn.retentionTier == .full
                && turn.isCompleted
                && !turn.responseSpans.contains(where: { $0.lifecycle == .open })
            guard isEligible else {
                for spanIndex in updatedTranscript.turns[turnIndex].responseSpans.indices {
                    updatedTranscript.turns[turnIndex].responseSpans[spanIndex].fullRenderGroupedHistoryCache = nil
                }
                continue
            }
            var didCollapseTurn = false
            var emittedConclusionActivityIDs = Set<UUID>()
            for spanIndex in updatedTranscript.turns[turnIndex].responseSpans.indices {
                let span = updatedTranscript.turns[turnIndex].responseSpans[spanIndex]
                let leafBlocks = fullSpanLeafBlocks(
                    for: span,
                    in: turn,
                    archived: false,
                    emittedConclusionActivityIDs: &emittedConclusionActivityIDs
                )
                guard let plan = groupedHistoryCollapsePlan(
                    in: leafBlocks,
                    spanID: span.id,
                    detailedToolTailLimit: detailedToolTailLimit
                ) else {
                    updatedTranscript.turns[turnIndex].responseSpans[spanIndex].fullRenderGroupedHistoryCache = nil
                    continue
                }
                didCollapseTurn = true
                if let cache = span.fullRenderGroupedHistoryCache,
                   cache.detailedToolTailLimit == detailedToolTailLimit,
                   cache.collapseDigest == plan.collapseDigest
                {
                    continue
                }
                let summary = groupedHistorySummary(
                    for: plan.groupedPrefix,
                    summarySourceBlocks: plan.collapsedPrefix,
                    context: context
                )
                updatedTranscript.turns[turnIndex].responseSpans[spanIndex].fullRenderGroupedHistoryCache = .init(
                    detailedToolTailLimit: detailedToolTailLimit,
                    collapseDigest: plan.collapseDigest,
                    summary: summary
                )
            }
            if didCollapseTurn {
                let frozenLimit = normalizedFrozenDetailedToolTailLimit(for: updatedTranscript.turns[turnIndex])
                if frozenLimit == nil || detailedToolTailLimit < (frozenLimit ?? Int.max) {
                    updatedTranscript.turns[turnIndex].frozenDetailedToolTailLimit = detailedToolTailLimit
                }
            }
        }
        return updatedTranscript
    }

    private static func canReuseGroupedHistoryState(
        for turn: AgentTranscriptTurn,
        detailedToolTailLimit: Int
    ) -> Bool {
        let isEligible = turn.retentionTier == .full
            && turn.isCompleted
            && !turn.responseSpans.contains(where: { $0.lifecycle == .open })
        guard isEligible else {
            return turn.responseSpans.allSatisfy { $0.fullRenderGroupedHistoryCache == nil }
        }
        if let frozenLimit = normalizedFrozenDetailedToolTailLimit(for: turn) {
            guard frozenLimit == detailedToolTailLimit else { return false }
            return turn.responseSpans.allSatisfy { span in
                span.fullRenderGroupedHistoryCache?.detailedToolTailLimit == detailedToolTailLimit
                    || span.fullRenderGroupedHistoryCache == nil
            }
        }
        return standaloneToolBlockCount(for: turn) <= detailedToolTailLimit
            && turn.responseSpans.allSatisfy { $0.fullRenderGroupedHistoryCache == nil }
    }

    static func build(
        from transcript: AgentTranscript,
        protection: AgentTranscriptProjectionProtection = .none,
        context: AgentToolResultProcessingContext? = nil
    ) -> AgentTranscriptProjection {
        buildWithCaches(
            from: transcript,
            protection: protection,
            turnCaches: [:],
            context: context
        ).projection
    }

    static func buildWithCaches(
        from transcript: AgentTranscript,
        protection: AgentTranscriptProjectionProtection = .none,
        turnCaches: [UUID: AgentTranscriptTurnProjectionCache],
        context: AgentToolResultProcessingContext? = nil
    ) -> AgentTranscriptProjectionBuildResult {
        buildProjection(
            from: transcript,
            protection: protection,
            reusablePrefix: nil,
            turnCaches: turnCaches,
            processingContext: context
        )
    }

    static func buildReusingFrozenPrefix(
        from transcript: AgentTranscript,
        previousTranscript: AgentTranscript,
        previousProjection: AgentTranscriptProjection,
        previousProtection: AgentTranscriptProjectionProtection,
        protection: AgentTranscriptProjectionProtection = .none,
        reusableFrozenPrefixTurnCount: Int,
        context: AgentToolResultProcessingContext? = nil
    ) -> AgentTranscriptProjection? {
        guard reusableFrozenPrefixTurnCount > 0,
              protection == previousProtection,
              AgentTranscriptIO.validatedReusableFrozenPrefixTurnCount(in: transcript) == reusableFrozenPrefixTurnCount,
              previousTranscript.turns.count >= reusableFrozenPrefixTurnCount,
              transcript.turns.count > reusableFrozenPrefixTurnCount,
              previousTranscript.turns.prefix(reusableFrozenPrefixTurnCount).elementsEqual(
                  transcript.turns.prefix(reusableFrozenPrefixTurnCount)
              )
        else {
            return nil
        }
        let prefixTurnIDs = Set(transcript.turns.prefix(reusableFrozenPrefixTurnCount).map(\.id))
        let reusablePrefix = reusableProjectionPrefix(
            from: previousProjection,
            turnIDs: prefixTurnIDs,
            turnCount: reusableFrozenPrefixTurnCount
        )
        return buildProjection(
            from: transcript,
            protection: protection,
            reusablePrefix: reusablePrefix,
            turnCaches: [:],
            processingContext: context
        ).projection
    }

    private static func buildProjection(
        from transcript: AgentTranscript,
        protection: AgentTranscriptProjectionProtection,
        reusablePrefix: ReusableProjectionPrefix?,
        turnCaches: [UUID: AgentTranscriptTurnProjectionCache],
        processingContext: AgentToolResultProcessingContext? = nil
    ) -> AgentTranscriptProjectionBuildResult {
        #if DEBUG
            let startedAt = Date.timeIntervalSinceReferenceDate
        #endif
        let context = AgentTranscriptProjectionBuildContext(processingContext: processingContext ?? AgentToolResultProcessingContext())
        let detailedToolTailLimits = detailedToolTailLimits(for: transcript)
        var workingBlocks: [AgentTranscriptRenderBlock] = reusablePrefix?.workingBlocks ?? []
        var archivedBlocks: [AgentTranscriptRenderBlock] = reusablePrefix?.archivedBlocks ?? []
        var workingRows: [AgentChatItem] = reusablePrefix?.workingRows ?? []
        var archivedRows: [AgentChatItem] = reusablePrefix?.archivedRows ?? []
        var rowAnchorIndex: [UUID: AgentTranscriptAnchor] = reusablePrefix?.rowAnchorIndex ?? [:]
        var anchorBlockIndex: [AgentTranscriptAnchor: String] = reusablePrefix?.anchorBlockIndex ?? [:]
        let transcriptTurnIDs = Set(transcript.turns.map(\.id))
        let protectedTurnID = protection.protectedTurnID
        var updatedTurnCaches = turnCaches.filter { transcriptTurnIDs.contains($0.key) }
        var cacheHitCount = 0

        for turn in transcript.turns.dropFirst(reusablePrefix?.turnCount ?? 0) {
            if let cachedProjection = cachedProjection(
                for: turn,
                protectedTurnID: protectedTurnID,
                turnCaches: updatedTurnCaches
            ) {
                appendCachedProjectionState(
                    cachedProjection,
                    workingBlocks: &workingBlocks,
                    archivedBlocks: &archivedBlocks,
                    workingRows: &workingRows,
                    archivedRows: &archivedRows,
                    rowAnchorIndex: &rowAnchorIndex,
                    anchorBlockIndex: &anchorBlockIndex
                )
                cacheHitCount += 1
                continue
            }

            let workingBlockStart = workingBlocks.count
            let archivedBlockStart = archivedBlocks.count
            appendProjectionState(
                for: turn,
                detailedToolTailLimit: detailedToolTailLimits[turn.id] ?? 0,
                context: context,
                workingBlocks: &workingBlocks,
                archivedBlocks: &archivedBlocks,
                workingRows: &workingRows,
                archivedRows: &archivedRows,
                rowAnchorIndex: &rowAnchorIndex,
                anchorBlockIndex: &anchorBlockIndex
            )
            if turn.isCompleted, turn.id != protectedTurnID {
                let newWorkingBlocks = Array(workingBlocks.dropFirst(workingBlockStart))
                let newArchivedBlocks = Array(archivedBlocks.dropFirst(archivedBlockStart))
                updatedTurnCaches[turn.id] = projectionCache(
                    for: turn,
                    token: validationToken(for: turn),
                    workingBlocks: newWorkingBlocks,
                    archivedBlocks: newArchivedBlocks,
                    workingRows: projectionRows(for: newWorkingBlocks),
                    archivedRows: projectionRows(for: newArchivedBlocks),
                    rowAnchorIndex: rowAnchorIndex,
                    anchorBlockIndex: anchorBlockIndex
                )
            } else if !turn.isCompleted {
                updatedTurnCaches.removeValue(forKey: turn.id)
            }
        }

        workingRows.sort { lhs, rhs in lhs.sequenceIndex < rhs.sequenceIndex }
        archivedRows.sort { lhs, rhs in lhs.sequenceIndex < rhs.sequenceIndex }
        let projection = AgentTranscriptProjection(
            workingBlocks: workingBlocks,
            archivedBlocks: archivedBlocks,
            workingRows: workingRows,
            archivedRows: archivedRows,
            rowAnchorIndex: rowAnchorIndex,
            anchorBlockIndex: anchorBlockIndex,
            workingUnitCount: workingBlocks.count
        )
        #if DEBUG
            let workingRowTail = Array(workingRows.suffix(8)).map(debugRowSummary).joined(separator: ", ")
            let workingBlockTail = Array(workingBlocks.suffix(8)).map(debugBlockSummary).joined(separator: " | ")
            AgentModeViewModel.logCodexDebug(
                "[AgentTranscriptProjection] build turns=\(transcript.turns.count) workingRows=\(workingRows.count) workingBlocks=\(workingBlocks.count) reusedPrefixTurns=\(reusablePrefix?.turnCount ?? 0) cacheHits=\(cacheHitCount) workingRowTail=[\(workingRowTail)] workingBlockTail=[\(workingBlockTail)]"
            )
            if AgentTranscriptDebugInstrumentation.isEnabled {
                AgentTranscriptDebugInstrumentation.projectionBuildHandler?(.init(
                    turnCount: transcript.turns.count,
                    reusedPrefixTurnCount: reusablePrefix?.turnCount ?? 0,
                    cacheHitCount: cacheHitCount,
                    workingBlockCount: workingBlocks.count,
                    archivedBlockCount: archivedBlocks.count,
                    workingRowCount: workingRows.count,
                    archivedRowCount: archivedRows.count,
                    workingUnitCount: projection.workingUnitCount,
                    durationMS: AgentTranscriptDebugInstrumentation.durationMS(since: startedAt)
                ))
            }
        #endif
        return AgentTranscriptProjectionBuildResult(
            projection: projection,
            updatedTurnCaches: updatedTurnCaches
        )
    }

    static func updatedTurnCaches(
        for transcript: AgentTranscript,
        projection: AgentTranscriptProjection,
        protection: AgentTranscriptProjectionProtection = .none,
        existingTurnCaches: [UUID: AgentTranscriptTurnProjectionCache] = [:]
    ) -> [UUID: AgentTranscriptTurnProjectionCache] {
        let transcriptTurnIDs = Set(transcript.turns.map(\.id))
        let protectedTurnID = protection.protectedTurnID
        var updatedTurnCaches = existingTurnCaches.filter { transcriptTurnIDs.contains($0.key) }
        for turn in transcript.turns {
            guard turn.isCompleted else {
                updatedTurnCaches.removeValue(forKey: turn.id)
                continue
            }
            guard turn.id != protectedTurnID else { continue }
            updatedTurnCaches[turn.id] = projectionCache(
                for: turn,
                token: validationToken(for: turn),
                projection: projection
            )
        }
        return updatedTurnCaches
    }

    static func rows(for turn: AgentTranscriptTurn, archived: Bool, isLatestTurn: Bool = true) -> [AgentChatItem] {
        if turn.retentionTier != .full {
            return compactedRows(for: turn)
        }
        let context = AgentTranscriptProjectionBuildContext()
        return blocks(
            for: turn,
            archived: archived,
            isLatestTurn: isLatestTurn,
            context: context
        ).flatMap(projectionRows(for:))
    }

    static func estimatedWorkingUnitCount(for transcript: AgentTranscript) -> Int {
        let detailedToolTailLimits = detailedToolTailLimits(for: transcript)
        return transcript.turns.reduce(into: 0) { partial, turn in
            guard turn.retentionTier != .archived else { return }
            partial += estimatedBlockCount(
                for: turn,
                detailedToolTailLimit: detailedToolTailLimits[turn.id] ?? 0
            )
        }
    }

    fileprivate static func estimatedSummaryWorkingUnitContribution(for turn: AgentTranscriptTurn) -> Int {
        guard turn.retentionTier == .summary else { return 0 }
        // Must remain exactly equivalent to `estimatedBlockCount`'s `.summary` contribution:
        // summary archival subtracts this value locally instead of rebuilding full pressure.
        return compactTierBlockCount(for: turn)
    }

    static func projectionCounts(for transcript: AgentTranscript) -> AgentTranscriptProjectionCounts {
        let detailedToolTailLimits = detailedToolTailLimits(for: transcript)
        var workingVisibleRowCount = 0
        var archivedVisibleRowCount = 0
        for turn in transcript.turns {
            let visibleRowCount: Int = switch turn.retentionTier {
            case .full:
                fullTurnVisibleRowCount(
                    for: turn,
                    detailedToolTailLimit: detailedToolTailLimits[turn.id] ?? 0
                )
            case .condensed, .summary:
                compactTierVisibleRowCount(for: turn)
            case .archived:
                compactedVisibleRowCount(for: turn)
            }
            if turn.retentionTier == .archived {
                archivedVisibleRowCount += visibleRowCount
            } else {
                workingVisibleRowCount += visibleRowCount
            }
        }
        return .init(
            canonicalVisibleRowCount: workingVisibleRowCount + archivedVisibleRowCount,
            defaultPresentedRowCount: workingVisibleRowCount
        )
    }

    static func projectionCounts(for projection: AgentTranscriptProjection) -> AgentTranscriptProjectionCounts {
        .init(
            canonicalVisibleRowCount: presentedItemCount(for: projection.workingBlocks)
                + presentedItemCount(for: projection.archivedBlocks),
            defaultPresentedRowCount: presentedItemCount(for: projection.workingBlocks)
        )
    }

    static func workingProjection(from fullProjection: AgentTranscriptProjection) -> AgentTranscriptProjection {
        let workingRowIDs = Set(fullProjection.workingRows.map(\.id))
        let workingBlockIDs = Set(fullProjection.workingBlocks.map(\.id))
        return .init(
            workingBlocks: fullProjection.workingBlocks,
            workingRows: fullProjection.workingRows,
            rowAnchorIndex: filteredRowAnchorIndex(
                fullProjection.rowAnchorIndex,
                retaining: workingRowIDs
            ),
            anchorBlockIndex: filteredAnchorBlockIndex(
                fullProjection.anchorBlockIndex,
                retaining: workingBlockIDs
            ),
            workingUnitCount: fullProjection.workingUnitCount
        )
    }

    static func archivedSnapshot(from fullProjection: AgentTranscriptProjection) -> AgentArchivedTranscriptSnapshot {
        let archivedRowIDs = Set(fullProjection.archivedRows.map(\.id))
        let archivedBlockIDs = Set(fullProjection.archivedBlocks.map(\.id))
        return .init(
            blocks: fullProjection.archivedBlocks,
            rows: fullProjection.archivedRows,
            rowAnchorIndex: filteredRowAnchorIndex(
                fullProjection.rowAnchorIndex,
                retaining: archivedRowIDs
            ),
            anchorBlockIndex: filteredAnchorBlockIndex(
                fullProjection.anchorBlockIndex,
                retaining: archivedBlockIDs
            ),
            compressedItems: fullProjection.archivedRows.map { .single($0) },
            presentedRowCount: presentedItemCount(for: fullProjection.archivedBlocks),
            blockCount: fullProjection.archivedBlocks.count
        )
    }

    static func projectedVisibleRowCount(for transcript: AgentTranscript) -> Int {
        projectionCounts(for: transcript).canonicalVisibleRowCount
    }

    static func visibleToolResultRowIDs(in projection: AgentTranscriptProjection) -> Set<UUID> {
        var ids = Set<UUID>()
        ids.reserveCapacity(projection.workingRows.count + projection.archivedRows.count)
        for block in projection.workingBlocks {
            for row in block.rows where row.kind == .toolResult {
                ids.insert(row.id)
            }
        }
        for block in projection.archivedBlocks {
            for row in block.rows where row.kind == .toolResult {
                ids.insert(row.id)
            }
        }
        return ids
    }

    static func blocks(for transcript: AgentTranscript) -> [AgentTranscriptRenderBlock] {
        let context = AgentTranscriptProjectionBuildContext()
        let detailedToolTailLimits = detailedToolTailLimits(for: transcript)
        return transcript.turns.flatMap { turn in
            let archived = turn.retentionTier == .archived
            return blocksForTurn(
                turn,
                archived: archived,
                detailedToolTailLimit: detailedToolTailLimits[turn.id] ?? 0,
                context: context,
                protectDetachedFocus: false
            )
        }
    }

    private static func projectionRows(for block: AgentTranscriptRenderBlock) -> [AgentChatItem] {
        switch block.kind {
        case .groupedHistory:
            []
        case .request, .activityCluster, .standaloneAssistant, .standaloneTool, .standaloneNote, .middleSummary, .conclusion:
            block.rows
        }
    }

    private static func projectionRows(for blocks: [AgentTranscriptRenderBlock]) -> [AgentChatItem] {
        blocks.flatMap(projectionRows(for:))
    }

    private static func reusableProjectionPrefix(
        from projection: AgentTranscriptProjection,
        turnIDs: Set<UUID>,
        turnCount: Int
    ) -> ReusableProjectionPrefix {
        let workingBlocks = projection.workingBlocks.filter { turnIDs.contains($0.turnID) }
        let archivedBlocks = projection.archivedBlocks.filter { turnIDs.contains($0.turnID) }
        let reusableWorkingRowIDs = Set(workingBlocks.flatMap(projectionRows(for:)).map(\.id))
        let reusableArchivedRowIDs = Set(archivedBlocks.flatMap(projectionRows(for:)).map(\.id))
        let rowAnchorIndex = projection.rowAnchorIndex.filter { turnIDs.contains(turnID(for: $0.value)) }
        return ReusableProjectionPrefix(
            turnCount: turnCount,
            workingBlocks: workingBlocks,
            archivedBlocks: archivedBlocks,
            workingRows: projection.workingRows.filter { reusableWorkingRowIDs.contains($0.id) },
            archivedRows: projection.archivedRows.filter { reusableArchivedRowIDs.contains($0.id) },
            rowAnchorIndex: rowAnchorIndex,
            anchorBlockIndex: projection.anchorBlockIndex.filter { turnIDs.contains(turnID(for: $0.key)) }
        )
    }

    private static func appendProjectionState(
        for turn: AgentTranscriptTurn,
        detailedToolTailLimit: Int,
        context: AgentTranscriptProjectionBuildContext,
        workingBlocks: inout [AgentTranscriptRenderBlock],
        archivedBlocks: inout [AgentTranscriptRenderBlock],
        workingRows: inout [AgentChatItem],
        archivedRows: inout [AgentChatItem],
        rowAnchorIndex: inout [UUID: AgentTranscriptAnchor],
        anchorBlockIndex: inout [AgentTranscriptAnchor: String]
    ) {
        let archived = turn.retentionTier == .archived
        let blocks = blocksForTurn(
            turn,
            archived: archived,
            detailedToolTailLimit: detailedToolTailLimit,
            context: context,
            protectDetachedFocus: false
        )
        for block in blocks {
            let projectedRows = projectionRows(for: block)
            if archived {
                archivedBlocks.append(block)
                archivedRows.append(contentsOf: projectedRows)
            } else {
                workingBlocks.append(block)
                workingRows.append(contentsOf: projectedRows)
            }
        }
        registerAnchors(for: turn, blocks: blocks, into: &rowAnchorIndex)
        registerBlockAnchors(for: turn, blocks: blocks, into: &anchorBlockIndex)
    }

    static func validationToken(for turn: AgentTranscriptTurn) -> AgentTranscriptTurnProjectionCache.ValidationToken {
        .init(
            turnID: turn.id,
            retentionTier: turn.retentionTier,
            isCompleted: turn.isCompleted,
            responseSpanCount: turn.responseSpans.count,
            activityCount: turn.allActivities.count,
            conclusionActivityID: turn.conclusionActivityID,
            frozenDetailedToolTailLimit: turn.frozenDetailedToolTailLimit
        )
    }

    private static func cachedProjection(
        for turn: AgentTranscriptTurn,
        protectedTurnID: UUID?,
        turnCaches: [UUID: AgentTranscriptTurnProjectionCache]
    ) -> AgentTranscriptTurnProjectionCache? {
        guard turn.isCompleted,
              turn.id != protectedTurnID,
              let cachedProjection = turnCaches[turn.id],
              cachedProjection.token == validationToken(for: turn)
        else {
            return nil
        }
        return cachedProjection
    }

    private static func appendCachedProjectionState(
        _ cachedProjection: AgentTranscriptTurnProjectionCache,
        workingBlocks: inout [AgentTranscriptRenderBlock],
        archivedBlocks: inout [AgentTranscriptRenderBlock],
        workingRows: inout [AgentChatItem],
        archivedRows: inout [AgentChatItem],
        rowAnchorIndex: inout [UUID: AgentTranscriptAnchor],
        anchorBlockIndex: inout [AgentTranscriptAnchor: String]
    ) {
        workingBlocks.append(contentsOf: cachedProjection.workingBlocks)
        archivedBlocks.append(contentsOf: cachedProjection.archivedBlocks)
        workingRows.append(contentsOf: cachedProjection.workingRows)
        archivedRows.append(contentsOf: cachedProjection.archivedRows)
        rowAnchorIndex.merge(cachedProjection.rowAnchorIndex) { _, new in new }
        anchorBlockIndex.merge(cachedProjection.anchorBlockIndex) { _, new in new }
    }

    private static func projectionCache(
        for turn: AgentTranscriptTurn,
        token: AgentTranscriptTurnProjectionCache.ValidationToken,
        workingBlocks: [AgentTranscriptRenderBlock],
        archivedBlocks: [AgentTranscriptRenderBlock],
        workingRows: [AgentChatItem],
        archivedRows: [AgentChatItem],
        rowAnchorIndex: [UUID: AgentTranscriptAnchor],
        anchorBlockIndex: [AgentTranscriptAnchor: String]
    ) -> AgentTranscriptTurnProjectionCache {
        AgentTranscriptTurnProjectionCache(
            token: token,
            workingBlocks: workingBlocks,
            archivedBlocks: archivedBlocks,
            workingRows: workingRows,
            archivedRows: archivedRows,
            rowAnchorIndex: rowAnchorIndex.filter { turnID(for: $0.value) == turn.id },
            anchorBlockIndex: anchorBlockIndex.filter { turnID(for: $0.key) == turn.id }
        )
    }

    private static func projectionCache(
        for turn: AgentTranscriptTurn,
        token: AgentTranscriptTurnProjectionCache.ValidationToken,
        projection: AgentTranscriptProjection
    ) -> AgentTranscriptTurnProjectionCache {
        let workingBlocks = projection.workingBlocks.filter { $0.turnID == turn.id }
        let archivedBlocks = projection.archivedBlocks.filter { $0.turnID == turn.id }
        return projectionCache(
            for: turn,
            token: token,
            workingBlocks: workingBlocks,
            archivedBlocks: archivedBlocks,
            workingRows: projectionRows(for: workingBlocks),
            archivedRows: projectionRows(for: archivedBlocks),
            rowAnchorIndex: projection.rowAnchorIndex,
            anchorBlockIndex: projection.anchorBlockIndex
        )
    }

    static func blocks(for turn: AgentTranscriptTurn, archived: Bool, isLatestTurn: Bool = true) -> [AgentTranscriptRenderBlock] {
        let context = AgentTranscriptProjectionBuildContext()
        return blocks(
            for: turn,
            archived: archived,
            isLatestTurn: isLatestTurn,
            context: context
        )
    }

    private static func blocks(
        for turn: AgentTranscriptTurn,
        archived: Bool,
        isLatestTurn: Bool,
        context: AgentTranscriptProjectionBuildContext
    ) -> [AgentTranscriptRenderBlock] {
        _ = isLatestTurn
        return blocksForTurn(
            turn,
            archived: archived,
            detailedToolTailLimit: effectiveDetailedToolTailLimit(for: turn),
            context: context,
            protectDetachedFocus: false
        )
    }

    static func blocks(for turn: AgentTranscriptTurn, archived: Bool, detailedToolTailLimit: Int) -> [AgentTranscriptRenderBlock] {
        let context = AgentTranscriptProjectionBuildContext()
        return blocksForTurn(
            turn,
            archived: archived,
            detailedToolTailLimit: detailedToolTailLimit,
            context: context,
            protectDetachedFocus: false
        )
    }

    static func normalizedFrozenDetailedToolTailLimits(in transcript: AgentTranscript) -> AgentTranscript {
        var updatedTranscript = transcript
        for index in updatedTranscript.turns.indices {
            guard updatedTranscript.turns[index].retentionTier == .full,
                  updatedTranscript.turns[index].isCompleted
            else {
                updatedTranscript.turns[index].frozenDetailedToolTailLimit = nil
                continue
            }
            updatedTranscript.turns[index].frozenDetailedToolTailLimit =
                normalizedFrozenDetailedToolTailLimit(for: updatedTranscript.turns[index])
        }

        let detailedToolTailLimits = detailedToolTailLimits(for: updatedTranscript)
        for index in updatedTranscript.turns.indices {
            guard updatedTranscript.turns[index].retentionTier == .full,
                  updatedTranscript.turns[index].isCompleted
            else {
                updatedTranscript.turns[index].frozenDetailedToolTailLimit = nil
                continue
            }
            let detailedToolTailLimit = detailedToolTailLimits[updatedTranscript.turns[index].id] ?? 0
            updatedTranscript.turns[index].frozenDetailedToolTailLimit = groupedHistoryWouldCollapse(
                in: updatedTranscript.turns[index],
                detailedToolTailLimit: detailedToolTailLimit
            ) ? detailedToolTailLimit : nil
        }
        return updatedTranscript
    }

    fileprivate static func groupedHistoryWouldCollapse(
        in turn: AgentTranscriptTurn,
        detailedToolTailLimit: Int
    ) -> Bool {
        guard turn.retentionTier == .full else { return false }
        var emittedConclusionActivityIDs = Set<UUID>()
        for span in turn.responseSpans {
            let leafBlocks = fullSpanLeafBlocks(
                for: span,
                in: turn,
                archived: false,
                emittedConclusionActivityIDs: &emittedConclusionActivityIDs
            )
            if groupedHistoryCollapsePlan(
                in: leafBlocks,
                spanID: span.id,
                detailedToolTailLimit: detailedToolTailLimit
            ) != nil {
                return true
            }
        }
        return false
    }

    fileprivate static func normalizedFrozenDetailedToolTailLimit(for turn: AgentTranscriptTurn) -> Int? {
        guard turn.retentionTier == .full,
              turn.isCompleted,
              let rawFrozen = turn.frozenDetailedToolTailLimit
        else {
            return nil
        }
        let frozen = max(0, rawFrozen)
        guard standaloneToolBlockCount(for: turn) > frozen else { return nil }
        return groupedHistoryWouldCollapse(in: turn, detailedToolTailLimit: frozen) ? frozen : nil
    }

    fileprivate static func detailedToolTailLimits(for transcript: AgentTranscript) -> [UUID: Int] {
        var remainingBudget = globalDetailedToolTailLimit
        var limits: [UUID: Int] = [:]

        for turn in transcript.turns.reversed() {
            guard turn.retentionTier == .full else {
                limits[turn.id] = 0
                continue
            }
            let visibleToolCeiling = normalizedFrozenDetailedToolTailLimit(for: turn)
                ?? standaloneToolBlockCount(for: turn)
            let visibleToolCount = min(visibleToolCeiling, remainingBudget)
            limits[turn.id] = visibleToolCount
            remainingBudget = max(0, remainingBudget - visibleToolCount)
        }

        return limits
    }

    private static func effectiveDetailedToolTailLimit(for turn: AgentTranscriptTurn) -> Int {
        guard turn.retentionTier == .full else { return 0 }
        if let frozen = normalizedFrozenDetailedToolTailLimit(for: turn) {
            return frozen
        }
        return min(standaloneToolBlockCount(for: turn), globalDetailedToolTailLimit)
    }

    static func projectionProtection(
        for transcript: AgentTranscript,
        viewportState: AgentTranscriptViewportState
    ) -> AgentTranscriptProjectionProtection {
        guard viewportState.isDetachedFromLiveBottom,
              let authority = viewportState.effectiveDetachedAuthority
        else {
            return .none
        }
        if let targetTurnID = authority.targetID.flatMap({ turnID(for: $0, in: transcript) }) {
            return .protectedTurn(targetTurnID)
        }
        if let anchorTurnID = authority.anchor.map(turnID(for:)) {
            return .protectedTurn(anchorTurnID)
        }
        if let sequenceIndex = authority.sequenceIndex,
           let sequenceTurnID = turnID(containingSequenceIndex: sequenceIndex, in: transcript)
        {
            return .protectedTurn(sequenceTurnID)
        }
        return .none
    }

    private static func turnID(
        for targetID: AgentTranscriptViewportTargetID,
        in transcript: AgentTranscript
    ) -> UUID? {
        switch targetID {
        case let .row(rowID):
            transcript.turns.first { turn in
                turn.request?.id == rowID || turn.allActivities.contains(where: { $0.id == rowID })
            }?.id
        case .block:
            nil
        }
    }

    private static func turnID(for anchor: AgentTranscriptAnchor) -> UUID {
        switch anchor {
        case let .request(turnID), let .summary(turnID), let .groupedHistory(turnID, _):
            turnID
        case let .activity(turnID, _, _), let .conclusion(turnID, _):
            turnID
        }
    }

    private static func turnID(
        containingSequenceIndex sequenceIndex: Int,
        in transcript: AgentTranscript
    ) -> UUID? {
        transcript.turns.first { turn in
            if turn.request?.sequenceIndex == sequenceIndex {
                return true
            }
            return turn.allActivities.contains(where: { $0.sequenceIndex == sequenceIndex })
        }?.id
    }

    private static func preferredDetailedToolTailLimit(for turn: AgentTranscriptTurn) -> Int {
        isEligibleForDetailedTailBoost(in: turn)
            ? boostedDetailedToolActivityThreshold
            : fullTurnDetailedActivityThreshold
    }

    private static func isEligibleForDetailedTailBoost(in turn: AgentTranscriptTurn) -> Bool {
        var previousSpanExceededBaseThreshold = false
        for span in turn.responseSpans {
            let orderedActivities = span.activities.sorted { lhs, rhs in
                if lhs.sequenceIndex == rhs.sequenceIndex {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.sequenceIndex < rhs.sequenceIndex
            }
            var seenStandaloneToolBlockCount = 0
            var hasOpenStandaloneToolBlock = false
            var openToolExecutionID: String?
            for activity in orderedActivities {
                guard !isSuppressedActivity(activity) else { continue }
                switch classify(activity: activity, in: turn) {
                case .standaloneTool:
                    let executionID = activity.toolExecution?.stableExecutionID
                    let startsNewBlock = !hasOpenStandaloneToolBlock || openToolExecutionID != executionID
                    guard startsNewBlock else { continue }
                    hasOpenStandaloneToolBlock = true
                    openToolExecutionID = executionID
                    if isDetailedTailBoostTool(activity: activity) {
                        return !previousSpanExceededBaseThreshold
                            && seenStandaloneToolBlockCount <= fullTurnDetailedActivityThreshold
                    }
                    seenStandaloneToolBlockCount += 1
                case .conclusion, .standaloneAssistant, .standaloneNote:
                    hasOpenStandaloneToolBlock = false
                    openToolExecutionID = nil
                }
            }
            if seenStandaloneToolBlockCount > fullTurnDetailedActivityThreshold {
                previousSpanExceededBaseThreshold = true
            }
        }
        return false
    }

    private static func isDetailedTailBoostTool(activity: AgentTranscriptActivity) -> Bool {
        guard activity.itemKind == .toolCall || activity.itemKind == .toolResult else { return false }
        let toolName = AgentTranscriptToolNormalizer.normalizedToolName(activity.toolExecution?.toolName) ?? ""
        return detailedToolTailBoostToolNames.contains(toolName)
    }

    fileprivate static func standaloneToolBlockCount(for turn: AgentTranscriptTurn) -> Int {
        var emittedConclusionActivityIDs = Set<UUID>()
        return turn.responseSpans.reduce(into: 0) { partial, span in
            let kinds = fullSpanLeafBlockKinds(
                for: span,
                in: turn,
                emittedConclusionActivityIDs: &emittedConclusionActivityIDs
            )
            partial += kinds.count(where: { $0 == .standaloneTool })
        }
    }

    private static func blocksForTurn(
        _ turn: AgentTranscriptTurn,
        archived: Bool,
        detailedToolTailLimit: Int,
        context: AgentTranscriptProjectionBuildContext,
        protectDetachedFocus: Bool
    ) -> [AgentTranscriptRenderBlock] {
        let unsortedBlocks: [AgentTranscriptRenderBlock] = if protectDetachedFocus, turn.retentionTier != .archived {
            fullBlocks(
                for: turn,
                archived: archived,
                detailedToolTailLimit: standaloneToolBlockCount(for: turn),
                context: context
            )
        } else {
            switch turn.retentionTier {
            case .full:
                fullBlocks(
                    for: turn,
                    archived: archived,
                    detailedToolTailLimit: detailedToolTailLimit,
                    context: context
                )
            case .condensed, .summary:
                compactTierBlocks(
                    for: turn,
                    archived: archived,
                    context: context
                )
            case .archived:
                compactedBlocks(for: turn, archived: archived)
            }
        }
        return unsortedBlocks.enumerated().sorted { lhs, rhs in
            let lhsSequence = blockSequenceIndex(lhs.element)
            let rhsSequence = blockSequenceIndex(rhs.element)
            if lhsSequence == rhsSequence {
                return lhs.offset < rhs.offset
            }
            return lhsSequence < rhsSequence
        }.map(\.element)
    }

    private static func blockSequenceIndex(_ block: AgentTranscriptRenderBlock) -> Int {
        if let rowSequence = block.rows.map(\.sequenceIndex).min() {
            return rowSequence
        }
        if let groupedHistory = block.groupedHistory {
            let childSequences = groupedHistory.sections
                .flatMap(\.childBlocks)
                .map(blockSequenceIndex)
            if let childSequence = childSequences.min() {
                return childSequence
            }
        }
        return Int.max
    }

    private static func estimatedBlockCount(for turn: AgentTranscriptTurn, detailedToolTailLimit: Int) -> Int {
        switch turn.retentionTier {
        case .full:
            estimatedFullBlockCount(for: turn, detailedToolTailLimit: detailedToolTailLimit)
        case .condensed, .summary:
            compactTierBlockCount(for: turn)
        case .archived:
            0
        }
    }

    private static func compactedVisibleRowCount(for turn: AgentTranscriptTurn) -> Int {
        compactedRows(for: turn).count
    }

    private static func compactTierBlockCount(for turn: AgentTranscriptTurn) -> Int {
        var count = turn.request == nil ? 0 : 1
        var emittedConclusionActivityIDs = Set<UUID>()
        for span in turn.responseSpans {
            if span.activities.isEmpty {
                if span.collapsedSummary != nil {
                    count += 1
                }
                continue
            }
            let leafDescriptors = fullSpanLeafDescriptors(
                for: span,
                in: turn,
                emittedConclusionActivityIDs: &emittedConclusionActivityIDs
            )
            let contentCount = leafDescriptors.count(where: { $0.kind != .conclusion })
            let conclusionCount = leafDescriptors.count(where: { $0.kind == .conclusion })
            count += (contentCount > 0 ? 1 : 0) + conclusionCount
        }
        if emittedConclusionActivityIDs.isEmpty, conclusionRow(for: turn) != nil {
            count += 1
        }
        return count
    }

    private static func compactTierVisibleRowCount(for turn: AgentTranscriptTurn) -> Int {
        var count = turn.request == nil ? 0 : 1
        var emittedConclusionActivityIDs = Set<UUID>()
        for span in turn.responseSpans {
            if span.activities.isEmpty {
                if span.collapsedSummary != nil {
                    count += 1
                }
                continue
            }
            let leafDescriptors = fullSpanLeafDescriptors(
                for: span,
                in: turn,
                emittedConclusionActivityIDs: &emittedConclusionActivityIDs
            )
            if leafDescriptors.contains(where: { $0.kind != .conclusion }) {
                count += 1
            }
            count += leafDescriptors
                .filter { $0.kind == .conclusion }
                .reduce(0) { $0 + $1.rowCount }
        }
        if emittedConclusionActivityIDs.isEmpty, conclusionRow(for: turn) != nil {
            count += 1
        }
        return count
    }

    private static func compactedRows(for turn: AgentTranscriptTurn) -> [AgentChatItem] {
        var rows: [AgentChatItem] = []
        if let request = turn.request?.toItem() {
            rows.append(request)
        }
        if let summaryRow = middleSummaryRow(for: turn) {
            rows.append(summaryRow)
        }
        if let conclusionRow = conclusionRow(for: turn) {
            rows.append(conclusionRow)
        }
        return rows
    }

    private static func estimatedFullBlockCount(for turn: AgentTranscriptTurn, detailedToolTailLimit: Int) -> Int {
        var count = turn.request == nil ? 0 : 1
        var emittedConclusionActivityIDs = Set<UUID>()
        for span in turn.responseSpans {
            count += estimatedFullSpanBlockCount(
                for: span,
                in: turn,
                detailedToolTailLimit: detailedToolTailLimit,
                emittedConclusionActivityIDs: &emittedConclusionActivityIDs
            )
        }
        if emittedConclusionActivityIDs.isEmpty, conclusionRow(for: turn) != nil {
            count += 1
        }
        return count
    }

    private static func fullTurnVisibleRowCount(
        for turn: AgentTranscriptTurn,
        detailedToolTailLimit: Int
    ) -> Int {
        var count = turn.request == nil ? 0 : 1
        var emittedConclusionActivityIDs = Set<UUID>()
        for span in turn.responseSpans {
            let leafDescriptors = fullSpanLeafDescriptors(
                for: span,
                in: turn,
                emittedConclusionActivityIDs: &emittedConclusionActivityIDs
            )
            count += collapsedVisibleRowCount(
                for: leafDescriptors,
                detailedToolTailLimit: detailedToolTailLimit
            )
        }
        if emittedConclusionActivityIDs.isEmpty, conclusionRow(for: turn) != nil {
            count += 1
        }
        return count
    }

    private static func estimatedFullSpanBlockCount(
        for span: AgentTranscriptProviderResponseSpan,
        in turn: AgentTranscriptTurn,
        detailedToolTailLimit: Int,
        emittedConclusionActivityIDs: inout Set<UUID>
    ) -> Int {
        let leafDescriptors = fullSpanLeafDescriptors(
            for: span,
            in: turn,
            emittedConclusionActivityIDs: &emittedConclusionActivityIDs
        )
        return collapsedBlockCount(for: leafDescriptors, detailedToolTailLimit: detailedToolTailLimit)
    }

    private static func fullSpanLeafBlockKinds(
        for span: AgentTranscriptProviderResponseSpan,
        in turn: AgentTranscriptTurn,
        emittedConclusionActivityIDs: inout Set<UUID>
    ) -> [AgentTranscriptRenderBlockKind] {
        let orderedActivities = span.activities.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        var kinds: [AgentTranscriptRenderBlockKind] = []
        var currentToolExecutionID: String?
        for activity in orderedActivities {
            guard !isSuppressedActivity(activity) else { continue }
            switch classify(activity: activity, in: turn) {
            case .conclusion:
                currentToolExecutionID = nil
                if emittedConclusionActivityIDs.insert(activity.id).inserted {
                    kinds.append(.conclusion)
                }
            case .standaloneTool:
                let stableExecutionID = activity.toolExecution?.stableExecutionID
                if currentToolExecutionID != stableExecutionID {
                    kinds.append(.standaloneTool)
                    currentToolExecutionID = stableExecutionID
                }
            case .standaloneAssistant:
                currentToolExecutionID = nil
                kinds.append(.standaloneAssistant)
            case .standaloneNote:
                currentToolExecutionID = nil
                kinds.append(.standaloneNote)
            }
        }
        return kinds
    }

    private static func fullSpanLeafDescriptors(
        for span: AgentTranscriptProviderResponseSpan,
        in turn: AgentTranscriptTurn,
        emittedConclusionActivityIDs: inout Set<UUID>
    ) -> [CollapsibleLeafDescriptor] {
        let orderedActivities = span.activities.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        var descriptors: [CollapsibleLeafDescriptor] = []
        var currentToolExecutionID: String?
        var currentToolRowCount = 0

        func flushStandaloneToolDescriptor() {
            guard currentToolRowCount > 0 else { return }
            descriptors.append(.init(kind: .standaloneTool, rowCount: currentToolRowCount))
            currentToolExecutionID = nil
            currentToolRowCount = 0
        }

        for activity in orderedActivities {
            guard !isSuppressedActivity(activity) else { continue }
            switch classify(activity: activity, in: turn) {
            case .conclusion:
                flushStandaloneToolDescriptor()
                if emittedConclusionActivityIDs.insert(activity.id).inserted {
                    descriptors.append(.init(kind: .conclusion, rowCount: 1))
                }
            case .standaloneTool:
                let stableExecutionID = activity.toolExecution?.stableExecutionID
                if currentToolRowCount > 0,
                   currentToolExecutionID == stableExecutionID
                {
                    currentToolRowCount += 1
                } else {
                    flushStandaloneToolDescriptor()
                    currentToolExecutionID = stableExecutionID
                    currentToolRowCount = 1
                }
            case .standaloneAssistant:
                flushStandaloneToolDescriptor()
                descriptors.append(.init(
                    kind: .standaloneAssistant,
                    rowCount: 1
                ))
            case .standaloneNote:
                flushStandaloneToolDescriptor()
                descriptors.append(.init(
                    kind: .standaloneNote,
                    rowCount: 1,
                    containsProgressNote: activity.itemKind == .thinking
                ))
            }
        }

        flushStandaloneToolDescriptor()
        return descriptors
    }

    private static func collapsedBlockCount(
        for leafDescriptors: [CollapsibleLeafDescriptor],
        detailedToolTailLimit: Int
    ) -> Int {
        collapsedPresentationMetrics(
            for: leafDescriptors,
            detailedToolTailLimit: detailedToolTailLimit
        ).visibleBlockCount
    }

    private static func collapsedVisibleRowCount(
        for leafDescriptors: [CollapsibleLeafDescriptor],
        detailedToolTailLimit: Int
    ) -> Int {
        collapsedPresentationMetrics(
            for: leafDescriptors,
            detailedToolTailLimit: detailedToolTailLimit
        ).visibleRowCount
    }

    private struct CollapsedPresentationMetrics {
        let visibleBlockCount: Int
        let visibleRowCount: Int
    }

    private static func collapsedPresentationMetrics(
        for leafDescriptors: [CollapsibleLeafDescriptor],
        detailedToolTailLimit: Int
    ) -> CollapsedPresentationMetrics {
        let conclusionDescriptors = leafDescriptors.filter { $0.kind == .conclusion }
        let conclusionBlockCount = conclusionDescriptors.count
        let conclusionRowCount = conclusionDescriptors.reduce(0) { $0 + $1.rowCount }
        let contentDescriptors = leafDescriptors.filter { $0.kind != .conclusion }
        let toolIndices = contentDescriptors.indices.filter { contentDescriptors[$0].kind == .standaloneTool }
        guard !toolIndices.isEmpty else {
            return .init(
                visibleBlockCount: contentDescriptors.count + conclusionBlockCount,
                visibleRowCount: contentDescriptors.reduce(0) { $0 + $1.rowCount } + conclusionRowCount
            )
        }

        let detailedStartIndex: Int
        if detailedToolTailLimit <= 0 {
            detailedStartIndex = contentDescriptors.count
        } else {
            guard toolIndices.count > detailedToolTailLimit else {
                return .init(
                    visibleBlockCount: contentDescriptors.count + conclusionBlockCount,
                    visibleRowCount: contentDescriptors.reduce(0) { $0 + $1.rowCount } + conclusionRowCount
                )
            }
            let firstKeptToolIndex = toolIndices[toolIndices.count - detailedToolTailLimit]
            var computedDetailedStartIndex = firstKeptToolIndex
            while computedDetailedStartIndex > 0 {
                let previousDescriptor = contentDescriptors[computedDetailedStartIndex - 1]
                if previousDescriptor.kind == .standaloneTool {
                    break
                }
                computedDetailedStartIndex -= 1
            }
            detailedStartIndex = computedDetailedStartIndex
        }

        let collapsedPrefix = contentDescriptors.prefix(detailedStartIndex)
        let detailedSuffix = contentDescriptors.dropFirst(detailedStartIndex)
        guard !collapsedPrefix.isEmpty else {
            return .init(
                visibleBlockCount: contentDescriptors.count + conclusionBlockCount,
                visibleRowCount: contentDescriptors.reduce(0) { $0 + $1.rowCount } + conclusionRowCount
            )
        }

        let bufferedLeadingDescriptor = shouldBufferLeadingAssistant(in: collapsedPrefix)
            ? collapsedPrefix.first
            : nil
        return .init(
            visibleBlockCount: 1 + (bufferedLeadingDescriptor == nil ? 0 : 1) + detailedSuffix.count + conclusionBlockCount,
            visibleRowCount: 1
                + (bufferedLeadingDescriptor?.rowCount ?? 0)
                + detailedSuffix.reduce(0) { $0 + $1.rowCount }
                + conclusionRowCount
        )
    }

    private static func filteredRowAnchorIndex(
        _ index: [UUID: AgentTranscriptAnchor],
        retaining rowIDs: Set<UUID>
    ) -> [UUID: AgentTranscriptAnchor] {
        guard !index.isEmpty, !rowIDs.isEmpty else { return [:] }
        return index.filter { rowIDs.contains($0.key) }
    }

    private static func filteredAnchorBlockIndex(
        _ index: [AgentTranscriptAnchor: String],
        retaining blockIDs: Set<String>
    ) -> [AgentTranscriptAnchor: String] {
        guard !index.isEmpty, !blockIDs.isEmpty else { return [:] }
        return index.filter { blockIDs.contains($0.value) }
    }

    private static func presentedItemCount(for blocks: [AgentTranscriptRenderBlock]) -> Int {
        blocks.reduce(0) { partial, block in
            partial + presentedItemCount(for: block)
        }
    }

    private static func presentedItemCount(for block: AgentTranscriptRenderBlock) -> Int {
        switch block.kind {
        case .activityCluster, .groupedHistory:
            1
        case .request, .standaloneAssistant, .standaloneTool, .standaloneNote, .middleSummary, .conclusion:
            block.rows.count
        }
    }

    private static func shouldBufferLeadingAssistant(
        in collapsedPrefix: [AgentTranscriptRenderBlock]
    ) -> Bool {
        guard let firstCollapsed = collapsedPrefix.first,
              firstCollapsed.kind == .standaloneAssistant
        else {
            return false
        }
        return !collapsedPrefix.dropFirst().contains { block in
            block.kind == .standaloneNote && block.rows.contains(where: { $0.kind == .thinking })
        }
    }

    private static func shouldBufferLeadingAssistant(
        in collapsedPrefix: ArraySlice<CollapsibleLeafDescriptor>
    ) -> Bool {
        guard let firstCollapsed = collapsedPrefix.first,
              firstCollapsed.kind == .standaloneAssistant
        else {
            return false
        }
        return !collapsedPrefix.dropFirst().contains(where: \.containsProgressNote)
    }

    private static func groupedHistoryCollapsePlan(
        in leafBlocks: [AgentTranscriptRenderBlock],
        spanID: UUID,
        detailedToolTailLimit: Int
    ) -> GroupedHistoryCollapsePlan? {
        let conclusionBlocks = leafBlocks.filter { $0.kind == .conclusion }
        let contentBlocks = leafBlocks.filter { $0.kind != .conclusion }
        let toolIndices = contentBlocks.indices.filter { contentBlocks[$0].kind == .standaloneTool }
        guard !toolIndices.isEmpty else { return nil }

        let collapsedPrefix: [AgentTranscriptRenderBlock]
        let detailedSuffix: [AgentTranscriptRenderBlock]
        if detailedToolTailLimit <= 0 {
            collapsedPrefix = contentBlocks
            detailedSuffix = []
        } else {
            guard toolIndices.count > detailedToolTailLimit else { return nil }
            let firstKeptToolIndex = toolIndices[toolIndices.count - detailedToolTailLimit]
            var detailedStartIndex = firstKeptToolIndex
            while detailedStartIndex > 0 {
                let previousBlock = contentBlocks[detailedStartIndex - 1]
                if previousBlock.kind == .standaloneTool || previousBlock.spanID != spanID {
                    break
                }
                detailedStartIndex -= 1
            }
            collapsedPrefix = Array(contentBlocks.prefix(detailedStartIndex))
            detailedSuffix = Array(contentBlocks.dropFirst(detailedStartIndex))
        }
        guard !collapsedPrefix.isEmpty else { return nil }

        let bufferedLeadingAssistant: AgentTranscriptRenderBlock?
        let groupedPrefix: [AgentTranscriptRenderBlock]
        if shouldBufferLeadingAssistant(in: collapsedPrefix),
           let firstCollapsed = collapsedPrefix.first
        {
            bufferedLeadingAssistant = firstCollapsed
            groupedPrefix = Array(collapsedPrefix.dropFirst())
        } else {
            bufferedLeadingAssistant = nil
            groupedPrefix = collapsedPrefix
        }
        guard !groupedPrefix.isEmpty else { return nil }

        return GroupedHistoryCollapsePlan(
            contentBlocks: contentBlocks,
            conclusionBlocks: conclusionBlocks,
            collapsedPrefix: collapsedPrefix,
            groupedPrefix: groupedPrefix,
            detailedSuffix: detailedSuffix,
            bufferedLeadingAssistant: bufferedLeadingAssistant,
            collapseDigest: groupedHistoryCollapseDigest(
                for: collapsedPrefix,
                detailedToolTailLimit: detailedToolTailLimit
            )
        )
    }

    private static func groupedHistoryCollapseDigest(
        for collapsedPrefix: [AgentTranscriptRenderBlock],
        detailedToolTailLimit: Int
    ) -> String {
        let blockSignature = collapsedPrefix.map { block in
            let activityIDs = block.activityIDs.map { $0.uuidString.lowercased() }.joined(separator: ",")
            return "\(block.kind.rawValue)|\(block.id)|\(activityIDs)"
        }.joined(separator: ";")
        return "tail:\(detailedToolTailLimit)#\(blockSignature)"
    }

    private static func requestBlockID(_ requestID: UUID) -> String {
        "block-\(requestID.uuidString.lowercased())"
    }

    private static func requestAnchor(for turnID: UUID) -> AgentTranscriptAnchor {
        .request(turnID: turnID)
    }

    private static func summaryAnchor(for turnID: UUID) -> AgentTranscriptAnchor {
        .summary(turnID: turnID)
    }

    private static func groupedHistoryAnchor(for turnID: UUID, spanID: UUID) -> AgentTranscriptAnchor {
        .groupedHistory(turnID: turnID, spanID: spanID)
    }

    private static func activityAnchor(for activityID: UUID, turnID: UUID, spanID: UUID) -> AgentTranscriptAnchor {
        .activity(turnID: turnID, spanID: spanID, activityID: activityID)
    }

    private static func conclusionAnchor(for activityID: UUID, turnID: UUID) -> AgentTranscriptAnchor {
        .conclusion(turnID: turnID, activityID: activityID)
    }

    private static func semanticAnchor(for activityID: UUID, in turn: AgentTranscriptTurn, spanID: UUID) -> AgentTranscriptAnchor {
        if activityID == turn.conclusionActivityID {
            return conclusionAnchor(for: activityID, turnID: turn.id)
        }
        return activityAnchor(for: activityID, turnID: turn.id, spanID: spanID)
    }

    private static func activityBlockID(_ activityID: UUID?, fallback turnID: UUID) -> String {
        "block-\((activityID ?? turnID).uuidString.lowercased())"
    }

    private static func groupedHistoryBlockID(turnID: UUID, spanID: UUID) -> String {
        "grouped-history:\(turnID.uuidString.lowercased()):\(spanID.uuidString.lowercased())"
    }

    private static func summaryBlockID(_ summaryID: UUID) -> String {
        "block-\(summaryID.uuidString.lowercased())"
    }

    fileprivate static let globalDetailedToolTailLimit = 8
    private static let fullTurnDetailedActivityThreshold = 5
    private static let boostedDetailedToolActivityThreshold = 10
    private static let detailedToolTailBoostToolNames: Set<String> = ["apply_edits", "apply_patch", "bash"]

    private enum ActivityRenderClass {
        case conclusion
        case standaloneAssistant
        case standaloneTool
        case standaloneNote
    }

    private static func fullBlocks(
        for turn: AgentTranscriptTurn,
        archived: Bool,
        detailedToolTailLimit: Int,
        context: AgentTranscriptProjectionBuildContext
    ) -> [AgentTranscriptRenderBlock] {
        var blocks: [AgentTranscriptRenderBlock] = []
        if let request = turn.request {
            blocks.append(.init(
                id: requestBlockID(request.id),
                kind: .request,
                turnID: turn.id,
                retentionTier: turn.retentionTier,
                rows: [request.toItem()],
                isArchived: archived,
                primaryAnchor: requestAnchor(for: turn.id)
            ))
        }
        var emittedConclusionActivityIDs = Set<UUID>()
        for span in turn.responseSpans {
            let leafBlocks = fullSpanLeafBlocks(
                for: span,
                in: turn,
                archived: archived,
                emittedConclusionActivityIDs: &emittedConclusionActivityIDs
            )
            blocks.append(contentsOf: collapseOlderHistory(
                in: leafBlocks,
                span: span,
                turn: turn,
                spanID: span.id,
                archived: archived,
                detailedToolTailLimit: detailedToolTailLimit,
                context: context
            ))
        }
        if emittedConclusionActivityIDs.isEmpty,
           let conclusionRow = conclusionRow(for: turn)
        {
            blocks.append(.init(
                id: activityBlockID(turn.conclusionActivityID ?? conclusionRow.id, fallback: turn.id),
                kind: .conclusion,
                turnID: turn.id,
                retentionTier: turn.retentionTier,
                rows: [conclusionRow],
                isArchived: archived,
                primaryAnchor: conclusionAnchor(for: turn.conclusionActivityID ?? conclusionRow.id, turnID: turn.id),
                anchorActivityID: turn.conclusionActivityID ?? conclusionRow.id,
                activityIDs: turn.conclusionActivityID.map { [$0] } ?? [conclusionRow.id]
            ))
        }
        return blocks
    }

    private static func compactTierBlocks(
        for turn: AgentTranscriptTurn,
        archived: Bool,
        context: AgentTranscriptProjectionBuildContext
    ) -> [AgentTranscriptRenderBlock] {
        var blocks: [AgentTranscriptRenderBlock] = []
        if let request = turn.request {
            blocks.append(.init(
                id: requestBlockID(request.id),
                kind: .request,
                turnID: turn.id,
                retentionTier: turn.retentionTier,
                rows: [request.toItem()],
                isArchived: archived,
                primaryAnchor: requestAnchor(for: turn.id)
            ))
        }
        var emittedConclusionActivityIDs = Set<UUID>()
        for span in turn.responseSpans {
            if span.activities.isEmpty {
                if let collapsedSummary = span.collapsedSummary {
                    blocks.append(groupedHistoryBlock(
                        for: [],
                        frozenSummary: collapsedSummary,
                        turn: turn,
                        spanID: span.id,
                        archived: archived,
                        context: context
                    ))
                }
                continue
            }
            let leafBlocks = fullSpanLeafBlocks(
                for: span,
                in: turn,
                archived: archived,
                emittedConclusionActivityIDs: &emittedConclusionActivityIDs
            )
            let contentBlocks = leafBlocks.filter { $0.kind != .conclusion }
            let conclusionBlocks = leafBlocks.filter { $0.kind == .conclusion }
            if !contentBlocks.isEmpty {
                blocks.append(groupedHistoryBlock(
                    for: contentBlocks,
                    frozenSummary: span.collapsedSummary,
                    turn: turn,
                    spanID: span.id,
                    archived: archived,
                    context: context
                ))
            }
            blocks.append(contentsOf: conclusionBlocks)
        }
        if emittedConclusionActivityIDs.isEmpty,
           let conclusionRow = conclusionRow(for: turn)
        {
            blocks.append(.init(
                id: activityBlockID(turn.conclusionActivityID ?? conclusionRow.id, fallback: turn.id),
                kind: .conclusion,
                turnID: turn.id,
                retentionTier: turn.retentionTier,
                rows: [conclusionRow],
                isArchived: archived,
                primaryAnchor: conclusionAnchor(for: turn.conclusionActivityID ?? conclusionRow.id, turnID: turn.id),
                anchorActivityID: turn.conclusionActivityID ?? conclusionRow.id,
                activityIDs: turn.conclusionActivityID.map { [$0] } ?? [conclusionRow.id]
            ))
        }
        return blocks
    }

    private static func compactedBlocks(for turn: AgentTranscriptTurn, archived: Bool) -> [AgentTranscriptRenderBlock] {
        var blocks: [AgentTranscriptRenderBlock] = []
        if let request = turn.request {
            blocks.append(.init(
                id: requestBlockID(request.id),
                kind: .request,
                turnID: turn.id,
                retentionTier: turn.retentionTier,
                rows: [request.toItem()],
                isArchived: archived,
                primaryAnchor: requestAnchor(for: turn.id)
            ))
        }
        if let summaryRow = middleSummaryRow(for: turn) {
            blocks.append(.init(
                id: summaryBlockID(summaryRow.id),
                kind: .middleSummary,
                turnID: turn.id,
                retentionTier: turn.retentionTier,
                rows: [summaryRow],
                isArchived: archived,
                primaryAnchor: summaryAnchor(for: turn.id),
                anchorActivityID: summaryRow.id,
                activityIDs: [summaryRow.id]
            ))
        }
        if let conclusionRow = conclusionRow(for: turn) {
            blocks.append(.init(
                id: activityBlockID(turn.conclusionActivityID ?? conclusionRow.id, fallback: turn.id),
                kind: .conclusion,
                turnID: turn.id,
                retentionTier: turn.retentionTier,
                rows: [conclusionRow],
                isArchived: archived,
                primaryAnchor: conclusionAnchor(for: turn.conclusionActivityID ?? conclusionRow.id, turnID: turn.id),
                anchorActivityID: turn.conclusionActivityID ?? conclusionRow.id,
                activityIDs: turn.conclusionActivityID.map { [$0] } ?? [conclusionRow.id]
            ))
        }
        return blocks
    }

    private static func classify(activity: AgentTranscriptActivity, in turn: AgentTranscriptTurn) -> ActivityRenderClass {
        if activity.id == turn.conclusionActivityID {
            return .conclusion
        }
        switch activity.itemKind {
        case .assistant, .assistantInline:
            return .standaloneAssistant
        case .toolCall, .toolResult:
            return .standaloneTool
        case .thinking, .system:
            return .standaloneNote
        case .error, .user:
            return .standaloneNote
        }
    }

    private static func fullSpanLeafBlocks(
        for span: AgentTranscriptProviderResponseSpan,
        in turn: AgentTranscriptTurn,
        archived: Bool,
        emittedConclusionActivityIDs: inout Set<UUID>
    ) -> [AgentTranscriptRenderBlock] {
        let orderedActivities = span.activities.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        var blocks: [AgentTranscriptRenderBlock] = []
        var standaloneToolActivities: [AgentTranscriptActivity] = []

        func flushStandaloneToolActivities() {
            guard !standaloneToolActivities.isEmpty else { return }
            blocks.append(standaloneToolBlock(
                for: standaloneToolActivities,
                turn: turn,
                spanID: span.id,
                archived: archived
            ))
            standaloneToolActivities.removeAll(keepingCapacity: true)
        }

        for activity in orderedActivities {
            guard !isSuppressedActivity(activity) else { continue }
            let renderClass = classify(activity: activity, in: turn)
            if renderClass == .conclusion {
                flushStandaloneToolActivities()
                if emittedConclusionActivityIDs.insert(activity.id).inserted {
                    blocks.append(conclusionBlock(
                        for: activity,
                        turn: turn,
                        spanID: span.id,
                        archived: archived
                    ))
                }
                continue
            }

            switch renderClass {
            case .standaloneTool:
                if standaloneToolActivities.first?.toolExecution?.stableExecutionID == activity.toolExecution?.stableExecutionID {
                    standaloneToolActivities.append(activity)
                } else {
                    flushStandaloneToolActivities()
                    standaloneToolActivities.append(activity)
                }
            case .standaloneAssistant, .standaloneNote:
                flushStandaloneToolActivities()
                blocks.append(standaloneBlock(
                    for: activity,
                    renderClass: renderClass,
                    turn: turn,
                    spanID: span.id,
                    archived: archived
                ))
            case .conclusion:
                break
            }
        }

        flushStandaloneToolActivities()
        return blocks
    }

    private static func isDisplaylessAssistant(_ activity: AgentTranscriptActivity) -> Bool {
        guard activity.itemKind == .assistant || activity.itemKind == .assistantInline else { return false }
        return !AgentDisplayableText.hasDisplayableBody(activity.text)
    }

    private static func isSuppressedActivity(_ activity: AgentTranscriptActivity) -> Bool {
        isDisplaylessAssistant(activity) || AgentTranscriptToolVisibilityPolicy.shouldSuppressActivity(activity)
    }

    private static func collapseOlderHistory(
        in leafBlocks: [AgentTranscriptRenderBlock],
        span: AgentTranscriptProviderResponseSpan,
        turn: AgentTranscriptTurn,
        spanID: UUID,
        archived: Bool,
        detailedToolTailLimit: Int,
        context: AgentTranscriptProjectionBuildContext
    ) -> [AgentTranscriptRenderBlock] {
        guard !leafBlocks.isEmpty else { return [] }
        guard let plan = groupedHistoryCollapsePlan(
            in: leafBlocks,
            spanID: spanID,
            detailedToolTailLimit: detailedToolTailLimit
        ) else {
            let conclusionBlocks = leafBlocks.filter { $0.kind == .conclusion }
            let contentBlocks = leafBlocks.filter { $0.kind != .conclusion }
            return contentBlocks + conclusionBlocks
        }

        var visibleBlocks: [AgentTranscriptRenderBlock] = []
        if let bufferedLeadingAssistant = plan.bufferedLeadingAssistant {
            visibleBlocks.append(bufferedLeadingAssistant)
        }
        if !plan.groupedPrefix.isEmpty {
            let frozenSummary: AgentTranscriptGroupedHistorySummary? = if let cache = span.fullRenderGroupedHistoryCache,
                                                                          cache.detailedToolTailLimit == detailedToolTailLimit,
                                                                          cache.collapseDigest == plan.collapseDigest
            {
                cache.summary
            } else {
                nil
            }
            visibleBlocks.append(groupedHistoryBlock(
                for: plan.groupedPrefix,
                summarySourceBlocks: plan.collapsedPrefix,
                frozenSummary: frozenSummary,
                turn: turn,
                spanID: spanID,
                archived: archived,
                context: context
            ))
        }
        if !plan.detailedSuffix.isEmpty {
            visibleBlocks.append(contentsOf: plan.detailedSuffix)
        }
        return visibleBlocks + plan.conclusionBlocks
    }

    private static func standaloneBlock(
        for activity: AgentTranscriptActivity,
        renderClass: ActivityRenderClass,
        turn: AgentTranscriptTurn,
        spanID: UUID,
        archived: Bool
    ) -> AgentTranscriptRenderBlock {
        let kind: AgentTranscriptRenderBlockKind = switch renderClass {
        case .standaloneAssistant:
            .standaloneAssistant
        case .standaloneTool:
            .standaloneTool
        case .standaloneNote:
            .standaloneNote
        case .conclusion:
            .standaloneNote
        }
        return .init(
            id: activityBlockID(activity.id, fallback: turn.id),
            kind: kind,
            turnID: turn.id,
            spanID: spanID,
            retentionTier: turn.retentionTier,
            rows: [activity.toItem()],
            isArchived: archived,
            primaryAnchor: semanticAnchor(for: activity.id, in: turn, spanID: spanID),
            anchorActivityID: activity.id,
            activityIDs: [activity.id]
        )
    }

    private static func activityClusterBlock(
        for childBlocks: [AgentTranscriptRenderBlock],
        turn: AgentTranscriptTurn,
        spanID: UUID,
        archived: Bool,
        context: AgentTranscriptProjectionBuildContext
    ) -> AgentTranscriptRenderBlock {
        let rows = childBlocks.flatMap(\.rows)
        let allActivityIDs = childBlocks.flatMap(\.activityIDs)
        let anchorActivityID = allActivityIDs.first
        return .init(
            id: activityBlockID(anchorActivityID, fallback: turn.id),
            kind: .activityCluster,
            turnID: turn.id,
            spanID: spanID,
            retentionTier: turn.retentionTier,
            rows: rows,
            isArchived: archived,
            primaryAnchor: childBlocks.first?.primaryAnchor,
            anchorActivityID: anchorActivityID,
            activityIDs: allActivityIDs,
            clusterSummary: clusterSummary(for: rows, context: context),
            defaultPresentation: .collapsed
        )
    }

    private static func standaloneToolBlock(
        for activities: [AgentTranscriptActivity],
        turn: AgentTranscriptTurn,
        spanID: UUID,
        archived: Bool
    ) -> AgentTranscriptRenderBlock {
        let rows = activities.map { $0.toItem() }
        let anchorActivityID = activities.first?.id
        return .init(
            id: activityBlockID(anchorActivityID, fallback: turn.id),
            kind: .standaloneTool,
            turnID: turn.id,
            spanID: spanID,
            retentionTier: turn.retentionTier,
            rows: rows,
            isArchived: archived,
            primaryAnchor: anchorActivityID.map { semanticAnchor(for: $0, in: turn, spanID: spanID) },
            anchorActivityID: anchorActivityID,
            activityIDs: activities.map(\.id)
        )
    }

    private static func groupedHistoryBlock(
        for childBlocks: [AgentTranscriptRenderBlock],
        summarySourceBlocks: [AgentTranscriptRenderBlock]? = nil,
        frozenSummary: AgentTranscriptGroupedHistorySummary? = nil,
        turn: AgentTranscriptTurn,
        spanID: UUID,
        archived: Bool,
        context: AgentTranscriptProjectionBuildContext
    ) -> AgentTranscriptRenderBlock {
        let allActivityIDs = childBlocks.flatMap(\.activityIDs)
        let summaryBlocks = summarySourceBlocks ?? childBlocks
        let presentationSummary = frozenSummary.map(sanitizedGroupedHistorySummaryForPresentation)
        return .init(
            id: groupedHistoryBlockID(turnID: turn.id, spanID: spanID),
            kind: .groupedHistory,
            turnID: turn.id,
            spanID: spanID,
            retentionTier: turn.retentionTier,
            rows: [],
            isArchived: archived,
            primaryAnchor: groupedHistoryAnchor(for: turn.id, spanID: spanID),
            anchorActivityID: allActivityIDs.first,
            activityIDs: allActivityIDs,
            groupedHistory: .init(
                summary: presentationSummary ?? groupedHistorySummary(
                    for: childBlocks,
                    summarySourceBlocks: summaryBlocks,
                    context: context
                ),
                sections: turn.retentionTier == .full
                    ? groupedHistorySections(
                        for: childBlocks,
                        spanID: spanID,
                        context: context
                    )
                    : []
            ),
            defaultPresentation: .collapsed
        )
    }

    private static func conclusionBlock(
        for activity: AgentTranscriptActivity,
        turn: AgentTranscriptTurn,
        spanID: UUID,
        archived: Bool
    ) -> AgentTranscriptRenderBlock {
        .init(
            id: activityBlockID(activity.id, fallback: turn.id),
            kind: .conclusion,
            turnID: turn.id,
            spanID: spanID,
            retentionTier: turn.retentionTier,
            rows: [activity.toItem(isStreaming: false)],
            isArchived: archived,
            primaryAnchor: conclusionAnchor(for: activity.id, turnID: turn.id),
            anchorActivityID: activity.id,
            activityIDs: [activity.id]
        )
    }

    private static func sanitizedGroupedHistorySummaryForPresentation(
        _ summary: AgentTranscriptGroupedHistorySummary
    ) -> AgentTranscriptGroupedHistorySummary {
        let placeholderSanitized = placeholderSanitizedGroupedHistorySummaryForPresentation(summary)
        return retaxedAgentControlGroupedHistorySummaryForPresentation(placeholderSanitized)
    }

    private static func placeholderSanitizedGroupedHistorySummaryForPresentation(
        _ summary: AgentTranscriptGroupedHistorySummary
    ) -> AgentTranscriptGroupedHistorySummary {
        guard let toolSummary = summary.toolSummary,
              !toolSummary.containsFailure,
              !toolSummary.containsWarning
        else {
            return summary
        }
        let placeholderNames = Set(toolSummary.toolNames.filter(AgentTranscriptToolVisibilityPolicy.isPlaceholderToolName))
        let placeholderCount = toolSummary.toolNameCounts.reduce(0) { partial, entry in
            AgentTranscriptToolVisibilityPolicy.isPlaceholderToolName(entry.key) ? partial + entry.value : partial
        }
        guard !placeholderNames.isEmpty || placeholderCount > 0 else { return summary }
        let filteredNames = toolSummary.toolNames.filter { !AgentTranscriptToolVisibilityPolicy.isPlaceholderToolName($0) }
        let filteredCounts = toolSummary.toolNameCounts.filter { !AgentTranscriptToolVisibilityPolicy.isPlaceholderToolName($0.key) }
        let remainingToolCount = max(0, toolSummary.toolCount - max(placeholderCount, placeholderNames.count))
        let filteredToolSummary: AgentTranscriptClusterSummary? = remainingToolCount > 0 || toolSummary.shortNarration != nil
            ? AgentTranscriptClusterSummary(
                toolCount: remainingToolCount,
                toolNames: filteredNames,
                toolNameCounts: filteredCounts,
                toolGroups: ClusterToolCategory.buildGroups(
                    toolNames: filteredCounts.isEmpty ? filteredNames : Array(filteredCounts.keys.sorted()),
                    counts: filteredCounts
                ),
                keyPaths: toolSummary.keyPaths,
                containsRunningWork: toolSummary.containsRunningWork,
                containsFailure: toolSummary.containsFailure,
                containsWarning: toolSummary.containsWarning,
                shortNarration: toolSummary.shortNarration
            )
            : nil
        let hiddenToolCardCount = max(0, summary.hiddenToolCardCount - max(placeholderCount, placeholderNames.count))
        let sanitized = AgentTranscriptGroupedHistorySummary(
            hiddenToolCardCount: hiddenToolCardCount,
            hiddenAssistantCount: summary.hiddenAssistantCount,
            hiddenProgressCount: summary.hiddenProgressCount,
            hiddenNoteCount: summary.hiddenNoteCount,
            toolSummary: filteredToolSummary
        )
        return AgentTranscriptGroupedHistorySummary(
            hiddenToolCardCount: sanitized.hiddenToolCardCount,
            hiddenAssistantCount: sanitized.hiddenAssistantCount,
            hiddenProgressCount: sanitized.hiddenProgressCount,
            hiddenNoteCount: sanitized.hiddenNoteCount,
            toolSummary: sanitized.toolSummary,
            collapsedDisplay: AgentTranscriptSummaryTextFormatter.collapsedDisplay(summary: sanitized)
        )
    }

    private static func retaxedAgentControlGroupedHistorySummaryForPresentation(
        _ summary: AgentTranscriptGroupedHistorySummary
    ) -> AgentTranscriptGroupedHistorySummary {
        guard let toolSummary = summary.toolSummary else { return summary }
        let sourceNames = toolSummary.toolNames + Array(toolSummary.toolNameCounts.keys)
        guard sourceNames.contains(where: {
            ClusterToolCategory.classification(forNormalizedToolName: $0).family == .agentControl
        }) else {
            return summary
        }

        let groupSourceNames = toolSummary.toolNameCounts.isEmpty
            ? toolSummary.toolNames
            : Array(toolSummary.toolNameCounts.keys.sorted())
        let retaxedToolGroups = ClusterToolCategory.buildGroups(
            toolNames: groupSourceNames,
            counts: toolSummary.toolNameCounts
        )
        let retaxedToolSummaryBase = AgentTranscriptClusterSummary(
            toolCount: toolSummary.toolCount,
            toolNames: toolSummary.toolNames,
            toolNameCounts: toolSummary.toolNameCounts,
            toolGroups: retaxedToolGroups,
            keyPaths: toolSummary.keyPaths,
            containsRunningWork: toolSummary.containsRunningWork,
            containsFailure: toolSummary.containsFailure,
            containsWarning: toolSummary.containsWarning,
            shortNarration: toolSummary.shortNarration
        )
        let retaxedToolSummary = AgentTranscriptClusterSummary(
            toolCount: retaxedToolSummaryBase.toolCount,
            toolNames: retaxedToolSummaryBase.toolNames,
            toolNameCounts: retaxedToolSummaryBase.toolNameCounts,
            toolGroups: retaxedToolSummaryBase.toolGroups,
            keyPaths: retaxedToolSummaryBase.keyPaths,
            containsRunningWork: retaxedToolSummaryBase.containsRunningWork,
            containsFailure: retaxedToolSummaryBase.containsFailure,
            containsWarning: retaxedToolSummaryBase.containsWarning,
            shortNarration: retaxedToolSummaryBase.shortNarration,
            collapsedDisplay: AgentTranscriptSummaryTextFormatter.collapsedDisplay(
                for: retaxedToolSummaryBase,
                fallbackCount: retaxedToolSummaryBase.toolCount
            )
        )
        let retaxedSummary = AgentTranscriptGroupedHistorySummary(
            hiddenToolCardCount: summary.hiddenToolCardCount,
            hiddenAssistantCount: summary.hiddenAssistantCount,
            hiddenProgressCount: summary.hiddenProgressCount,
            hiddenNoteCount: summary.hiddenNoteCount,
            toolSummary: retaxedToolSummary
        )
        return AgentTranscriptGroupedHistorySummary(
            hiddenToolCardCount: retaxedSummary.hiddenToolCardCount,
            hiddenAssistantCount: retaxedSummary.hiddenAssistantCount,
            hiddenProgressCount: retaxedSummary.hiddenProgressCount,
            hiddenNoteCount: retaxedSummary.hiddenNoteCount,
            toolSummary: retaxedSummary.toolSummary,
            collapsedDisplay: AgentTranscriptSummaryTextFormatter.collapsedDisplay(summary: retaxedSummary)
        )
    }

    private static func groupedHistorySummary(
        for childBlocks: [AgentTranscriptRenderBlock],
        summarySourceBlocks: [AgentTranscriptRenderBlock]? = nil,
        context: AgentTranscriptProjectionBuildContext
    ) -> AgentTranscriptGroupedHistorySummary {
        let hiddenAssistantCount = childBlocks.reduce(0) { partial, block in
            partial + block.rows.filter(\.hasDisplayableAssistantBody).count
        }
        let hiddenProgressCount = childBlocks.reduce(0) { partial, block in
            partial + block.rows.count(where: { $0.kind == .thinking })
        }
        let hiddenNoteCount = childBlocks.reduce(0) { partial, block in
            partial + block.rows.count(where: { $0.kind == .system || $0.kind == .error })
        }
        let summaryRows = (summarySourceBlocks ?? childBlocks).flatMap(\.rows)
        let summary = AgentTranscriptGroupedHistorySummary(
            hiddenToolCardCount: childBlocks.count(where: { $0.kind == .standaloneTool }),
            hiddenAssistantCount: hiddenAssistantCount,
            hiddenProgressCount: hiddenProgressCount,
            hiddenNoteCount: hiddenNoteCount,
            toolSummary: clusterSummary(for: summaryRows, context: context)
        )
        return AgentTranscriptGroupedHistorySummary(
            hiddenToolCardCount: summary.hiddenToolCardCount,
            hiddenAssistantCount: summary.hiddenAssistantCount,
            hiddenProgressCount: summary.hiddenProgressCount,
            hiddenNoteCount: summary.hiddenNoteCount,
            toolSummary: summary.toolSummary,
            collapsedDisplay: AgentTranscriptSummaryTextFormatter.collapsedDisplay(summary: summary)
        )
    }

    private static func groupedHistorySections(
        for childBlocks: [AgentTranscriptRenderBlock],
        spanID: UUID,
        context: AgentTranscriptProjectionBuildContext
    ) -> [AgentTranscriptGroupedSection] {
        guard !childBlocks.isEmpty else { return [] }
        var sections: [AgentTranscriptGroupedSection] = []
        var currentBlocks: [AgentTranscriptRenderBlock] = []

        func flushSection() {
            guard !currentBlocks.isEmpty else { return }
            let kind = groupedSectionKind(for: currentBlocks)
            let firstChildID = currentBlocks.first?.id ?? UUID().uuidString.lowercased()
            let summary = currentBlocks.contains(where: { $0.kind == .standaloneTool })
                ? clusterSummary(for: currentBlocks.flatMap(\.rows), context: context)
                : nil
            let titleAndIcon = groupedSectionTitleAndIcon(kind: kind, sectionSummary: summary)
            sections.append(.init(
                id: "grouped-section:\(spanID.uuidString.lowercased()):\(firstChildID)",
                kind: kind,
                title: titleAndIcon.title,
                icon: titleAndIcon.icon,
                childBlocks: currentBlocks,
                clusterSummary: summary
            ))
            currentBlocks.removeAll(keepingCapacity: true)
        }

        for block in childBlocks {
            if shouldStartNewGroupedSection(currentBlocks: currentBlocks, nextBlock: block) {
                flushSection()
            }
            currentBlocks.append(block)
        }
        flushSection()
        return sections
    }

    private static func shouldStartNewGroupedSection(
        currentBlocks: [AgentTranscriptRenderBlock],
        nextBlock: AgentTranscriptRenderBlock
    ) -> Bool {
        guard let currentBlock = currentBlocks.last else { return false }
        return groupedSectionAffinity(for: currentBlock) != groupedSectionAffinity(for: nextBlock)
    }

    private static func groupedSectionAffinity(for block: AgentTranscriptRenderBlock) -> GroupedSectionAffinity {
        switch block.kind {
        case .standaloneTool, .standaloneAssistant:
            .activity
        case .standaloneNote:
            block.rows.contains(where: { $0.kind == .thinking }) ? .activity : .notes
        case .request, .activityCluster, .groupedHistory, .middleSummary, .conclusion:
            .mixed
        }
    }

    private static func groupedSectionKind(for childBlocks: [AgentTranscriptRenderBlock]) -> AgentTranscriptGroupedSectionKind {
        var containsTools = false
        var containsAssistant = false
        var containsProgress = false
        var containsNotes = false
        var containsMixed = false

        for block in childBlocks {
            switch block.kind {
            case .standaloneTool:
                containsTools = true
            case .standaloneAssistant:
                containsAssistant = true
            case .standaloneNote:
                if block.rows.contains(where: { $0.kind == .thinking }) {
                    containsProgress = true
                } else {
                    containsNotes = true
                }
            case .request, .activityCluster, .groupedHistory, .middleSummary, .conclusion:
                containsMixed = true
            }
        }

        if containsMixed || containsNotes {
            if containsNotes, !containsMixed, !containsTools, !containsAssistant, !containsProgress {
                return .notes
            }
            return .mixed
        }
        if containsTools {
            return .tools
        }
        if containsAssistant, containsProgress {
            return .mixed
        }
        if containsAssistant {
            return .assistant
        }
        if containsProgress {
            return .progress
        }
        return .mixed
    }

    private enum GroupedSectionAffinity {
        case activity
        case notes
        case mixed
    }

    private static func groupedSectionTitleAndIcon(
        kind: AgentTranscriptGroupedSectionKind,
        sectionSummary: AgentTranscriptClusterSummary?
    ) -> (title: String?, icon: String?) {
        switch kind {
        case .assistant:
            return ("Assistant updates", "text.bubble")
        case .tools:
            let title = groupedSummaryTitle(from: sectionSummary)
            return (title, "folder")
        case .progress:
            return ("Progress", "clock.arrow.trianglehead.counterclockwise.rotate.90")
        case .notes:
            return ("Notes", "info.circle")
        case .mixed:
            return ("Earlier activity", "square.stack.3d.down.right")
        }
    }

    private static func clusterSummary(
        for rows: [AgentChatItem],
        context: AgentTranscriptProjectionBuildContext
    ) -> AgentTranscriptClusterSummary? {
        guard !rows.isEmpty else { return nil }
        let cacheKey = ClusterSummaryCacheKey(rowIDs: rows.map(\.id))
        if let cached = context.clusterSummaryByRowIDs[cacheKey] {
            return cached
        }
        let groupedExecutions = Dictionary(grouping: rows.compactMap { row -> (AgentChatItem, AgentTranscriptToolExecution)? in
            guard let execution = AgentTranscriptToolNormalizer.toolExecution(
                for: row,
                context: context.processingContext
            ) else { return nil }
            return (row, execution)
        }, by: { $0.1.stableExecutionID })
        let orderedExecutionGroups = groupedExecutions.values
            .map { grouped in
                grouped.sorted { lhs, rhs in
                    if lhs.0.sequenceIndex == rhs.0.sequenceIndex {
                        return lhs.0.timestamp < rhs.0.timestamp
                    }
                    return lhs.0.sequenceIndex < rhs.0.sequenceIndex
                }
            }
            .sorted { lhs, rhs in
                guard let lhsLast = lhs.last?.0 else { return false }
                guard let rhsLast = rhs.last?.0 else { return true }
                if lhsLast.sequenceIndex == rhsLast.sequenceIndex {
                    if lhsLast.timestamp == rhsLast.timestamp {
                        return lhsLast.id.uuidString < rhsLast.id.uuidString
                    }
                    return lhsLast.timestamp < rhsLast.timestamp
                }
                return lhsLast.sequenceIndex < rhsLast.sequenceIndex
            }
        let toolExecutions: [AgentTranscriptToolExecution] = orderedExecutionGroups.compactMap { orderedGroup in
            guard let latestExecution = orderedGroup.last?.1 else { return nil }
            return orderedGroup.dropLast().reduce(latestExecution) { partial, entry in
                mergedToolExecutionMetadata(partial, with: entry.1)
            }
        }
        let toolNames = Array(NSOrderedSet(array: toolExecutions.compactMap {
            let normalized = AgentTranscriptToolNormalizer.normalizedToolName($0.toolName) ?? ""
            return normalized.isEmpty ? nil : normalized
        })) as? [String] ?? []
        var toolNameCounts: [String: Int] = [:]
        for exec in toolExecutions {
            let normalized = AgentTranscriptToolNormalizer.normalizedToolName(exec.toolName) ?? ""
            if !normalized.isEmpty {
                toolNameCounts[normalized, default: 0] += 1
            }
        }
        let keyPaths = Array(NSOrderedSet(array: toolExecutions.flatMap(\.keyPaths))) as? [String] ?? []
        let containsRunningWork = toolExecutions.contains { $0.status == .running || $0.status == .pending }
        let containsFailure = toolExecutions.contains { $0.status == .failed || $0.status == .cancelled }
        let containsWarning = toolExecutions.contains { $0.status == .warning }
        let narration = latestNarrationText(from: rows)
        let shortNarration: String? = if let narration, !narration.isEmpty {
            narration.count > 120 ? String(narration.prefix(120)) + "…" : narration
        } else {
            nil
        }
        let allToolNames = toolNameCounts.isEmpty ? Array(toolNames) : Array(toolNameCounts.keys.sorted())
        let toolGroups = ClusterToolCategory.buildGroups(toolNames: allToolNames, counts: toolNameCounts)
        let summary = AgentTranscriptClusterSummary(
            toolCount: toolExecutions.count,
            toolNames: Array(toolNames.prefix(6)),
            toolNameCounts: toolNameCounts,
            toolGroups: toolGroups,
            keyPaths: Array(keyPaths.prefix(6)),
            containsRunningWork: containsRunningWork,
            containsFailure: containsFailure,
            containsWarning: containsWarning,
            shortNarration: shortNarration
        )
        let renderedSummary = AgentTranscriptClusterSummary(
            toolCount: summary.toolCount,
            toolNames: summary.toolNames,
            toolNameCounts: summary.toolNameCounts,
            toolGroups: summary.toolGroups,
            keyPaths: summary.keyPaths,
            containsRunningWork: summary.containsRunningWork,
            containsFailure: summary.containsFailure,
            containsWarning: summary.containsWarning,
            shortNarration: summary.shortNarration,
            collapsedDisplay: AgentTranscriptSummaryTextFormatter.collapsedDisplay(
                for: summary,
                fallbackCount: summary.toolCount
            )
        )
        context.clusterSummaryByRowIDs[cacheKey] = renderedSummary
        return renderedSummary
    }

    private static func latestNarrationText(from rows: [AgentChatItem]) -> String? {
        let latestAssistantText = rows.reversed().first(where: {
            $0.hasDisplayableAssistantBody
        })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let latestAssistantText {
            return latestAssistantText
        }

        let latestThinkingText = rows.reversed().first(where: {
            $0.kind == .thinking
        })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let latestThinkingText, !latestThinkingText.isEmpty {
            return latestThinkingText
        }
        return nil
    }

    private static func groupedSummaryTitle(from summary: AgentTranscriptClusterSummary?) -> String {
        guard let summary else { return "Earlier activity" }
        switch ClusterToolCategory.summaryTitleSemantic(
            toolNames: summary.toolNames,
            toolNameCounts: summary.toolNameCounts,
            containsRunningWork: summary.containsRunningWork
        ) {
        case .running:
            return "Running"
        case .exploredAndEdited:
            return "Explored & edited"
        case .madeChanges:
            return "Made changes"
        case .ranCommands:
            return "Ran commands"
        case .agentActivity:
            return "Agent activity"
        case .exploredCodebase:
            return "Explored codebase"
        case .toolActivity:
            return "Tool activity"
        case .none:
            return "Earlier activity"
        }
    }

    private static func middleSummaryRow(for turn: AgentTranscriptTurn) -> AgentChatItem? {
        guard let summary = turn.summary,
              let text = summary.middleSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        let requestSequence = turn.request?.sequenceIndex ?? (turn.allActivities.first?.sequenceIndex ?? 0)
        let conclusionSequence = conclusionRow(for: turn)?.sequenceIndex ?? (turn.allActivities.last?.sequenceIndex ?? requestSequence + 1)
        let sequenceIndex = min(conclusionSequence - 1, requestSequence + 1)
        return AgentChatItem(
            id: summary.middleSummaryItemID,
            timestamp: turn.completedAt ?? turn.lastActivityAt ?? turn.startedAt,
            kind: .system,
            text: text,
            sequenceIndex: max(sequenceIndex, requestSequence),
            isStreaming: false
        )
    }

    private static func conclusionRow(for turn: AgentTranscriptTurn) -> AgentChatItem? {
        if let conclusionActivityID = turn.conclusionActivityID,
           let activity = turn.allActivities.first(where: { $0.id == conclusionActivityID })
        {
            let text: String? = switch turn.retentionTier {
            case .full, .condensed:
                displayableAssistantText(activity.text)
            case .summary, .archived:
                displayableAssistantText(turn.summary?.compactConclusionText)
                    ?? displayableAssistantText(turn.summary?.conclusionText)
                    ?? displayableAssistantText(activity.text)
            }
            if let text {
                return activity.toItem(text: text, isStreaming: false)
            }
        }
        guard let summary = turn.summary,
              let text = displayableAssistantText(summary.compactConclusionText) ?? displayableAssistantText(summary.conclusionText)
        else {
            return nil
        }
        let sequenceIndex = max(turn.request?.sequenceIndex ?? 0, (turn.allActivities.last?.sequenceIndex ?? 0) + 1)
        return AgentChatItem(
            id: AgentTranscriptIO.deterministicConclusionItemID(for: turn.id),
            timestamp: turn.completedAt ?? turn.lastActivityAt ?? turn.startedAt,
            kind: .assistant,
            text: text,
            sequenceIndex: sequenceIndex,
            isStreaming: false
        )
    }

    private static func displayableAssistantText(_ text: String?) -> String? {
        guard let text,
              AgentDisplayableText.hasDisplayableBody(text)
        else {
            return nil
        }
        return text
    }

    private static func registerAnchors(
        for turn: AgentTranscriptTurn,
        blocks: [AgentTranscriptRenderBlock],
        into index: inout [UUID: AgentTranscriptAnchor]
    ) {
        if let request = turn.request {
            index[request.id] = .request(turnID: turn.id)
        }
        for span in turn.responseSpans {
            for activity in span.activities {
                guard !isSuppressedActivity(activity) else { continue }
                if activity.id == turn.conclusionActivityID {
                    index[activity.id] = .conclusion(turnID: turn.id, activityID: activity.id)
                } else {
                    index[activity.id] = .activity(turnID: turn.id, spanID: span.id, activityID: activity.id)
                }
            }
        }
        if let summary = turn.summary,
           blocks.contains(where: { $0.rows.contains(where: { $0.id == summary.middleSummaryItemID }) })
        {
            index[summary.middleSummaryItemID] = .summary(turnID: turn.id)
        }
    }

    private static func registerBlockAnchors(
        for turn: AgentTranscriptTurn,
        blocks: [AgentTranscriptRenderBlock],
        into index: inout [AgentTranscriptAnchor: String]
    ) {
        for block in blocks {
            if let primaryAnchor = block.primaryAnchor {
                index[primaryAnchor] = block.id
            }
            guard let spanID = block.spanID else { continue }
            if block.kind == .groupedHistory {
                index[groupedHistoryAnchor(for: turn.id, spanID: spanID)] = block.id
            }
            for activityID in block.activityIDs {
                index[semanticAnchor(for: activityID, in: turn, spanID: spanID)] = block.id
            }
        }

        switch turn.retentionTier {
        case .full:
            return
        case .condensed, .summary:
            let groupedHistoryBlockIDBySpan: [UUID: String] = Dictionary(
                uniqueKeysWithValues: blocks.compactMap { block -> (UUID, String)? in
                    guard block.kind == .groupedHistory, let spanID = block.spanID else { return nil }
                    return (spanID, block.id)
                }
            )
            let firstGroupedHistoryBlockID = blocks.first(where: { $0.kind == .groupedHistory })?.id
            let conclusionBlockID = blocks.first(where: { $0.kind == .conclusion })?.id
            let requestBlockID = blocks.first(where: { $0.kind == .request })?.id
            let fallbackBlockID = firstGroupedHistoryBlockID ?? conclusionBlockID ?? requestBlockID
            guard let fallbackBlockID else { return }

            if let firstGroupedHistoryBlockID {
                index[summaryAnchor(for: turn.id)] = firstGroupedHistoryBlockID
            }

            for span in turn.responseSpans {
                let spanBlockID = groupedHistoryBlockIDBySpan[span.id] ?? fallbackBlockID
                index[groupedHistoryAnchor(for: turn.id, spanID: span.id)] = spanBlockID
                for activity in span.activities {
                    guard !isSuppressedActivity(activity) else { continue }
                    if activity.id == turn.conclusionActivityID {
                        index[conclusionAnchor(for: activity.id, turnID: turn.id)] = conclusionBlockID ?? spanBlockID
                    } else {
                        index[semanticAnchor(for: activity.id, in: turn, spanID: span.id)] = spanBlockID
                    }
                }
            }
        case .archived:
            let summaryBlockID = blocks.first(where: { $0.kind == .middleSummary })?.id
            let conclusionBlockID = blocks.first(where: { $0.kind == .conclusion })?.id
            let requestBlockID = blocks.first(where: { $0.kind == .request })?.id
            let fallbackBlockID = summaryBlockID ?? conclusionBlockID ?? requestBlockID
            guard let fallbackBlockID else { return }

            for span in turn.responseSpans {
                for activity in span.activities {
                    guard !isSuppressedActivity(activity) else { continue }
                    if activity.id == turn.conclusionActivityID {
                        index[conclusionAnchor(for: activity.id, turnID: turn.id)] = conclusionBlockID ?? fallbackBlockID
                    } else {
                        index[semanticAnchor(for: activity.id, in: turn, spanID: span.id)] = summaryBlockID ?? fallbackBlockID
                    }
                }
            }
        }
    }
}

enum AgentTranscriptAnalyticsBuilder {
    static func build(from transcript: AgentTranscript, selectedAgent: AgentProviderKind?) -> AgentTranscriptAnalyticsSnapshot {
        var observedReadFiles = Set<String>()
        var latestWorkspaceContextItem: AgentChatItem?
        var latestManageSelectionItem: AgentChatItem?
        var latestContextBuilderItem: AgentChatItem?
        var totalCharacters = 0

        for turn in transcript.turns {
            totalCharacters += turn.request?.text.count ?? 0
        }

        for activity in transcript.allActivities {
            let row = activity.toItem()
            totalCharacters += row.text.count
            guard row.kind == .toolCall || row.kind == .toolResult,
                  !AgentTranscriptToolVisibilityPolicy.shouldSuppressActivity(activity),
                  let normalizedToolName = AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(row.toolName)?.lowercased()
            else {
                continue
            }
            if row.kind == .toolCall, normalizedToolName == "read_file",
               let args = ToolJSON.decodeArgs(ToolArgsDTOs.ReadFileArgs.self, from: row.toolArgsJSON),
               let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty
            {
                observedReadFiles.insert(path)
            }
            guard row.kind == .toolResult else { continue }
            switch normalizedToolName {
            case "workspace_context":
                latestWorkspaceContextItem = row
            case "manage_selection":
                latestManageSelectionItem = row
            case "context_builder":
                latestContextBuilderItem = row
            case "read_file":
                if let dto = ToolJSON.decodeResult(ToolResultDTOs.ReadFileReply.self, from: row.toolResultJSON),
                   let path = dto.displayPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty
                {
                    observedReadFiles.insert(path)
                }
            default:
                break
            }
        }

        return AgentTranscriptAnalyticsSnapshot(
            observedReadFiles: observedReadFiles,
            latestWorkspaceContextItem: latestWorkspaceContextItem,
            latestManageSelectionItem: latestManageSelectionItem,
            latestContextBuilderItem: latestContextBuilderItem,
            estimatedTranscriptTokens: totalCharacters > 0 ? totalCharacters / 4 : nil,
            selectedAgent: selectedAgent
        )
    }
}
