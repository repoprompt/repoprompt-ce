import Foundation

/// App transcript projection stays outside the provider controller and its transport state.
extension CodexNativeSessionController {
    struct CommandExecutionRunningItemIndex {
        var indexByInvocationID: [UUID: Int] = [:]
        var indexByProcessID: [String: Int] = [:]
        var lastBashIndex: Int?

        init(items: [AgentChatItem]) {
            rebuild(from: items)
        }

        mutating func rebuild(from items: [AgentChatItem]) {
            indexByInvocationID.removeAll(keepingCapacity: true)
            indexByProcessID.removeAll(keepingCapacity: true)
            lastBashIndex = nil
            for index in items.indices {
                let item = items[index]
                guard CodexNativeSessionController.normalizedExternalToolName(item.toolName) == "bash" else { continue }
                if let invocationID = item.toolInvocationID {
                    indexByInvocationID[invocationID] = index
                }
                if let processID = CodexNativeSessionController.commandExecutionProcessID(from: item.toolResultJSON) {
                    indexByProcessID[processID] = index
                }
                lastBashIndex = index
            }
        }

        mutating func applyMutation(
            oldItem: AgentChatItem,
            newItem: AgentChatItem,
            at index: Int
        ) {
            if let oldInvocationID = oldItem.toolInvocationID, indexByInvocationID[oldInvocationID] == index {
                indexByInvocationID.removeValue(forKey: oldInvocationID)
            }
            if let oldProcessID = CodexNativeSessionController.commandExecutionProcessID(from: oldItem.toolResultJSON),
               indexByProcessID[oldProcessID] == index
            {
                indexByProcessID.removeValue(forKey: oldProcessID)
            }

            guard CodexNativeSessionController.normalizedExternalToolName(newItem.toolName) == "bash" else {
                if lastBashIndex == index {
                    lastBashIndex = nil
                }
                return
            }
            if let invocationID = newItem.toolInvocationID {
                indexByInvocationID[invocationID] = index
            }
            if let processID = CodexNativeSessionController.commandExecutionProcessID(from: newItem.toolResultJSON) {
                indexByProcessID[processID] = index
            }
            if let lastBashIndex {
                if index > lastBashIndex {
                    self.lastBashIndex = index
                }
            } else {
                lastBashIndex = index
            }
        }
    }

    static func applyCommandExecutionRunningUpdate(
        _ update: CommandExecutionRunningUpdate,
        to items: inout [AgentChatItem]
    ) -> Bool {
        var index: CommandExecutionRunningItemIndex? = nil
        return applyCommandExecutionRunningUpdate(update, to: &items, index: &index)
    }

    static func applyCommandExecutionRunningUpdates(
        _ updates: [CommandExecutionRunningUpdate],
        to items: inout [AgentChatItem]
    ) -> Int {
        guard !updates.isEmpty else { return 0 }
        var index: CommandExecutionRunningItemIndex? = nil
        var appliedCount = 0
        for update in updates {
            if applyCommandExecutionRunningUpdate(update, to: &items, index: &index) {
                appliedCount &+= 1
            }
        }
        return appliedCount
    }

    static func applyCommandExecutionRunningUpdate(
        _ update: CommandExecutionRunningUpdate,
        to items: inout [AgentChatItem],
        index: inout CommandExecutionRunningItemIndex?
    ) -> Bool {
        if index == nil {
            index = CommandExecutionRunningItemIndex(items: items)
        }
        let target = commandExecutionRunningTarget(update: update, items: items, index: &index)

        guard let target else {
            logCodexDebug("[CodexNativeController] runningUpdateMiss invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil") outputChars=\(update.appendedOutput?.count ?? 0) bashCount=\(items.count(where: { normalizedExternalToolName($0.toolName) == "bash" }))")
            return false
        }
        let targetIndex = target.index
        let oldItem = items[targetIndex]
        var item = oldItem
        var didChange = false

        if item.toolIsError != true,
           commandExecutionResultIndicatesTerminal(raw: item.toolResultJSON)
        {
            logCodexDebug("[CodexNativeController] runningUpdateIgnored reason=terminal targetIndex=\(targetIndex) match=\(target.reason) invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil")")
            return false
        }

        if item.kind == .toolCall {
            item.kind = .toolResult
            didChange = true
        }
        if item.toolIsError != false {
            item.toolIsError = false
            didChange = true
        }

        if shouldPatchCommandExecutionRunningPayload(
            raw: item.toolResultJSON,
            processID: update.processID,
            appendOutput: update.appendedOutput
        ) {
            let patched = withCommandExecutionRunningStatus(
                raw: item.toolResultJSON,
                processID: update.processID,
                appendOutput: update.appendedOutput
            )
            if patched != item.toolResultJSON {
                item.toolResultJSON = patched
                didChange = true
            }
        }

        guard didChange else { return false }
        items[targetIndex] = item
        index?.applyMutation(oldItem: oldItem, newItem: item, at: targetIndex)
        logCodexDebug("[CodexNativeController] runningUpdateApplied match=\(target.reason) targetIndex=\(targetIndex) invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil") outputChars=\(update.appendedOutput?.count ?? 0)")
        return true
    }

    static func matchingBashToolResultIndex(
        in items: [AgentChatItem],
        toolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        resultJSON: String
    ) -> Int? {
        guard normalizedExternalToolName(toolName) == "bash" else { return nil }

        var metadataCacheByItemID: [UUID: BashToolResultParser.Metadata] = [:]
        func metadata(_ item: AgentChatItem) -> BashToolResultParser.Metadata {
            if let cached = metadataCacheByItemID[item.id] {
                return cached
            }
            let parsed = BashToolResultParser.parseMetadata(raw: item.toolResultJSON)
            metadataCacheByItemID[item.id] = parsed
            return parsed
        }

        var parseCacheByItemID: [UUID: BashToolResultParser.ParsedResult] = [:]
        func parsed(_ item: AgentChatItem) -> BashToolResultParser.ParsedResult {
            if let cached = parseCacheByItemID[item.id] {
                return cached
            }
            let parsed = BashToolResultParser.parse(raw: item.toolResultJSON, argsJSON: item.toolArgsJSON)
            parseCacheByItemID[item.id] = parsed
            return parsed
        }

        func isRunningBash(_ item: AgentChatItem) -> Bool {
            guard item.kind == .toolResult else { return false }
            guard normalizedExternalToolName(item.toolName) == "bash" else { return false }
            return metadata(item).isRunning
        }

        if let invocationID,
           let index = items.lastIndex(where: {
               $0.toolInvocationID == invocationID && isRunningBash($0)
           })
        {
            return index
        }

        let incomingMetadata = BashToolResultParser.parseMetadata(raw: resultJSON)
        let incomingProcessID = incomingMetadata.processID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingArgs = argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
        var incomingParsedResult: BashToolResultParser.ParsedResult?
        func incomingCommand() -> String? {
            if incomingParsedResult == nil {
                incomingParsedResult = BashToolResultParser.parse(raw: resultJSON, argsJSON: argsJSON)
            }
            let command = incomingParsedResult?.command?.trimmingCharacters(in: .whitespacesAndNewlines)
            return command?.isEmpty == false ? command : nil
        }

        if let incomingProcessID, !incomingProcessID.isEmpty,
           let index = items.lastIndex(where: { item in
               guard isRunningBash(item) else { return false }
               let existingProcessID = metadata(item).processID?.trimmingCharacters(in: .whitespacesAndNewlines)
               return existingProcessID == incomingProcessID
           })
        {
            return index
        }

        if let incomingArgs, !incomingArgs.isEmpty,
           let index = items.lastIndex(where: { item in
               guard isRunningBash(item) else { return false }
               let existingArgs = item.toolArgsJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
               return existingArgs == incomingArgs
           })
        {
            return index
        }

        if let incomingCommand = incomingCommand(), !incomingCommand.isEmpty,
           let index = items.lastIndex(where: { item in
               guard isRunningBash(item) else { return false }
               let existingCommand = parsed(item).command?.trimmingCharacters(in: .whitespacesAndNewlines)
               return existingCommand == incomingCommand
           })
        {
            return index
        }

        let runningBashIndexes = items.indices.filter { isRunningBash(items[$0]) }
        if runningBashIndexes.count == 1 {
            return runningBashIndexes[0]
        }
        return nil
    }

    private static func commandExecutionRunningTarget(
        update: CommandExecutionRunningUpdate,
        items: [AgentChatItem],
        index: inout CommandExecutionRunningItemIndex?
    ) -> (index: Int, reason: String)? {
        if let invocationID = update.invocationID,
           let byInvocation = index?.indexByInvocationID[invocationID],
           isBashItem(at: byInvocation, in: items)
        {
            return (byInvocation, "invocation-index")
        }
        if let processID = update.processID,
           let byProcess = index?.indexByProcessID[processID],
           isBashItem(at: byProcess, in: items)
        {
            return (byProcess, "process-index")
        }
        let fallbackRequiresCorrelation = update.invocationID != nil || (update.processID?.isEmpty == false)
        if let uniqueFallback = uniqueFallbackEligibleBashIndex(
            in: items,
            requireCorrelationForErroredItem: fallbackRequiresCorrelation
        ) {
            return (uniqueFallback, "single-bash-index")
        }

        let scannedTarget: (index: Int, reason: String)? = {
            if let invocationID = update.invocationID,
               let byInvocation = items.lastIndex(where: {
                   $0.toolInvocationID == invocationID && normalizedExternalToolName($0.toolName) == "bash"
               })
            {
                return (byInvocation, "invocation-scan")
            }
            if let processID = update.processID,
               let byProcess = items.lastIndex(where: { item in
                   normalizedExternalToolName(item.toolName) == "bash"
                       && commandExecutionProcessID(from: item.toolResultJSON) == processID
               })
            {
                return (byProcess, "process-scan")
            }
            if let uniqueFallback = uniqueFallbackEligibleBashIndex(
                in: items,
                requireCorrelationForErroredItem: fallbackRequiresCorrelation
            ) {
                return (uniqueFallback, "single-bash-scan")
            }
            return nil
        }()
        if scannedTarget != nil {
            index = CommandExecutionRunningItemIndex(items: items)
        }
        return scannedTarget
    }

    private static func isBashItem(at index: Int, in items: [AgentChatItem]) -> Bool {
        guard items.indices.contains(index) else { return false }
        return normalizedExternalToolName(items[index].toolName) == "bash"
    }

    private static func isFallbackEligibleBashItem(
        at index: Int,
        in items: [AgentChatItem],
        requireCorrelationForErroredItem: Bool
    ) -> Bool {
        guard isBashItem(at: index, in: items) else { return false }
        let item = items[index]
        if item.toolIsError == true {
            return requireCorrelationForErroredItem
        }
        return !commandExecutionResultIndicatesTerminal(raw: item.toolResultJSON)
    }

    private static func uniqueFallbackEligibleBashIndex(
        in items: [AgentChatItem],
        requireCorrelationForErroredItem: Bool
    ) -> Int? {
        var resolvedIndex: Int?
        for index in items.indices where isFallbackEligibleBashItem(
            at: index,
            in: items,
            requireCorrelationForErroredItem: requireCorrelationForErroredItem
        ) {
            if resolvedIndex != nil {
                return nil
            }
            resolvedIndex = index
        }
        return resolvedIndex
    }

    static func reconcilePersistedCommandExecutionStatuses(
        in items: inout [AgentChatItem],
        rolloutPath: String
    ) -> Bool {
        let trimmedPath = rolloutPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return false }
        let candidateIndices = items.indices.filter { index in
            let item = items[index]
            guard item.kind == .toolResult else { return false }
            guard normalizedExternalToolName(item.toolName) == "bash" else { return false }
            let processID = commandExecutionProcessID(from: item.toolResultJSON)
            let callID = commandExecutionCallID(from: item.toolResultJSON)
            guard processID != nil || callID != nil else {
                return false
            }
            let processIDLooksSessionScoped = processID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("session:") == true
            guard item.toolIsError == true || processIDLooksSessionScoped else {
                return false
            }
            if item.toolIsError == true {
                return true
            }
            return !commandExecutionResultIndicatesRunning(raw: item.toolResultJSON)
        }
        guard !candidateIndices.isEmpty else { return false }

        let signals = loadPersistedCommandSignals(fromRolloutPath: trimmedPath)
        guard !signals.runningProcessIDs.isEmpty
            || !signals.runningCallIDs.isEmpty
        else { return false }

        var didChange = false
        for index in candidateIndices {
            var item = items[index]
            let processID = commandExecutionProcessID(from: item.toolResultJSON)
            let processSignalKeys = canonicalCommandProcessIDs(for: processID)
            let callID = commandExecutionCallID(from: item.toolResultJSON)
            let recoveredOutput =
                (callID.flatMap { signals.outputByCallID[$0] })
                    ?? processSignalKeys.lazy.compactMap { signals.outputByProcessID[$0] }.first
            let hasTerminalSignal =
                processSignalKeys.contains(where: { signals.terminalProcessIDs.contains($0) })
                    || (callID.map { signals.terminalCallIDs.contains($0) } ?? false)
            guard !hasTerminalSignal else { continue }

            let shouldPatch =
                processSignalKeys.contains(where: { signals.runningProcessIDs.contains($0) })
                    || (callID.map { signals.runningCallIDs.contains($0) } ?? false)
            guard shouldPatch else { continue }

            if item.toolIsError != false {
                item.toolIsError = false
                didChange = true
            }
            let patched = withCommandExecutionRunningStatus(
                raw: item.toolResultJSON,
                processID: processID,
                appendOutput: recoveredOutput
            )
            if patched != item.toolResultJSON {
                item.toolResultJSON = patched
                didChange = true
            }
            items[index] = item
        }
        return didChange
    }
}
