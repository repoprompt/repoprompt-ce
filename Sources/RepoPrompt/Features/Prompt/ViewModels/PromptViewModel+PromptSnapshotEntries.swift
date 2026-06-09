import Foundation

extension PromptViewModel {
    @MainActor
    private func effectiveCodeMapUsageForChatPromptEntries() -> CodeMapUsage {
        let chatPreset = currentChatPreset()
        let context = resolvedPromptContext(from: chatPreset) ?? resolvePromptContext()
        return context.codeMapUsage
    }

    @MainActor
    private func chatPromptEntriesRequest() -> (
        key: ChatPromptEntriesCacheKey,
        selection: StoredSelection,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay
    ) {
        let selection = activeComposeTabStoredSelectionForPromptProjection()
        let codeMapUsage = effectiveCodeMapUsageForChatPromptEntries()
        let filePathDisplay = filePathDisplayOption
        let key = ChatPromptEntriesCacheKey(
            selection: selection,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay,
            selectionVersion: chatSelectionVersion,
            slicesVersion: chatSlicesVersion,
            autoCodemapVersion: chatAutoCodemapVersion,
            fileAPIsVersion: chatFileAPIsVersion
        )
        return (key, selection, codeMapUsage, filePathDisplay)
    }

    @MainActor
    func hasPromptSnapshotEntriesForChat() -> Bool {
        !promptSnapshotEntriesForChatCached().isEmpty
    }

    @MainActor
    func promptSnapshotEntriesForChatCached() -> [PromptFileEntry] {
        let request = chatPromptEntriesRequest()
        if let cache = chatPromptEntriesCache, cache.key == request.key {
            return cache.entries
        }

        refreshPromptSnapshotEntriesForChatIfNeeded(request)
        return []
    }

    @MainActor
    private func refreshPromptSnapshotEntriesForChatIfNeeded(
        _ request: (
            key: ChatPromptEntriesCacheKey,
            selection: StoredSelection,
            codeMapUsage: CodeMapUsage,
            filePathDisplay: FilePathDisplay
        )
    ) {
        guard chatPromptEntriesProjectionKey != request.key else { return }

        chatPromptEntriesProjectionGeneration &+= 1
        let generation = chatPromptEntriesProjectionGeneration
        chatPromptEntriesProjectionTask?.cancel()
        chatPromptEntriesProjectionKey = request.key

        let adapter = WorkspacePromptProjectionAdapter(store: workspaceFileContextStore)
        chatPromptEntriesProjectionTask = Task { [weak self] in
            do {
                let projection = try await adapter.project(
                    selection: request.selection,
                    codeMapUsage: request.codeMapUsage,
                    filePathDisplay: request.filePathDisplay
                )
                try Task.checkCancellation()
                guard let self,
                      chatPromptEntriesProjectionGeneration == generation,
                      chatPromptEntriesProjectionKey == request.key,
                      chatPromptEntriesRequest().key == request.key
                else { return }

                let entries = adapter.mapToLivePromptEntries(projection) { projectedFile in
                    self.fileManager.findFileByFullPath(projectedFile.standardizedFullPath)
                }
                objectWillChange.send()
                chatPromptEntriesCache = (
                    key: request.key,
                    projection: projection,
                    entries: entries
                )
                chatPromptEntriesProjectionTask = nil
                chatPromptEntriesProjectionKey = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      chatPromptEntriesProjectionGeneration == generation,
                      chatPromptEntriesProjectionKey == request.key
                else { return }
                chatPromptEntriesProjectionTask = nil
                chatPromptEntriesProjectionKey = nil
            }
        }
    }

    @MainActor
    func promptSnapshotEntriesForChat() -> [PromptFileEntry] {
        promptSnapshotEntriesForChatCached()
    }
}
