import Foundation

struct AgentSanitizedToolResult: Equatable {
    let text: String
    let resultJSON: String?
    let toolIsError: Bool?
    let persistedStatusWord: String
    let transcriptStatus: AgentTranscriptToolStatus
    let summaryOnly: Bool
    let processID: String?
    let exitCode: Int?
    let preservesRawPayload: Bool

    var shouldRetainEphemeralRawPayload: Bool {
        !preservesRawPayload && summaryOnly
    }
}

struct AgentSanitizedTranscriptMetrics: Equatable {
    let transcript: AgentTranscript
    let sanitizedActivityCount: Int
    let reusedTurnCount: Int
}

struct AgentPersistedToolResultSummary: Equatable {
    let resultJSON: String
    let statusWord: String
    let transcriptStatus: AgentTranscriptToolStatus
    let toolIsError: Bool?
    let processID: String?
    let exitCode: Int?
    let summaryText: String
    let summaryOnly: Bool
}

enum AgentToolResultSanitizationPurpose {
    case runtimePresentation
    case persistentStorage
}

enum AgentToolResultPersistencePolicy {
    static let maxPersistedToolSummaryBytes = 2048
    private static let cursorACPPersistedDiffBytesLimit = 1200
    private static let cursorACPFallbackPersistedDiffBytesLimit = 600
    private static let cursorACPGeneratedDiffInputBytesLimit = 16384
    private static let cursorACPGeneratedDiffInputLineLimit = 800
    private static let promptExportFileMetadataLimit = 12

    static func sanitizeItem(_ item: AgentChatItem) -> AgentChatItem {
        guard let sanitized = sanitizedToolResult(for: item) else { return item }
        var updated = item
        updated.text = sanitized.text
        updated.toolResultJSON = sanitized.resultJSON
        updated.toolIsError = sanitized.toolIsError
        return updated
    }

    static func sanitizedToolResult(
        for item: AgentChatItem,
        toolExecution: AgentTranscriptToolExecution? = nil,
        context: AgentToolResultProcessingContext? = nil
    ) -> AgentSanitizedToolResult? {
        guard item.kind == .toolResult else { return nil }
        let normalizedToolName = normalizedToolName(item.toolName)
        let rawResultJSON = item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preservedText = rawResultJSON?.isEmpty == false ? rawResultJSON! : item.text
        if normalizedToolName == "ask_user" || normalizedToolName == "ask_user_question" {
            let execution = toolExecution ?? AgentTranscriptToolNormalizer.toolExecution(for: item, context: context)
            let status = execution?.status ?? AgentTranscriptToolNormalizer.status(for: item, context: context)
            let statusWord = AgentTranscriptToolStatusSemantics.persistedStatusWord(from: status)
            return AgentSanitizedToolResult(
                text: preservedText,
                resultJSON: item.toolResultJSON,
                toolIsError: item.toolIsError,
                persistedStatusWord: statusWord,
                transcriptStatus: status,
                summaryOnly: false,
                processID: execution?.processID,
                exitCode: execution?.exitCode,
                preservesRawPayload: true
            )
        }

        if normalizedToolName == "agent_run" || normalizedToolName == "agent_explore" {
            let rawObject = jsonObject(from: rawResultJSON, context: context)
            let statusWord = normalizedAgentRunStatusWord(stringValue(rawObject, keys: ["status"])) ?? "unknown"
            let transcriptStatus = transcriptStatusForAgentRunStatusWord(statusWord)
            let summaryJSON = agentRunSummaryJSON(normalizedToolName: normalizedToolName, statusWord: statusWord, rawObject: rawObject)
            let text = summaryJSON ?? minimalResultJSON(statusWord: statusWord)
            return AgentSanitizedToolResult(
                text: text,
                resultJSON: summaryJSON ?? minimalResultJSON(statusWord: statusWord),
                toolIsError: item.toolIsError,
                persistedStatusWord: statusWord,
                transcriptStatus: transcriptStatus,
                summaryOnly: true,
                processID: nil,
                exitCode: nil,
                preservesRawPayload: false
            )
        }

        let execution = toolExecution ?? AgentTranscriptToolNormalizer.toolExecution(for: item, context: context)
        if normalizedToolName == "prompt",
           let rawObject = jsonObject(from: rawResultJSON, context: context),
           let promptExportJSON = promptExportMetadataJSON(rawObject: rawObject)
        {
            let statusWord: String = {
                if let executionStatus = execution?.status,
                   executionStatus != .unknown
                {
                    return AgentTranscriptToolStatusSemantics.persistedStatusWord(from: executionStatus)
                }
                return derivedStatusWord(
                    normalizedToolName: normalizedToolName,
                    rawResultJSON: rawResultJSON,
                    rawObject: rawObject,
                    executionStatus: execution?.status,
                    toolIsError: item.toolIsError,
                    context: context
                )
            }()
            let status = AgentTranscriptToolStatusSemantics.transcriptStatus(fromNormalizedStatusWord: statusWord)
            return AgentSanitizedToolResult(
                text: promptExportJSON,
                resultJSON: promptExportJSON,
                toolIsError: persistedToolIsError(
                    normalizedToolName: normalizedToolName,
                    status: status,
                    original: item.toolIsError
                ),
                persistedStatusWord: statusWord,
                transcriptStatus: status,
                summaryOnly: false,
                processID: execution?.processID,
                exitCode: execution?.exitCode,
                preservesRawPayload: true
            )
        }

        let requiresStructuredSummaryDetails = normalizedToolName == "apply_edits"
            || normalizedToolName == "apply_patch"
            || normalizedToolName == "agent_run"
            || normalizedToolName == "agent_explore"
            || normalizedToolName == "agent_manage"
            || normalizedToolName == "ask_oracle"
            || normalizedToolName == "oracle_send"
        let looksLikeCursorACPPayload = rawResultJSON?.contains("\"acp_status\"") == true
        let needsRawObjectFallbacks =
            requiresStructuredSummaryDetails
                || looksLikeCursorACPPayload
                || (normalizedToolName != "bash" && execution == nil)
                || (normalizedToolName != "bash" && execution?.status == .unknown)
                || (normalizedToolName != "bash" && execution?.processID == nil)
                || (normalizedToolName != "bash" && execution?.exitCode == nil)
        let rawObject = needsRawObjectFallbacks ? jsonObject(from: rawResultJSON, context: context) : nil
        let shouldParseBashMetadata = normalizedToolName == "bash"
        let bashMetadata = shouldParseBashMetadata
            ? BashToolResultParser.parseMetadata(raw: rawResultJSON, context: context)
            : nil
        let statusWord: String = {
            if normalizedToolName != "bash",
               let executionStatus = execution?.status,
               executionStatus != .unknown
            {
                return AgentTranscriptToolStatusSemantics.persistedStatusWord(from: executionStatus)
            }
            return derivedStatusWord(
                normalizedToolName: normalizedToolName,
                rawResultJSON: rawResultJSON,
                rawObject: rawObject,
                executionStatus: execution?.status,
                toolIsError: item.toolIsError,
                context: context
            )
        }()
        let status = AgentTranscriptToolStatusSemantics.transcriptStatus(fromNormalizedStatusWord: statusWord)
        let rawOutputObject = rawObject?["rawOutput"] as? [String: Any]
        let processID = execution?.processID
            ?? bashMetadata?.processID
            ?? stringValue(rawObject, keys: ["processId", "process_id"])
            ?? stringValue(rawOutputObject, keys: ["processId", "process_id"])
            ?? bashTextProcessID(from: rawResultJSON, context: context)
        let exitCode = execution?.exitCode
            ?? bashMetadata?.exitCode
            ?? intValue(rawObject, keys: ["exitCode", "exit_code", "code"])
            ?? intValue(rawOutputObject, keys: ["exitCode", "exit_code", "code"])
            ?? bashTextExitCode(from: rawResultJSON, context: context)
        let summaryJSON = sanitizedSummaryJSON(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode,
            rawObject: rawObject,
            argsJSON: item.toolArgsJSON,
            context: context
        )
        let persistedToolIsError = persistedToolIsError(
            normalizedToolName: normalizedToolName,
            status: status,
            original: item.toolIsError
        )
        let text = summaryJSON ?? minimalResultJSON(statusWord: statusWord)
        return AgentSanitizedToolResult(
            text: text,
            resultJSON: summaryJSON ?? minimalResultJSON(statusWord: statusWord),
            toolIsError: persistedToolIsError,
            persistedStatusWord: statusWord,
            transcriptStatus: status,
            summaryOnly: true,
            processID: processID,
            exitCode: exitCode,
            preservesRawPayload: false
        )
    }

    static func retainedEphemeralRawPayload(
        for item: AgentChatItem,
        toolExecution: AgentTranscriptToolExecution? = nil,
        context: AgentToolResultProcessingContext? = nil
    ) -> String? {
        guard let sanitized = sanitizedToolResult(for: item, toolExecution: toolExecution, context: context) else { return nil }
        guard sanitized.shouldRetainEphemeralRawPayload else { return nil }
        let raw = item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let persisted = sanitized.resultJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, raw != persisted else { return nil }
        return raw
    }

    static func shouldRetainEphemeralRawPayload(for item: AgentChatItem) -> Bool {
        retainedEphemeralRawPayload(for: item) != nil
    }

    static func persistedToolResultSummary(
        for item: AgentChatItem,
        toolExecution: AgentTranscriptToolExecution? = nil,
        rawResultTextFallback: String? = nil,
        context: AgentToolResultProcessingContext? = nil
    ) -> AgentPersistedToolResultSummary? {
        guard item.kind == .toolResult else { return nil }
        let generatedExecution = toolExecution ?? AgentTranscriptToolNormalizer.toolExecution(for: item, context: context)
        let normalizedToolName = normalizedToolName(generatedExecution?.toolName ?? item.toolName)
        let rawCandidates = storageRawPayloadCandidates(
            executionResultJSON: generatedExecution?.resultJSON,
            itemResultJSON: item.toolResultJSON,
            textFallback: rawResultTextFallback ?? item.text
        )
        var sourceItem = item
        if let rawPayload = firstStorageRawPayload(from: rawCandidates) {
            sourceItem.toolResultJSON = rawPayload
            sourceItem.text = rawPayload
        }
        let sanitized = sanitizedToolResult(
            for: sourceItem,
            toolExecution: generatedExecution,
            context: context
        )
        let transcriptStatus = sanitized?.transcriptStatus
            ?? generatedExecution?.status
            ?? AgentTranscriptToolNormalizer.status(for: sourceItem, context: context)
        let statusWord = sanitized?.persistedStatusWord
            ?? AgentTranscriptToolStatusSemantics.persistedStatusWord(from: transcriptStatus)
        let processID = storageSafeMetadataString(sanitized?.processID ?? generatedExecution?.processID)
        let exitCode = sanitized?.exitCode ?? generatedExecution?.exitCode
        let renderSummary = storageSafeRenderSummary(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            rawResultJSONCandidates: rawCandidates,
            argsJSON: sourceItem.toolArgsJSON ?? generatedExecution?.argsJSON,
            context: context,
            allowExistingSummaryOnly: generatedExecution?.summaryOnly == true
        )
        let summaryText = renderSummary?.inlineSummaryText ?? storageSafeSummaryText(
            normalizedToolName: normalizedToolName,
            toolName: generatedExecution?.toolName ?? item.toolName,
            status: transcriptStatus,
            rawResultJSONCandidates: rawCandidates,
            argsJSON: sourceItem.toolArgsJSON,
            context: context
        )
        let fallbackWithMetadata = minimalResultJSON(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            processID: processID,
            exitCode: exitCode,
            summaryText: summaryText,
            renderSummary: renderSummary
        )
        let cursorACPStructuredSummary = storageSafeCursorACPStructuredSummary(
            sanitized?.resultJSON,
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode,
            context: context
        )
        let allowedStructuredSummary: String? = {
            let allowedTools: Set = [
                "apply_edits",
                "ask_oracle",
                "oracle_send"
            ]
            guard let normalizedToolName,
                  let resultJSON = sanitized?.resultJSON,
                  !exceedsPersistedToolSummaryBudget(resultJSON)
            else {
                return nil
            }
            if allowedTools.contains(normalizedToolName) {
                return resultJSON
            }
            if normalizedToolName == "agent_manage",
               let object = jsonObject(from: resultJSON, context: context),
               let countSummary = agentManageCountSummaryJSON(statusWord: statusWord, rawObject: object),
               !exceedsPersistedToolSummaryBudget(countSummary)
            {
                return countSummary
            }
            return nil
        }()
        let promptExportStructuredMetadata: String? = {
            guard normalizedToolName == "prompt",
                  let resultJSON = sanitized?.resultJSON,
                  sanitized?.summaryOnly == false,
                  !exceedsPersistedToolSummaryBudget(resultJSON)
            else {
                return nil
            }
            return resultJSON
        }()
        let resultJSON = promptExportStructuredMetadata
            ?? cursorACPStructuredSummary
            ?? allowedStructuredSummary
            ?? (
                exceedsPersistedToolSummaryBudget(fallbackWithMetadata)
                    ? minimalResultJSON(statusWord: statusWord, normalizedToolName: normalizedToolName)
                    : fallbackWithMetadata
            )
        return AgentPersistedToolResultSummary(
            resultJSON: resultJSON,
            statusWord: statusWord,
            transcriptStatus: transcriptStatus,
            toolIsError: sanitized?.toolIsError ?? generatedExecution?.toolIsError ?? item.toolIsError,
            processID: processID,
            exitCode: exitCode,
            summaryText: summaryText,
            summaryOnly: promptExportStructuredMetadata == nil
        )
    }

    private static func storageRawPayloadCandidates(
        executionResultJSON: String?,
        itemResultJSON: String?,
        textFallback: String?
    ) -> [String?] {
        [executionResultJSON, itemResultJSON, textFallback]
    }

    private static func firstStorageRawPayload(from candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    private static func promptExportMetadataJSON(rawObject: [String: Any]) -> String? {
        guard trimmedStorageString(stringValue(rawObject, keys: ["op"]))?.lowercased() == "export",
              let rawExport = rawObject["export"] as? [String: Any],
              let path = storageSafeMetadataString(stringValue(rawExport, keys: ["path"])),
              let tokens = intValue(rawExport, keys: ["tokens"]),
              let bytes = intValue(rawExport, keys: ["bytes"])
        else { return nil }

        let coreExportObject: [String: Any] = [
            "path": path,
            "tokens": tokens,
            "bytes": bytes
        ]
        let cappedFiles = promptExportFileMetadata(rawExport["files"] as? [[String: Any]], limit: promptExportFileMetadataLimit)
        let copyPreset = promptExportCopyPresetMetadata(rawExport["copy_preset"] as? [String: Any])
        let reducedCopyPreset = copyPreset.map { promptExportCopyPresetMetadataWithoutKind($0) }
        var candidates: [([String: Any], [[String: Any]])] = []
        if let copyPreset {
            var exportObject = coreExportObject
            exportObject["copy_preset"] = copyPreset
            candidates.append((exportObject, cappedFiles))
            candidates.append((exportObject, []))
        }
        if let reducedCopyPreset {
            var exportObject = coreExportObject
            exportObject["copy_preset"] = reducedCopyPreset
            candidates.append((exportObject, []))
        }
        candidates.append((coreExportObject, cappedFiles))
        candidates.append((coreExportObject, []))

        for (exportObject, files) in candidates {
            guard let json = promptExportMetadataJSONString(exportObject: exportObject, files: files),
                  !exceedsPersistedToolSummaryBudget(json) else { continue }
            return json
        }
        return nil
    }

    private static func promptExportMetadataJSONString(
        exportObject: [String: Any],
        files: [[String: Any]]
    ) -> String? {
        var exportObject = exportObject
        exportObject["files"] = files
        return jsonString(from: [
            "op": "export",
            "export": exportObject
        ])
    }

    private static func promptExportCopyPresetMetadata(_ rawCopyPreset: [String: Any]?) -> [String: Any]? {
        guard let rawCopyPreset,
              let id = storageSafeMetadataString(stringValue(rawCopyPreset, keys: ["id"])),
              let name = storageSafeMetadataString(stringValue(rawCopyPreset, keys: ["name"])),
              let isBuiltIn = boolValue(rawCopyPreset, keys: ["is_built_in", "isBuiltIn"])
        else { return nil }
        var copyPreset: [String: Any] = [
            "id": id,
            "name": name,
            "is_built_in": isBuiltIn
        ]
        if let kind = storageSafeMetadataString(stringValue(rawCopyPreset, keys: ["kind"])) {
            copyPreset["kind"] = kind
        }
        return copyPreset
    }

    private static func promptExportCopyPresetMetadataWithoutKind(_ copyPreset: [String: Any]) -> [String: Any] {
        var reduced = copyPreset
        reduced.removeValue(forKey: "kind")
        return reduced
    }

    private static func promptExportFileMetadata(_ rawFiles: [[String: Any]]?, limit: Int) -> [[String: Any]] {
        guard let rawFiles, limit > 0 else { return [] }
        return rawFiles.prefix(limit).compactMap { rawFile in
            guard let path = storageSafeMetadataString(stringValue(rawFile, keys: ["path"])),
                  let tokens = intValue(rawFile, keys: ["tokens"])
            else { return nil }
            var file: [String: Any] = [
                "path": path,
                "tokens": tokens,
                "render_mode": storageSafeMetadataString(stringValue(rawFile, keys: ["render_mode", "renderMode"])) ?? "unknown",
                "is_auto": boolValue(rawFile, keys: ["is_auto", "isAuto"]) ?? false
            ]
            if let codemapOrigin = storageSafeMetadataString(stringValue(rawFile, keys: ["codemap_origin", "codemapOrigin"])) {
                file["codemap_origin"] = codemapOrigin
            }
            if let pathWithinRoot = storageSafeMetadataString(stringValue(rawFile, keys: ["path_within_root", "pathWithinRoot"])) {
                file["path_within_root"] = pathWithinRoot
            }
            return file
        }
    }

    private static func storageSafeCursorACPStructuredSummary(
        _ resultJSON: String?,
        normalizedToolName: String?,
        statusWord: String,
        processID: String?,
        exitCode: Int?,
        context: AgentToolResultProcessingContext?
    ) -> String? {
        guard let resultJSON = resultJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resultJSON.isEmpty,
              let object = jsonObject(from: resultJSON, context: context),
              stringValue(object, keys: ["acp_status"]) != nil
        else { return nil }
        if boolValue(object, keys: ["summary_only", "summaryOnly"]) == true,
           !exceedsPersistedToolSummaryBudget(resultJSON)
        {
            return resultJSON
        }
        return cursorACPSummaryJSON(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode,
            rawObject: object
        )
    }

    static func sanitizeTranscript(_ transcript: AgentTranscript) -> AgentTranscript {
        sanitizeTranscriptWithMetrics(transcript).transcript
    }

    static func sanitizeTranscriptForPersistence(_ transcript: AgentTranscript) -> AgentTranscript {
        sanitizeTranscriptForPersistenceWithMetrics(transcript).transcript
    }

    static func sanitizeTranscriptForPersistenceWithMetrics(
        _ transcript: AgentTranscript,
        context: AgentToolResultProcessingContext? = nil
    ) -> AgentSanitizedTranscriptMetrics {
        sanitizeTranscriptWithMetrics(
            transcript,
            previousSanitizedTranscript: nil,
            reusablePrefixTurnCount: nil,
            preservedVisibleToolResultRowIDs: [],
            context: context,
            purpose: .persistentStorage
        )
    }

    static func sanitizeTranscriptWithMetrics(
        _ transcript: AgentTranscript,
        previousSanitizedTranscript: AgentTranscript? = nil,
        reusablePrefixTurnCount: Int? = nil,
        trustedReusablePrefixTurnCount: Int? = nil,
        trustedIncrementalFinalTurnStartSequenceIndex: Int? = nil,
        preservedVisibleToolResultRowIDs: Set<UUID>? = nil,
        context: AgentToolResultProcessingContext? = nil,
        purpose: AgentToolResultSanitizationPurpose = .runtimePresentation
    ) -> AgentSanitizedTranscriptMetrics {
        let reusedTurnCount: Int = switch purpose {
        case .runtimePresentation:
            validatedReusablePrefixTurnCount(
                in: transcript,
                previousSanitizedTranscript: previousSanitizedTranscript,
                requestedPrefixTurnCount: trustedReusablePrefixTurnCount ?? reusablePrefixTurnCount
            )
        case .persistentStorage:
            0
        }
        if purpose == .runtimePresentation,
           let trustedIncrementalFinalTurnStartSequenceIndex,
           let previousSanitizedTranscript,
           transcript.turns.count == previousSanitizedTranscript.turns.count,
           reusedTurnCount == max(0, transcript.turns.count - 1),
           let currentFinalTurn = transcript.turns.last,
           let previousFinalTurn = previousSanitizedTranscript.turns.last,
           currentFinalTurn.id == previousFinalTurn.id
        {
            var sanitizedTranscript = transcript
            if let sanitizedActivityCount = sanitizeFinalTurnIncrementally(
                &sanitizedTranscript.turns[sanitizedTranscript.turns.count - 1],
                previousSanitizedTurn: previousFinalTurn,
                startingAtSequenceIndex: trustedIncrementalFinalTurnStartSequenceIndex,
                preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs ?? [],
                context: context
            ) {
                return AgentSanitizedTranscriptMetrics(
                    transcript: sanitizedTranscript,
                    sanitizedActivityCount: sanitizedActivityCount,
                    reusedTurnCount: reusedTurnCount
                )
            }
        }
        let containsSanitizableActivities: Bool = switch purpose {
        case .runtimePresentation:
            containsToolResultActivities(in: transcript)
        case .persistentStorage:
            containsToolExecutionActivities(in: transcript)
        }
        guard containsSanitizableActivities else {
            return AgentSanitizedTranscriptMetrics(
                transcript: transcript,
                sanitizedActivityCount: 0,
                reusedTurnCount: reusedTurnCount
            )
        }
        let preservedRowIDs: Set<UUID> = switch purpose {
        case .runtimePresentation:
            // The Agent Mode VM projection path stays sanitized and visible cards
            // read retained raw payloads from the ephemeral map at render time.
            // Some pipeline callers may still preserve explicit visible row IDs.
            preservedVisibleToolResultRowIDs ?? []
        case .persistentStorage:
            []
        }
        var sanitizedTranscript = transcript
        if reusedTurnCount > 0, let previousSanitizedTranscript {
            sanitizedTranscript.turns.replaceSubrange(
                0 ..< reusedTurnCount,
                with: previousSanitizedTranscript.turns.prefix(reusedTurnCount)
            )
        }
        var sanitizedActivityCount = 0
        for turnIndex in sanitizedTranscript.turns.indices where turnIndex >= reusedTurnCount {
            sanitizedActivityCount += sanitizeTurn(
                &sanitizedTranscript.turns[turnIndex],
                preservedVisibleToolResultRowIDs: preservedRowIDs,
                context: context,
                purpose: purpose
            )
        }
        return AgentSanitizedTranscriptMetrics(
            transcript: sanitizedTranscript,
            sanitizedActivityCount: sanitizedActivityCount,
            reusedTurnCount: reusedTurnCount
        )
    }

    private static func sanitizeFinalTurnIncrementally(
        _ turn: inout AgentTranscriptTurn,
        previousSanitizedTurn: AgentTranscriptTurn,
        startingAtSequenceIndex: Int,
        preservedVisibleToolResultRowIDs: Set<UUID>,
        context: AgentToolResultProcessingContext?
    ) -> Int? {
        guard turn.request?.id == previousSanitizedTurn.request?.id,
              turn.responseSpans.count == previousSanitizedTurn.responseSpans.count
        else {
            return nil
        }

        var updatedTurn = turn
        var reachedChangedSuffix = false
        var sanitizedActivityCount = 0

        for spanIndex in updatedTurn.responseSpans.indices {
            let currentSpan = turn.responseSpans[spanIndex]
            let previousSpan = previousSanitizedTurn.responseSpans[spanIndex]
            guard currentSpan.id == previousSpan.id else { return nil }

            if !reachedChangedSuffix {
                let changedActivityIndex = lowerBoundActivityIndex(
                    in: currentSpan.activities,
                    sequenceIndex: startingAtSequenceIndex
                )
                if changedActivityIndex == currentSpan.activities.count {
                    guard currentSpan.activities.count == previousSpan.activities.count,
                          currentSpan.activities.first?.id == previousSpan.activities.first?.id,
                          currentSpan.activities.last?.id == previousSpan.activities.last?.id
                    else {
                        return nil
                    }
                    updatedTurn.responseSpans[spanIndex].activities = previousSpan.activities
                    continue
                }

                guard changedActivityIndex <= previousSpan.activities.count else { return nil }
                if changedActivityIndex > 0 {
                    guard currentSpan.activities[changedActivityIndex - 1].id
                        == previousSpan.activities[changedActivityIndex - 1].id
                    else {
                        return nil
                    }
                }

                var mergedActivities = previousSpan.activities
                mergedActivities.replaceSubrange(
                    changedActivityIndex ..< mergedActivities.count,
                    with: currentSpan.activities[changedActivityIndex...]
                )
                updatedTurn.responseSpans[spanIndex].activities = mergedActivities
                sanitizedActivityCount += sanitizeActivities(
                    in: &updatedTurn.responseSpans[spanIndex],
                    startingAt: changedActivityIndex,
                    preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs,
                    context: context,
                    purpose: .runtimePresentation
                )
                reachedChangedSuffix = true
                continue
            }

            sanitizedActivityCount += sanitizeActivities(
                in: &updatedTurn.responseSpans[spanIndex],
                startingAt: 0,
                preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs,
                context: context,
                purpose: .runtimePresentation
            )
        }

        guard reachedChangedSuffix else { return nil }
        turn = updatedTurn
        return sanitizedActivityCount
    }

    private static func lowerBoundActivityIndex(
        in activities: [AgentTranscriptActivity],
        sequenceIndex: Int
    ) -> Int {
        var lowerBound = activities.startIndex
        var upperBound = activities.endIndex
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if activities[midpoint].sequenceIndex < sequenceIndex {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private static func validatedReusablePrefixTurnCount(
        in transcript: AgentTranscript,
        previousSanitizedTranscript: AgentTranscript?,
        requestedPrefixTurnCount: Int?
    ) -> Int {
        guard let previousSanitizedTranscript else { return 0 }
        let availablePrefixTurnCount = min(transcript.turns.count, previousSanitizedTranscript.turns.count)
        guard availablePrefixTurnCount > 0 else { return 0 }
        let candidatePrefixTurnCount = min(requestedPrefixTurnCount ?? availablePrefixTurnCount, availablePrefixTurnCount)
        guard candidatePrefixTurnCount > 0 else { return 0 }
        var reusableTurnCount = 0
        for index in 0 ..< candidatePrefixTurnCount {
            let currentTurn = transcript.turns[index]
            let previousTurn = previousSanitizedTranscript.turns[index]
            guard currentTurn == previousTurn else {
                break
            }
            reusableTurnCount += 1
        }
        return reusableTurnCount
    }

    private static func containsToolResultActivities(in transcript: AgentTranscript) -> Bool {
        for turn in transcript.turns {
            for span in turn.responseSpans {
                if span.activities.contains(where: { $0.itemKind == .toolResult }) {
                    return true
                }
            }
        }
        return false
    }

    private static func containsToolExecutionActivities(in transcript: AgentTranscript) -> Bool {
        for turn in transcript.turns {
            for span in turn.responseSpans {
                if span.activities.contains(where: { $0.toolExecution != nil || $0.itemKind == .toolCall || $0.itemKind == .toolResult }) {
                    return true
                }
            }
        }
        return false
    }

    @discardableResult
    private static func sanitizeTurn(
        _ turn: inout AgentTranscriptTurn,
        preservedVisibleToolResultRowIDs: Set<UUID>,
        context: AgentToolResultProcessingContext?,
        purpose: AgentToolResultSanitizationPurpose
    ) -> Int {
        var sanitizedActivityCount = 0
        for spanIndex in turn.responseSpans.indices {
            sanitizedActivityCount += sanitizeActivities(
                in: &turn.responseSpans[spanIndex],
                startingAt: 0,
                preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs,
                context: context,
                purpose: purpose
            )
        }
        return sanitizedActivityCount
    }

    private static func sanitizeActivities(
        in span: inout AgentTranscriptProviderResponseSpan,
        startingAt startIndex: Int,
        preservedVisibleToolResultRowIDs: Set<UUID>,
        context: AgentToolResultProcessingContext?,
        purpose: AgentToolResultSanitizationPurpose
    ) -> Int {
        guard startIndex < span.activities.count else { return 0 }
        var sanitizedActivityCount = 0
        var spanDidMutate = false
        for activityIndex in startIndex ..< span.activities.count {
            var activity = span.activities[activityIndex]
            let didNormalizeToolIdentity = normalizeToolIdentity(&activity, context: context)
            let didSanitize: Bool = switch purpose {
            case .runtimePresentation:
                sanitizeRuntimeActivity(
                    &activity,
                    preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs,
                    context: context
                )
            case .persistentStorage:
                sanitizePersistentStorageActivity(&activity, context: context)
            }
            guard didNormalizeToolIdentity || didSanitize else { continue }
            span.activities[activityIndex] = activity
            spanDidMutate = true
            sanitizedActivityCount += 1
        }
        if spanDidMutate {
            span.fullRenderGroupedHistoryCache = nil
        }
        return sanitizedActivityCount
    }

    private static func normalizeToolIdentity(
        _ activity: inout AgentTranscriptActivity,
        context: AgentToolResultProcessingContext?
    ) -> Bool {
        guard activity.itemKind == .toolCall || activity.itemKind == .toolResult else { return false }
        let originalActivity = activity
        let sourceItem = activity.toItem()
        let execution = activity.toolExecution ?? AgentTranscriptToolNormalizer.toolExecution(for: sourceItem, context: context)
        guard var updatedExecution = execution else { return false }
        let rawToolName = updatedExecution.toolName ?? sourceItem.toolName
        if let normalizedToolName = AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(rawToolName),
           !normalizedToolName.isEmpty
        {
            updatedExecution.toolName = normalizedToolName
        }
        if let pathSignal = AgentTranscriptToolVisibilityPolicy.pathSignal(fromPathLikeToolName: rawToolName),
           !updatedExecution.keyPaths.contains(pathSignal)
        {
            updatedExecution.keyPaths.insert(pathSignal, at: 0)
        }
        activity.toolExecution = updatedExecution
        context?.storeToolExecution(updatedExecution, for: activity.id)
        return activity != originalActivity
    }

    private static func sanitizeRuntimeActivity(
        _ activity: inout AgentTranscriptActivity,
        preservedVisibleToolResultRowIDs: Set<UUID>,
        context: AgentToolResultProcessingContext?
    ) -> Bool {
        guard activity.itemKind == .toolResult else { return false }
        guard !preservedVisibleToolResultRowIDs.contains(activity.id) else { return false }
        let item = activity.toItem()
        guard let sanitized = sanitizedToolResult(for: item, toolExecution: activity.toolExecution, context: context) else { return false }
        let generatedExecution = activity.toolExecution ?? AgentTranscriptToolNormalizer.toolExecution(for: item, context: context)
        guard var updatedExecution = generatedExecution else { return false }
        updatedExecution.resultJSON = sanitized.resultJSON
        updatedExecution.toolIsError = sanitized.toolIsError
        updatedExecution.status = sanitized.transcriptStatus
        updatedExecution.summaryOnly = sanitized.summaryOnly
        updatedExecution.processID = sanitized.processID
        updatedExecution.exitCode = sanitized.exitCode
        context?.storeToolExecution(updatedExecution, for: activity.id)
        activity.text = sanitized.text
        activity.toolExecution = updatedExecution
        return true
    }

    private static func sanitizePersistentStorageActivity(
        _ activity: inout AgentTranscriptActivity,
        context: AgentToolResultProcessingContext?
    ) -> Bool {
        guard activity.toolExecution != nil || activity.itemKind == .toolCall || activity.itemKind == .toolResult else { return false }
        let item = activity.toItem()
        let generatedExecution = activity.toolExecution ?? AgentTranscriptToolNormalizer.toolExecution(for: item, context: context)
        guard var updatedExecution = generatedExecution else { return false }
        let originalActivity = activity
        let normalizedToolName = normalizedToolName(updatedExecution.toolName ?? item.toolName)
        var persistentSummaryOnly = true

        if activity.itemKind == .toolResult,
           let persistedSummary = persistedToolResultSummary(
               for: item,
               toolExecution: updatedExecution,
               rawResultTextFallback: activity.text,
               context: context
           )
        {
            updatedExecution.resultJSON = persistedSummary.resultJSON
            updatedExecution.toolIsError = persistedSummary.toolIsError
            updatedExecution.status = persistedSummary.transcriptStatus
            updatedExecution.processID = persistedSummary.processID
            updatedExecution.exitCode = persistedSummary.exitCode
            updatedExecution.summaryText = persistedSummary.summaryText
            persistentSummaryOnly = persistedSummary.summaryOnly
            activity.text = persistedSummary.resultJSON
        } else if activity.itemKind == .toolResult {
            let statusWord = AgentTranscriptToolStatusSemantics.persistedStatusWord(from: updatedExecution.status)
            let summaryText = storageSafeSummaryText(
                normalizedToolName: normalizedToolName,
                toolName: updatedExecution.toolName ?? item.toolName,
                status: updatedExecution.status,
                rawResultJSONCandidates: [updatedExecution.resultJSON, item.toolResultJSON, activity.text],
                argsJSON: item.toolArgsJSON,
                context: context
            )
            let renderSummary = storageSafeRenderSummary(
                normalizedToolName: normalizedToolName,
                statusWord: statusWord,
                rawResultJSONCandidates: [updatedExecution.resultJSON, item.toolResultJSON, activity.text],
                argsJSON: item.toolArgsJSON ?? updatedExecution.argsJSON,
                context: context,
                allowExistingSummaryOnly: updatedExecution.summaryOnly
            )
            let minimalJSON = minimalResultJSON(
                statusWord: statusWord,
                normalizedToolName: normalizedToolName,
                processID: storageSafeMetadataString(updatedExecution.processID),
                exitCode: updatedExecution.exitCode,
                summaryText: renderSummary?.inlineSummaryText ?? summaryText,
                renderSummary: renderSummary
            )
            updatedExecution.resultJSON = minimalJSON
            updatedExecution.summaryText = summaryText
            activity.text = minimalJSON
        } else {
            updatedExecution.resultJSON = nil
            updatedExecution.summaryText = storageSafeSummaryText(
                normalizedToolName: normalizedToolName,
                toolName: updatedExecution.toolName ?? item.toolName,
                status: updatedExecution.status,
                rawResultJSONCandidates: [],
                argsJSON: nil,
                context: context
            )
            activity.text = sanitizedToolCallText(toolName: updatedExecution.toolName ?? item.toolName)
        }

        updatedExecution.argsJSON = nil
        updatedExecution.summaryOnly = persistentSummaryOnly
        updatedExecution.keyPaths = []
        enforcePersistentPayloadCap(
            activity: &activity,
            execution: &updatedExecution,
            normalizedToolName: normalizedToolName
        )
        activity.toolExecution = updatedExecution
        context?.storeToolExecution(updatedExecution, for: activity.id)
        return activity != originalActivity
    }

    private static func enforcePersistentPayloadCap(
        activity: inout AgentTranscriptActivity,
        execution: inout AgentTranscriptToolExecution,
        normalizedToolName: String?
    ) {
        execution.processID = storageSafeMetadataString(execution.processID)
        execution.summaryText = smallStorageSummaryText(execution.summaryText)
        if exceedsCommittedMetadataLimit(execution.toolName) {
            execution.toolName = storageSafeMetadataString(normalizedToolName) ?? "tool"
        }

        let statusWord = AgentTranscriptToolStatusSemantics.persistedStatusWord(from: execution.status)
        let fallbackWithMetadata = minimalResultJSON(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            processID: execution.processID,
            exitCode: execution.exitCode,
            summaryText: execution.summaryText
        )
        let fallbackJSON = exceedsPersistedToolSummaryBudget(fallbackWithMetadata)
            ? minimalResultJSON(statusWord: statusWord, normalizedToolName: normalizedToolName)
            : fallbackWithMetadata

        if exceedsPersistedToolSummaryBudget(activity.text) {
            activity.text = fallbackJSON
        }
        if let resultJSON = execution.resultJSON,
           exceedsPersistedToolSummaryBudget(resultJSON)
        {
            execution.resultJSON = fallbackJSON
            if activity.itemKind == .toolResult {
                activity.text = fallbackJSON
            }
        }
        if let argsJSON = execution.argsJSON,
           exceedsPersistedToolSummaryBudget(argsJSON)
        {
            execution.argsJSON = nil
        }
        if let summaryText = execution.summaryText,
           exceedsPersistedToolSummaryBudget(summaryText)
        {
            execution.summaryText = smallStorageSummaryText(summaryText)
        }
    }

    private static func storageSafeMetadataString(_ value: String?) -> String? {
        guard let value = trimmedStorageString(value) else { return nil }
        return value.utf8.count <= 512 ? value : nil
    }

    private static func exceedsCommittedMetadataLimit(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.utf8.count > 512
    }

    private static func exceedsPersistedToolSummaryBudget(_ value: String) -> Bool {
        value.utf8.count > maxPersistedToolSummaryBytes
    }

    static func sanitizedToolCallText(toolName: String?) -> String {
        let name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return "Using tool" }
        return "Using tool: \(name)"
    }

    static func storageSafeSummaryText(toolName: String?, status: AgentTranscriptToolStatus) -> String {
        storageSafeSummaryText(
            normalizedToolName: normalizedToolName(toolName),
            toolName: toolName,
            status: status,
            rawResultJSONCandidates: [],
            argsJSON: nil,
            context: nil
        )
    }

    private static func storageSafeSummaryText(
        normalizedToolName: String?,
        toolName: String?,
        status: AgentTranscriptToolStatus,
        rawResultJSONCandidates: [String?],
        argsJSON: String?,
        context: AgentToolResultProcessingContext?
    ) -> String {
        let statusWord = AgentTranscriptToolStatusSemantics.persistedStatusWord(from: status)
        if let renderSummary = storageSafeRenderSummary(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            rawResultJSONCandidates: rawResultJSONCandidates,
            argsJSON: argsJSON,
            context: context,
            allowExistingSummaryOnly: false
        ), let inlineSummary = renderSummary.inlineSummaryText {
            return inlineSummary
        }
        if normalizedToolName == "git" {
            let argsObject = jsonObject(from: argsJSON, context: context)
            for rawResultJSON in rawResultJSONCandidates {
                guard let summary = gitStorageSummaryText(
                    rawObject: jsonObject(from: rawResultJSON, context: context),
                    argsObject: argsObject
                ) else { continue }
                return summary
            }
            if let summary = gitStorageSummaryText(rawObject: nil, argsObject: argsObject) {
                return summary
            }
        }
        let name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false) ? name ?? "tool" : "tool"
        return "\(displayName) • \(status.rawValue)"
    }

    static func minimalResultJSON(
        statusWord: String,
        normalizedToolName: String? = nil,
        processID: String? = nil,
        exitCode: Int? = nil,
        summaryText: String? = nil,
        renderSummary: AgentToolCardRenderSummary? = nil
    ) -> String {
        var object = minimalResultObject(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            processID: processID,
            exitCode: exitCode,
            summaryText: summaryText,
            renderSummary: renderSummary
        )
        if let json = jsonString(from: object), !exceedsPersistedToolSummaryBudget(json) {
            return json
        }
        if let renderSummary, renderSummary.detailText != nil {
            let shortened = renderSummary.withoutDetailText()
            object = minimalResultObject(
                statusWord: statusWord,
                normalizedToolName: normalizedToolName,
                processID: processID,
                exitCode: exitCode,
                summaryText: shortened.inlineSummaryText ?? summaryText,
                renderSummary: shortened
            )
            if let json = jsonString(from: object), !exceedsPersistedToolSummaryBudget(json) {
                return json
            }
        }
        object = minimalResultObject(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            processID: processID,
            exitCode: exitCode,
            summaryText: summaryText,
            renderSummary: nil
        )
        if let json = jsonString(from: object), !exceedsPersistedToolSummaryBudget(json) {
            return json
        }
        object = minimalResultObject(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            processID: processID,
            exitCode: exitCode,
            summaryText: nil,
            renderSummary: nil
        )
        return jsonString(from: object) ?? #"{"status":"unknown","summary_only":true}"#
    }

    private static func minimalResultObject(
        statusWord: String,
        normalizedToolName: String?,
        processID: String?,
        exitCode: Int?,
        summaryText: String?,
        renderSummary: AgentToolCardRenderSummary?
    ) -> [String: Any] {
        var object: [String: Any] = [
            "status": statusWord,
            "summary_only": true
        ]
        if normalizedToolName == "bash" {
            object["type"] = "commandExecution"
        }
        if let processID, !processID.isEmpty {
            object["processId"] = processID
        }
        if let exitCode {
            object["exitCode"] = exitCode
        }
        if let summaryText = smallStorageSummaryText(summaryText) {
            object["summary_text"] = summaryText
        }
        if let renderSummary {
            object["render_summary"] = renderSummary.dictionary
        }
        return object
    }

    private static func gitStorageSummaryText(rawObject: [String: Any]?, argsObject: [String: Any]?) -> String? {
        if let existingSummary = existingGitSummaryOnlyText(rawObject) {
            return existingSummary
        }
        if boolValue(rawObject, keys: ["summary_only", "summaryOnly"]) == true {
            return nil
        }
        guard rawObject != nil || argsObject != nil else { return nil }
        let op = trimmedStorageString(stringValue(rawObject, keys: ["op"]))
            ?? trimmedStorageString(stringValue(argsObject, keys: ["op"]))
            ?? "git"
        let subtitle: String
        let detailText: String?
        switch op.lowercased() {
        case "status":
            subtitle = joinStorageSummary(op, gitStatusPrimarySummary(rawObject: rawObject))
            detailText = gitStatusDetailText(rawObject: rawObject)
        case "diff":
            subtitle = joinStorageSummary(op, gitPreferredDiffSummary(rawObject: rawObject))
            detailText = gitDiffDetailText(rawObject: rawObject, argsObject: argsObject)
        case "log":
            subtitle = joinStorageSummary(op, gitLogSummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject))
            detailText = nil
        case "show":
            subtitle = joinStorageSummary(op, gitShowSummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject))
            detailText = nil
        case "blame":
            subtitle = joinStorageSummary(op, gitBlameSummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject))
            detailText = nil
        default:
            subtitle = joinStorageSummary(op, gitPreferredDiffSummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject))
            detailText = nil
        }
        return inlineStorageSummary(subtitle, detailText)
    }

    private static func storageSafeRenderSummary(
        normalizedToolName: String?,
        statusWord: String,
        rawResultJSONCandidates: [String?],
        argsJSON: String?,
        context: AgentToolResultProcessingContext?,
        allowExistingSummaryOnly: Bool = false
    ) -> AgentToolCardRenderSummary? {
        let argsObject = jsonObject(from: argsJSON, context: context)
        for rawResultJSON in rawResultJSONCandidates {
            let rawObject = jsonObject(from: rawResultJSON, context: context)
            guard rawObject != nil else { continue }
            if let summary = AgentToolCardRenderSummaryBuilder.build(
                normalizedToolName: normalizedToolName,
                statusWord: statusWord,
                rawObject: rawObject,
                argsObject: argsObject,
                allowExistingSummaryOnly: allowExistingSummaryOnly
            ) {
                return summary
            }
        }
        return AgentToolCardRenderSummaryBuilder.build(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            rawObject: nil,
            argsObject: argsObject,
            allowExistingSummaryOnly: false
        )
    }

    private static func existingGitSummaryOnlyText(_ rawObject: [String: Any]?) -> String? {
        guard boolValue(rawObject, keys: ["summary_only", "summaryOnly"]) == true else { return nil }
        return smallStorageSummaryText(stringValue(rawObject, keys: ["summary_text", "summaryText"]))
    }

    private static func gitStatusPrimarySummary(rawObject: [String: Any]?) -> String? {
        let status = rawObject?["status"] as? [String: Any]
        return trimmedStorageString(stringValue(status, keys: ["branch"]))
            ?? gitRepoCountText(rawObject: rawObject)
    }

    private static func gitStatusDetailText(rawObject: [String: Any]?) -> String? {
        guard let status = rawObject?["status"] as? [String: Any] else { return nil }
        var parts: [String] = []
        let ahead = intValue(status, keys: ["ahead"])
        let behind = intValue(status, keys: ["behind"])
        if let ahead, let behind, ahead > 0 || behind > 0 {
            parts.append("+\(ahead) -\(behind)")
        }
        if let upstream = trimmedStorageString(stringValue(status, keys: ["upstream"])) {
            parts.append(upstream)
        }
        appendArrayCountSummary(&parts, object: status, key: "staged", label: "staged")
        appendArrayCountSummary(&parts, object: status, key: "modified", label: "modified")
        appendArrayCountSummary(&parts, object: status, key: "untracked", label: "untracked")
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func gitDiffDetailText(rawObject: [String: Any]?, argsObject: [String: Any]?) -> String? {
        let inputs = rawObject?["inputs"] as? [String: Any]
        let diff = rawObject?["diff"] as? [String: Any]
        let worktree = rawObject?["worktree"] as? [String: Any]
        var parts: [String] = []
        if let compare = trimmedStorageString(stringValue(inputs, keys: ["compare"]) ?? stringValue(argsObject, keys: ["compare"])) {
            parts.append(compare)
        }
        if let scope = trimmedStorageString(stringValue(inputs, keys: ["scope"])) {
            parts.append(scope)
        }
        if let detail = trimmedStorageString(stringValue(diff, keys: ["detail"]) ?? stringValue(argsObject, keys: ["detail"])) {
            parts.append(detail)
        }
        if parts.count < 3,
           let branch = trimmedStorageString(stringValue(worktree, keys: ["worktree_branch"]))
        {
            parts.append(branch)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func gitPreferredDiffSummary(rawObject: [String: Any]?) -> String? {
        let aggregate = rawObject?["aggregate"] as? [String: Any]
        let diff = rawObject?["diff"] as? [String: Any]
        let summary = rawObject?["summary"] as? [String: Any]
        return gitTotalsSummaryText(object: aggregate?["totals"] as? [String: Any])
            ?? gitTotalsSummaryText(object: diff?["totals"] as? [String: Any])
            ?? gitTotalsSummaryText(object: summary)
            ?? safeGitDiffOneliner(stringValue(aggregate, keys: ["oneliner"]))
            ?? safeGitDiffOneliner(stringValue(diff, keys: ["oneliner"]))
            ?? safeGitDiffOneliner(stringValue(rawObject, keys: ["oneliner"]))
    }

    private static func safeGitDiffOneliner(_ value: String?) -> String? {
        guard let value = trimmedStorageString(value) else { return nil }
        let lowered = value.lowercased()
        guard !lowered.contains("diff --"),
              !lowered.contains("@@"),
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\n"),
              !value.contains("+++"),
              !value.contains("---")
        else { return nil }
        if lowered == "no changes" { return value }
        let pattern = #"^(?:[0-9]+ repos?: )?[0-9]+ files? \(\+[0-9]+ -[0-9]+\)$"#
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: value, range: range) != nil ? value : nil
    }

    private static func gitTotalsSummaryText(object: [String: Any]?) -> String? {
        guard let files = intValue(object, keys: ["files"]),
              let insertions = intValue(object, keys: ["insertions"]),
              let deletions = intValue(object, keys: ["deletions"])
        else { return nil }
        return "\(files) files (+\(insertions) -\(deletions))"
    }

    private static func gitLogSummary(rawObject: [String: Any]?) -> String? {
        guard let log = rawObject?["log"] as? [String: Any],
              let commits = log["commits"] as? [[String: Any]]
        else { return nil }
        if commits.count == 1,
           let first = commits.first,
           let shortSHA = trimmedStorageString(stringValue(first, keys: ["short_sha", "shortSha"]))
        {
            return shortSHA
        }
        return "\(commits.count) commits"
    }

    private static func gitShowSummary(rawObject: [String: Any]?) -> String? {
        guard let show = rawObject?["show"] as? [String: Any] else { return nil }
        return trimmedStorageString(stringValue(show, keys: ["short_sha", "shortSha"]))
    }

    private static func gitBlameSummary(rawObject: [String: Any]?) -> String? {
        guard let blame = rawObject?["blame"] as? [String: Any],
              let lines = blame["lines"] as? [Any]
        else { return nil }
        return "\(lines.count) lines"
    }

    private static func gitRepoCountText(rawObject: [String: Any]?) -> String? {
        guard let repos = rawObject?["repos"] as? [[String: Any]], repos.count > 1 else { return nil }
        return "\(repos.count) repos"
    }

    private static func appendArrayCountSummary(_ parts: inout [String], object: [String: Any], key: String, label: String) {
        guard let array = object[key] as? [Any], !array.isEmpty else { return }
        parts.append("\(array.count) \(label)")
    }

    private static func inlineStorageSummary(_ primary: String?, _ secondary: String?) -> String? {
        let parts = [primary, secondary]
            .compactMap { trimmedStorageString($0) }
        guard !parts.isEmpty else { return nil }
        return smallStorageSummaryText(parts.joined(separator: " • "))
    }

    private static func joinStorageSummary(_ lhs: String, _ rhs: String?) -> String {
        guard let rhs = trimmedStorageString(rhs) else { return lhs }
        return "\(lhs) • \(rhs)"
    }

    private static func smallStorageSummaryText(_ text: String?) -> String? {
        guard let text = trimmedStorageString(text) else { return nil }
        if text.count <= 240 { return text }
        let prefix = text.prefix(237).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : prefix + "…"
    }

    private static func trimmedStorageString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func normalizedToolName(_ raw: String?) -> String? {
        AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(raw)
    }

    private static func derivedStatusWord(
        normalizedToolName: String?,
        rawResultJSON: String?,
        rawObject: [String: Any]?,
        executionStatus: AgentTranscriptToolStatus?,
        toolIsError: Bool?,
        context: AgentToolResultProcessingContext?
    ) -> String {
        if normalizedToolName == "bash" {
            let metadata = BashToolResultParser.parseMetadata(raw: rawResultJSON, context: context)
            if let statusWord = AgentTranscriptToolStatusSemantics.normalizedBashStatusWord(
                metadata: metadata,
                rawObject: rawObject
            ) {
                return statusWord
            }
            if let bashTextStatus = bashTextStatus(from: rawResultJSON, context: context) {
                return bashTextStatus
            }
        }
        if let rawStatus = AgentTranscriptToolStatusSemantics.normalizedStatusWord(
            stringValue(rawObject, keys: ["status", "result", "outcome", "state", "subtype"])
        ) {
            return rawStatus
        }
        if let executionStatus, executionStatus != .unknown {
            return AgentTranscriptToolStatusSemantics.persistedStatusWord(from: executionStatus)
        }
        if let toolIsError {
            return toolIsError ? "failed" : "success"
        }
        return "unknown"
    }

    private static func persistedToolIsError(
        normalizedToolName: String?,
        status: AgentTranscriptToolStatus,
        original: Bool?
    ) -> Bool? {
        if normalizedToolName == "bash" {
            return status == .running ? false : nil
        }
        if let original {
            return original
        }
        switch status {
        case .failed, .cancelled:
            return true
        case .success:
            return false
        default:
            return nil
        }
    }

    private static func sanitizedSummaryJSON(
        normalizedToolName: String?,
        statusWord: String,
        processID: String?,
        exitCode: Int?,
        rawObject: [String: Any]?,
        argsJSON: String?,
        context: AgentToolResultProcessingContext?
    ) -> String? {
        let allowExistingRenderSummary = boolValue(rawObject, keys: ["summary_only", "summaryOnly"]) == true
        if let renderSummary = AgentToolCardRenderSummaryBuilder.build(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            rawObject: rawObject,
            argsObject: jsonObject(from: argsJSON, context: context),
            allowExistingSummaryOnly: allowExistingRenderSummary
        ) {
            return minimalResultJSON(
                statusWord: statusWord,
                normalizedToolName: normalizedToolName,
                processID: processID,
                exitCode: exitCode,
                summaryText: renderSummary.inlineSummaryText,
                renderSummary: renderSummary
            )
        }
        if let cursorSummaryJSON = cursorACPSummaryJSON(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode,
            rawObject: rawObject
        ) {
            return cursorSummaryJSON
        }
        switch normalizedToolName {
        case "apply_edits":
            return applyEditsSummaryJSON(
                statusWord: statusWord,
                rawObject: rawObject
            )
        case "apply_patch":
            return applyPatchSummaryJSON(
                statusWord: statusWord,
                rawObject: rawObject,
                argsJSON: argsJSON,
                context: context
            )
        case "bash":
            return bashSummaryJSON(
                statusWord: statusWord,
                processID: processID,
                exitCode: exitCode
            )
        case "agent_run", "agent_explore":
            return agentRunSummaryJSON(normalizedToolName: normalizedToolName, statusWord: statusWord, rawObject: rawObject)
        case "agent_manage":
            return agentManageSummaryJSON(statusWord: statusWord, rawObject: rawObject)
        case "ask_oracle", "oracle_send":
            return oracleChatSummaryJSON(
                normalizedToolName: normalizedToolName,
                statusWord: statusWord,
                rawObject: rawObject
            )
        default:
            return genericSummaryJSON(
                normalizedToolName: normalizedToolName,
                statusWord: statusWord,
                processID: processID,
                exitCode: exitCode
            )
        }
    }

    private static func genericSummaryJSON(
        normalizedToolName: String?,
        statusWord: String,
        processID: String?,
        exitCode: Int?
    ) -> String? {
        jsonString(from: genericSummaryObject(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode
        ))
    }

    private static func genericSummaryObject(
        normalizedToolName: String?,
        statusWord: String,
        processID: String?,
        exitCode: Int?
    ) -> [String: Any] {
        var object: [String: Any] = [
            "status": statusWord,
            "summary_only": true
        ]
        if normalizedToolName == "bash" {
            object["type"] = "commandExecution"
        }
        if let processID, !processID.isEmpty {
            object["processId"] = processID
        }
        if let exitCode {
            object["exitCode"] = exitCode
        }
        return object
    }

    private static func bashSummaryJSON(
        statusWord: String,
        processID: String?,
        exitCode: Int?
    ) -> String? {
        jsonString(from: genericSummaryObject(
            normalizedToolName: "bash",
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode
        ))
    }

    private static func applyEditsSummaryJSON(
        statusWord: String,
        rawObject: [String: Any]?
    ) -> String? {
        var object = genericSummaryObject(
            normalizedToolName: "apply_edits",
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        if let editsRequested = intValue(rawObject, keys: ["edits_requested"]) {
            object["edits_requested"] = editsRequested
        }
        if let editsApplied = intValue(rawObject, keys: ["edits_applied"]) {
            object["edits_applied"] = editsApplied
        }
        if let totalLinesChanged = intValue(rawObject, keys: ["total_lines_changed"]) {
            object["total_lines_changed"] = totalLinesChanged
        }
        if let fileCreated = boolValue(rawObject, keys: ["file_created"]) {
            object["file_created"] = fileCreated
        }
        if let fileOverwritten = boolValue(rawObject, keys: ["file_overwritten"]) {
            object["file_overwritten"] = fileOverwritten
        }
        if let reviewStatus = stringValue(rawObject, keys: ["review_status"]),
           !reviewStatus.isEmpty
        {
            object["review_status"] = reviewStatus
        }
        if let requiresUserApproval = boolValue(rawObject, keys: ["requires_user_approval"]) {
            object["requires_user_approval"] = requiresUserApproval
        }
        if let note = smallStringValue(rawObject, keys: ["note"]) {
            object["note"] = note
        }
        if let rejectionReason = smallStringValue(rawObject, keys: ["rejection_reason"]) {
            object["rejection_reason"] = rejectionReason
        }
        return jsonString(from: object)
    }

    private static func applyPatchSummaryJSON(
        statusWord: String,
        rawObject: [String: Any]?,
        argsJSON: String?,
        context: AgentToolResultProcessingContext?
    ) -> String? {
        var object = genericSummaryObject(
            normalizedToolName: "apply_patch",
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        let changes = summarizedPatchChanges(from: rawObject)
        object["changes"] = changes
        if let changeCount = intValue(rawObject, keys: ["change_count"]) {
            object["change_count"] = max(changeCount, changes.count)
        } else if let argCount = intValue(jsonObject(from: argsJSON, context: context), keys: ["change_count"]) {
            object["change_count"] = max(argCount, changes.count)
        } else {
            object["change_count"] = changes.count
        }
        return jsonString(from: object)
    }

    private static func summarizedPatchChanges(from rawObject: [String: Any]?) -> [[String: Any]] {
        guard let rawChanges = rawObject?["changes"] as? [[String: Any]] else { return [] }
        return rawChanges.compactMap { change in
            guard let path = stringValue(change, keys: ["path"]),
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            var summarized: [String: Any] = [
                "path": path,
                "kind": stringValue(change, keys: ["kind"]) ?? "update",
                "diff": ""
            ]
            if let movePath = stringValue(change, keys: ["move_path", "movePath"]),
               !movePath.isEmpty
            {
                summarized["move_path"] = movePath
            }
            return summarized
        }
    }

    private static func cursorACPSummaryJSON(
        normalizedToolName: String?,
        statusWord: String,
        processID: String?,
        exitCode: Int?,
        rawObject: [String: Any]?
    ) -> String? {
        guard let rawObject,
              stringValue(rawObject, keys: ["acp_status"]) != nil
        else { return nil }

        let isEdit = normalizedToolName == "edit"
        var object = cursorACPBaseSummaryObject(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode,
            rawObject: rawObject
        )
        if let content = cursorACPContentSummary(
            from: rawObject,
            isEdit: isEdit,
            diffLimit: cursorACPPersistedDiffBytesLimit
        ), !content.isEmpty {
            object["content"] = content
            if isEdit {
                object["change_count"] = content.count
            }
        }
        if let rawOutput = cursorACPRawOutputSummary(from: rawObject["rawOutput"]) {
            object["rawOutput"] = rawOutput
        }
        if let json = jsonString(from: object), !exceedsPersistedToolSummaryBudget(json) {
            return json
        }
        guard isEdit,
              let compactContent = cursorACPContentSummary(
                  from: rawObject,
                  isEdit: true,
                  diffLimit: cursorACPFallbackPersistedDiffBytesLimit
              ), !compactContent.isEmpty
        else { return nil }
        object["content"] = compactContent
        object["change_count"] = compactContent.count
        return jsonString(from: object).flatMap { exceedsPersistedToolSummaryBudget($0) ? nil : $0 }
    }

    private static func cursorACPBaseSummaryObject(
        normalizedToolName: String?,
        statusWord: String,
        processID: String?,
        exitCode: Int?,
        rawObject: [String: Any]
    ) -> [String: Any] {
        var object = genericSummaryObject(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode
        )
        if let acpStatus = smallStringValue(rawObject, keys: ["acp_status"]) {
            object["acp_status"] = acpStatus
        }
        if let kind = smallStringValue(rawObject, keys: ["kind"]) {
            object["kind"] = kind
        }
        if let title = smallStringValue(rawObject, keys: ["title"]) {
            object["title"] = title
        }
        return object
    }

    private static func cursorACPContentSummary(
        from rawObject: [String: Any],
        isEdit: Bool,
        diffLimit: Int
    ) -> [[String: Any]]? {
        guard let rawContent = rawObject["content"] as? [[String: Any]] else { return nil }
        let summaries: [[String: Any]] = rawContent.compactMap { entry in
            let type = stringValue(entry, keys: ["type"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = stringValue(entry, keys: ["path"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard type?.isEmpty == false || path?.isEmpty == false else { return nil }
            return isEdit
                ? cursorACPEditContentSummary(entry: entry, type: type, path: path, diffLimit: diffLimit)
                : cursorACPNonEditContentSummary(entry: entry, type: type, path: path)
        }
        return summaries.isEmpty ? nil : summaries
    }

    private static func cursorACPEditContentSummary(
        entry: [String: Any],
        type: String?,
        path: String?,
        diffLimit: Int
    ) -> [String: Any]? {
        var summary: [String: Any] = [:]
        if let type, !type.isEmpty { summary["type"] = type }
        if let path, !path.isEmpty { summary["path"] = path }
        if let oldTextTruncated = boolValue(entry, keys: ["oldText_truncated", "old_text_truncated", "oldTextTruncated"]) {
            summary["oldText_truncated"] = oldTextTruncated
        }
        if let newTextTruncated = boolValue(entry, keys: ["newText_truncated", "new_text_truncated", "newTextTruncated"]) {
            summary["newText_truncated"] = newTextTruncated
        }
        if let diffTruncated = boolValue(entry, keys: ["diff_truncated", "diffTruncated"]) {
            summary["diff_truncated"] = diffTruncated
        }
        if let existingDiff = stringValue(entry, keys: ["unified_diff", "card_unified_diff"]),
           let clipped = clippedCursorACPString(existingDiff, limit: diffLimit)
        {
            summary["unified_diff"] = clipped.value
            if clipped.wasTruncated {
                summary["diff_truncated"] = true
            }
            return summary.isEmpty ? nil : summary
        }
        if let path, !path.isEmpty,
           let oldText = stringValue(entry, keys: ["oldText", "old_text"]),
           let newText = stringValue(entry, keys: ["newText", "new_text"])
        {
            copyCursorACPStringMetrics(from: entry, key: "oldText", into: &summary)
            copyCursorACPStringMetrics(from: entry, key: "newText", into: &summary)
            guard shouldGenerateCursorACPDiff(oldText: oldText, newText: newText) else {
                summary["diff_truncated"] = true
                return summary.isEmpty ? nil : summary
            }
            guard let diff = cursorACPUnifiedDiff(path: path, oldText: oldText, newText: newText),
                  let clipped = clippedCursorACPString(diff, limit: diffLimit) else { return summary.isEmpty ? nil : summary }
            summary["unified_diff"] = clipped.value
            if clipped.wasTruncated {
                summary["diff_truncated"] = true
            }
        }
        return summary.isEmpty ? nil : summary
    }

    private static func cursorACPNonEditContentSummary(
        entry: [String: Any],
        type: String?,
        path: String?
    ) -> [String: Any]? {
        var summary: [String: Any] = [:]
        if let type, !type.isEmpty { summary["type"] = type }
        if let path, !path.isEmpty { summary["path"] = path }
        for key in ["text", "content", "output", "oldText", "newText"] {
            copyCursorACPStringMetrics(from: entry, key: key, into: &summary)
        }
        return summary.isEmpty ? nil : summary
    }

    private static func shouldGenerateCursorACPDiff(oldText: String, newText: String) -> Bool {
        let totalBytes = oldText.utf8.count + newText.utf8.count
        guard totalBytes <= cursorACPGeneratedDiffInputBytesLimit else { return false }
        let totalLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).count
            + newText.split(separator: "\n", omittingEmptySubsequences: false).count
        return totalLines <= cursorACPGeneratedDiffInputLineLimit
    }

    private static func cursorACPUnifiedDiff(path: String, oldText: String, newText: String) -> String? {
        let oldLines = String.splitContentPreservingLineEndings(oldText).0
        let newLines = String.splitContentPreservingLineEndings(newText).0
        let chunks = UnifiedDiffGenerator.diffChunks(
            oldLines: oldLines,
            newLines: newLines,
            context: 2
        )
        let diff = UnifiedDiffGenerator.build(filePath: path, chunks: chunks, context: 2)
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : diff
    }

    private static func cursorACPRawOutputSummary(from rawOutput: Any?) -> [String: Any]? {
        guard let rawOutput = rawOutput as? [String: Any], !rawOutput.isEmpty else { return nil }
        var summary: [String: Any] = [:]
        for key in ["success", "truncated", "totalFiles", "exitCode", "code", "stdoutSanitized"] {
            if let value = rawOutput[key], value is Bool || value is NSNumber || value is Int || value is Double {
                summary[key] = value
            }
        }
        for key in ["stdout", "stderr", "content", "output"] {
            copyCursorACPStringMetrics(from: rawOutput, key: key, into: &summary)
            copyExistingCursorACPStringMetrics(from: rawOutput, key: key, into: &summary)
        }
        for key in ["error", "errorMessage", "message"] {
            copyClippedCursorACPString(from: rawOutput, key: key, into: &summary)
        }
        return summary.isEmpty ? nil : summary
    }

    private static func copyCursorACPStringMetrics(
        from object: [String: Any],
        key: String,
        into summary: inout [String: Any]
    ) {
        guard let raw = stringValue(object, keys: [key]),
              !raw.isEmpty else { return }
        summary["\(key)_bytes"] = raw.utf8.count
        summary["\(key)_line_count"] = raw.isEmpty ? 0 : raw.split(separator: "\n", omittingEmptySubsequences: false).count
        if boolValue(object, keys: ["\(key)_truncated", "\(key)Truncated"]) == true {
            summary["\(key)_truncated"] = true
        }
    }

    private static func copyExistingCursorACPStringMetrics(
        from object: [String: Any],
        key: String,
        into summary: inout [String: Any]
    ) {
        if let bytes = intValue(object, keys: ["\(key)_bytes", "\(key)Bytes"]) {
            summary["\(key)_bytes"] = bytes
        }
        if let lineCount = intValue(object, keys: ["\(key)_line_count", "\(key)LineCount"]) {
            summary["\(key)_line_count"] = lineCount
        }
        if boolValue(object, keys: ["\(key)_truncated", "\(key)Truncated"]) == true {
            summary["\(key)_truncated"] = true
        }
    }

    private static func copyClippedCursorACPString(
        from object: [String: Any],
        key: String,
        into summary: inout [String: Any]
    ) {
        guard let raw = stringValue(object, keys: [key]),
              let clipped = clippedCursorACPString(raw) else { return }
        summary[key] = clipped.value
        if clipped.wasTruncated {
            summary["\(key)_truncated"] = true
        }
    }

    private static func clippedCursorACPString(_ raw: String, limit: Int = 600) -> (value: String, wasTruncated: Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return (trimmed, false) }
        let prefix = trimmed.prefix(limit).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : (prefix + "…", true)
    }

    private static func agentRunSummaryJSON(
        normalizedToolName: String?,
        statusWord: String,
        rawObject: [String: Any]?
    ) -> String? {
        var object = genericSummaryObject(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        if let rawObject {
            if let reason = smallStringValue(rawObject, keys: ["reason"]) {
                object["reason"] = reason
            }
            if let note = smallStringValue(rawObject, keys: ["note"]) {
                object["note"] = note
            }
            if let op = smallStringValue(rawObject, keys: ["op"]) {
                object["op"] = op
            }
            if let statusText = smallStringValue(rawObject, keys: ["status_text"]) {
                object["status_text"] = statusText
            }
            if let assistantText = smallStringValue(rawObject, keys: ["assistant_text"]) {
                object["assistant_text"] = assistantText
            }
            if let transcriptItemCount = intValue(rawObject, keys: ["transcript_item_count"]) {
                object["transcript_item_count"] = transcriptItemCount
            }
            if let workflowID = smallStringValue(rawObject, keys: ["workflow_id"]) {
                object["workflow_id"] = workflowID
            }
            if let workflowName = smallStringValue(rawObject, keys: ["workflow_name"]) {
                object["workflow_name"] = workflowName
            }
            if let session = rawObject["session"] as? [String: Any] {
                var sessionObject: [String: Any] = [:]
                if let id = stringValue(session, keys: ["id"]), !id.isEmpty {
                    sessionObject["id"] = id
                }
                if let name = smallStringValue(session, keys: ["name"]) {
                    sessionObject["name"] = name
                }
                if !sessionObject.isEmpty {
                    object["session"] = sessionObject
                }
            }
            if let sessionID = stringValue(rawObject, keys: ["session_id"])
                ?? stringValue(rawObject["session"] as? [String: Any], keys: ["id"]),
                !sessionID.isEmpty
            {
                object["session_id"] = sessionID
            }
            if let agent = rawObject["agent"] as? [String: Any] {
                var agentObject: [String: Any] = [:]
                if let id = stringValue(agent, keys: ["id"]), !id.isEmpty {
                    agentObject["id"] = id
                }
                if let name = smallStringValue(agent, keys: ["name"]) {
                    agentObject["name"] = name
                }
                if let model = smallStringValue(agent, keys: ["model"]) {
                    agentObject["model"] = model
                }
                if let reasoningEffort = smallStringValue(agent, keys: ["reasoning_effort"]) {
                    agentObject["reasoning_effort"] = reasoningEffort
                }
                if !agentObject.isEmpty {
                    object["agent"] = agentObject
                }
            }
            if let interaction = rawObject["interaction"] as? [String: Any] {
                var interactionObject: [String: Any] = [:]
                if let id = stringValue(interaction, keys: ["id"]), !id.isEmpty {
                    interactionObject["id"] = id
                }
                if let kind = smallStringValue(interaction, keys: ["kind"]) {
                    interactionObject["kind"] = kind
                }
                if let responseType = smallStringValue(interaction, keys: ["response_type"]) {
                    interactionObject["response_type"] = responseType
                }
                if let prompt = smallStringValue(interaction, keys: ["prompt"]) {
                    interactionObject["prompt"] = prompt
                }
                if !interactionObject.isEmpty {
                    object["interaction"] = interactionObject
                }
            }
            if let meta = rawObject["_meta"] as? [String: Any],
               let delivery = smallStringValue(meta, keys: ["delivery"])
            {
                object["_meta"] = ["delivery": delivery]
            }
        }
        return jsonString(from: object)
    }

    private static func agentManageSummaryJSON(
        statusWord: String,
        rawObject: [String: Any]?
    ) -> String? {
        var object = genericSummaryObject(
            normalizedToolName: "agent_manage",
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        if let rawObject {
            if let name = smallStringValue(rawObject, keys: ["name"]) {
                object["name"] = name
            }
            if let sessionID = stringValue(rawObject, keys: ["session_id"]), !sessionID.isEmpty {
                object["session_id"] = sessionID
            }
            if let returnedTurnCount = intValue(rawObject, keys: ["returned_turn_count"]) {
                object["returned_turn_count"] = returnedTurnCount
            }
            if let totalTurns = intValue(rawObject, keys: ["total_turns"]) {
                object["total_turns"] = totalTurns
            }
            if let agent = rawObject["agent"] as? [String: Any] {
                var agentObject: [String: Any] = [:]
                if let id = stringValue(agent, keys: ["id"]), !id.isEmpty {
                    agentObject["id"] = id
                }
                if let name = smallStringValue(agent, keys: ["name"]) {
                    agentObject["name"] = name
                }
                if let model = smallStringValue(agent, keys: ["model"]) {
                    agentObject["model"] = model
                }
                if !agentObject.isEmpty {
                    object["agent"] = agentObject
                }
            } else if let agent = smallStringValue(rawObject, keys: ["agent"]) {
                object["agent"] = agent
            }
            if let agents = rawObject["agents"] as? [[String: Any]] {
                object["agents"] = agents.prefix(10).map { agent in
                    var summary: [String: Any] = [:]
                    if let name = smallStringValue(agent, keys: ["name", "id"]) { summary["name"] = name }
                    if let available = boolValue(agent, keys: ["available"]) { summary["available"] = available }
                    return summary
                }
            }
            if let sessions = rawObject["sessions"] as? [[String: Any]] {
                object["sessions"] = sessions.prefix(10).map { session in
                    var summary: [String: Any] = [:]
                    if let name = smallStringValue(session, keys: ["name"]) { summary["name"] = name }
                    if let state = smallStringValue(session, keys: ["state"]) { summary["state"] = state }
                    if let agent = session["agent"] as? [String: Any] {
                        var agentSummary: [String: Any] = [:]
                        if let id = smallStringValue(agent, keys: ["id"]) { agentSummary["id"] = id }
                        if let name = smallStringValue(agent, keys: ["name"]) { agentSummary["name"] = name }
                        if !agentSummary.isEmpty { summary["agent"] = agentSummary }
                    } else if let agent = smallStringValue(session, keys: ["agent"]) {
                        summary["agent"] = agent
                    }
                    return summary
                }
            }
            if let deletedCount = intValue(rawObject, keys: ["deleted_count", "deletedCount"])
                ?? (rawObject["deleted_sessions"] as? [Any])?.count
                ?? (rawObject["deletedSessions"] as? [Any])?.count
            {
                object["deleted_count"] = deletedCount
            }
            if let skippedCount = intValue(rawObject, keys: ["skipped_count", "skippedCount"])
                ?? (rawObject["skipped_sessions"] as? [Any])?.count
                ?? (rawObject["skippedSessions"] as? [Any])?.count
            {
                object["skipped_count"] = skippedCount
            }
            if let deletedCount = object["deleted_count"] as? Int,
               let skippedCount = object["skipped_count"] as? Int
            {
                object["summary_text"] = "\(deletedCount) deleted, \(skippedCount) skipped"
            } else if let deletedCount = object["deleted_count"] as? Int {
                object["summary_text"] = "\(deletedCount) deleted"
            } else if let skippedCount = object["skipped_count"] as? Int {
                object["summary_text"] = "\(skippedCount) skipped"
            }
            if let workflows = rawObject["workflows"] as? [[String: Any]] {
                object["workflows"] = workflows.prefix(10).map { workflow in
                    var summary: [String: Any] = [:]
                    if let name = smallStringValue(workflow, keys: ["name", "id"]) { summary["name"] = name }
                    return summary
                }
            }
        }
        return jsonString(from: object)
    }

    private static func agentManageCountSummaryJSON(
        statusWord: String,
        rawObject: [String: Any]?
    ) -> String? {
        let deletedCount = intValue(rawObject, keys: ["deleted_count", "deletedCount"])
        let skippedCount = intValue(rawObject, keys: ["skipped_count", "skippedCount"])
        guard deletedCount != nil || skippedCount != nil else { return nil }
        var object = genericSummaryObject(
            normalizedToolName: "agent_manage",
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        if let deletedCount {
            object["deleted_count"] = deletedCount
        }
        if let skippedCount {
            object["skipped_count"] = skippedCount
        }
        if let deletedCount, let skippedCount {
            object["summary_text"] = "\(deletedCount) deleted, \(skippedCount) skipped"
        } else if let deletedCount {
            object["summary_text"] = "\(deletedCount) deleted"
        } else if let skippedCount {
            object["summary_text"] = "\(skippedCount) skipped"
        }
        return jsonString(from: object)
    }

    private static func oracleChatSummaryJSON(
        normalizedToolName: String?,
        statusWord: String,
        rawObject: [String: Any]?
    ) -> String? {
        var object = genericSummaryObject(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        guard let rawObject else { return jsonString(from: object) }
        if let chatID = smallStringValue(rawObject, keys: ["chat_id", "chatID"]) {
            object["chat_id"] = chatID
        }
        if let mode = smallStringValue(rawObject, keys: ["mode"]) {
            object["mode"] = mode
        }
        let diffCount = intValue(rawObject, keys: ["diff_count", "diffCount"])
            ?? (rawObject["diffs"] as? [Any])?.count
            ?? (rawObject["patches"] as? [Any])?.count
        if let diffCount {
            object["diff_count"] = diffCount
        }
        if let response = stringValue(rawObject, keys: ["response"]),
           !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            object["has_response"] = true
        } else if let hasResponse = boolValue(rawObject, keys: ["has_response", "hasResponse"]) {
            object["has_response"] = hasResponse
        }
        let rawErrors = rawObject["errors"] as? [Any] ?? []
        if !rawErrors.isEmpty {
            object["error_count"] = rawErrors.count
        } else if let errorCount = intValue(rawObject, keys: ["error_count", "errorCount"]) {
            object["error_count"] = errorCount
        }
        if let summaryText = oracleChatSummaryText(from: object) {
            object["summary_text"] = summaryText
        }
        if let json = jsonString(from: object), !exceedsPersistedToolSummaryBudget(json) {
            return json
        }
        return minimalResultJSON(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            summaryText: object["summary_text"] as? String
        )
    }

    private static func oracleChatSummaryText(from object: [String: Any]) -> String? {
        var parts: [String] = []
        if let mode = stringValue(object, keys: ["mode"]), !mode.isEmpty {
            parts.append(mode)
        }
        let diffCount = intValue(object, keys: ["diff_count", "diffCount"])
        if let chatID = stringValue(object, keys: ["chat_id", "chatID"]),
           !chatID.isEmpty,
           parts.isEmpty || (diffCount ?? 0) == 0
        {
            parts.append(chatID)
        }
        if let diffCount, diffCount > 0 {
            parts.append("\(diffCount) \(diffCount == 1 ? "diff" : "diffs")")
        }
        if parts.isEmpty,
           let errorCount = intValue(object, keys: ["error_count", "errorCount"]),
           errorCount > 0
        {
            parts.append("\(errorCount) \(errorCount == 1 ? "error" : "errors")")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " • ")
    }

    private static func normalizedAgentRunStatusWord(_ raw: String?) -> String? {
        guard let normalized = AgentTranscriptToolStatusSemantics.normalizedStatusWord(raw) else {
            return nil
        }
        switch normalized {
        case "success":
            return "completed"
        case "running", "waiting_for_input", "completed", "failed", "cancelled", "expired":
            return normalized
        default:
            return nil
        }
    }

    private static func transcriptStatusForAgentRunStatusWord(_ statusWord: String) -> AgentTranscriptToolStatus {
        switch statusWord {
        case "running":
            .running
        case "waiting_for_input":
            .warning
        case "completed":
            .success
        case "failed":
            .failed
        case "cancelled":
            .cancelled
        case "expired":
            .warning
        default:
            .unknown
        }
    }

    private static func isTerminalAgentRunStatusWord(_ statusWord: String) -> Bool {
        switch statusWord {
        case "completed", "failed", "cancelled", "expired":
            true
        default:
            false
        }
    }

    private static func smallStringValue(_ object: [String: Any]?, keys: [String]) -> String? {
        guard let value = stringValue(object, keys: keys)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.count <= 240
        else {
            return nil
        }
        return value
    }

    private static let bashProcessIDRegex = try! NSRegularExpression(
        pattern: #"process\s+running\s+with\s+session\s+id\s+([^\s]+)"#,
        options: [.caseInsensitive]
    )
    private static let bashExitCodeRegex = try! NSRegularExpression(
        pattern: #"process\s+completed\s+with\s+exit\s+code\s+(-?[0-9]+)"#,
        options: [.caseInsensitive]
    )

    private static func bashTextProcessID(from raw: String?, context: AgentToolResultProcessingContext? = nil) -> String? {
        captureFirstGroup(
            in: raw,
            regex: bashProcessIDRegex,
            context: context
        )
    }

    private static func bashTextExitCode(from raw: String?, context: AgentToolResultProcessingContext? = nil) -> Int? {
        guard let captured = captureFirstGroup(
            in: raw,
            regex: bashExitCodeRegex,
            context: context
        ) else {
            return nil
        }
        return Int(captured)
    }

    private static func bashTextStatus(from raw: String?, context: AgentToolResultProcessingContext? = nil) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        let lowered = raw.lowercased()
        if lowered.contains("process running with session id")
            || lowered.contains("\"status\":\"running\"")
            || lowered.contains("\"status\": \"running\"")
        {
            return "running"
        }
        if let exitCode = bashTextExitCode(from: raw, context: context) {
            return exitCode == 0 ? "success" : "failed"
        }
        if lowered.contains("stdin is closed for this session") {
            return "failed"
        }
        return nil
    }

    private static func captureFirstGroup(
        in text: String?,
        regex: NSRegularExpression,
        context: AgentToolResultProcessingContext?
    ) -> String? {
        context?.recordRegexCapture()
        guard let text, !text.isEmpty else {
            return nil
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1
        else {
            return nil
        }
        let groupRange = match.range(at: 1)
        guard groupRange.location != NSNotFound,
              let swiftRange = Range(groupRange, in: text)
        else {
            return nil
        }
        let captured = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return captured.isEmpty ? nil : captured
    }

    private static func jsonObject(from raw: String?, context: AgentToolResultProcessingContext? = nil) -> [String: Any]? {
        if let context {
            return context.jsonObject(from: raw)
        }
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    private static func jsonString(from object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    private static func stringValue(_ object: [String: Any]?, keys: [String]) -> String? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? String {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.stringValue
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
