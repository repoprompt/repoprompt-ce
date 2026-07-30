import Foundation

extension PromptViewModel {
    @MainActor
    private func effectiveCodeMapUsageForChatPromptEntries() -> CodeMapUsage {
        let chatPreset = currentChatPreset()
        let context = resolvedPromptContext(from: chatPreset) ?? resolvePromptContext()
        return context.codeMapUsage
    }

    @MainActor
    func hasPromptSnapshotEntriesForChat() -> Bool {
        let selectionCount = fileManager.selectedFiles.count
        let codeMapUsage = effectiveCodeMapUsageForChatPromptEntries()
        let presentation = tokenCountingViewModel.codemapPresentation

        switch codeMapUsage {
        case .none, .selected:
            return selectionCount > 0
        case .auto, .complete:
            return selectionCount > 0 || !presentation.orderedEntries.isEmpty
        }
    }

    @MainActor
    func promptSnapshotEntriesForChatCached() -> [PromptFileEntry] {
        let codeMapUsage = effectiveCodeMapUsageForChatPromptEntries()
        let key = ChatPromptEntriesCacheKey(
            codeMapUsage: codeMapUsage,
            selectionVersion: chatSelectionVersion,
            slicesVersion: chatSlicesVersion,
            autoCodemapVersion: chatAutoCodemapVersion,
            codemapAuthorityVersion: chatCodemapAuthorityVersion
        )

        if let cache = chatPromptEntriesCache, cache.key == key {
            return cache.entries
        }

        let entries = buildPromptSnapshotEntriesForCurrentChatProjection(codeMapUsage: codeMapUsage)
        chatPromptEntriesCache = (key: key, entries: entries)
        return entries
    }

    @MainActor
    private func buildPromptSnapshotEntriesForCurrentChatProjection(codeMapUsage: CodeMapUsage) -> [PromptFileEntry] {
        let selectedFiles = fileManager.selectedFiles
        let selectedIDs = Set(selectedFiles.map(\.id))
        let presentation = tokenCountingViewModel.codemapPresentation
        var entries: [PromptFileEntry] = selectedFiles.map { file in
            PromptFileEntry(
                file: file,
                codemap: nil,
                ranges: fileManager.selectionSlicesByFileID[file.id]
            )
        }

        let codemapFiles = fileManager.codemapAutoEnabled
            ? fileManager.autoCodemapFiles
            : fileManager.manualCodemapFiles
        for file in codemapFiles where !selectedIDs.contains(file.id) {
            guard let codemap = presentation.entriesByFileID[file.id] else { continue }
            entries.append(PromptFileEntry(file: file, codemap: codemap, ranges: nil))
        }

        switch codeMapUsage {
        case .none:
            entries.removeAll { $0.isCodemap }
        case .auto:
            break
        case .selected:
            entries = entries.compactMap { entry in
                guard selectedIDs.contains(entry.file.id) else { return nil }
                let codemap = presentation.entriesByFileID[entry.file.id]
                return PromptFileEntry(
                    file: entry.file,
                    codemap: codemap,
                    ranges: codemap == nil ? entry.ranges : nil
                )
            }
        case .complete:
            for codemap in presentation.orderedEntries {
                guard !selectedIDs.contains(codemap.fileID),
                      let file = fileManager.fileViewModel(id: codemap.fileID)
                else { continue }
                entries.append(PromptFileEntry(file: file, codemap: codemap, ranges: nil))
            }
        }

        return entries
    }

    @MainActor
    func promptSnapshotEntriesForChat() -> [PromptFileEntry] {
        promptSnapshotEntriesForChatCached()
    }
}
